// sdp_ram.v
// Simple dual-port RAM: one write port, one read port, registered read.
// Written in the style Quartus recognizes, so it maps onto the MAX 10's
// M9K block RAM instead of being built out of logic elements.

module sdp_ram #(
    parameter WIDTH = 64,
    parameter DEPTH = 256
) (
    input  wire                     clk,
    input  wire                     we,
    input  wire [$clog2(DEPTH)-1:0] waddr,
    input  wire [WIDTH-1:0]         wdata,
    input  wire [$clog2(DEPTH)-1:0] raddr,
    output reg  [WIDTH-1:0]         rdata
);
    reg [WIDTH-1:0] mem [0:DEPTH-1];

    always @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
        rdata <= mem[raddr];
    end
endmodule
