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
// The partial sum is 32 bits. The largest possible column sum in a 16x16
// array is 16 * (-128) * (-128) = 262144, which needs 19 bits, so 32 bits also
// leaves room for accumulating across many tiles without overflow.
//
// USE_DSP picks where the 8x8 multiplier is built. The MAX 10 has 144 DSP
// blocks; each PE's weight register has its own load enable, so in practice
// one PE fits per block. A 16x16 array (256 PEs) therefore builds half of its
// multipliers in DSP blocks and half out of logic elements.

module pe #(
    parameter USE_DSP = 1
) (
    input  wire               clk,
    input  wire               w_we,     // load a new weight
    input  wire signed [7:0]  w_in,
    input  wire signed [7:0]  a_in,     // activation from the left
    input  wire signed [31:0] p_in,     // partial sum from above
    output reg  signed [7:0]  a_out = 0,// activation to the right
    output reg  signed [31:0] p_out = 0 // partial sum downward
);
    reg signed [7:0] w = 0;
    wire signed [15:0] prod;

    generate
        if (USE_DSP) begin : g_dsp
            assign prod = a_in * w;                     // all operands signed
        end else begin : g_logic
            // Shift-and-add multiply, written out so it can only be built from
            // logic (Quartus ignored a multstyle hint). In two's complement the
            // weight's top bit is worth -128, so that partial product is
            // subtracted:  a*w = sum_{k<7} w[k]*(a<<k) - w[7]*(a<<7)
            wire signed [15:0] a16 = a_in;
            wire signed [15:0] pp [0:7];
            genvar k;
            for (k = 0; k < 8; k = k + 1) begin : g_pp
                assign pp[k] = w[k] ? (a16 <<< k) : 16'sd0;
            end
            assign prod = ((pp[0] + pp[1]) + (pp[2] + pp[3])) +
                          ((pp[4] + pp[5]) + pp[6]) - pp[7];
        end
    endgenerate

    always @(posedge clk) begin
        if (w_we) w <= w_in;
        a_out <= a_in;
        p_out <= p_in + prod;       // signed multiply-add
    end
endmodule
