// sync_fifo.v
// Synchronous first-in first-out buffer, "first-word fall-through" style:
// the oldest entry is always visible on `dout` while `empty` is low, and
// `rd_en` removes it.
//
// Pointers are one bit wider than the address. When the addresses match the
// FIFO is either empty (extra bits equal) or full (extra bits differ). This is
// the standard trick for telling full and empty apart without a counter.
//
// DEPTH must be a power of 2.

module sync_fifo #(
    parameter WIDTH = 8,
    parameter DEPTH = 64
) (
    input  wire             clk,
    input  wire             rst,
    input  wire             wr_en,
    input  wire [WIDTH-1:0] din,
    output wire             full,
    input  wire             rd_en,
    output wire [WIDTH-1:0] dout,
    output wire             empty
);
    localparam AW = $clog2(DEPTH);

    reg [WIDTH-1:0] mem [0:DEPTH-1];
    reg [AW:0]      wptr = 0;
    reg [AW:0]      rptr = 0;

    assign empty = (wptr == rptr);
    assign full  = (wptr[AW] != rptr[AW]) && (wptr[AW-1:0] == rptr[AW-1:0]);
    assign dout  = mem[rptr[AW-1:0]];

    always @(posedge clk) begin
        if (rst) begin
            wptr <= 0;
            rptr <= 0;
        end else begin
            if (wr_en && !full) begin
                mem[wptr[AW-1:0]] <= din;
                wptr <= wptr + 1'b1;
            end
            if (rd_en && !empty) begin
                rptr <= rptr + 1'b1;
            end
        end
    end
endmodule
