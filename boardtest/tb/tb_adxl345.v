// tb_adxl345.v
// Checks adxl345_spi against a tiny SPI-mode-3, 3-wire ADXL345 stand-in:
// register writes must land, DEVID must read back as E5, and the axis
// registers must be reassembled into 10-bit values.
//
// iverilog -g2012 -o sim tb_adxl345.v ../rtl/adxl345_spi.v && vvp sim

`timescale 1ns/1ps

module tb_adxl345;
    reg clk = 0;
    always #10 clk = ~clk;

    wire cs_n, sclk, sdio;
    wire [7:0] devid;
    wire [9:0] x, y, z;

    adxl345_spi #(.HALF(25), .GAP(100), .STARTUP(100)) dut (
        .clk(clk), .cs_n(cs_n), .sclk(sclk), .sdio(sdio),
        .devid(devid), .x(x), .y(y), .z(z)
    );

    // ---- fake ADXL345
    reg [7:0] regs [0:63];
    initial begin
        regs[6'h00] = 8'hE5;
        regs[6'h31] = 8'h00;  regs[6'h2D] = 8'h00;
        regs[6'h32] = 8'h34;  regs[6'h33] = 8'h01;   // X = 0x134
        regs[6'h34] = 8'hCD;  regs[6'h35] = 8'h03;   // Y = 0x3CD (negative)
        regs[6'h36] = 8'h00;  regs[6'h37] = 8'h01;   // Z = 0x100 (+1 g)
    end

    reg [4:0] n = 0;
    reg [7:0] cmd = 0, wdata = 0, rdata = 0;
    reg       drive = 0, bitout = 0;
    integer   contention = 0;
    assign sdio = drive ? bitout : 1'bz;

    always @(negedge cs_n) begin n = 0; drive = 0; end
    always @(posedge cs_n) begin
        drive = 0;
        if (!cmd[7]) regs[cmd[5:0]] = wdata;
    end
    always @(posedge sclk) if (!cs_n) begin          // sample on rising edge
        if (n < 8) cmd = {cmd[6:0], sdio};
        else if (!cmd[7]) wdata = {wdata[6:0], sdio};
        n = n + 1;
        if (n == 8) rdata = regs[cmd[5:0]];
    end
    always @(negedge sclk) if (!cs_n && n >= 8 && cmd[7]) begin   // drive on falling
        #40 drive = 1; bitout = rdata[7]; rdata = rdata << 1;
    end
    always @(posedge clk) if (drive && dut.oe) contention = contention + 1;

    initial begin
        #2_000_000;
        $display("DATA_FORMAT=%h POWER_CTL=%h devid=%h x=%h y=%h z=%h contention=%0d",
                 regs[6'h31], regs[6'h2D], devid, x, y, z, contention);
        if (regs[6'h31] == 8'h40 && regs[6'h2D] == 8'h08 && devid == 8'hE5 &&
            x == 10'h134 && y == 10'h3CD && z == 10'h100 && contention == 0)
            $display("RESULT: PASS");
        else
            $display("RESULT: FAIL");
        $finish;
    end
endmodule
