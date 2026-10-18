// de10lite_top.v
// Board wrapper for the Terasic DE10-Lite (Intel MAX 10, 10M50DAF484C7G).
//
// Wiring (USB-to-serial adapter, 3.3 V logic):
//   adapter TX  -> ARDUINO_IO[0]  (FPGA receives, labeled "RX<-0" on the board)
//   adapter RX  <- ARDUINO_IO[1]  (FPGA transmits, labeled "TX->1")
//   adapter GND -> any GND pin on the header
//   do NOT connect the adapter's VCC / 5V pin
//
// Controls and lights:
//   KEY[0]   reset (press to reset)
//   LEDR[0]  heartbeat (blinks about once per second: the design is running)
//   LEDR[1]  byte received
//   LEDR[2]  byte sent
//   LEDR[3]  array busy computing
//   LEDR[9]  error seen (bad UART frame, unknown command, or RX overflow);
//            stays on until reset
//   HEX1..0  number of RUN commands finished, in hex (wraps at FF)

module de10lite_top #(
    parameter CLK_HZ = 50_000_000,
    parameter BAUD   = 2_000_000
) (
    input  wire        MAX10_CLK1_50,
    input  wire [1:0]  KEY,
    input  wire [9:0]  SW,
    output wire [9:0]  LEDR,
    output wire [7:0]  HEX0,
    output wire [7:0]  HEX1,
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

    // ------------------------------------------------------------------
    // Accelerator
    // ------------------------------------------------------------------
    wire uart_tx;
    wire busy, rx_pulse, tx_pulse, err_pulse;

    accel_top #(
        .CLKS_PER_BIT(CLKS_PER_BIT),
        .N(8),
        .MAX_M(256)
    ) u_accel (
        .clk(clk), .rst(rst),
        .uart_rx(ARDUINO_IO[0]),
        .uart_tx(uart_tx),
        .busy(busy), .rx_pulse(rx_pulse), .tx_pulse(tx_pulse), .err_pulse(err_pulse)
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

    // Count finished runs: busy falling edge
    reg       busy_d = 0;
    reg [7:0] runs   = 0;
    always @(posedge clk) begin
        busy_d <= busy;
        if (rst)                 runs <= 0;
        else if (busy_d && !busy) runs <= runs + 1'b1;
    end

    assign LEDR[0]   = hb[25];
    assign LEDR[1]   = rx_led != 0;
    assign LEDR[2]   = tx_led != 0;
    assign LEDR[3]   = busy;
    assign LEDR[8:4] = 5'd0;
    assign LEDR[9]   = err_led;

    hex7seg u_hex0 (.value(runs[3:0]), .seg(HEX0));
    hex7seg u_hex1 (.value(runs[7:4]), .seg(HEX1));

    // SW is unused for now (reserved for future modes)
    wire _unused = &{1'b0, SW, KEY[1]};
endmodule

// Seven-segment decoder. DE10-Lite segments are active low; bit 7 is the dot.
module hex7seg (
    input  wire [3:0] value,
    output reg  [7:0] seg
);
    always @(*) begin
        case (value)
            4'h0: seg = 8'b11000000;
            4'h1: seg = 8'b11111001;
            4'h2: seg = 8'b10100100;
            4'h3: seg = 8'b10110000;
            4'h4: seg = 8'b10011001;
            4'h5: seg = 8'b10010010;
            4'h6: seg = 8'b10000010;
            4'h7: seg = 8'b11111000;
            4'h8: seg = 8'b10000000;
            4'h9: seg = 8'b10010000;
            4'hA: seg = 8'b10001000;
            4'hB: seg = 8'b10000011;
            4'hC: seg = 8'b11000110;
            4'hD: seg = 8'b10100001;
            4'hE: seg = 8'b10000110;
            default: seg = 8'b10001110; // F
        endcase
    end
endmodule
