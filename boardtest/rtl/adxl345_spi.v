// adxl345_spi.v
// Reads the ADXL345 accelerometer on the DE10-Lite over 3-wire SPI (the same
// mode Terasic's own demo uses: one bidirectional data pin, GSENSOR_SDI).
//
// SPI mode 3: SCLK idles high, we change data on the falling edge, both sides
// sample on the rising edge. Each transfer is 16 bits: a command byte
// (bit 7 = read, bits 5:0 = register) then a data byte.
//
// Sequence: wait 2 ms after power-up, write DATA_FORMAT = 0x40 (3-wire SPI,
// +/-2 g, 10-bit), write POWER_CTL = 0x08 (start measuring), then loop reading
// DEVID (always 0xE5 on a working chip) and the X/Y/Z axis registers.
// At +/-2 g, 10-bit, 1 g = 256 counts.

module adxl345_spi #(
    parameter HALF = 25,             // SCLK half period in clocks: 1 MHz
    parameter GAP  = 1000,           // idle clocks between transfers
    parameter STARTUP = 100_000      // 2 ms power-up wait
) (
    input  wire       clk,
    output reg        cs_n = 1'b1,
    output reg        sclk = 1'b1,
    inout  wire       sdio,
    output reg  [7:0] devid = 8'h00,
    output reg  [9:0] x = 10'd0,
    output reg  [9:0] y = 10'd0,
    output reg  [9:0] z = 10'd0
);
    reg sdo_r = 1'b0, oe = 1'b0;
    assign sdio = oe ? sdo_r : 1'bz;

    reg s_meta = 1'b0, s_sync = 1'b0;
    always @(posedge clk) begin
        s_meta <= sdio;
        s_sync <= s_meta;
    end

    // Transfer list: {read, register, write data}
    function [15:0] word(input [3:0] step);
        case (step)
            4'd0: word = {1'b0, 1'b0, 6'h31, 8'h40};   // DATA_FORMAT: 3-wire SPI
            4'd1: word = {1'b0, 1'b0, 6'h2D, 8'h08};   // POWER_CTL: measure
            4'd2: word = {1'b1, 1'b0, 6'h00, 8'h00};   // DEVID
            4'd3: word = {1'b1, 1'b0, 6'h32, 8'h00};   // DATAX0
            4'd4: word = {1'b1, 1'b0, 6'h33, 8'h00};   // DATAX1
            4'd5: word = {1'b1, 1'b0, 6'h34, 8'h00};   // DATAY0
            4'd6: word = {1'b1, 1'b0, 6'h35, 8'h00};   // DATAY1
            4'd7: word = {1'b1, 1'b0, 6'h36, 8'h00};   // DATAZ0
            default: word = {1'b1, 1'b0, 6'h37, 8'h00}; // DATAZ1
        endcase
    endfunction

    localparam S_GAP = 2'd0, S_SETUP = 2'd1, S_LOW = 2'd2, S_HIGH = 2'd3;

    reg [1:0]  state = S_GAP;
    reg [16:0] cnt   = STARTUP;
    reg [3:0]  step  = 4'd0;
    reg [3:0]  bitn  = 4'd0;
    reg [15:0] tx    = 16'd0;
    reg [7:0]  rx    = 8'd0;
    reg [7:0]  xl = 0, yl = 0, zl = 0;
    reg        is_read = 1'b0;

    always @(posedge clk) begin
        if (cnt != 0) begin
            cnt <= cnt - 1'b1;
        end else begin
            case (state)
                S_GAP: begin                    // select the chip
                    tx      <= word(step);
                    is_read <= word(step) >> 15;
                    cs_n    <= 1'b0;
                    bitn    <= 4'd0;
                    cnt     <= HALF;
                    state   <= S_SETUP;
                end
                S_SETUP: begin                  // first falling edge, bit 15
                    sclk  <= 1'b0;
                    sdo_r <= tx[15];
                    oe    <= 1'b1;
                    cnt   <= HALF;
                    state <= S_LOW;
                end
                S_LOW: begin                    // rising edge: sample
                    sclk  <= 1'b1;
                    rx    <= {rx[6:0], s_sync};
                    cnt   <= HALF;
                    state <= S_HIGH;
                end
                S_HIGH: begin
                    if (bitn == 4'd15) begin    // done: deselect, store result
                        cs_n <= 1'b1;
                        oe   <= 1'b0;
                        case (step)
                            4'd2: devid <= rx;
                            4'd3: xl <= rx;
                            4'd4: x  <= {rx[1:0], xl};
                            4'd5: yl <= rx;
                            4'd6: y  <= {rx[1:0], yl};
                            4'd7: zl <= rx;
                            4'd8: z  <= {rx[1:0], zl};
                            default: ;
                        endcase
                        step  <= (step == 4'd8) ? 4'd2 : step + 1'b1;
                        cnt   <= GAP;
                        state <= S_GAP;
                    end else begin              // next falling edge
                        bitn  <= bitn + 1'b1;
                        tx    <= tx << 1;
                        sclk  <= 1'b0;
                        sdo_r <= tx[14];
                        // reads: let go of the data pin for the data byte
                        if (is_read && bitn == 4'd7) oe <= 1'b0;
                        cnt   <= HALF;
                        state <= S_LOW;
                    end
                end
            endcase
        end
    end
endmodule
