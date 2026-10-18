// accel_core.v
// Controller + buffers around the systolic array.
//
// It reads a byte stream of commands (from the UART receive FIFO), loads
// weights and activations, runs the array, and writes responses back out
// (to the UART transmit FIFO). See docs/protocol.md for the byte format.
//
//   'P' 0x50  PING       -> replies A5, N, MAX_M-1, VERSION
//   'W' 0x57  LOAD_W     + N*N weight bytes (int8, row-major W[k][n]) + checksum
//   'A' 0x41  LOAD_A     + (M-1) + M*N activation bytes (int8, row-major A[m][k]) + checksum
//   'R' 0x52  RUN        C  = A x W, replies D0 + 4-byte cycle count
//   'U' 0x55  RUN_ACC    C += A x W (accumulate onto the last result)
//   'C' 0x43  READ_C     -> replies M*N int32 results, little-endian, + checksum
//   other                -> replies EE
//
// Link protection (protocol version 2):
//   * checksum = sum of the data bytes mod 256 (for LOAD_A this includes the
//     M-1 byte). If a LOAD's checksum is wrong, or a LOAD stalls for
//     RX_TIMEOUT clocks (a byte was lost), the loaded data is marked bad and
//     the next RUN/RUN_ACC replies EC 00 00 00 00 without computing, so the
//     output buffer is untouched and the host can simply resend the tile.
//   * The stall timeout also drops the controller back to idle, so a lost
//     byte can never leave it stuck waiting.
//   * PING clears the bad flag: the host PINGs to resync after an error.
//
// Buffers (all inferred as block RAM):
//   activation buffer : MAX_M rows x (8*N) bits
//   output buffer     : MAX_M rows x (32*N) bits
//
// RUN_ACC is what makes tiling cheap: a big matrix product is split into
// N-wide slices of the K dimension, and each slice's result is added onto the
// output buffer in hardware, so only the final sum has to be sent back.

module accel_core #(
    parameter N          = 8,
    parameter MAX_M      = 256,
    parameter RX_TIMEOUT = 2_500_000   // clocks of silence mid-LOAD before giving up (50 ms)
) (
    input  wire       clk,
    input  wire       rst,

    // incoming bytes (first-word fall-through FIFO)
    input  wire       rx_empty,
    input  wire [7:0] rx_data,
    output wire       rx_rd,

    // outgoing bytes
    input  wire       tx_full,
    output reg  [7:0] tx_data,
    output reg        tx_wr,

    output wire       busy,
    output wire       cmd_error
);
    localparam MW = $clog2(MAX_M);
    localparam NN = N * N;
    localparam WW = $clog2(NN);
    localparam BW = $clog2(N);          // byte-in-row index width
    localparam OB = $clog2(4 * N);      // byte-in-output-row index width
    localparam [7:0] VERSION   = 8'd2;
    localparam [7:0] N_BYTE    = N;
    localparam [7:0] MLAST_MAX = MAX_M - 1;

    localparam CMD_PING    = 8'h50;  // 'P'
    localparam CMD_LOAD_W  = 8'h57;  // 'W'
    localparam CMD_LOAD_A  = 8'h41;  // 'A'
    localparam CMD_RUN     = 8'h52;  // 'R'
    localparam CMD_RUN_ACC = 8'h55;  // 'U'
    localparam CMD_READ    = 8'h43;  // 'C'

    localparam RSP_PING = 8'hA5;
    localparam RSP_DONE = 8'hD0;
    localparam RSP_ERR  = 8'hEE;
    localparam RSP_BAD  = 8'hEC;     // RUN refused: last LOAD had a bad checksum or timed out

    localparam S_IDLE    = 4'd0;
    localparam S_LOAD_W  = 4'd1;
    localparam S_ALEN    = 4'd2;
    localparam S_LOAD_A  = 4'd3;
    localparam S_FEED    = 4'd4;
    localparam S_DRAIN   = 4'd5;
    localparam S_RESP    = 4'd6;
    localparam S_RD_ADDR = 4'd7;
    localparam S_RD_SEND = 4'd8;
    localparam S_CSUM_W  = 4'd9;     // waiting for LOAD_W's checksum byte
    localparam S_CSUM_A  = 4'd10;    // waiting for LOAD_A's checksum byte
    localparam S_RD_CSUM = 4'd11;    // sending READ_C's checksum byte

    reg [3:0] state = S_IDLE;

    // ------------------------------------------------------------------
    // Registers
    // ------------------------------------------------------------------
    reg [WW-1:0]    wcnt     = 0;      // weight byte counter
    reg [MW-1:0]    m_last   = 0;      // M-1 for the loaded activations
    reg [MW-1:0]    a_row    = 0;      // row being loaded
    reg [BW-1:0]    a_byte   = 0;      // byte within that row
    reg [8*N-1:0]   row_buf  = 0;      // assembles one activation row

    reg             acc_mode = 0;      // RUN_ACC vs RUN
    reg [MW-1:0]    feed_cnt = 0;      // activation row being fed
    reg             feed_v   = 0;      // a_row data valid this cycle
    reg [MW-1:0]    pre_row  = 0;      // output row being pre-read
    reg [MW-1:0]    wr_row   = 0;      // output row being written
    reg [31:0]      cycles   = 0;      // compute cycle counter

    reg [39:0]      resp_buf = 0;      // up to 5 response bytes
    reg [2:0]       resp_len = 0;
    reg [2:0]       resp_idx = 0;

    reg [MW-1:0]    rd_row   = 0;      // READ_C row
    reg [OB-1:0]    rd_byte  = 0;      // READ_C byte within row

    reg             err_flag = 0;

    reg [7:0]       csum     = 0;      // running checksum of LOAD data / READ_C bytes
    reg             bad      = 0;      // loaded data is not trustworthy
    localparam TW = $clog2(RX_TIMEOUT + 1);
    reg [TW-1:0]    quiet    = 0;      // clocks since the last byte, during a LOAD

    // ------------------------------------------------------------------
    // Activation buffer
    // ------------------------------------------------------------------
    reg              amem_we    = 0;
    reg  [MW-1:0]    amem_waddr = 0;
    reg  [8*N-1:0]   amem_wdata = 0;
    wire [8*N-1:0]   amem_rdata;

    sdp_ram #(.WIDTH(8*N), .DEPTH(MAX_M)) u_amem (
        .clk(clk), .we(amem_we), .waddr(amem_waddr), .wdata(amem_wdata),
        .raddr(feed_cnt), .rdata(amem_rdata)
    );

    // ------------------------------------------------------------------
    // Systolic array
    // ------------------------------------------------------------------
    wire              arr_pre_valid;
    wire              arr_out_valid;
    wire [32*N-1:0]   arr_c_row;

    wire   loading = (state == S_LOAD_W || state == S_ALEN || state == S_LOAD_A ||
                      state == S_CSUM_W || state == S_CSUM_A);
    assign rx_rd = !rx_empty && (state == S_IDLE || loading);

    systolic_array #(.N(N)) u_array (
        .clk      (clk),
        .rst      (rst),
        .w_we     (state == S_LOAD_W && rx_rd),
        .w_addr   (wcnt),
        .w_data   (rx_data),
        .in_valid (feed_v),
        .a_row    (feed_v ? amem_rdata : {8*N{1'b0}}),
        .pre_valid(arr_pre_valid),
        .out_valid(arr_out_valid),
        .c_row    (arr_c_row)
    );

    // ------------------------------------------------------------------
    // Output buffer (read-modify-write for accumulate mode)
    // ------------------------------------------------------------------
    wire             reading  = (state == S_RD_ADDR || state == S_RD_SEND);
    wire [MW-1:0]    omem_raddr = reading ? rd_row : pre_row;
    wire [32*N-1:0]  omem_rdata;
    wire [32*N-1:0]  omem_wdata;

    genvar g;
    generate
        for (g = 0; g < N; g = g + 1) begin : g_acc
            assign omem_wdata[32*g +: 32] = acc_mode
                ? omem_rdata[32*g +: 32] + arr_c_row[32*g +: 32]
                : arr_c_row[32*g +: 32];
        end
    endgenerate

    sdp_ram #(.WIDTH(32*N), .DEPTH(MAX_M)) u_omem (
        .clk(clk), .we(arr_out_valid), .waddr(wr_row), .wdata(omem_wdata),
        .raddr(omem_raddr), .rdata(omem_rdata)
    );

    // ------------------------------------------------------------------
    // Transmit mux
    // ------------------------------------------------------------------
    always @(*) begin
        tx_wr   = 1'b0;
        tx_data = 8'd0;
        if (state == S_RESP) begin
            tx_data = resp_buf[8*resp_idx +: 8];
            tx_wr   = !tx_full;
        end else if (state == S_RD_SEND) begin
            tx_data = omem_rdata[8*rd_byte +: 8];
            tx_wr   = !tx_full;
        end else if (state == S_RD_CSUM) begin
            tx_data = csum;
            tx_wr   = !tx_full;
        end
    end

    assign busy      = (state == S_FEED || state == S_DRAIN);
    assign cmd_error = err_flag;

    // ------------------------------------------------------------------
    // Main state machine
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        amem_we  <= 1'b0;
        feed_v   <= 1'b0;
        err_flag <= 1'b0;

        if (rst) begin
            state <= S_IDLE;
        end else begin
            // output-side bookkeeping runs whenever the array produces data
            if (arr_pre_valid) pre_row <= pre_row + 1'b1;
            if (arr_out_valid) wr_row  <= wr_row + 1'b1;
            if (busy)          cycles  <= cycles + 1'b1;

            // A LOAD that goes quiet means a byte was lost: give up on it.
            if (loading && !rx_rd) quiet <= quiet + 1'b1;
            else                   quiet <= 0;

            case (state)
                S_IDLE: if (rx_rd) begin
                    case (rx_data)
                        CMD_PING: begin             // also the host's resync point
                            bad      <= 1'b0;
                            resp_buf <= {8'd0, VERSION, MLAST_MAX, N_BYTE, RSP_PING};
                            resp_len <= 3'd4;
                            resp_idx <= 0;
                            state    <= S_RESP;
                        end
                        CMD_LOAD_W: begin
                            wcnt  <= 0;
                            csum  <= 0;
                            state <= S_LOAD_W;
                        end
                        CMD_LOAD_A: begin
                            csum  <= 0;
                            state <= S_ALEN;
                        end
                        CMD_RUN, CMD_RUN_ACC: begin
                            if (bad) begin              // refuse: data is suspect
                                bad      <= 1'b0;
                                resp_buf <= {32'd0, RSP_BAD};
                                resp_len <= 3'd5;
                                resp_idx <= 0;
                                state    <= S_RESP;
                            end else begin
                                acc_mode <= (rx_data == CMD_RUN_ACC);
                                feed_cnt <= 0;
                                pre_row  <= 0;
                                wr_row   <= 0;
                                cycles   <= 0;
                                state    <= S_FEED;
                            end
                        end
                        CMD_READ: begin
                            rd_row  <= 0;
                            rd_byte <= 0;
                            csum    <= 0;
                            state   <= S_RD_ADDR;
                        end
                        default: begin
                            resp_buf <= {32'd0, RSP_ERR};
                            resp_len <= 3'd1;
                            resp_idx <= 0;
                            err_flag <= 1'b1;
                            state    <= S_RESP;
                        end
                    endcase
                end

                S_LOAD_W: if (rx_rd) begin
                    // the weight itself is written straight into the PE
                    // (see w_we/w_addr/w_data on the array)
                    csum <= csum + rx_data;
                    if (wcnt == NN - 1) state <= S_CSUM_W;
                    wcnt <= wcnt + 1'b1;
                end

                S_CSUM_W, S_CSUM_A: if (rx_rd) begin
                    if (rx_data != csum) bad <= 1'b1;
                    state <= S_IDLE;
                end

                S_ALEN: if (rx_rd) begin
                    csum   <= csum + rx_data;
                    m_last <= rx_data[MW-1:0];
                    a_row  <= 0;
                    a_byte <= 0;
                    state  <= S_LOAD_A;
                end

                S_LOAD_A: if (rx_rd) begin
                    csum <= csum + rx_data;
                    if (a_byte == N - 1) begin
                        amem_we    <= 1'b1;
                        amem_waddr <= a_row;
                        amem_wdata <= {rx_data, row_buf[8*(N-1)-1:0]};
                        a_byte     <= 0;
                        a_row      <= a_row + 1'b1;
                        if (a_row == m_last) state <= S_CSUM_A;
                    end else begin
                        row_buf[8*a_byte +: 8] <= rx_data;
                        a_byte <= a_byte + 1'b1;
                    end
                end

                // Issue one activation-buffer read per cycle. The data comes
                // out of the RAM one cycle later, which is when feed_v is high.
                S_FEED: begin
                    feed_v   <= 1'b1;
                    feed_cnt <= feed_cnt + 1'b1;
                    if (feed_cnt == m_last) state <= S_DRAIN;
                end

                // Wait for the last result row to be written
                S_DRAIN: begin
                    if (arr_out_valid && wr_row == m_last) begin
                        resp_buf <= {cycles + 32'd1, RSP_DONE};
                        resp_len <= 3'd5;
                        resp_idx <= 0;
                        state    <= S_RESP;
                    end
                end

                S_RESP: if (tx_wr) begin
                    if (resp_idx == resp_len - 1'b1) state <= S_IDLE;
                    resp_idx <= resp_idx + 1'b1;
                end

                // Output RAM read takes one cycle: address now, data next state
                S_RD_ADDR: state <= S_RD_SEND;

                S_RD_SEND: if (tx_wr) begin
                    csum <= csum + tx_data;
                    if (rd_byte == 4 * N - 1) begin
                        rd_byte <= 0;
                        if (rd_row == m_last) begin
                            state <= S_RD_CSUM;
                        end else begin
                            rd_row <= rd_row + 1'b1;
                            state  <= S_RD_ADDR;
                        end
                    end else begin
                        rd_byte <= rd_byte + 1'b1;
                    end
                end

                S_RD_CSUM: if (tx_wr) state <= S_IDLE;

                default: state <= S_IDLE;
            endcase

            // Lost byte: abandon the LOAD, mark its data bad, back to idle.
            if (loading && quiet == RX_TIMEOUT[TW-1:0]) begin
                bad      <= 1'b1;
                err_flag <= 1'b1;
                state    <= S_IDLE;
            end
        end
    end
endmodule
