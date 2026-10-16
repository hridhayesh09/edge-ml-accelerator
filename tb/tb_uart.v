// tb_uart.v
// Test wrapper: puts a uart_rx and a uart_tx side by side so cocotb can
// drive the receiver and watch the transmitter in one simulation.

module tb_uart #(
    parameter CLKS_PER_BIT = 16
) (
    input  wire       clk,
    input  wire       rst,
    // receiver side
    input  wire       rx,
    output wire [7:0] rx_data,
    output wire       rx_valid,
    output wire       rx_frame_err,
    // transmitter side
    input  wire [7:0] tx_data,
    input  wire       tx_start,
    output wire       tx,
    output wire       tx_busy
);
    uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_rx (
        .clk(clk), .rst(rst), .rx(rx),
        .data(rx_data), .valid(rx_valid), .frame_err(rx_frame_err)
    );

    uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tx (
        .clk(clk), .rst(rst), .data(tx_data), .start(tx_start),
        .tx(tx), .busy(tx_busy)
    );
endmodule
