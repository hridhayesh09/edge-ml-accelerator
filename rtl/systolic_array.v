// systolic_array.v
// N x N weight-stationary systolic array (default 8 x 8 = 64 PEs).
//
// Computes one row of C = A x W per clock cycle, where
//   A is M x N  (activations, streamed in one row per cycle)
//   W is N x N  (weights, loaded once and kept inside the PEs)
//   C is M x N  (32-bit results, streamed out one row per cycle)
//
// PE[i][j] holds W[i][j]. Activation A[m][i] flows left-to-right along row i,
// and partial sums flow top-to-bottom down column j, so the bottom of column j
// produces sum_i A[m][i] * W[i][j] = C[m][j].
//
// Skewing: the sum for column j picks up row 0's product first, then row 1's
// one cycle later, and so on. So A[m][i] must enter row i exactly i cycles
// after A[m][0] enters row 0. The input skew registers do that. Column j's
// result also comes out j cycles after column 0's, so the output deskew
// registers delay column j by (N-1-j) cycles to line a full row back up.
//
// Latency: a row presented on a_row with in_valid=1 comes out on c_row with
// out_valid=1 exactly LAT = 2N-1 cycles later. pre_valid goes high one cycle
// before out_valid (the controller uses it to start a RAM read early).

module systolic_array #(
    parameter N = 8
) (
    input  wire                 clk,
    input  wire                 rst,

    // weight loading, one byte at a time (from the UART):
    //   weight index = i*N + j  (row i = input k, column j = output n)
    input  wire                 w_we,
    input  wire [$clog2(N*N)-1:0] w_addr,
    input  wire [7:0]           w_data,

    // weight loading, one whole row of PEs per clock (from the on-chip
    // weight ROM): w_row_data[8*j +: 8] goes into PE[w_row_idx][j]
    input  wire                 w_row_we,
    input  wire [$clog2(N)-1:0] w_row_idx,
    input  wire [8*N-1:0]       w_row_data,

    // activation input: a_row[8*i +: 8] = A[m][i]
    input  wire                 in_valid,
    input  wire [8*N-1:0]       a_row,

    // result output: c_row[32*j +: 32] = C[m][j]
    output wire                 pre_valid,
    output wire                 out_valid,
    output wire [32*N-1:0]      c_row
);
    localparam LAT = 2 * N - 1;

    // a_h: horizontal activation wires, N rows with N+1 taps each
    //   a_h[i*(N+1) + j] = activation entering PE[i][j]
    // p_v: vertical partial-sum wires, N+1 rows of N columns
    //   p_v[i*N + j]     = partial sum entering PE[i][j]
    // (Arrays of separate wires rather than one giant bus: simulators handle
    //  this much faster, and it reads closer to the picture of the grid.)
    wire [7:0]  a_h [0:N*(N+1)-1];
    wire [31:0] p_v [0:N*(N+1)-1];

    genvar i, j;

    // ---------------------------------------------------------------
    // Input skew: row i is delayed by i cycles
    // ---------------------------------------------------------------
    generate
        for (i = 0; i < N; i = i + 1) begin : g_skew
            if (i == 0) begin : g_direct
                assign a_h[i*(N+1)] = a_row[8*i +: 8];
            end else begin : g_delay
                reg [7:0] sr [0:i-1];
                integer k;
                initial for (k = 0; k < i; k = k + 1) sr[k] = 8'd0;
                always @(posedge clk) begin
                    sr[0] <= a_row[8*i +: 8];
                    for (k = 1; k < i; k = k + 1)
                        sr[k] <= sr[k-1];
                end
                assign a_h[i*(N+1)] = sr[i-1];
            end
        end
    endgenerate

    // ---------------------------------------------------------------
    // The PE grid
    // ---------------------------------------------------------------
    generate
        for (j = 0; j < N; j = j + 1) begin : g_ptop
            assign p_v[j] = 32'd0;     // nothing above the top row
        end

        for (i = 0; i < N; i = i + 1) begin : g_row
            for (j = 0; j < N; j = j + 1) begin : g_col
                pe u_pe (
                    .clk  (clk),
                    .w_we ((w_we && (w_addr == i*N + j)) || (w_row_we && (w_row_idx == i))),
                    .w_in (w_row_we ? w_row_data[8*j +: 8] : w_data),
                    .a_in (a_h[i*(N+1) + j]),
                    .a_out(a_h[i*(N+1) + j + 1]),
                    .p_in (p_v[i*N + j]),
                    .p_out(p_v[(i+1)*N + j])
                );
            end
        end
    endgenerate

    // ---------------------------------------------------------------
    // Output deskew: column j is delayed by N-1-j cycles
    // ---------------------------------------------------------------
    generate
        for (j = 0; j < N; j = j + 1) begin : g_deskew
            if (j == N - 1) begin : g_direct
                assign c_row[32*j +: 32] = p_v[N*N + j];
            end else begin : g_delay
                reg [31:0] sr [0:N-2-j];
                integer k;
                initial for (k = 0; k <= N-2-j; k = k + 1) sr[k] = 32'd0;
                always @(posedge clk) begin
                    sr[0] <= p_v[N*N + j];
                    for (k = 1; k <= N-2-j; k = k + 1)
                        sr[k] <= sr[k-1];
                end
                assign c_row[32*j +: 32] = sr[N-2-j];
            end
        end
    endgenerate

    // ---------------------------------------------------------------
    // Valid pipeline: tracks which output cycles hold real results
    // ---------------------------------------------------------------
    reg [LAT-1:0] vpipe = 0;
    always @(posedge clk) begin
        if (rst) vpipe <= 0;
        else     vpipe <= {vpipe[LAT-2:0], in_valid};
    end
    assign out_valid = vpipe[LAT-1];
    assign pre_valid = vpipe[LAT-2];

endmodule
