// rom.v
// Read-only memory with a registered read, filled from a hex file when the
// FPGA is configured ($readmemh works in both Quartus and Icarus). Quartus
// maps it onto M9K block RAM, so the MNIST weights cost no logic.

module rom #(
    parameter WIDTH     = 64,
    parameter DEPTH     = 256,
    parameter INIT_FILE = ""
) (
    input  wire                     clk,
    input  wire [$clog2(DEPTH)-1:0] addr,
    output reg  [WIDTH-1:0]         data
);
    reg [WIDTH-1:0] mem [0:DEPTH-1];
    initial $readmemh(INIT_FILE, mem);

    always @(posedge clk) data <= mem[addr];
endmodule
