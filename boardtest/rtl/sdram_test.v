// sdram_test.v
// Write/read test of the whole 64 MB SDRAM on the DE10-Lite (IS42S16320D,
// 32M words x 16 bits: 4 banks x 8192 rows x 1024 columns).
//
// It loops forever:
//   1. write every word with a pattern made from its own address
//   2. read every word back and compare
//   3. repeat with the pattern inverted, so every data bit is tested as 0 and 1
// Using the address in the pattern catches broken address lines too: if two
// addresses alias, the later write overwrites the earlier one and the readback
// of the earlier address fails.
//
// The controller is deliberately simple and slow (one word per 9 clocks,
// ~12 s for a full write+read of 64 MB). Every access opens a row (ACTIVE),
// does one READ or WRITE with auto-precharge, and waits until the bank is idle.
//
// Clocking: the SDRAM clock is the inverted 50 MHz clock, so the chip samples
// our commands in the middle of each cycle (10 ns after we change them).
// With CAS latency 2, read data is valid roughly 41-58 ns after we issue READ,
// so we capture it on the falling edge 50 ns after, right in the middle.

module sdram_test #(
    parameter ADDR_BITS     = 25,     // 2^25 words = 64 MB
    parameter INIT_WAIT     = 12000,  // power-up wait, > 200 us at 50 MHz
    parameter REFRESH_EVERY = 380     // cycles between refreshes (< 7.8 us)
) (
    input  wire        clk,
    output wire        dram_clk,
    output wire        dram_cke,
    output wire        dram_cs_n,
    output wire        dram_ras_n,
    output wire        dram_cas_n,
    output wire        dram_we_n,
    output reg  [1:0]  dram_ba = 2'd0,
    output reg  [12:0] dram_addr = 13'd0,
    inout  wire [15:0] dram_dq,
    output wire        dram_ldqm,
    output wire        dram_udqm,

    output reg         init_done = 1'b0,
    output reg         writing = 1'b1,      // 1 = write phase, 0 = read phase
    output reg  [15:0] passes = 16'd0,      // completed write+read passes
    output reg  [11:0] errors = 12'd0,      // mismatched words (saturates)
    output reg  [7:0]  progress = 8'd0,     // top 8 address bits of the phase

    // Diagnostics (read over JTAG)
    input  wire        clear,               // rising edge: restart test, zero counters
    input  wire [1:0]  test_mode,           // 0 full, 1 write-then-read, 2 2x refresh, 3 small region
    output reg  [23:0] err_a = 24'd0,       // errors per read sample point
    output reg  [23:0] err_b = 24'd0,
    output reg  [23:0] err_c = 24'd0,
    output reg  [23:0] err_d = 24'd0,
    output reg  [23:0] err_e = 24'd0,
    output reg  [31:0] reads = 32'd0,       // reads checked since restart
    output reg  [23:0] err_after_ref = 24'd0, // errors on the first read after a refresh
    output reg  [15:0] err_bits = 16'd0,    // OR of (read XOR expected): which data bits fail
    output reg  [3:0]  err_banks = 4'd0,    // which banks had errors
    output reg         first_seen = 1'b0,
    output reg  [24:0] first_addr = 25'd0,
    output reg  [15:0] first_exp  = 16'd0,
    output reg  [15:0] first_got  = 16'd0
);
    // {CS_N, RAS_N, CAS_N, WE_N}
    localparam CMD_NOP   = 4'b0111;
    localparam CMD_ACT   = 4'b0011;
    localparam CMD_READ  = 4'b0101;
    localparam CMD_WRITE = 4'b0100;
    localparam CMD_PRE   = 4'b0010;
    localparam CMD_REF   = 4'b0001;
    localparam CMD_LMR   = 4'b0000;

    // Mode register: burst length 1, sequential, CAS latency 2
    localparam MODE_REG = 13'h020;

    localparam S_INIT_WAIT = 3'd0;
    localparam S_INIT_REF  = 3'd1;
    localparam S_INIT_LMR  = 3'd2;
    localparam S_IDLE      = 3'd3;
    localparam S_RW        = 3'd4;
    localparam S_NEXT      = 3'd5;

    reg [3:0]  cmd = CMD_NOP;
    assign {dram_cs_n, dram_ras_n, dram_cas_n, dram_we_n} = cmd;
    assign dram_clk  = ~clk;
    assign dram_cke  = 1'b1;
    assign dram_ldqm = 1'b0;
    assign dram_udqm = 1'b0;

    reg [15:0] dq_out = 16'd0;
    reg        dq_oe  = 1'b0;
    assign dram_dq = dq_oe ? dq_out : 16'bz;

    reg [2:0]  state    = S_INIT_WAIT;
    reg [15:0] wait_cnt = INIT_WAIT;
    reg [3:0]  ref_done = 4'd0;           // init refreshes issued (counts up from 0)
    reg [9:0]  ref_timer = 10'd0;
    reg        inv = 1'b0;               // pattern inverted this pass
    reg [ADDR_BITS-1:0] addr = 0;
    wire [24:0] a = addr;                // zero-extended to the full 25 bits

    function [15:0] pattern(input [24:0] ad, input invert);
        pattern = (ad[15:0] ^ ad[24:9]) ^ {16{invert}};
    endfunction

    // Read pipeline. READ is issued at rising edge k (time T). The data bus
    // is sampled at five moments so we can see where the valid data really
    // is on the board:
    //   a: falling edge T+30   b: rising edge T+40   c: falling edge T+50 (used)
    //   d: rising edge T+60    e: falling edge T+70
    // All five are compared at edge k+5; error counts are kept for each.
    reg        rd_issue = 1'b0, p1 = 1'b0, p2 = 1'b0, p3 = 1'b0, chk = 1'b0;
    reg [15:0] rd_expect = 16'd0, exp1 = 16'd0, exp2 = 16'd0, exp3 = 16'd0, exp4 = 16'd0;
    reg [24:0] rd_addr = 25'd0, ad1 = 0, ad2 = 0, ad3 = 0, ad4 = 0;
    reg        rd_ref = 1'b0, rf1 = 0, rf2 = 0, rf3 = 0, rf4 = 0;
    reg [15:0] dq_neg = 16'd0, dq_pos = 16'd0;
    reg [15:0] sa = 0, sb = 0, sc = 0, sd = 0, se = 0;
    reg        restart = 1'b0;               // 1-cycle pulse from the FSM

    always @(negedge clk) dq_neg <= dram_dq;
    always @(posedge clk) dq_pos <= dram_dq;

    always @(posedge clk) begin
        p1 <= rd_issue;  exp1 <= rd_expect;  ad1 <= rd_addr;  rf1 <= rd_ref;
        p2 <= p1;        exp2 <= exp1;       ad2 <= ad1;      rf2 <= rf1;
        p3 <= p2;        exp3 <= exp2;       ad3 <= ad2;      rf3 <= rf2;
        chk <= p3;       exp4 <= exp3;       ad4 <= ad3;      rf4 <= rf3;
        if (p1) sa <= dq_neg;                // sampled at T+30
        if (p2) sb <= dq_pos;                // sampled at T+40
        if (p2) sc <= dq_neg;                // sampled at T+50
        if (p3) sd <= dq_pos;                // sampled at T+60
        if (p3) se <= dq_neg;                // sampled at T+70
        if (restart) begin
            err_a <= 0; err_b <= 0; err_c <= 0; err_d <= 0; err_e <= 0;
            reads <= 0; err_after_ref <= 0; err_bits <= 0; err_banks <= 0;
            errors <= 0; first_seen <= 1'b0;
        end else if (chk) begin
            reads <= reads + 1'b1;
            if (sa !== exp4 && err_a != 24'hFFFFFF) err_a <= err_a + 1'b1;
            if (sb !== exp4 && err_b != 24'hFFFFFF) err_b <= err_b + 1'b1;
            if (sc !== exp4 && err_c != 24'hFFFFFF) err_c <= err_c + 1'b1;
            if (sd !== exp4 && err_d != 24'hFFFFFF) err_d <= err_d + 1'b1;
            if (se !== exp4 && err_e != 24'hFFFFFF) err_e <= err_e + 1'b1;
            if (sc !== exp4) begin
                if (errors != 12'hFFF) errors <= errors + 1'b1;
                if (rf4 && err_after_ref != 24'hFFFFFF) err_after_ref <= err_after_ref + 1'b1;
                err_bits <= err_bits | (sc ^ exp4);
                err_banks[ad4[24:23]] <= 1'b1;
                if (!first_seen) begin
                    first_seen <= 1'b1;
                    first_addr <= ad4;
                    first_exp  <= exp4;
                    first_got  <= sc;
                end
            end
        end
    end

    // clear comes from the JTAG clock domain: synchronize, then edge-detect
    reg [2:0] clr_s = 3'b000;
    reg       clear_req = 1'b0;
    always @(posedge clk) clr_s <= {clr_s[1:0], clear};

    reg [1:0] mode_s1 = 2'd0, mode_s2 = 2'd0;
    always @(posedge clk) begin
        mode_s1 <= test_mode;
        mode_s2 <= mode_s1;
    end
    wire [9:0] ref_period = (mode_s2 == 2'd2) ? (REFRESH_EVERY / 2) : REFRESH_EVERY;
    wire       last_addr  = (mode_s2 == 2'd3) ? (addr[15:0] == 16'hFFFF)
                                              : (addr == {ADDR_BITS{1'b1}});
    reg        after_ref = 1'b0;

    always @(posedge clk) begin
        cmd      <= CMD_NOP;
        dq_oe    <= 1'b0;
        rd_issue <= 1'b0;
        restart  <= 1'b0;
        if (ref_timer != 0) ref_timer <= ref_timer - 1'b1;
        if (clr_s[2:1] == 2'b01) clear_req <= 1'b1;

        if (wait_cnt != 0) begin
            wait_cnt <= wait_cnt - 1'b1;
        end else begin
            case (state)
                S_INIT_WAIT: begin              // precharge all banks
                    cmd            <= CMD_PRE;
                    dram_addr[10]  <= 1'b1;
                    wait_cnt       <= 16'd3;
                    state          <= S_INIT_REF;
                end
                S_INIT_REF: begin               // 8 auto refreshes
                    if (ref_done != 4'd8) begin
                        cmd      <= CMD_REF;
                        ref_done <= ref_done + 1'b1;
                        wait_cnt <= 16'd7;
                    end else begin
                        state <= S_INIT_LMR;
                    end
                end
                S_INIT_LMR: begin               // load mode register
                    cmd       <= CMD_LMR;
                    dram_ba   <= 2'd0;
                    dram_addr <= MODE_REG;
                    wait_cnt  <= 16'd3;
                    ref_timer <= REFRESH_EVERY;
                    init_done <= 1'b1;
                    state     <= S_IDLE;
                    // Start the test from a known state here instead of trusting
                    // register power-up values (the board showed writing=0 at
                    // power-up despite the "= 1'b1" initializer).
                    restart   <= 1'b1;
                    addr      <= 0;
                    writing   <= 1'b1;
                    inv       <= 1'b0;
                    passes    <= 16'd0;
                end
                S_IDLE: begin
                    if (ref_timer == 0) begin   // all banks are idle here
                        cmd       <= CMD_REF;
                        wait_cnt  <= 16'd7;
                        ref_timer <= ref_period;
                        after_ref <= 1'b1;
                    end else begin              // open the row
                        cmd       <= CMD_ACT;
                        dram_ba   <= a[24:23];
                        dram_addr <= a[22:10];
                        wait_cnt  <= 16'd1;
                        state     <= S_RW;
                    end
                end
                S_RW: begin                     // one word, auto-precharge (A10)
                    dram_addr <= {2'b00, 1'b1, a[9:0]};
                    if (writing) begin
                        cmd    <= CMD_WRITE;
                        dq_out <= pattern(a, inv);
                        dq_oe  <= 1'b1;
                    end else begin
                        cmd       <= CMD_READ;
                        rd_issue  <= 1'b1;
                        rd_expect <= pattern(a, inv);
                        rd_addr   <= a;
                        rd_ref    <= after_ref;
                    end
                    after_ref <= 1'b0;
                    wait_cnt <= 16'd5;
                    state    <= S_NEXT;
                end
                S_NEXT: begin
                    progress <= addr[ADDR_BITS-1 -: 8];
                    if (clear_req) begin                // restart from scratch
                        clear_req <= 1'b0;
                        restart   <= 1'b1;
                        addr      <= 0;
                        writing   <= 1'b1;
                        inv       <= 1'b0;
                        passes    <= 16'd0;
                    end else if (mode_s2 == 2'd1) begin // write, read back, next word
                        if (writing) begin
                            writing <= 1'b0;
                        end else begin
                            writing <= 1'b1;
                            if (last_addr) begin
                                addr   <= 0;
                                inv    <= ~inv;
                                passes <= passes + 1'b1;
                            end else begin
                                addr <= addr + 1'b1;
                            end
                        end
                    end else if (last_addr) begin
                        addr <= 0;
                        if (writing) begin
                            writing <= 1'b0;
                        end else begin
                            writing <= 1'b1;
                            inv     <= ~inv;
                            passes  <= passes + 1'b1;
                        end
                    end else begin
                        addr <= addr + 1'b1;
                    end
                    state <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
