// pe.v
// Processing element (PE): one cell of the systolic array.
//
// Each PE holds one INT8 weight. Every clock cycle it:
//   1. multiplies the activation coming from the left by its weight,
//   2. adds that to the partial sum coming from above,
//   3. passes the activation to the right and the new sum downward.
//
// Both outputs are registers, so a value moves exactly one PE per cycle.
// That is what makes the array "systolic": data pulses through it in waves.
//
// The partial sum is 32 bits. The largest possible column sum in an 8x8
// array is 8 * (-128) * (-128) = 131072, which needs 18 bits, so 32 bits also
// leaves room for accumulating across many tiles without overflow.

module pe (
    input  wire               clk,
    input  wire               w_we,     // load a new weight
    input  wire signed [7:0]  w_in,
    input  wire signed [7:0]  a_in,     // activation from the left
    input  wire signed [31:0] p_in,     // partial sum from above
    output reg  signed [7:0]  a_out = 0,// activation to the right
    output reg  signed [31:0] p_out = 0 // partial sum downward
);
    reg signed [7:0] w = 0;

    always @(posedge clk) begin
        if (w_we) w <= w_in;
        a_out <= a_in;
        p_out <= p_in + a_in * w;   // all operands signed: signed multiply-add
    end
endmodule
