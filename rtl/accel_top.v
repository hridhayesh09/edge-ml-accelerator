// accel_top.v
// Board-independent top level: UART <-> FIFOs <-> accelerator core.
//
//   rx pin -> uart_rx -> RX FIFO -> accel_core -> TX FIFO -> uart_tx -> tx pin
//
// The FIFOs decouple the slow serial link from the core. The core can pull
// bytes out as fast as one per clock, and it can push a burst of response
// bytes without waiting for each one to finish transmitting.

module accel_top #(
    parameter CLKS_PER_BIT = 25,    // 50 MHz / 2,000,000 baud
    parameter N            = 8,
    parameter MAX_M        = 256,
    parameter FIFO_DEPTH   = 64,
    parameter RX_TIMEOUT   = 2_500_000,  // 50 ms at 50 MHz, see accel_core.v
    parameter MODEL_DIR    = "../rtl/model/"   // MNIST weight files (relative to quartus/)
) (
    input  wire clk,
    input  wire rst,
    input  wire uart_rx,
    output wire uart_tx,

    // status, for LEDs
    output wire busy,
    output wire rx_pulse,
    output wire tx_pulse,
    output wire err_pulse
);
    // receive path
    wire [7:0] rx_byte;
    wire       rx_valid;
    wire       rx_frame_err;

    uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_uart_rx (
        .clk(clk), .rst(rst), .rx(uart_rx),
        .data(rx_byte), .valid(rx_valid), .frame_err(rx_frame_err)
    );

    wire       rxf_empty, rxf_full, rxf_rd;
    wire [7:0] rxf_dout;

    sync_fifo #(.WIDTH(8), .DEPTH(FIFO_DEPTH)) u_rx_fifo (
        .clk(clk), .rst(rst),
        .wr_en(rx_valid), .din(rx_byte), .full(rxf_full),
        .rd_en(rxf_rd), .dout(rxf_dout), .empty(rxf_empty)
    );

    // core
    wire [7:0] core_tx_data;
    wire       core_tx_wr;
    wire       txf_full;
    wire       core_err;

    accel_core #(.N(N), .MAX_M(MAX_M), .RX_TIMEOUT(RX_TIMEOUT), .MODEL_DIR(MODEL_DIR)) u_core (
        .clk(clk), .rst(rst),
        .rx_empty(rxf_empty), .rx_data(rxf_dout), .rx_rd(rxf_rd),
        .tx_full(txf_full), .tx_data(core_tx_data), .tx_wr(core_tx_wr),
        .busy(busy), .cmd_error(core_err)
    );

    // transmit path
    wire       txf_empty;
    wire [7:0] txf_dout;
    wire       tx_busy;
    wire       tx_start = !txf_empty && !tx_busy;

    sync_fifo #(.WIDTH(8), .DEPTH(FIFO_DEPTH)) u_tx_fifo (
        .clk(clk), .rst(rst),
        .wr_en(core_tx_wr), .din(core_tx_data), .full(txf_full),
        .rd_en(tx_start), .dout(txf_dout), .empty(txf_empty)
    );

    uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_uart_tx (
        .clk(clk), .rst(rst), .data(txf_dout), .start(tx_start),
        .tx(uart_tx), .busy(tx_busy)
    );

    assign rx_pulse  = rx_valid;
    assign tx_pulse  = tx_start;
    assign err_pulse = rx_frame_err | core_err | (rx_valid & rxf_full);
endmodule
