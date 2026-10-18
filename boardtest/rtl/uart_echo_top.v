// uart_echo_top.v
// Link-speed experiment: echoes every byte received on Arduino D0 back out on
// D1, at a baud rate set by CLKS_PER_BIT. With USE_PLL = 1 the UART runs from
// a 48 MHz clock made by the MAX 10's PLL (50 MHz x 24 / 25), so baud rates
// derived from 48 MHz (like the CH343 bridge's 6 Mbaud) come out exact.
//
// LEDR0 = PLL locked (always on without the PLL), LEDR1 = frame error seen.

module uart_echo_top #(
    parameter CLKS_PER_BIT = 10,
    parameter USE_PLL      = 0
) (
    input  wire        MAX10_CLK1_50,
    output wire [9:0]  LEDR,
    inout  wire [15:0] ARDUINO_IO
);
    wire clk, locked;
    generate
        if (USE_PLL) begin : g_pll
            wire [4:0] clks;
            altpll #(
                .intended_device_family ("MAX 10"),
                .lpm_type               ("altpll"),
                .operation_mode         ("NORMAL"),
                .pll_type               ("AUTO"),
                .inclk0_input_frequency (20000),      // 50 MHz, in ps
                .clk0_multiply_by       (24),
                .clk0_divide_by         (25),         // -> 48 MHz
                .clk0_duty_cycle        (50),
                .clk0_phase_shift       ("0"),
                .compensate_clock       ("CLK0"),
                .width_clock            (5)
            ) u_pll (
                .inclk  ({1'b0, MAX10_CLK1_50}),
                .clk    (clks),
                .locked (locked)
            );
            assign clk = clks[0];
        end else begin : g_direct
            assign clk = MAX10_CLK1_50;
            assign locked = 1'b1;
        end
    endgenerate

    // rx -> FIFO -> tx, so a byte arriving while the previous echo is still
    // going out (or a slightly fast sender) never gets dropped
    wire [7:0] data, fdata;
    wire       valid, ferr, tx, busy, fempty, ffull;
    uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_rx (
        .clk(clk), .rst(!locked), .rx(ARDUINO_IO[0]), .data(data), .valid(valid), .frame_err(ferr));
    sync_fifo #(.WIDTH(8), .DEPTH(256)) u_fifo (
        .clk(clk), .rst(!locked), .wr_en(valid), .din(data), .full(ffull),
        .rd_en(!fempty && !busy), .dout(fdata), .empty(fempty));
    uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tx (
        .clk(clk), .rst(!locked), .data(fdata), .start(!fempty && !busy), .tx(tx), .busy(busy));

    reg seen_ferr = 1'b0;
    always @(posedge clk) if (ferr) seen_ferr <= 1'b1;

    assign ARDUINO_IO[0]    = 1'bz;
    assign ARDUINO_IO[1]    = tx;
    assign ARDUINO_IO[15:2] = 14'bz;
    assign LEDR = {8'd0, seen_ferr, locked};
endmodule
