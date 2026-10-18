// tb_board.v
// Test wrapper around the real board top level (de10lite_top), so the board
// wiring, reset logic, real 2 Mbaud setting, LEDs, switches, KEY1 demo button
// and 7-segment displays are all simulated exactly as they will be built.
// (Only the KEY1 debounce is shortened, so a button press takes microseconds
// of simulated time instead of 20 ms.)

module tb_board #(
    parameter MODEL_DIR = "../rtl/model/"
) (
    input  wire       clk,
    input  wire       key0_n,      // KEY[0], active low (reset)
    input  wire       key1_n,      // KEY[1], active low (demo)
    input  wire [9:0] sw,
    input  wire       uart_rx,     // into the FPGA (ARDUINO_IO[0])
    output wire       uart_tx,     // out of the FPGA (ARDUINO_IO[1])
    output wire [9:0] ledr,
    output wire [7:0] hex0,
    output wire [7:0] hex1,
    output wire [7:0] hex2,
    output wire [7:0] hex3,
    output wire [7:0] hex4,
    output wire [7:0] hex5
);
    wire [15:0] io;
    assign io[0] = uart_rx;
    assign uart_tx = io[1];

    de10lite_top #(.MODEL_DIR(MODEL_DIR), .DEBOUNCE(6), .USE_PROBE(0)) u_board (
        .MAX10_CLK1_50(clk),
        .KEY({key1_n, key0_n}),
        .SW(sw),
        .LEDR(ledr),
        .HEX0(hex0), .HEX1(hex1), .HEX2(hex2), .HEX3(hex3), .HEX4(hex4), .HEX5(hex5),
        .ARDUINO_IO(io)
    );
endmodule
