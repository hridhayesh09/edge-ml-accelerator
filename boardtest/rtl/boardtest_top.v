// boardtest_top.v
// DE10-Lite board self-test. Checks every part of the board a used board
// could have broken, one display "mode" at a time.
//
//   KEY0 (hold)  lamp test: every LED, segment and decimal point on
//   KEY1 (press) next mode
//   SW9..SW0     always shown on LEDR9..LEDR0 (switch + LED test)
//   VGA          color bars + color ramps, always on
//   Arduino D0/D1  UART echo at 115200 baud (modes 0-2): every byte sent comes back
//   SDRAM        tested continuously in the background from power-up
//
//   Mode 0  display test: all six digits count 0..F together
//   Mode 1  accelerometer: HEX5-4 = chip ID (must be E5),
//           HEX3-2 = X tilt, HEX1-0 = Y tilt (00 when flat, changes when tilted)
//   Mode 2  SDRAM: HEX5-4 = progress (00..FF), HEX3-0 = passes completed;
//           dot on HEX4 = write phase. Any error: shows "Err" + error count
//   Mode 3  pin scan: every Arduino and GPIO pin is an input with a pull-up.
//           Touch a jumper from a GND pin to a header pin; the display shows
//           which pin it saw ("A 07" = Arduino D7, "G 12" = GPIO 12) and
//           HEX1-0 = how many different pins have been seen (52 = all)

module boardtest_top (
    input  wire        MAX10_CLK1_50,
    input  wire [1:0]  KEY,
    input  wire [9:0]  SW,
    output wire [9:0]  LEDR,
    output wire [7:0]  HEX0, HEX1, HEX2, HEX3, HEX4, HEX5,

    output wire [12:0] DRAM_ADDR,
    output wire [1:0]  DRAM_BA,
    output wire        DRAM_CAS_N, DRAM_CKE, DRAM_CLK, DRAM_CS_N,
    inout  wire [15:0] DRAM_DQ,
    output wire        DRAM_LDQM, DRAM_RAS_N, DRAM_UDQM, DRAM_WE_N,

    output wire [3:0]  VGA_R, VGA_G, VGA_B,
    output wire        VGA_HS, VGA_VS,

    output wire        GSENSOR_CS_N,
    output wire        GSENSOR_SCLK,
    inout  wire        GSENSOR_SDI,
    inout  wire        GSENSOR_SDO,

    inout  wire [15:0] ARDUINO_IO,
    inout  wire [35:0] GPIO
);
    wire clk = MAX10_CLK1_50;

    // ------------------------------------------------------------ keys
    // Sample the keys every ~21 ms: slow enough to ignore contact bounce.
    reg [19:0] key_div = 0;
    reg [1:0]  key_s = 2'b11, key_q = 2'b11, key_prev = 2'b11;
    always @(posedge clk) begin
        key_s   <= KEY;
        key_div <= key_div + 1'b1;
        if (key_div == 0) begin
            key_prev <= key_q;
            key_q    <= key_s;
        end
    end
    wire lamp      = !key_q[0];
    wire next_mode = (key_div == 1) && key_prev[1] && !key_q[1];

    reg [1:0] mode = 2'd0;
    always @(posedge clk) if (next_mode) mode <= mode + 1'b1;

    // ------------------------------------------------------------ SDRAM
    wire        sd_init, sd_writing;
    wire [15:0] sd_passes;
    wire [11:0] sd_errors;
    wire [7:0]  sd_progress;

    wire [23:0] sd_err_a, sd_err_b, sd_err_c, sd_err_d, sd_err_e, sd_err_ref;
    wire [31:0] sd_reads;
    wire [15:0] sd_err_bits, sd_first_exp, sd_first_got;
    wire [3:0]  sd_err_banks;
    wire        sd_first_seen;
    wire [24:0] sd_first_addr;
    wire [2:0]  jtag_src;          // [0] clear/restart, [2:1] SDRAM test mode

    sdram_test u_sdram (
        .clk(clk), .dram_clk(DRAM_CLK), .dram_cke(DRAM_CKE),
        .dram_cs_n(DRAM_CS_N), .dram_ras_n(DRAM_RAS_N),
        .dram_cas_n(DRAM_CAS_N), .dram_we_n(DRAM_WE_N),
        .dram_ba(DRAM_BA), .dram_addr(DRAM_ADDR), .dram_dq(DRAM_DQ),
        .dram_ldqm(DRAM_LDQM), .dram_udqm(DRAM_UDQM),
        .init_done(sd_init), .writing(sd_writing), .passes(sd_passes),
        .errors(sd_errors), .progress(sd_progress),
        .err_a(sd_err_a), .err_b(sd_err_b), .err_c(sd_err_c), .err_d(sd_err_d), .err_e(sd_err_e),
        .clear(jtag_src[0]), .test_mode(jtag_src[2:1]),
        .reads(sd_reads), .err_after_ref(sd_err_ref), .err_bits(sd_err_bits),
        .err_banks(sd_err_banks), .first_seen(sd_first_seen), .first_addr(sd_first_addr),
        .first_exp(sd_first_exp), .first_got(sd_first_got)
    );


    // ------------------------------------------------------------ accelerometer
    wire [7:0] g_id;
    wire [9:0] g_x, g_y, g_z;
    adxl345_spi u_gsensor (
        .clk(clk), .cs_n(GSENSOR_CS_N), .sclk(GSENSOR_SCLK), .sdio(GSENSOR_SDI),
        .devid(g_id), .x(g_x), .y(g_y), .z(g_z)
    );
    assign GSENSOR_SDO = 1'bz;   // unused in 3-wire mode

    // ------------------------------------------------------------ VGA
    vga_bars u_vga (
        .clk(clk), .hs(VGA_HS), .vs(VGA_VS), .r(VGA_R), .g(VGA_G), .b(VGA_B)
    );

    // ------------------------------------------------------------ UART echo
    wire [7:0] rx_data;
    wire       rx_valid, rx_err, tx_line, tx_busy;
    uart_rx #(.CLKS_PER_BIT(434)) u_rx (
        .clk(clk), .rst(1'b0), .rx(ARDUINO_IO[0]),
        .data(rx_data), .valid(rx_valid), .frame_err(rx_err)
    );
    uart_tx #(.CLKS_PER_BIT(434)) u_tx (
        .clk(clk), .rst(1'b0), .data(rx_data), .start(rx_valid && !tx_busy),
        .tx(tx_line), .busy(tx_busy)
    );

    // D1 drives only outside pin-scan mode; everything else is an input.
    assign ARDUINO_IO[0]    = 1'bz;
    assign ARDUINO_IO[1]    = (mode == 2'd3) ? 1'bz : tx_line;
    assign ARDUINO_IO[15:2] = 14'bz;
    assign GPIO             = 36'bz;

    // ------------------------------------------------------------ pin scan
    // A pin counts as touched if it reads low at two samples ~5 ms apart.
    reg [51:0] pin_meta = {52{1'b1}}, pin_sync = {52{1'b1}}, pin_prev = {52{1'b1}};
    reg [51:0] seen = 52'd0;
    reg [5:0]  last_pin = 6'd0;
    reg        any_seen = 1'b0;
    reg [17:0] scan_div = 0;
    integer    i;
    always @(posedge clk) begin
        pin_meta <= {GPIO, ARDUINO_IO[15:2],
                     (mode == 2'd3) ? ARDUINO_IO[1] : 1'b1, ARDUINO_IO[0]};
        pin_sync <= pin_meta;
        scan_div <= scan_div + 1'b1;
        if (scan_div == 0) begin
            pin_prev <= pin_sync;
            if (mode == 2'd3)
                for (i = 0; i < 52; i = i + 1)
                    if (!pin_sync[i] && !pin_prev[i]) begin
                        seen[i]  <= 1'b1;
                        last_pin <= i;
                        any_seen <= 1'b1;
                    end
        end
    end

    reg [5:0] seen_count;
    always @(*) begin
        seen_count = 0;
        for (i = 0; i < 52; i = i + 1) seen_count = seen_count + seen[i];
    end

    // ------------------------------------------------------------ display
    // Symbol codes: 0-15 hex digits, then a few letters.
    localparam [4:0] SYM_BLANK = 5'd16, SYM_DASH = 5'd17, SYM_R = 5'd18,
                     SYM_G = 5'd19, SYM_E = 5'd14, SYM_A = 5'd10;

    reg [25:0] slow = 0;
    always @(posedge clk) slow <= slow + 1'b1;

    wire [5:0] pin_num = (last_pin < 16) ? last_pin : last_pin - 6'd16;

    reg [4:0] d5, d4, d3, d2, d1, d0;
    reg [5:0] dots;                       // 1 = dot on, [5] is HEX5
    always @(*) begin
        dots = 6'b000000;
        case (mode)
            2'd0: begin
                {d5, d4, d3, d2, d1, d0} = {6{1'b0, slow[25:22]}};
                dots = {6{slow[22]}};
            end
            2'd1: begin
                d5 = g_id[7:4];  d4 = g_id[3:0];
                d3 = g_x[9:6];   d2 = g_x[5:2];
                d1 = g_y[9:6];   d0 = g_y[5:2];
            end
            2'd2: begin
                if (!sd_init) begin
                    {d5, d4, d3, d2, d1, d0} = {6{SYM_DASH}};
                end else if (sd_errors != 0) begin
                    d5 = SYM_E; d4 = SYM_R; d3 = SYM_R;
                    d2 = sd_errors[11:8]; d1 = sd_errors[7:4]; d0 = sd_errors[3:0];
                end else begin
                    d5 = sd_progress[7:4]; d4 = sd_progress[3:0];
                    d3 = sd_passes[15:12]; d2 = sd_passes[11:8];
                    d1 = sd_passes[7:4];   d0 = sd_passes[3:0];
                    dots[4] = sd_writing;
                end
            end
            default: begin
                if (any_seen) begin
                    d5 = (last_pin < 16) ? SYM_A : SYM_G;
                    d4 = pin_num / 10;  d3 = pin_num % 10;
                end else begin
                    d5 = SYM_DASH; d4 = SYM_DASH; d3 = SYM_DASH;
                end
                d2 = SYM_BLANK;
                d1 = seen_count / 10;  d0 = seen_count % 10;
            end
        endcase
    end

    function [7:0] seg(input [4:0] s, input dot);   // active low, bit 7 = dot
        begin
            case (s)
                5'd0:  seg[6:0] = 7'b1000000;
                5'd1:  seg[6:0] = 7'b1111001;
                5'd2:  seg[6:0] = 7'b0100100;
                5'd3:  seg[6:0] = 7'b0110000;
                5'd4:  seg[6:0] = 7'b0011001;
                5'd5:  seg[6:0] = 7'b0010010;
                5'd6:  seg[6:0] = 7'b0000010;
                5'd7:  seg[6:0] = 7'b1111000;
                5'd8:  seg[6:0] = 7'b0000000;
                5'd9:  seg[6:0] = 7'b0010000;
                5'd10: seg[6:0] = 7'b0001000;   // A
                5'd11: seg[6:0] = 7'b0000011;   // b
                5'd12: seg[6:0] = 7'b1000110;   // C
                5'd13: seg[6:0] = 7'b0100001;   // d
                5'd14: seg[6:0] = 7'b0000110;   // E
                5'd15: seg[6:0] = 7'b0001110;   // F
                SYM_DASH: seg[6:0] = 7'b0111111;
                SYM_R:    seg[6:0] = 7'b0101111;   // r
                SYM_G:    seg[6:0] = 7'b1000010;   // G
                default:  seg[6:0] = 7'b1111111;   // blank
            endcase
            seg[7] = ~dot;
        end
    endfunction

    assign HEX5 = lamp ? 8'h00 : seg(d5, dots[5]);
    assign HEX4 = lamp ? 8'h00 : seg(d4, dots[4]);
    assign HEX3 = lamp ? 8'h00 : seg(d3, dots[3]);
    assign HEX2 = lamp ? 8'h00 : seg(d2, dots[2]);
    assign HEX1 = lamp ? 8'h00 : seg(d1, dots[1]);
    assign HEX0 = lamp ? 8'h00 : seg(d0, dots[0]);
    assign LEDR = lamp ? 10'h3FF : SW;

    // In-System Sources and Probes: lets the laptop read these values over
    // the USB-Blaster cable (quartus_stp, see boardtest/read_probes.tcl).
    // Layout (LSB first) is decoded by boardtest/read_probes.py.
    wire [279:0] probe_bus = {g_id, sd_init, sd_writing, sd_passes,
                              sd_first_got, sd_first_exp, sd_first_addr, sd_first_seen,
                              sd_err_banks, sd_err_bits, sd_err_ref, sd_reads,
                              sd_err_e, sd_err_d, sd_err_c, sd_err_b, sd_err_a};
    altsource_probe #(
        .sld_auto_instance_index("YES"),
        .sld_instance_index(0),
        .instance_id("DIAG"),
        .probe_width(280),
        .source_width(3),
        .source_initial_value("0"),
        .enable_metastability("NO")
    ) u_probe (
        .probe(probe_bus),
        .source(jtag_src)
    );
endmodule
