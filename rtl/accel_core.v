// accel_core.v
// Controller + buffers around the systolic array.
//
// It reads a byte stream of commands (from the UART receive FIFO), loads
// weights and activations, runs the array, and writes responses back out
// (to the UART transmit FIFO). See docs/protocol.md for the byte format.
//
//   'P' 0x50  PING        -> replies A5, N, MAX_M-1, VERSION
//   'W' 0x57  LOAD_W      + N*N weight bytes (int8, row-major W[k][n]) + checksum
//   'A' 0x41  LOAD_A      + (M-1) + M*N activation bytes (int8, row-major A[m][k]) + checksum
//   'R' 0x52  RUN         C  = A x W, replies D0 + 4-byte cycle count
//   'U' 0x55  RUN_ACC     C += A x W (accumulate onto the last result)
//   'C' 0x43  READ_C      -> replies M*N int32 results, little-endian, + checksum
//   'I' 0x49  INFER       + (B-1) + B*784 raw pixels (uint8) + checksum
//                         -> runs the whole MNIST network on chip, replies
//                            D1 + B digits + 4-byte cycle count + checksum
//   'L' 0x4C  READ_LOGITS -> replies B*10 int32 logits of the last INFER + checksum
//   other                 -> replies EE
//
// Link protection (protocol version 2):
//   * checksum = sum of the data bytes mod 256 (for LOAD_A/INFER this includes
//     the length byte). If a LOAD's checksum is wrong, or a LOAD stalls for
//     RX_TIMEOUT clocks (a byte was lost), the loaded data is marked bad and
//     the next RUN/RUN_ACC replies EC 00 00 00 00 without computing, so the
//     output buffer is untouched and the host can simply resend the tile.
//     A bad INFER replies its normal-length frame with EC in place of D1.
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
//
// On-chip MNIST (INFER): the 784-64-10 INT8 network's weights live in ROMs
// (built into the bitstream from rtl/model/*.hex). The same array and output
// buffer do both layers; the only new arithmetic is the requantize step
// between the layers and an argmax at the end. For each layer:
//   for each N-wide slice of output units (nt):
//     for each N-wide slice of inputs (kt):
//       load the N x N weight tile, one PE row per clock, from the ROM
//       stream every image's kt-slice through the array (RUN, then RUN_ACC)
//     post-process the finished slice, one value per clock:
//       layer 1: h = clip((acc + b1) * REQ_MULT + 2^(REQ_SHIFT-1) >> REQ_SHIFT, 0, 127)
//                -> hidden buffer (the next layer's input)
//       layer 2: logit = acc + b2 -> logits buffer
// then argmax over each image's 10 logits gives the digit.

module accel_core #(
    parameter N          = 8,
    parameter MAX_M      = 256,
    parameter RX_TIMEOUT = 2_500_000,  // clocks of silence mid-LOAD before giving up (50 ms)
    parameter MAX_IMG    = 64,         // images per INFER batch
    parameter MODEL_DIR  = "../rtl/model/",   // where the weight .hex files are
    parameter REQ_MULT   = 9710,       // requantize multiplier (host/export_model.py)
    parameter REQ_SHIFT  = 24          // requantize shift
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
    localparam [7:0] VERSION   = 8'd3;
    localparam [7:0] N_BYTE    = N;
    localparam [7:0] MLAST_MAX = MAX_M - 1;

    // MNIST network shape
    localparam IN_PIX = 784;
    localparam HID    = 64;
    localparam OUTS   = 10;
    localparam KT1    = IN_PIX / N;              // input slices, layer 1
    localparam NT1    = HID / N;                 // output slices, layer 1
    localparam KT2    = HID / N;                 // input slices, layer 2
    localparam NT2    = (OUTS + N - 1) / N;      // output slices, layer 2
    localparam IMW    = $clog2(MAX_IMG);         // image index width
    localparam IBD    = MAX_IMG * KT1;           // image buffer depth (words)
    localparam HBD    = MAX_IMG * KT2;           // hidden buffer depth (words)

    localparam CMD_PING    = 8'h50;  // 'P'
    localparam CMD_LOAD_W  = 8'h57;  // 'W'
    localparam CMD_LOAD_A  = 8'h41;  // 'A'
    localparam CMD_RUN     = 8'h52;  // 'R'
    localparam CMD_RUN_ACC = 8'h55;  // 'U'
    localparam CMD_READ    = 8'h43;  // 'C'
    localparam CMD_INFER   = 8'h49;  // 'I'
    localparam CMD_LOGITS  = 8'h4C;  // 'L'

    localparam RSP_PING  = 8'hA5;
    localparam RSP_DONE  = 8'hD0;
    localparam RSP_INFER = 8'hD1;
    localparam RSP_ERR   = 8'hEE;
    localparam RSP_BAD   = 8'hEC;    // refused: last LOAD had a bad checksum or timed out

    localparam S_IDLE    = 5'd0;
    localparam S_LOAD_W  = 5'd1;
    localparam S_ALEN    = 5'd2;
    localparam S_LOAD_A  = 5'd3;
    localparam S_FEED    = 5'd4;
    localparam S_DRAIN   = 5'd5;
    localparam S_RESP    = 5'd6;
    localparam S_RD_ADDR = 5'd7;
    localparam S_RD_SEND = 5'd8;
    localparam S_CSUM_W  = 5'd9;     // waiting for LOAD_W's checksum byte
    localparam S_CSUM_A  = 5'd10;    // waiting for LOAD_A's checksum byte
    localparam S_RD_CSUM = 5'd11;    // sending READ_C's checksum byte
    // INFER: receive
    localparam S_ILEN    = 5'd12;    // batch size byte
    localparam S_IPIX    = 5'd13;    // pixels
    localparam S_ICSUM   = 5'd14;    // checksum byte
    // INFER: the engine
    localparam S_E_TILE  = 5'd15;    // set up one weight tile
    localparam S_E_WLOAD = 5'd16;    // load the tile from ROM, one PE row per clock
    localparam S_E_FEED  = 5'd17;    // stream the images' slice through the array
    localparam S_E_DRAIN = 5'd18;    // wait for the last result row
    localparam S_E_PRD   = 5'd19;    // post-process: read one output-buffer row
    localparam S_E_PLAT  = 5'd20;    //   latch it
    localparam S_E_PEL   = 5'd21;    //   one value per clock
    localparam S_E_ARG   = 5'd22;    // argmax over the 10 logits
    localparam S_I_RESP  = 5'd23;    // send the reply frame
    // READ_LOGITS
    localparam S_L_ADDR  = 5'd24;
    localparam S_L_SEND  = 5'd25;
    localparam S_E_PDRN  = 5'd26;    // post-process: let the 3-stage pipeline empty

    reg [4:0] state = S_IDLE;

    // ------------------------------------------------------------------
    // Registers
    // ------------------------------------------------------------------
    reg [WW-1:0]    wcnt     = 0;      // weight byte counter
    reg [MW-1:0]    m_last   = 0;      // rows - 1 for the current array run
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

    reg [7:0]       csum     = 0;      // running checksum of LOAD data / reply bytes
    reg             bad      = 0;      // loaded data is not trustworthy
    localparam TW = $clog2(RX_TIMEOUT + 1);
    reg [TW-1:0]    quiet    = 0;      // clocks since the last byte, during a LOAD

    // INFER registers
    reg [IMW-1:0]   b_last   = 0;      // images - 1 in this batch
    reg [9:0]       px_cnt   = 0;      // pixel within the image being received
    reg [IMW-1:0]   px_img   = 0;      // image being received
    reg [BW-1:0]    px_lane  = 0;      // byte within the image-buffer word
    reg [8*N-1:0]   px_word  = 0;      // assembles one word of quantized pixels
    reg             infer_ok = 0;      // checksum of this INFER was good

    reg             layer    = 0;      // 0 = layer 1, 1 = layer 2
    reg [7:0]       kt       = 0;      // input slice
    reg [3:0]       nt       = 0;      // output slice
    reg [BW:0]      wl_cnt   = 0;      // weight-tile load step (0..N)
    reg [12:0]      w_base   = 0;      // ROM address of row 0 of this tile
    reg [12:0]      w_nt_base = 0;     // ROM address of this output slice's first tile
    reg [12:0]      src_addr = 0;      // image/hidden buffer read address while feeding
    reg [IMW-1:0]   pm       = 0;      // post-process / argmax image
    reg [BW-1:0]    pj       = 0;      // post-process lane
    reg [32*N-1:0]  post_row = 0;      // the output-buffer row being post-processed
    reg [8*N-1:0]   h_word   = 0;      // assembles one hidden-buffer word
    reg [3:0]       ac       = 0;      // argmax: class whose logit is being read
    reg signed [31:0] best_v = 0;
    reg [3:0]       best_i   = 0;
    reg [3:0]       digit [0:MAX_IMG-1];
    reg [31:0]      icycles  = 0;      // INFER cycle counter
    reg [7:0]       ridx     = 0;      // reply byte index
    reg [3:0]       lc       = 0;      // READ_LOGITS class
    reg [1:0]       lbyte    = 0;      // READ_LOGITS byte within the int32

    integer d;
    initial for (d = 0; d < MAX_IMG; d = d + 1) digit[d] = 0;

    // ------------------------------------------------------------------
    // Activation buffer (UART matmul path)
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
    // MNIST model memories (filled from rtl/model/*.hex at configuration)
    // ------------------------------------------------------------------
    reg [7:0]  qlut [0:255];           // pixel 0..255 -> int8 0..127
    reg [31:0] b1   [0:HID-1];
    reg [31:0] b2   [0:15];
    initial begin
        $readmemh({MODEL_DIR, "qlut.hex"}, qlut);
        $readmemh({MODEL_DIR, "b1.hex"}, b1);
        $readmemh({MODEL_DIR, "b2.hex"}, b2);
    end

    wire [8*N-1:0] w1_rdata, w2_rdata;
    wire [12:0]    w_addr_now = w_base + wl_cnt;
    generate
        if (N == 16) begin : g_w16
            rom #(.WIDTH(8*N), .DEPTH(NT1*IN_PIX), .INIT_FILE({MODEL_DIR, "w1_n16.hex"})) u_w1 (
                .clk(clk), .addr(w_addr_now[$clog2(NT1*IN_PIX)-1:0]), .data(w1_rdata));
            rom #(.WIDTH(8*N), .DEPTH(NT2*HID), .INIT_FILE({MODEL_DIR, "w2_n16.hex"})) u_w2 (
                .clk(clk), .addr(w_addr_now[$clog2(NT2*HID)-1:0]), .data(w2_rdata));
        end else begin : g_w8
            rom #(.WIDTH(8*N), .DEPTH(NT1*IN_PIX), .INIT_FILE({MODEL_DIR, "w1_n8.hex"})) u_w1 (
                .clk(clk), .addr(w_addr_now[$clog2(NT1*IN_PIX)-1:0]), .data(w1_rdata));
            rom #(.WIDTH(8*N), .DEPTH(NT2*HID), .INIT_FILE({MODEL_DIR, "w2_n8.hex"})) u_w2 (
                .clk(clk), .addr(w_addr_now[$clog2(NT2*HID)-1:0]), .data(w2_rdata));
        end
    endgenerate

    // Image buffer: word (image*KT1 + kt) = the image's quantized pixels kt*N..kt*N+N-1
    reg                      img_we    = 0;
    reg  [$clog2(IBD)-1:0]   img_waddr = 0;
    reg  [8*N-1:0]           img_wdata = 0;
    wire [8*N-1:0]           img_rdata;
    sdp_ram #(.WIDTH(8*N), .DEPTH(IBD)) u_img (
        .clk(clk), .we(img_we), .waddr(img_waddr), .wdata(img_wdata),
        .raddr(src_addr[$clog2(IBD)-1:0]), .rdata(img_rdata)
    );

    // Hidden buffer: word (image*KT2 + slice) = 8-bit hidden units slice*N..slice*N+N-1
    reg                      hid_we    = 0;
    reg  [$clog2(HBD)-1:0]   hid_waddr = 0;
    reg  [8*N-1:0]           hid_wdata = 0;
    wire [8*N-1:0]           hid_rdata;
    sdp_ram #(.WIDTH(8*N), .DEPTH(HBD)) u_hid (
        .clk(clk), .we(hid_we), .waddr(hid_waddr), .wdata(hid_wdata),
        .raddr(src_addr[$clog2(HBD)-1:0]), .rdata(hid_rdata)
    );

    // Logits buffer: address image*16 + class
    reg                         lg_we    = 0;
    reg  [IMW+3:0]              lg_waddr = 0;
    reg  [31:0]                 lg_wdata = 0;
    wire [IMW+3:0]              lg_raddr = (state == S_E_ARG) ? {pm, ac} : {pm, lc};
    wire [31:0]                 lg_rdata;
    sdp_ram #(.WIDTH(32), .DEPTH(MAX_IMG * 16)) u_logits (
        .clk(clk), .we(lg_we), .waddr(lg_waddr), .wdata(lg_wdata),
        .raddr(lg_raddr), .rdata(lg_rdata)
    );

    // ------------------------------------------------------------------
    // Systolic array
    // ------------------------------------------------------------------
    wire              arr_pre_valid;
    wire              arr_out_valid;
    wire [32*N-1:0]   arr_c_row;

    wire   loading = (state == S_LOAD_W || state == S_ALEN || state == S_LOAD_A ||
                      state == S_CSUM_W || state == S_CSUM_A ||
                      state == S_ILEN || state == S_IPIX || state == S_ICSUM);
    assign rx_rd = !rx_empty && (state == S_IDLE || loading);

    wire       engine   = (state >= S_E_TILE && state <= S_E_ARG) || state == S_E_PDRN;
    wire [8*N-1:0] feed_data = !engine ? amem_rdata : (layer ? hid_rdata : img_rdata);

    systolic_array #(.N(N)) u_array (
        .clk       (clk),
        .rst       (rst),
        .w_we      (state == S_LOAD_W && rx_rd),
        .w_addr    (wcnt),
        .w_data    (rx_data),
        .w_row_we  (state == S_E_WLOAD && wl_cnt != 0),
        .w_row_idx (wl_cnt[BW-1:0] - 1'b1),
        .w_row_data(layer ? w2_rdata : w1_rdata),
        .in_valid  (feed_v),
        .a_row     (feed_v ? feed_data : {8*N{1'b0}}),
        .pre_valid (arr_pre_valid),
        .out_valid (arr_out_valid),
        .c_row     (arr_c_row)
    );

    // ------------------------------------------------------------------
    // Output buffer (read-modify-write for accumulate mode)
    // ------------------------------------------------------------------
    wire             reading  = (state == S_RD_ADDR || state == S_RD_SEND);
    wire [MW-1:0]    omem_raddr = reading            ? rd_row :
                                  (state == S_E_PRD) ? {{(MW-IMW){1'b0}}, pm} : pre_row;
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
    // Post-processing arithmetic: a 3-stage pipeline, one value per clock.
    // (Doing select + add + multiply + shift + clip in one 20 ns clock missed
    // timing, so each stage gets its own clock.)
    //   stage 1: pick lane pj of the output row and its bias
    //   stage 2: add the bias, multiply by REQ_MULT, add the rounding half
    //   stage 3: shift, clip to 0..127, write the hidden/logits buffer
    // ------------------------------------------------------------------
    wire [7:0]          col     = nt * N + pj;               // output unit
    wire signed [16:0]  mult    = REQ_MULT;

    reg                 p1_v = 0, p2_v = 0;
    reg [BW-1:0]        p1_pj = 0, p2_pj = 0;
    reg [7:0]           p1_col = 0, p2_col = 0;
    reg signed [31:0]   p1_elem = 0, p1_bias = 0;
    reg signed [32:0]   p2_biased = 0;
    reg signed [49:0]   p2_scaled = 0;

    wire signed [32:0]  biased  = p1_elem + p1_bias;
    wire signed [49:0]  shifted = p2_scaled >>> REQ_SHIFT;   // round half up
    wire [7:0]          h_val   = shifted < 0   ? 8'd0   :
                                  shifted > 127 ? 8'd127 : shifted[7:0];

    always @(posedge clk) begin
        // stage 1
        p1_v    <= (state == S_E_PEL);
        p1_pj   <= pj;
        p1_col  <= col;
        p1_elem <= post_row[32*pj +: 32];
        p1_bias <= layer ? b2[col[3:0]] : b1[col[5:0]];
        // stage 2
        p2_v      <= p1_v;
        p2_pj     <= p1_pj;
        p2_col    <= p1_col;
        p2_biased <= biased;
        p2_scaled <= biased * mult + (50'sd1 <<< (REQ_SHIFT - 1));
    end

    // ------------------------------------------------------------------
    // Transmit mux
    // ------------------------------------------------------------------
    // INFER reply frame: status, B digits, 4 cycle-count bytes, checksum
    wire [7:0] n_dig = b_last + 1'b1;
    reg  [7:0] frame_byte;
    always @(*) begin
        if (ridx == 0)
            frame_byte = infer_ok ? RSP_INFER : RSP_BAD;
        else if (ridx <= n_dig)
            frame_byte = infer_ok ? {4'd0, digit[ridx - 1]} : 8'd0;
        else if (ridx <= n_dig + 4)
            frame_byte = infer_ok ? icycles[8*(ridx - n_dig - 1) +: 8] : 8'd0;
        else
            frame_byte = csum;
    end

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
        end else if (state == S_I_RESP) begin
            tx_data = frame_byte;
            tx_wr   = !tx_full;
        end else if (state == S_L_SEND) begin
            tx_data = (lc == 4'd10) ? csum : lg_rdata[8*lbyte +: 8];
            tx_wr   = !tx_full;
        end
    end

    assign busy      = (state == S_FEED || state == S_DRAIN) || engine;
    assign cmd_error = err_flag;

    // ------------------------------------------------------------------
    // Main state machine
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        amem_we  <= 1'b0;
        img_we   <= 1'b0;
        hid_we   <= 1'b0;
        lg_we    <= 1'b0;
        feed_v   <= 1'b0;
        err_flag <= 1'b0;

        if (rst) begin
            state <= S_IDLE;
        end else begin
            // output-side bookkeeping runs whenever the array produces data
            if (arr_pre_valid) pre_row <= pre_row + 1'b1;
            if (arr_out_valid) wr_row  <= wr_row + 1'b1;
            if (state == S_FEED || state == S_DRAIN) cycles <= cycles + 1'b1;
            if (engine) icycles <= icycles + 1'b1;

            // A LOAD that goes quiet means a byte was lost: give up on it.
            if (loading && !rx_rd) quiet <= quiet + 1'b1;
            else                   quiet <= 0;

            // Post-processing stage 3: store the finished value
            if (p2_v) begin
                if (!layer) begin
                    h_word[8*p2_pj +: 8] <= h_val;
                    if (p2_pj == N - 1) begin
                        hid_we    <= 1'b1;
                        hid_waddr <= pm * KT2 + nt;
                        hid_wdata <= {h_val, h_word[8*(N-1)-1:0]};
                    end
                end else if (p2_col < OUTS) begin
                    lg_we    <= 1'b1;
                    lg_waddr <= {pm, p2_col[3:0]};
                    lg_wdata <= p2_biased[31:0];
                end
            end

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
                        CMD_INFER: begin
                            csum  <= 0;
                            state <= S_ILEN;
                        end
                        CMD_LOGITS: begin
                            pm    <= 0;
                            lc    <= 0;
                            lbyte <= 0;
                            csum  <= 0;
                            state <= S_L_ADDR;
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

                // ---------------------------------------------------------
                // INFER: receive the images
                // ---------------------------------------------------------
                S_ILEN: if (rx_rd) begin
                    csum      <= csum + rx_data;
                    b_last    <= rx_data[IMW-1:0];
                    px_cnt    <= 0;
                    px_img    <= 0;
                    px_lane   <= 0;
                    img_waddr <= {$clog2(IBD){1'b1}};   // first write lands on word 0
                    state     <= S_IPIX;
                end

                // Pixels arrive image by image, so image-buffer words fill in
                // address order: just count up.
                S_IPIX: if (rx_rd) begin
                    csum <= csum + rx_data;
                    if (px_lane == N - 1) begin
                        img_we    <= 1'b1;
                        img_waddr <= img_waddr + 1'b1;
                        img_wdata <= {qlut[rx_data], px_word[8*(N-1)-1:0]};
                        px_lane   <= 0;
                    end else begin
                        px_word[8*px_lane +: 8] <= qlut[rx_data];
                        px_lane <= px_lane + 1'b1;
                    end
                    if (px_cnt == IN_PIX - 1) begin
                        px_cnt <= 0;
                        px_img <= px_img + 1'b1;
                        if (px_img == b_last) state <= S_ICSUM;
                    end else begin
                        px_cnt <= px_cnt + 1'b1;
                    end
                end

                S_ICSUM: if (rx_rd) begin
                    infer_ok <= (rx_data == csum);
                    csum     <= 0;
                    ridx     <= 0;
                    if (rx_data == csum) begin           // start the network
                        icycles   <= 0;
                        layer     <= 0;
                        nt        <= 0;
                        kt        <= 0;
                        w_nt_base <= 0;
                        w_base    <= 0;
                        state     <= S_E_TILE;
                    end else begin
                        state     <= S_I_RESP;           // reply EC
                    end
                end

                // ---------------------------------------------------------
                // INFER: run one weight tile
                // ---------------------------------------------------------
                S_E_TILE: begin
                    acc_mode <= (kt != 0);
                    m_last   <= {{(MW-IMW){1'b0}}, b_last};
                    feed_cnt <= 0;
                    pre_row  <= 0;
                    wr_row   <= 0;
                    wl_cnt   <= 0;
                    state    <= S_E_WLOAD;
                end

                // ROM address for row wl_cnt goes out this cycle; its data
                // comes back next cycle and is written into PE row wl_cnt-1.
                S_E_WLOAD: begin
                    wl_cnt <= wl_cnt + 1'b1;
                    if (wl_cnt == N) begin
                        src_addr <= kt;                  // image 0's slice kt
                        state    <= S_E_FEED;
                    end
                end

                S_E_FEED: begin
                    feed_v   <= 1'b1;
                    feed_cnt <= feed_cnt + 1'b1;
                    src_addr <= src_addr + (layer ? KT2 : KT1);
                    if (feed_cnt == m_last) state <= S_E_DRAIN;
                end

                S_E_DRAIN: begin
                    if (arr_out_valid && wr_row == m_last) begin
                        if (kt == (layer ? KT2 - 1 : KT1 - 1)) begin
                            pm    <= 0;
                            state <= S_E_PRD;            // slice finished
                        end else begin
                            kt     <= kt + 1'b1;
                            w_base <= w_base + N;
                            state  <= S_E_TILE;
                        end
                    end
                end

                // ---------------------------------------------------------
                // INFER: post-process a finished output slice
                // ---------------------------------------------------------
                S_E_PRD:  state <= S_E_PLAT;             // omem read issued (raddr = pm)

                S_E_PLAT: begin
                    post_row <= omem_rdata;
                    pj       <= 0;
                    state    <= S_E_PEL;
                end

                // feed lanes 0..N-1 into the pipeline, one per clock
                S_E_PEL: begin
                    pj <= pj + 1'b1;
                    if (pj == N - 1) begin
                        wl_cnt <= 0;                     // reused as a 2-cycle counter
                        state  <= S_E_PDRN;
                    end
                end

                // the last lanes finish stages 2 and 3; then decide what's next
                S_E_PDRN: begin
                    wl_cnt <= wl_cnt + 1'b1;
                    if (wl_cnt == 1) begin
                        if (pm != b_last) begin
                            pm    <= pm + 1'b1;
                            state <= S_E_PRD;
                        end else if (nt != (layer ? NT2 - 1 : NT1 - 1)) begin
                            nt        <= nt + 1'b1;          // next output slice
                            kt        <= 0;
                            w_nt_base <= w_nt_base + (layer ? HID : IN_PIX);
                            w_base    <= w_nt_base + (layer ? HID : IN_PIX);
                            state     <= S_E_TILE;
                        end else if (!layer) begin
                            layer     <= 1'b1;               // on to layer 2
                            nt        <= 0;
                            kt        <= 0;
                            w_nt_base <= 0;
                            w_base    <= 0;
                            state     <= S_E_TILE;
                        end else begin
                            pm    <= 0;                      // all logits done
                            ac    <= 0;
                            state <= S_E_ARG;
                        end
                    end
                end

                // ---------------------------------------------------------
                // INFER: argmax. The logit of class ac is requested this
                // cycle and compared next cycle (as class ac-1).
                // ---------------------------------------------------------
                S_E_ARG: begin
                    if (ac != 0) begin
                        if (ac == 1 || $signed(lg_rdata) > best_v) begin
                            best_v <= lg_rdata;
                            best_i <= ac - 1'b1;
                        end
                    end
                    if (ac == OUTS) begin
                        // the compare above (class 9) lands in best_* this
                        // cycle, so decide using the same condition here
                        digit[pm] <= ($signed(lg_rdata) > best_v) ? 4'd9 : best_i;
                        ac <= 0;
                        if (pm == b_last) begin
                            state <= S_I_RESP;
                        end else begin
                            pm <= pm + 1'b1;
                        end
                    end else begin
                        ac <= ac + 1'b1;
                    end
                end

                S_I_RESP: if (tx_wr) begin
                    csum <= csum + tx_data;
                    ridx <= ridx + 1'b1;
                    if (ridx == n_dig + 5) state <= S_IDLE;
                end

                // ---------------------------------------------------------
                // READ_LOGITS: B images x 10 int32, then the checksum
                // ---------------------------------------------------------
                S_L_ADDR: state <= S_L_SEND;             // logits read issued

                S_L_SEND: if (tx_wr) begin
                    csum <= csum + tx_data;
                    if (lc == 4'd10) begin               // checksum byte sent
                        state <= S_IDLE;
                    end else if (lbyte == 2'd3) begin
                        lbyte <= 0;
                        if (lc == OUTS - 1) begin
                            if (pm == b_last) begin
                                lc    <= 4'd10;          // next: checksum
                            end else begin
                                lc    <= 0;
                                pm    <= pm + 1'b1;
                                state <= S_L_ADDR;
                            end
                        end else begin
                            lc    <= lc + 1'b1;
                            state <= S_L_ADDR;
                        end
                    end else begin
                        lbyte <= lbyte + 1'b1;
                    end
                end

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
