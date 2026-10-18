// demo.v
// Standalone demo: classify stored MNIST test images with no laptop attached.
//
// About 100 test images live in block RAM, quantized and compressed exactly
// the way the laptop sends them (rtl/model/demo_*.hex, written by
// host/export_model.py). This module plays the part of the laptop *inside*
// the chip: it feeds the accelerator core an INFER_RLE command byte by byte,
// through the same input the UART normally drives, and reads the reply. The
// core itself is unchanged and doesn't know the difference.
//
//   start_one : classify image `sel` (shows its true and predicted digit)
//   start_all : classify every stored image in batches of BATCH, count how
//               many are right, and time the whole run in microseconds
//
// It only takes over the core when the core is idle, and hands it back after
// the reply, so laptop commands keep working between demo runs.

module demo #(
    parameter BYTES     = 16384,          // compressed image store (16 M9K)
    parameter MAX_IMGS  = 128,
    parameter BATCH     = 32,             // = the core's MAX_IMG
    parameter CLK_MHZ   = 50,
    parameter MODEL_DIR = "../rtl/model/"
) (
    input  wire        clk,
    input  wire        rst,

    input  wire        start_one,
    input  wire        start_all,
    input  wire [6:0]  sel,
    input  wire        core_idle,

    // byte source for the core (first-word fall-through, like the RX FIFO)
    output reg         active = 1'b0,
    output wire        empty,
    output reg  [7:0]  data,
    input  wire        rd,
    // the core's reply bytes
    input  wire [7:0]  tx_data,
    input  wire        tx_wr,

    // results
    output wire [6:0]  count,             // images stored
    output reg  [6:0]  shown_idx   = 0,
    output reg  [3:0]  shown_label = 0,
    output reg  [3:0]  shown_pred  = 0,
    output reg         shown_valid = 1'b0,
    output reg  [7:0]  n_correct   = 0,
    output reg  [7:0]  n_total     = 0,
    output reg  [19:0] run_us      = 0,   // whole run-all, start to finish, in microseconds
    output reg  [31:0] run_cycles  = 0,   // sum of the accelerator's compute cycles
    output reg         all_done    = 1'b0
);
    localparam CMD_INFER_RLE = 8'h4A;
    localparam RSP_INFER     = 8'hD1;

    // ---------------------------------------------------------------- stores
    reg [15:0] index  [0:MAX_IMGS-1];     // start offset of each image
    reg [3:0]  labels [0:MAX_IMGS-1];
    reg [7:0]  n_store [0:0];
    initial begin
        $readmemh({MODEL_DIR, "demo_index.hex"}, index);
        $readmemh({MODEL_DIR, "demo_labels.hex"}, labels);
        $readmemh({MODEL_DIR, "demo_count.hex"}, n_store);
    end
    assign count = n_store[0][6:0];

    reg  [$clog2(BYTES)-1:0] ra = 0;      // byte store read address
    wire [7:0]               rom_byte;
    rom #(.WIDTH(8), .DEPTH(BYTES), .INIT_FILE({MODEL_DIR, "demo_bytes.hex"})) u_bytes (
        .clk(clk), .addr(ra), .data(rom_byte));

    // ---------------------------------------------------------------- sequencer
    localparam D_IDLE = 3'd0, D_CMD = 3'd1, D_LEN = 3'd2, D_BODY = 3'd3,
               D_CSUM = 3'd4, D_WAIT = 3'd5;

    reg [2:0]  st      = D_IDLE;
    reg        all     = 1'b0;            // run-all in progress
    reg [6:0]  k0      = 0;               // first image of this batch
    reg [6:0]  b       = 0;               // images in this batch
    reg [15:0] body_end = 0;              // one past the batch's last byte
    reg        have    = 1'b0;            // rom_byte is valid for address ra
    reg [7:0]  csum    = 0;
    reg [7:0]  ridx    = 0;               // reply byte index
    reg        reply_ok = 1'b0;
    reg [5:0]  us_div  = 0;               // clocks -> microseconds
    reg        timing  = 1'b0;

    wire [6:0] remaining = count - k0;
    wire [6:0] batch_n   = (remaining > BATCH) ? BATCH[6:0] : remaining;
    wire [6:0] sel_ok    = (sel < count) ? sel : count - 1'b1;

    assign empty = !((st == D_CMD) || (st == D_LEN) || (st == D_CSUM) || (st == D_BODY && have));

    always @(*) begin
        case (st)
            D_CMD:   data = CMD_INFER_RLE;
            D_LEN:   data = {1'b0, b - 1'b1};
            D_BODY:  data = rom_byte;
            default: data = csum;
        endcase
    end

    always @(posedge clk) begin
        // microsecond timer for run-all
        if (timing) begin
            if (us_div == CLK_MHZ - 1) begin
                us_div <= 0;
                run_us <= run_us + 1'b1;
            end else begin
                us_div <= us_div + 1'b1;
            end
        end

        if (rst) begin
            st     <= D_IDLE;
            active <= 1'b0;
            all    <= 1'b0;
            timing <= 1'b0;
        end else begin
            case (st)
                D_IDLE: begin
                    // start a batch: a new single image, a new run-all, or
                    // the next batch of a run-all that is in progress
                    if (core_idle && (start_one || start_all || all)) begin
                        if (start_one && !all) begin
                            k0 <= sel_ok;
                            b  <= 7'd1;
                        end else if (start_all && !all) begin
                            all        <= 1'b1;
                            all_done   <= 1'b0;
                            k0         <= 0;
                            b          <= (count > BATCH) ? BATCH[6:0] : count;
                            n_correct  <= 0;
                            n_total    <= 0;
                            run_us     <= 0;
                            run_cycles <= 0;
                            us_div     <= 0;
                            timing     <= 1'b1;
                        end else begin
                            b <= batch_n;                // next batch (k0 already advanced)
                        end
                        active <= 1'b1;
                        st     <= D_CMD;
                    end
                end

                D_CMD: if (rd) begin
                    csum <= 0;
                    st   <= D_LEN;
                end

                D_LEN: if (rd) begin
                    csum     <= {1'b0, b - 1'b1};
                    ra       <= index[k0][$clog2(BYTES)-1:0];
                    body_end <= index[k0 + b];
                    have     <= 1'b0;
                    st       <= D_BODY;
                end

                // one byte every two clocks: address out, data back, consumed
                D_BODY: begin
                    if (!have) begin
                        have <= 1'b1;
                    end else if (rd) begin
                        csum <= csum + rom_byte;
                        have <= 1'b0;
                        if ({2'b00, ra} == body_end - 1'b1) st <= D_CSUM;
                        else ra <= ra + 1'b1;
                    end
                end

                D_CSUM: if (rd) begin
                    ridx <= 0;
                    st   <= D_WAIT;
                end

                // reply: status, b digits, 4 cycle-count bytes, checksum
                D_WAIT: if (tx_wr) begin
                    ridx <= ridx + 1'b1;
                    if (ridx == 0) begin
                        reply_ok <= (tx_data == RSP_INFER);
                    end else if (ridx <= b) begin
                        // only a run-all counts toward the right/total display
                        if (all && reply_ok && tx_data[3:0] == labels[k0 + ridx - 1])
                            n_correct <= n_correct + 1'b1;
                        if (!all) begin
                            shown_idx   <= k0;
                            shown_label <= labels[k0];
                            shown_pred  <= tx_data[3:0];
                            shown_valid <= reply_ok;
                        end
                    end else if (ridx <= b + 4) begin
                        if (all) run_cycles <= run_cycles + (tx_data << (8 * (ridx - b - 1)));
                    end else begin                       // checksum byte: reply done
                        active  <= 1'b0;
                        st      <= D_IDLE;
                        if (all) begin
                            n_total <= n_total + b;
                            if (k0 + b >= count) begin
                                all      <= 1'b0;
                                all_done <= 1'b1;
                                timing   <= 1'b0;
                            end else begin
                                k0 <= k0 + b;
                            end
                        end
                    end
                end

                default: st <= D_IDLE;
            endcase
        end
    end
endmodule
