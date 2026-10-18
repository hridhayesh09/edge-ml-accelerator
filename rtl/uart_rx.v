// uart_rx.v
// 8N1 UART receiver.
//
// The rx line comes from outside the FPGA and is not synchronous to clk, so it
// first goes through a 2-flop synchronizer to avoid metastability. The receiver
// waits for a falling edge (start bit), moves to the middle of the start bit,
// then samples each data bit once per bit period, right in the middle of the bit
// where the signal is most stable.
//
// CLKS_PER_BIT = clock frequency / baud rate (50 MHz / 2,000,000 = 25 on the board).

module uart_rx #(
    parameter CLKS_PER_BIT = 434
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       rx,          // serial input (idle high)
    output reg  [7:0] data,        // received byte
    output reg        valid,       // 1-cycle pulse when data is ready
    output reg        frame_err    // 1-cycle pulse when the stop bit was 0
);
    localparam CW = $clog2(CLKS_PER_BIT + 1);

    // 2-flop synchronizer (initialized to idle-high)
    reg rx_meta = 1'b1;
    reg rx_sync = 1'b1;
    always @(posedge clk) begin
        rx_meta <= rx;
        rx_sync <= rx_meta;
    end

    localparam S_IDLE  = 2'd0;
    localparam S_START = 2'd1;
    localparam S_DATA  = 2'd2;
    localparam S_STOP  = 2'd3;

    reg [1:0]    state   = S_IDLE;
    reg [CW-1:0] cnt     = 0;
    reg [2:0]    bit_idx = 0;
    reg [7:0]    shift   = 0;

    always @(posedge clk) begin
        valid     <= 1'b0;
        frame_err <= 1'b0;
        if (rst) begin
            state   <= S_IDLE;
            cnt     <= 0;
            bit_idx <= 0;
        end else begin
            case (state)
                S_IDLE: begin
                    cnt <= 0;
                    if (!rx_sync) state <= S_START;   // falling edge = start bit
                end

                // Wait half a bit, then confirm the line is still low.
                // If it went back high it was a glitch, not a real start bit.
                S_START: begin
                    if (cnt == (CLKS_PER_BIT - 1) / 2) begin
                        cnt <= 0;
                        if (!rx_sync) begin
                            state   <= S_DATA;
                            bit_idx <= 0;
                        end else begin
                            state <= S_IDLE;
                        end
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end

                // We are now in the middle of a bit. Wait one full bit period,
                // which lands in the middle of the next bit, and sample it.
                // UART sends the least significant bit first.
                S_DATA: begin
                    if (cnt == CLKS_PER_BIT - 1) begin
                        cnt   <= 0;
                        shift <= {rx_sync, shift[7:1]};
                        if (bit_idx == 3'd7) state <= S_STOP;
                        else                 bit_idx <= bit_idx + 1'b1;
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end

                // Middle of the stop bit: it must be high. If it is, the byte
                // is good. Go straight back to idle so back-to-back bytes work.
                S_STOP: begin
                    if (cnt == CLKS_PER_BIT - 1) begin
                        cnt   <= 0;
                        state <= S_IDLE;
                        if (rx_sync) begin
                            data  <= shift;
                            valid <= 1'b1;
                        end else begin
                            frame_err <= 1'b1;
                        end
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end
            endcase
        end
    end
endmodule
