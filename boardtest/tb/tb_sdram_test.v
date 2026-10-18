// tb_sdram_test.v
// Runs sdram_test against sdram_model on a 4K-word slice for two full passes.
//   INJECT=0: expect 0 data errors and 0 protocol errors
//   INJECT=1: the model corrupts one word; expect exactly 2 errors (one per pass)
//
// iverilog -g2012 -o sim -P tb_sdram_test.INJECT=0 tb_sdram_test.v sdram_model.v ../rtl/sdram_test.v && vvp sim

`timescale 1ns/1ps

module tb_sdram_test;
    parameter INJECT = 0;
    parameter [1:0] MODE = 0;   // 0 full, 1 write-then-read, 2 2x refresh (3 needs >64K words)

    reg clk = 0;
    always #10 clk = ~clk;                       // 50 MHz

    wire        dram_clk, dram_cke, cs_n, ras_n, cas_n, we_n, ldqm, udqm;
    wire [1:0]  ba;
    wire [12:0] addr;
    wire [15:0] dq;
    wire        init_done, writing;
    wire [15:0] passes;
    wire [11:0] errors;
    wire [7:0]  progress;

    sdram_test #(.ADDR_BITS(12), .INIT_WAIT(200), .REFRESH_EVERY(380)) dut (
        .clear(1'b0), .test_mode(MODE[1:0]),
        .clk(clk), .dram_clk(dram_clk), .dram_cke(dram_cke),
        .dram_cs_n(cs_n), .dram_ras_n(ras_n), .dram_cas_n(cas_n), .dram_we_n(we_n),
        .dram_ba(ba), .dram_addr(addr), .dram_dq(dq), .dram_ldqm(ldqm), .dram_udqm(udqm),
        .init_done(init_done), .writing(writing), .passes(passes),
        .errors(errors), .progress(progress)
    );

    sdram_model #(.FLIP_INDEX(INJECT ? 1234 : -1)) mem (
        .clk(dram_clk), .cs_n(cs_n), .ras_n(ras_n), .cas_n(cas_n), .we_n(we_n),
        .ba(ba), .a(addr), .dq(dq)
    );

    initial begin
        fork
            wait (passes == 2);
            #5_000_000 begin $display("TIMEOUT"); $finish; end
        join_any
        #200;
        $display("err_a..e = %0d %0d %0d %0d %0d", dut.err_a, dut.err_b, dut.err_c, dut.err_d, dut.err_e);
        $display("passes=%0d errors=%0d protocol_errors=%0d reads=%0d writes=%0d refreshes=%0d",
                 passes, errors, mem.proto_errors, mem.reads, mem.writes, mem.refreshes);
        if (mem.proto_errors == 0 && mem.reads == 2*4096 && mem.writes >= 2*4096 &&    // the next pass may have started

            errors == (INJECT ? 2 : 0))
            $display("RESULT: PASS (INJECT=%0d)", INJECT);
        else
            $display("RESULT: FAIL (INJECT=%0d)", INJECT);
        $finish;
    end
endmodule
