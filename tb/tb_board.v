// tb_board.v
// Test wrapper around the real board top level (de10lite_top), so the board
// wiring, reset logic, real 2 Mbaud setting, LEDs, and 7-segment counter
// are all simulated exactly as they will be built.

module tb_board #(
    parameter MODEL_DIR = "../rtl/model/"
) (
    input  wire       clk,
    input  wire       key0_n,      // KEY[0], active low
    input  wire       uart_rx,     // into the FPGA (ARDUINO_IO[0])
    output wire       uart_tx,     // out of the FPGA (ARDUINO_IO[1])
    output wire [9:0] ledr,
    output wire [7:0] hex0,
    output wire [7:0] hex1
);
    wire [15:0] io;
    assign io[0] = uart_rx;
    assign uart_tx = io[1];

    de10lite_top #(.MODEL_DIR(MODEL_DIR)) u_board (
        .MAX10_CLK1_50(clk),
        .KEY({1'b1, key0_n}),
        .SW(10'd0),
        .LEDR(ledr),
        .HEX0(hex0),
        .HEX1(hex1),
        .ARDUINO_IO(io)
    );
endmodule
