// ch2 (CPU) word-latch testbench.
//
// Drives ch2 with access patterns a Z80 actually produces and counts the
// CMD_ACTIVE commands that reach the SDRAM. Every returned byte is checked
// against a behavioural memory model, so a lower access count cannot come from
// the controller answering with the wrong data.
//
// It also instruments -- without changing the datapath -- what a wider line or
// a second line WOULD have hit on the same trace, so the double/quad question
// is answered before any burst-mode work is done.
//
// Build/run:  make -C tb

`timescale 1ns/1ps

module sdram_tb #(parameter WORD_LATCH = 1);

    logic clk = 0, init = 1;
    always #5.82 clk = ~clk;          // 85.909 MHz

    logic [26:0] ch2_addr = 0;
    logic  [7:0] ch2_din  = 0;
    logic        ch2_req  = 0, ch2_rnw = 1;
    wire   [7:0] ch2_dout;
    wire         ch2_ready, ch2_rdtog, ch2_hit;

    wire [15:0] DQ, dut_dq_o, model_dq;
    wire        dut_dq_oe;
    wire [12:0] A;
    wire  [1:0] BA;
    wire nCS, nWE, nRAS, nCAS, DQML, DQMH, CKE, SDCLK;
    assign DQ = dut_dq_oe ? dut_dq_o : model_dq;

    sdram #(.WORD_LATCH(WORD_LATCH)) dut (
        .init(init), .clk(clk), .doRefresh(1'b0),
        .SDRAM_DQ_o(dut_dq_o), .SDRAM_DQ_oe(dut_dq_oe), .SDRAM_DQ_i(DQ),
        .SDRAM_A(A), .SDRAM_DQML(DQML), .SDRAM_DQMH(DQMH), .SDRAM_BA(BA),
        .SDRAM_nCS(nCS), .SDRAM_nWE(nWE), .SDRAM_nRAS(nRAS), .SDRAM_nCAS(nCAS),
        .SDRAM_CKE(CKE), .SDRAM_CLK(SDCLK),
        .ch1_addr(27'd0), .ch1_dout(), .ch1_din(8'd0), .ch1_req(1'b0), .ch1_rnw(1'b1), .ch1_ready(),
        .ch2_addr(ch2_addr), .ch2_dout(ch2_dout), .ch2_din(ch2_din), .ch2_req(ch2_req),
        .ch2_rnw(ch2_rnw), .ch2_ready(ch2_ready), .ch2_rdtog(ch2_rdtog), .ch2_hit(ch2_hit),
        .ch3_addr(27'd0), .ch3_dout(), .ch3_din(8'd0), .ch3_req(1'b0), .ch3_rnw(1'b1),
        .ch3_ready(), .ch3_done(),
        .ch4_addr(27'd0), .ch4_dout(), .ch4_dout16(), .ch4_din(8'd0), .ch4_req(1'b0),
        .ch4_rnw(1'b1), .ch4_ready()
    );

    sdram_model model (
        .clk(clk), .DQ(model_dq), .DQ_in(DQ), .A(A), .BA(BA), .nCS(nCS),
        .nWE(nWE), .nRAS(nRAS), .nCAS(nCAS), .DQML(DQML), .DQMH(DQMH)
    );

    int active_count = 0, errors = 0;
    always @(posedge clk)
        if (!nCS && {nRAS, nCAS, nWE} == 3'b011) active_count++;

    // ---- offline models of line variants, fed by the same trace -------------
    // Pure bookkeeping; no effect on the DUT. Counts what each configuration
    // would have answered without going to the chip.
    int    writes = 0, reads = 0, hit1 = 0, hit2 = 0, hit4 = 0, hit1x2 = 0;
    int    hit1ac = 0, hit2ac = 0, hit4ac = 0;   // address-compare invalidation
    logic [25:0] m1 = '1; logic [24:0] m2 = '1; logic [23:0] m4 = '1;
    logic        u1 = 0, u2 = 0, u4 = 0;
    logic [25:0] l1 = '1;                       // 1 word
    logic [24:0] l2 = '1;                       // 2 words (4 bytes)
    logic [23:0] l4 = '1;                       // 4 words (8 bytes)
    logic [25:0] w0 = '1, w1 = '1;              // two 1-word lines, LRU
    logic        v1 = 0, v2 = 0, v4 = 0, v0a = 0, v0b = 0;

    task automatic model_access(input [26:0] a, input bit is_write);
        if (is_write) begin
            writes++;
            v1 = 0; v2 = 0; v4 = 0; v0a = 0; v0b = 0;   // blanket invalidation
            // address-compare variant: only drop the line the write lands in
            if (a[26:1] == m1) u1 = 0;
            if (a[26:2] == m2) u2 = 0;
            if (a[26:3] == m4) u4 = 0;
        end else begin
            reads++;
            if (v1 && a[26:1]  == l1) hit1++; else begin l1 = a[26:1];  v1 = 1; end
            if (v2 && a[26:2]  == l2) hit2++; else begin l2 = a[26:2];  v2 = 1; end
            if (v4 && a[26:3]  == l4) hit4++; else begin l4 = a[26:3];  v4 = 1; end
            if (u1 && a[26:1] == m1) hit1ac++; else begin m1 = a[26:1]; u1 = 1; end
            if (u2 && a[26:2] == m2) hit2ac++; else begin m2 = a[26:2]; u2 = 1; end
            if (u4 && a[26:3] == m4) hit4ac++; else begin m4 = a[26:3]; u4 = 1; end
            if      (v0a && a[26:1] == w0) hit1x2++;
            else if (v0b && a[26:1] == w1) begin hit1x2++; w1 = w0; w0 = a[26:1]; v0b = v0a; v0a = 1; end
            else begin w1 = w0; v0b = v0a; w0 = a[26:1]; v0a = 1; end
        end
    endtask

    // ---- bus tasks ---------------------------------------------------------
    function automatic [15:0] exp_word(input [26:0] a);
        exp_word = ({a[24:23], a[14:10], a[9:1]}) ^ 16'hA5C3;
    endfunction
    function automatic [7:0] exp_byte(input [26:0] a);
        logic [15:0] wv; wv = exp_word(a);
        exp_byte = a[0] ? wv[15:8] : wv[7:0];
    endfunction

    task automatic rd(input [26:0] a, input [7:0] want, input string tag);
        model_access(a, 0);
        @(negedge clk); ch2_addr = a; ch2_rnw = 1; ch2_req = 1;
        repeat (14) @(negedge clk);
        if (ch2_dout !== want) begin
            $display("  FAIL %s addr=%06h got=%02h want=%02h", tag, a, ch2_dout, want);
            errors++;
        end
        ch2_req = 0; @(negedge clk);
    endtask

    task automatic wr(input [26:0] a, input [7:0] d);
        model_access(a, 1);
        @(negedge clk); ch2_addr = a; ch2_din = d; ch2_rnw = 0; ch2_req = 1;
        repeat (14) @(negedge clk);
        ch2_req = 0; @(negedge clk);
    endtask

    int base;
    task automatic report(input string name, input int n_acc);
        $display("  %-34s %3d ACTIVE  (%0d accesses)", name, active_count - base, n_acc);
    endtask

    logic [26:0] pc, sp;
    int seed = 32'h1234_5678;
    function automatic int rnd(); seed = seed*1103515245 + 12345; rnd = seed; endfunction

    initial begin
        ch2_req = 0; ch2_rnw = 1; ch2_addr = 0; ch2_din = 0;
        repeat (20) @(negedge clk);
        init = 0;
        wait (ch2_ready === 1'b1);
        repeat (10) @(negedge clk);
        $display("WORD_LATCH = %0d", WORD_LATCH);

        // A. straight-line opcode fetch
        base = active_count;
        pc = 27'h004000;
        for (int i = 0; i < 32; i++) begin rd(pc, exp_byte(pc), "A"); pc++; end
        report("A sequential fetch, 32 bytes", 32);

        // B. fetch interleaved with stack traffic (CALL/RET, PUSH/POP)
        base = active_count;
        pc = 27'h005000; sp = 27'h00F380;
        for (int i = 0; i < 16; i++) begin
            rd(pc, exp_byte(pc), "B"); pc++;
            rd(pc, exp_byte(pc), "B"); pc++;
            sp -= 2; wr(sp, 8'hAA); wr(sp+1, 8'hBB);    // PUSH
            rd(sp, 8'hAA, "B-pop"); rd(sp+1, 8'hBB, "B-pop"); sp += 2;
        end
        report("B fetch + stack interleaved", 16*6);

        // C. LDIR: read source, write dest, two distant streams
        base = active_count;
        for (int i = 0; i < 32; i++) begin
            rd(27'h006000 + i, exp_byte(27'h006000 + i), "C");
            wr(27'h009000 + i, 8'h11);
        end
        report("C LDIR-like copy, 32 bytes", 64);

        // D. random byte reads inside 4 kB (worst case)
        base = active_count;
        for (int i = 0; i < 32; i++) begin
            logic [26:0] a;
            a = 27'h00A000 + (rnd() & 27'hFFF);
            rd(a, exp_byte(a), "D");
        end
        report("D random reads in 4 kB", 32);

        $display("");
        $display("  ---- line-variant model over the same %0d reads ----", reads);
        $display("  1 word  (implemented)  hits %3d  (%0d%%)", hit1,   (100*hit1)/reads);
        $display("  2 words (4-byte line)  hits %3d  (%0d%%)", hit2,   (100*hit2)/reads);
        $display("  4 words (8-byte line)  hits %3d  (%0d%%)", hit4,   (100*hit4)/reads);
        $display("  2 lines x 1 word       hits %3d  (%0d%%)", hit1x2, (100*hit1x2)/reads);
        $display("  -- same, but invalidating only the line the write lands in --");
        $display("  1 word  + addr-compare  hits %3d  (%0d%%)", hit1ac, (100*hit1ac)/reads);
        $display("  2 words + addr-compare  hits %3d  (%0d%%)", hit2ac, (100*hit2ac)/reads);
        $display("  4 words + addr-compare  hits %3d  (%0d%%)", hit4ac, (100*hit4ac)/reads);
        $display("");
        // Ties the offline model to the DUT: with the latch on, the controller
        // must have issued exactly one access per read that the 1-word
        // address-compare model called a miss, plus one per write. If this
        // holds, the 2-word / 4-word rows above are trustworthy too.
        begin
            int expect_active;
            expect_active = writes + (WORD_LATCH ? reads - hit1ac : reads);
            $display("  self-check: ACTIVE=%0d expected=%0d  (%0d reads, %0d writes)",
                     active_count, expect_active, reads, writes);
            if (active_count != expect_active) begin
                $display("  -> model and DUT disagree");
                errors++;
            end
        end
        $display("");
        if (errors) $display("RESULT: %0d data mismatch(es)", errors);
        else        $display("RESULT: all data correct");
        $finish;
    end
endmodule
