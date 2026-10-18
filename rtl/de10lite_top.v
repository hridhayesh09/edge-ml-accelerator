// de10lite_top.v
// Board wrapper for the Terasic DE10-Lite (Intel MAX 10, 10M50DAF484C7G).
//
// Wiring (USB-to-serial bridge, 3.3 V logic):
//   bridge TX  -> ARDUINO_IO[0]  (FPGA receives, "IO0" on the board)
//   bridge RX  <- ARDUINO_IO[1]  (FPGA transmits, "IO1")
//   bridge GND -> any GND pin on the header
//   do NOT connect the bridge's VCC / 5V pin
//
// Controls and lights:
//   KEY[0]   reset (press to reset)
//   KEY[1]   standalone demo: classify (see below)
//   LEDR[0]  heartbeat (blinks about once per second: the design is running)
//   LEDR[1]  byte received        LEDR[2]  byte sent
//   LEDR[3]  array busy computing LEDR[4]  demo running
//   LEDR[5]  last demo image right   LEDR[6]  last demo image wrong
//   LEDR[7]  run-all finished
//   LEDR[9]  error seen (bad UART frame, unknown command, or RX overflow);
//            stays on until reset
//
// Standalone demo (no laptop needed; about 100 MNIST test images are stored
// on the chip, see demo.v):
//   SW9 down: SW6..SW0 pick an image. HEX5-4 show its number. Press KEY1:
//             HEX2 = true digit, HEX0 = the board's prediction.
//   SW9 up:   press KEY1 to classify every stored image.
//             SW8 down: HEX5-3 = how many were right, HEX2-0 = how many images
//             SW8 up:   HEX5-0 = how long the whole run took, in microseconds
//   Before the demo is used, HEX1-0 count the RUN commands from the laptop.

module de10lite_top #(
    parameter CLK_HZ = 50_000_000,
    parameter BAUD   = 2_000_000,
    parameter N      = 16,          // array size: N x N processing elements
    parameter MAX_IMG = 32,         // images per INFER batch (block RAM is the limit at 16x16)
    parameter DEBOUNCE = 20,        // KEY1 sampled every 2^DEBOUNCE clocks (~21 ms)
    parameter USE_PROBE = 1,        // JTAG trigger/readout for the demo (0 in simulation)
    parameter MODEL_DIR = "../rtl/model/"   // MNIST weight files (relative to quartus/)
) (
    input  wire        MAX10_CLK1_50,
    input  wire [1:0]  KEY,
    input  wire [9:0]  SW,
    output wire [9:0]  LEDR,
    output wire [7:0]  HEX0,
    output wire [7:0]  HEX1,
    output wire [7:0]  HEX2,
    output wire [7:0]  HEX3,
    output wire [7:0]  HEX4,
    output wire [7:0]  HEX5,
    inout  wire [15:0] ARDUINO_IO
);
    localparam CLKS_PER_BIT = (CLK_HZ + BAUD / 2) / BAUD;   // 25 at 2 Mbaud (exact)

    wire clk = MAX10_CLK1_50;

    // ------------------------------------------------------------------
    // Reset: hold for 16 cycles at power-up, and while KEY[0] is pressed.
    // KEY is asynchronous to the clock, so synchronize it first.
    // ------------------------------------------------------------------
    reg [1:0] key_sync = 2'b11;
    reg [3:0] por_cnt  = 4'd0;
    reg       rst      = 1'b1;
    always @(posedge clk) begin
        key_sync <= {key_sync[0], KEY[0]};
        if (por_cnt != 4'hF) por_cnt <= por_cnt + 1'b1;
        rst <= (por_cnt != 4'hF) || !key_sync[1];
    end

    // KEY1: synchronize, then sample slowly so contact bounce is ignored
    reg [1:0]          k1_sync = 2'b11;
    reg [DEBOUNCE-1:0] k1_div  = 0;
    reg                k1_q = 1'b1, k1_prev = 1'b1;
    always @(posedge clk) begin
        k1_sync <= {k1_sync[0], KEY[1]};
        k1_div  <= k1_div + 1'b1;
        if (k1_div == 0) begin
            k1_prev <= k1_q;
            k1_q    <= k1_sync[1];
        end
    end
    wire k1_press = (k1_div == 1) && k1_prev && !k1_q;     // one pulse per press

    // The demo can also be started over the USB-Blaster cable (JTAG), so it
    // can be run and read back without touching the board (host/demo_jtag.py).
    // jtag_src = {select[6:0], start_one, start_all}; a rising edge starts.
    wire [8:0] jtag_src;
    reg  [1:0] js_meta = 0, js_sync = 0, js_prev = 0;
    always @(posedge clk) begin
        js_meta <= jtag_src[1:0];
        js_sync <= js_meta;
        js_prev <= js_sync;
    end
    wire jtag_all = js_sync[0] && !js_prev[0];
    wire jtag_one = js_sync[1] && !js_prev[1];

    // ------------------------------------------------------------------
    // Accelerator + standalone demo
    // ------------------------------------------------------------------
    wire       uart_tx;
    wire       busy, rx_pulse, tx_pulse, err_pulse;
    wire       core_free, demo_active, demo_empty, demo_rd, demo_reply_wr;
    wire [7:0] demo_data, reply_data;

    accel_top #(
        .CLKS_PER_BIT(CLKS_PER_BIT),
        .N(N),
        .MAX_M(256),
        .MAX_IMG(MAX_IMG),
        .MODEL_DIR(MODEL_DIR)
    ) u_accel (
        .clk(clk), .rst(rst),
        .uart_rx(ARDUINO_IO[0]),
        .uart_tx(uart_tx),
        .busy(busy), .rx_pulse(rx_pulse), .tx_pulse(tx_pulse), .err_pulse(err_pulse),
        .core_free(core_free), .demo_active(demo_active), .demo_empty(demo_empty),
        .demo_data(demo_data), .demo_rd(demo_rd),
        .reply_data(reply_data), .demo_reply_wr(demo_reply_wr)
    );

    wire [6:0]  d_count, d_idx;
    wire [3:0]  d_label, d_pred;
    wire        d_valid, d_done;
    wire [7:0]  d_correct, d_total;
    wire [19:0] d_us;
    wire [31:0] d_cycles;

    demo #(.BATCH(MAX_IMG), .CLK_MHZ(CLK_HZ / 1_000_000), .MODEL_DIR(MODEL_DIR)) u_demo (
        .clk(clk), .rst(rst),
        .start_one((k1_press && !SW[9]) || jtag_one), .start_all((k1_press && SW[9]) || jtag_all),
        .sel(jtag_one ? jtag_src[8:2] : SW[6:0]),
        .core_idle(core_free),
        .active(demo_active), .empty(demo_empty), .data(demo_data), .rd(demo_rd),
        .tx_data(reply_data), .tx_wr(demo_reply_wr),
        .count(d_count), .shown_idx(d_idx), .shown_label(d_label), .shown_pred(d_pred),
        .shown_valid(d_valid), .n_correct(d_correct), .n_total(d_total),
        .run_us(d_us), .run_cycles(d_cycles), .all_done(d_done)
    );

    assign ARDUINO_IO[0]    = 1'bz;      // input
    assign ARDUINO_IO[1]    = uart_tx;   // output
    assign ARDUINO_IO[15:2] = 14'bz;     // unused

    // ------------------------------------------------------------------
    // LEDs
    // ------------------------------------------------------------------
    reg [25:0] hb = 0;
    always @(posedge clk) hb <= hb + 1'b1;

    // Stretch 1-cycle pulses to ~20 ms so they are visible
    reg [19:0] rx_led = 0, tx_led = 0;
    reg        err_led = 0;
    always @(posedge clk) begin
        rx_led <= rx_pulse ? 20'hFFFFF : (rx_led != 0 ? rx_led - 1'b1 : 20'd0);
        tx_led <= tx_pulse ? 20'hFFFFF : (tx_led != 0 ? tx_led - 1'b1 : 20'd0);
        if (rst)            err_led <= 1'b0;
        else if (err_pulse) err_led <= 1'b1;
    end

    // Count finished runs: busy falling edge (laptop RUN commands)
    reg       busy_d = 0;
    reg [7:0] runs   = 0;
    always @(posedge clk) begin
        busy_d <= busy;
        if (rst)                                  runs <= 0;
        else if (busy_d && !busy && !demo_active) runs <= runs + 1'b1;
    end

    wire single_right = d_valid && (d_pred == d_label);

    assign LEDR[0] = hb[25];
    assign LEDR[1] = rx_led != 0;
    assign LEDR[2] = tx_led != 0;
    assign LEDR[3] = busy;
    assign LEDR[4] = demo_active;
    assign LEDR[5] = d_valid &&  single_right;
    assign LEDR[6] = d_valid && !single_right;
    assign LEDR[7] = d_done;
    assign LEDR[8] = 1'b0;
    assign LEDR[9] = err_led;

    // ------------------------------------------------------------------
    // 7-segment displays
    // ------------------------------------------------------------------
    localparam [4:0] BLANK = 5'd16, DASH = 5'd17;

    // microseconds -> 6 decimal digits (shift-and-add-3, one bit per clock,
    // re-run continuously so the display follows the value)
    wire [23:0] us_bcd;
    bin2bcd #(.BITS(20), .DIGITS(6)) u_bcd (.clk(clk), .bin(d_us), .bcd(us_bcd));

    wire [6:0] sel  = (SW[6:0] < d_count) ? SW[6:0] : d_count - 1'b1;
    wire       used = d_valid || d_done || demo_active;

    reg [4:0] d5, d4, d3, d2, d1, d0;
    always @(*) begin
        {d5, d4, d3, d2, d1, d0} = {6{BLANK}};
        if (!used && !SW[9]) begin                     // laptop mode: RUN counter
            d1 = {1'b0, runs[7:4]};
            d0 = {1'b0, runs[3:0]};
            d5 = sel / 10;  d4 = sel % 10;               // selected demo image
        end else if (!SW[9]) begin                     // one image
            d5 = sel / 10;  d4 = sel % 10;
            if (d_valid && d_idx == sel) begin
                d2 = {1'b0, d_label};
                d0 = {1'b0, d_pred};
            end else begin
                d2 = DASH;  d0 = DASH;
            end
        end else if (!d_done) begin                    // run-all: not finished yet
            {d5, d4, d3, d2, d1, d0} = {6{DASH}};
        end else if (!SW[8]) begin                     // run-all: right / total
            d5 = d_correct / 100;  d4 = (d_correct / 10) % 10;  d3 = d_correct % 10;
            d2 = d_total / 100;    d1 = (d_total / 10) % 10;    d0 = d_total % 10;
        end else begin                                 // run-all: microseconds
            d5 = {1'b0, us_bcd[23:20]};  d4 = {1'b0, us_bcd[19:16]};
            d3 = {1'b0, us_bcd[15:12]};  d2 = {1'b0, us_bcd[11:8]};
            d1 = {1'b0, us_bcd[7:4]};    d0 = {1'b0, us_bcd[3:0]};
        end
    end

    seg7 u_h0 (.code(d0), .seg(HEX0));
    seg7 u_h1 (.code(d1), .seg(HEX1));
    seg7 u_h2 (.code(d2), .seg(HEX2));
    seg7 u_h3 (.code(d3), .seg(HEX3));
    seg7 u_h4 (.code(d4), .seg(HEX4));
    seg7 u_h5 (.code(d5), .seg(HEX5));

    // JTAG readout of the demo results (In-System Sources and Probes)
    generate
        if (USE_PROBE) begin : g_probe
            altsource_probe #(
                .sld_auto_instance_index("YES"),
                .sld_instance_index(0),
                .instance_id("DEMO"),
                .probe_width(86),
                .source_width(9),
                .source_initial_value("0"),
                .enable_metastability("NO")
            ) u_probe (
                .probe({d_cycles, d_us, d_total, d_correct, d_done, d_valid, d_pred, d_label, d_idx, demo_active}),
                .source(jtag_src)
            );
        end else begin : g_no_probe
            assign jtag_src = 9'd0;
        end
    endgenerate

    wire _unused = &{1'b0, SW[7]};
endmodule

// Seven-segment decoder. DE10-Lite segments are active low; bit 7 is the dot.
// Codes 0-15 are hex digits, 16 = blank, 17 = dash.
module seg7 (
    input  wire [4:0] code,
    output reg  [7:0] seg
);
    always @(*) begin
        case (code)
            5'h00: seg = 8'b11000000;
            5'h01: seg = 8'b11111001;
            5'h02: seg = 8'b10100100;
            5'h03: seg = 8'b10110000;
            5'h04: seg = 8'b10011001;
            5'h05: seg = 8'b10010010;
            5'h06: seg = 8'b10000010;
            5'h07: seg = 8'b11111000;
            5'h08: seg = 8'b10000000;
            5'h09: seg = 8'b10010000;
            5'h0A: seg = 8'b10001000;
            5'h0B: seg = 8'b10000011;
            5'h0C: seg = 8'b11000110;
            5'h0D: seg = 8'b10100001;
            5'h0E: seg = 8'b10000110;
            5'h0F: seg = 8'b10001110;
            5'h11: seg = 8'b10111111;   // dash
            default: seg = 8'b11111111; // blank
        endcase
    end
endmodule

// Binary to decimal (BCD) by "shift and add 3", one bit per clock. It
// re-starts on its own, so bcd follows bin within BITS+1 clocks.
module bin2bcd #(
    parameter BITS   = 20,
    parameter DIGITS = 6
) (
    input  wire                clk,
    input  wire [BITS-1:0]     bin,
    output reg  [4*DIGITS-1:0] bcd = 0
);
    reg [BITS-1:0]     sh  = 0;
    reg [4*DIGITS-1:0] acc = 0;
    reg [$clog2(BITS+1)-1:0] n = 0;
    integer i;
    reg [4*DIGITS-1:0] adj;
    always @(*) begin
        adj = acc;
        for (i = 0; i < DIGITS; i = i + 1)
            if (adj[4*i +: 4] >= 5) adj[4*i +: 4] = adj[4*i +: 4] + 4'd3;
    end
    always @(posedge clk) begin
        if (n == 0) begin
            sh  <= bin;
            acc <= 0;
            n   <= BITS;
        end else begin
            {acc, sh} <= {adj[4*DIGITS-2:0], sh, 1'b0};
            n <= n - 1'b1;
            if (n == 1) bcd <= {adj[4*DIGITS-2:0], sh[BITS-1]};
        end
    end
endmodule
