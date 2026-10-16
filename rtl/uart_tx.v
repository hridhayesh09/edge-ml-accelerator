// uart_tx.v
// 8N1 UART transmitter: 1 start bit (0), 8 data bits LSB first, 1 stop bit (1).
//
// Pulse `start` for one cycle while `busy` is low; the byte on `data` is
// latched and shifted out. `busy` stays high until the stop bit is finished.

module uart_tx #(
    parameter CLKS_PER_BIT = 434
) (
    input  wire       clk,
    input  wire       rst,
    input  wire [7:0] data,
    input  wire       start,
    output reg        tx = 1'b1,   // serial output (idle high)
    output wire       busy
);
    localparam CW = $clog2(CLKS_PER_BIT + 1);

    localparam S_IDLE  = 2'd0;
    localparam S_START = 2'd1;
    localparam S_DATA  = 2'd2;
    localparam S_STOP  = 2'd3;

    reg [1:0]    state   = S_IDLE;
    reg [CW-1:0] cnt     = 0;
    reg [2:0]    bit_idx = 0;
    reg [7:0]    shift   = 0;

    assign busy = (state != S_IDLE);

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            cnt   <= 0;
            tx    <= 1'b1;
        end else begin
            case (state)
                S_IDLE: begin
                    tx  <= 1'b1;
                    cnt <= 0;
                    if (start) begin
                        shift <= data;
                        state <= S_START;
                        tx    <= 1'b0;          // start bit
                    end
                end

                S_START: begin
                    if (cnt == CLKS_PER_BIT - 1) begin
                        cnt     <= 0;
                        state   <= S_DATA;
                        bit_idx <= 0;
                        tx      <= shift[0];    // first data bit (LSB)
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end

                S_DATA: begin
                    if (cnt == CLKS_PER_BIT - 1) begin
                        cnt <= 0;
                        if (bit_idx == 3'd7) begin
                            state <= S_STOP;
                            tx    <= 1'b1;      // stop bit
                        end else begin
                            bit_idx <= bit_idx + 1'b1;
                            tx      <= shift[bit_idx + 1'b1];
                        end
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end

                S_STOP: begin
                    if (cnt == CLKS_PER_BIT - 1) begin
                        cnt   <= 0;
                        state <= S_IDLE;
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end
            endcase
        end
    end
endmodule
