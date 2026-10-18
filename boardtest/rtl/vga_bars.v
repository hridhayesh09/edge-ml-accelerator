// vga_bars.v
// 640x480 @ 60 Hz test pattern (25 MHz pixel clock = 50 MHz / 2).
//   top half:    8 color bars (white, yellow, cyan, green, magenta, red, blue, black)
//   bottom half: 16-step ramps of red, green, blue and gray, which exercise
//                every one of the 12 VGA resistor-DAC bits
//   a 1-pixel white border shows whether the monitor lines the picture up

module vga_bars (
    input  wire       clk,
    output reg        hs = 1'b1,
    output reg        vs = 1'b1,
    output reg  [3:0] r = 4'd0,
    output reg  [3:0] g = 4'd0,
    output reg  [3:0] b = 4'd0
);
    reg       pix_en = 1'b0;
    reg [9:0] hc = 10'd0, vc = 10'd0;

    wire [2:0] bar   = hc / 80;
    wire [3:0] level = hc / 40;
    wire [1:0] band  = (vc - 10'd240) / 60;

    always @(posedge clk) begin
        pix_en <= ~pix_en;
        if (pix_en) begin
            if (hc == 10'd799) begin
                hc <= 10'd0;
                vc <= (vc == 10'd524) ? 10'd0 : vc + 1'b1;
            end else begin
                hc <= hc + 1'b1;
            end

            hs <= ~(hc >= 10'd656 && hc < 10'd752);   // active-low syncs
            vs <= ~(vc >= 10'd490 && vc < 10'd492);

            if (hc >= 10'd640 || vc >= 10'd480) begin
                {r, g, b} <= 12'h000;                  // blanking
            end else if (hc == 0 || hc == 639 || vc == 0 || vc == 479) begin
                {r, g, b} <= 12'hFFF;
            end else if (vc < 10'd240) begin
                r <= {4{~bar[1]}};
                g <= {4{~bar[2]}};
                b <= {4{~bar[0]}};
            end else begin
                r <= (band == 2'd0 || band == 2'd3) ? level : 4'd0;
                g <= (band == 2'd1 || band == 2'd3) ? level : 4'd0;
                b <= (band == 2'd2 || band == 2'd3) ? level : 4'd0;
            end
        end
    end
endmodule
