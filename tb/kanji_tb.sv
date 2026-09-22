// kanji_tb -- the kanji ROM device (rtl/peripheral/slots/kanji.sv) reading its
// glyph bytes through the REAL sdram.sv, driven the way a Z80 INIR does it:
// set the JIS address on D8h/D9h, then 32 I/O reads, one per INI (16 T at
// 3.58 MHz = 96 clk21m apart, RD asserted for ~2.5 T, data sampled ~2 T after RD).
//
// Board, 2026-09-23 (Illusion City, both Z80 and R800): the 32 bytes come back
// in the right ORDER but each new word lags -- 18 distinct bytes in 32 reads.
// The sdram_model returns a byte that is a function of its address
// (exp_byte), so every read here has one right answer.
`timescale 1ns/1ps
module kanji_tb #(parameter int RD_T = 15, parameter int SAMPLE_T = 12, parameter int GAP_T = 81);
    logic clk = 0;  always #5.82 clk = ~clk;              // clk_sdram 85.909 MHz
    logic clk21m = 0;
    initial begin #(2 * 5.82 * 4 / 6); forever #(2 * 5.82 * 2) clk21m = ~clk21m; end
    logic init = 1;
    // ---- SDRAM under test + model (as tb/guard_tb.sv) --------------------------
    wire  [7:0] ch2_dout; wire ch2_ready, ch2_rdtog, ch2_hit;
    wire [15:0] DQ, dut_dq_o, model_dq; wire dut_dq_oe;
    wire [12:0] A; wire [1:0] BA; wire nCS, nWE, nRAS, nCAS, DQML, DQMH, CKE, SDCLK;
    assign DQ = dut_dq_oe ? dut_dq_o : model_dq;
    wire [26:0] mem_addr; wire ram_ce;
    sdram #(.CACHE_LINES(8192)) dut (
        .init(init), .clk(clk), .doRefresh(1'b0),
        .SDRAM_DQ_o(dut_dq_o), .SDRAM_DQ_oe(dut_dq_oe), .SDRAM_DQ_i(DQ),
        .SDRAM_A(A), .SDRAM_DQML(DQML), .SDRAM_DQMH(DQMH), .SDRAM_BA(BA),
        .SDRAM_nCS(nCS), .SDRAM_nWE(nWE), .SDRAM_nRAS(nRAS), .SDRAM_nCAS(nCAS),
        .SDRAM_CKE(CKE), .SDRAM_CLK(SDCLK),
        .ch1_addr(27'd0), .ch1_dout(), .ch1_din(8'd0), .ch1_req(1'b0), .ch1_rnw(1'b1), .ch1_ready(),
        .ch2_addr(mem_addr), .ch2_dout(ch2_dout), .ch2_din(8'd0), .ch2_req(ram_ce),
        .ch2_rnw(1'b1), .ch2_ready(ch2_ready), .ch2_rdtog(ch2_rdtog), .ch2_hit(ch2_hit),
        .ch3_addr(27'd0), .ch3_dout(), .ch3_din(8'd0), .ch3_req(1'b0), .ch3_rnw(1'b1), .ch3_ready(), .ch3_done(),
        .ch4_addr(27'd0), .ch4_dout(), .ch4_dout16(), .ch4_din(8'd0), .ch4_req(1'b0), .ch4_rnw(1'b1), .ch4_ready());
    sdram_model model (.clk(clk), .DQ(model_dq), .DQ_in(DQ), .A(A), .BA(BA), .nCS(nCS),
                       .nWE(nWE), .nRAS(nRAS), .nCAS(nCAS), .DQML(DQML), .DQMH(DQMH));
    function automatic [15:0] exp_word(input [26:0] a);
        exp_word = ({a[24:23], a[14:10], a[9:1]}) ^ 16'hA5C3;
    endfunction
    function automatic [7:0] exp_byte(input [26:0] a);
        logic [15:0] wv; wv = exp_word(a); exp_byte = a[0] ? wv[15:8] : wv[7:0];
    endfunction
    // ---- kanji device --------------------------------------------------------
    localparam [26:0] BASE = 27'h0100000;
    logic [7:0] port = 8'h00, din = 8'h00;
    logic cpu_wr = 0, cpu_rd = 0, cpu_iorq = 0;
    kanji k (.clk(clk21m), .reset(init), .din(din), .addr(port), .cpu_wr(cpu_wr), .cpu_rd(cpu_rd),
             .cpu_iorq(cpu_iorq), .cs(1'b1), .base_ram(BASE), .rom_size(16'd16),
             .mem_addr(mem_addr), .ram_ce(ram_ce));
    // a Z80 OUT (n),A: IORQ+WR for ~2.5 T
    task automatic io_write(input [7:0] p, input [7:0] v);
        @(posedge clk21m); #1; port = p; din = v; cpu_iorq = 1; cpu_wr = 1;
        repeat (RD_T) @(posedge clk21m); #1; cpu_wr = 0; cpu_iorq = 0;
        repeat (6) @(posedge clk21m);
    endtask
    // a Z80 IN: IORQ+RD for RD_T clk21m, data sampled SAMPLE_T clk21m after RD rises
    task automatic io_read(input [7:0] p, output [7:0] v);
        @(posedge clk21m); #1; port = p; cpu_iorq = 1; cpu_rd = 1;
        repeat (SAMPLE_T) @(posedge clk21m); #1; v = ch2_dout;
        repeat (RD_T - SAMPLE_T) @(posedge clk21m); #1; cpu_rd = 0; cpu_iorq = 0;
        repeat (GAP_T) @(posedge clk21m);
    endtask
    int errors = 0, distinct = 0;
    logic [7:0] got [0:31], want [0:31];
    initial begin
        repeat (20) @(posedge clk21m); init = 0;
        wait (ch2_ready === 1'b1); repeat (10) @(posedge clk21m);
        // JIS 07FBh: D9 <- 07 (high), D8 <- FB (low)  =>  addr1 = (7<<11)|(3Bh<<5) = 3F60h
        io_write(8'hD9, 8'h07); io_write(8'hD8, 8'hFB);
        for (int i = 0; i < 32; i++) begin
            want[i] = exp_byte(BASE + 27'h3F60 + i);
            io_read(8'hD9, got[i]);
            if (got[i] !== want[i]) errors++;
            if (i == 0 || got[i] !== got[i-1]) distinct++;
        end
        $write("  got : "); for (int i = 0; i < 32; i++) $write("%02h ", got[i]);  $write("\n");
        $write("  want: "); for (int i = 0; i < 32; i++) $write("%02h ", want[i]); $write("\n");
        $display("  RD %0d clk21m, sample @%0d, gap %0d: %0d/32 wrong, %0d distinct", RD_T, SAMPLE_T, GAP_T, errors, distinct);
        if (errors) $display("RESULT: FAIL"); else $display("RESULT: PASS");
        $finish;
    end
endmodule
