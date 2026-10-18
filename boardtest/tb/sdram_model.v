// sdram_model.v
// Small behavioral SDRAM model for simulating sdram_test.v. It stores 64K
// words, decodes the commands on the rising edge of the SDRAM clock, drives
// read data with CAS latency 2 timing (valid 6 ns after the next edge, held
// 2.7 ns past the edge after that), and complains about protocol mistakes:
// commands before the mode register is loaded, reads/writes to a closed row,
// refresh with an open row, and timing gaps that are too short or too long.
//
// FLIP_INDEX >= 0 flips bit 0 of that word on every read, to prove the
// tester actually detects bad data.

`timescale 1ns/1ps

module sdram_model #(
    parameter integer FLIP_INDEX = -1
) (
    input  wire        clk,
    input  wire        cs_n, ras_n, cas_n, we_n,
    input  wire [1:0]  ba,
    input  wire [12:0] a,
    inout  wire [15:0] dq
);
    reg [15:0] mem [0:65535];
    reg [12:0] open_row [0:3];
    reg        row_open [0:3];
    realtime   t_act    [0:3];
    realtime   t_last_ref = 0;
    reg        mode_set = 0;
    reg        ref_started = 0;
    integer    init_refs = 0;
    integer    proto_errors = 0;
    integer    reads = 0, writes = 0, refreshes = 0;
    integer    i;

    reg [15:0] dout = 0;
    reg        drive = 0;
    assign dq = drive ? dout : 16'bz;

    initial for (i = 0; i < 4; i = i + 1) begin
        row_open[i] = 0;
        t_act[i]    = -1000;
    end

    task fail(input [8*48-1:0] msg);
        begin
            proto_errors = proto_errors + 1;
            if (proto_errors <= 10) $display("%t SDRAM MODEL ERROR: %0s", $realtime, msg);
        end
    endtask

    function [15:0] idx(input [1:0] b, input [12:0] r, input [9:0] c);
        idx = {b, r[3:0], c};
    endfunction

    reg [15:0] rd_val;
    event      rd_ev;
    always @(rd_ev) begin
        #26.0 dout = rd_val; drive = 1;     // next edge + tAC (6 ns)
        #16.7 drive = 0;                    // edge after that + tOH (2.7 ns)
    end

    reg [15:0] k;
    always @(posedge clk) begin
        case ({cs_n, ras_n, cas_n, we_n})
            4'b0111, 4'b1111: ;                                    // NOP / deselect
            4'b0000: begin                                         // LOAD MODE
                if (init_refs < 2)  fail("mode set before 2 init refreshes");
                if (a[2:0] != 3'b000) fail("burst length is not 1");
                if (a[6:4] != 3'b010) fail("CAS latency is not 2");
                mode_set = 1;
            end
            4'b0011: begin                                         // ACTIVE
                if (!mode_set)    fail("ACTIVE before mode set");
                if (row_open[ba]) fail("ACTIVE on an open bank");
                if ($realtime - t_act[ba] < 63.0) fail("tRC too short");
                open_row[ba] = a;
                row_open[ba] = 1;
                t_act[ba]    = $realtime;
            end
            4'b0101, 4'b0100: begin                                // READ / WRITE
                if (!row_open[ba]) fail("READ/WRITE on a closed bank");
                if ($realtime - t_act[ba] < 15.0) fail("tRCD too short");
                k = idx(ba, open_row[ba], a[9:0]);
                if (we_n) begin
                    rd_val = mem[k];
                    if (FLIP_INDEX >= 0 && k == FLIP_INDEX) rd_val = rd_val ^ 16'h0001;
                    -> rd_ev;
                    reads = reads + 1;
                end else begin
                    mem[k] = dq;
                    writes = writes + 1;
                end
                if (a[10]) row_open[ba] = 0;                       // auto-precharge
            end
            4'b0010: begin                                         // PRECHARGE
                if (a[10]) for (i = 0; i < 4; i = i + 1) row_open[i] = 0;
                else row_open[ba] = 0;
            end
            4'b0001: begin                                         // REFRESH
                for (i = 0; i < 4; i = i + 1)
                    if (row_open[i]) fail("REFRESH with an open bank");
                if (mode_set && ref_started && $realtime - t_last_ref > 7800.0)
                    fail("refresh interval over 7.8 us");
                if (!mode_set) init_refs = init_refs + 1;
                else ref_started = 1;
                t_last_ref = $realtime;
                refreshes  = refreshes + 1;
            end
            default: fail("unknown command");
        endcase
    end
endmodule
