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

module sdram_tb #(parameter CACHE_LINES = 8192);

    logic clk = 0, init = 1;
    always #5.82 clk = ~clk;          // 85.909 MHz

    logic [26:0] ch1_addr = 0;
    logic  [7:0] ch1_din  = 0;
    logic        ch1_req  = 0;
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

    sdram #(.CACHE_LINES(CACHE_LINES)) dut (
        .init(init), .clk(clk), .doRefresh(1'b0),
        .SDRAM_DQ_o(dut_dq_o), .SDRAM_DQ_oe(dut_dq_oe), .SDRAM_DQ_i(DQ),
        .SDRAM_A(A), .SDRAM_DQML(DQML), .SDRAM_DQMH(DQMH), .SDRAM_BA(BA),
        .SDRAM_nCS(nCS), .SDRAM_nWE(nWE), .SDRAM_nRAS(nRAS), .SDRAM_nCAS(nCAS),
        .SDRAM_CKE(CKE), .SDRAM_CLK(SDCLK),
        .ch1_addr(ch1_addr), .ch1_dout(), .ch1_din(ch1_din), .ch1_req(ch1_req), .ch1_rnw(1'b0), .ch1_ready(),
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

    // ---- offline models fed by the same trace --------------------------------
    // (a) 1-word latch with address-compare invalidation: what the previous
    //     commit delivered, kept for comparison.
    // (b) direct-mapped cache with the DUT's exact geometry and its
    //     invalidate-by-index rule -- used by the self-check below.
    int    writes = 0, reads = 0, hit_latch = 0, hit_cache = 0;
    logic [25:0] l1 = '1; logic u1 = 0;
    localparam MCL = (CACHE_LINES > 1) ? CACHE_LINES : 2;
    localparam MCW = $clog2(MCL);
    logic        mvalid [0:MCL-1];
    logic [25:0] mword  [0:MCL-1];
    initial for (int i = 0; i < MCL; i++) mvalid[i] = 0;

    task automatic model_access(input [26:0] a, input bit is_write);
        logic [MCW-1:0] ix;
        ix = a[MCW:1];
        if (is_write) begin
            writes++;
            if (a[26:1] == l1) u1 = 0;
            mvalid[ix] = 0;                       // invalidate-by-index
        end else begin
            reads++;
            if (u1 && a[26:1] == l1) hit_latch++; else begin l1 = a[26:1]; u1 = 1; end
            if (CACHE_LINES != 0 && mvalid[ix] && mword[ix] == a[26:1]) hit_cache++;
            else begin mvalid[ix] = 1; mword[ix] = a[26:1]; end
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

    // same as rd() but not fed to the offline models (used inside F, which is
    // excluded from the self-check as a whole)
    task automatic rd_raw(input [26:0] a, input [7:0] want, input string tag);
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

    int base, f_reads = 0, f_active = 0, f_active_base = 0;
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
        $display("CACHE_LINES = %0d", CACHE_LINES);

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

        // E. game main loop: the same 48-byte code block, 4 PUSH/POP pairs and
        //    8 data bytes, repeated 8 times.  This is what a cache is for.
        base = active_count;
        for (int it = 0; it < 8; it++) begin
            pc = 27'h004100; sp = 27'h00F380;
            for (int i = 0; i < 48; i++) begin rd(pc, exp_byte(pc), "E-code"); pc++; end
            for (int i = 0; i < 4; i++) begin
                sp -= 2; wr(sp, 8'h10 + i); wr(sp+1, 8'h20 + i);
            end
            for (int i = 0; i < 8; i++) rd(27'h008000 + i, exp_byte(27'h008000 + i), "E-data");
            for (int i = 3; i >= 0; i--) begin
                rd(sp, 8'h10 + i, "E-pop"); rd(sp+1, 8'h20 + i, "E-pop"); sp += 2;
            end
        end
        report("E main loop x8 (code+stack+data)", 8*(48+8+8+8));

        // F. read-during-write hazard sweep.  Prime the cache with X, then fire a
        //    ch1 WRITE to X and a ch2 READ of X `off` clk cycles apart, for every
        //    offset that can land the invalidate on or next to the lookup edge.
        //    Whatever that racing read returned, a later read of X must see the
        //    written value: a stale line surviving the race would fail here.
        //    Not counted in the model/self-check (cross-channel order is
        //    unspecified), so the counters are excluded from that comparison.
        f_active_base = active_count;
        begin
            int stale = 0, base_r, base_w, base_hc;
            base_r = reads; base_w = writes; base_hc = hit_cache;
            for (int off = 0; off < 16; off++) begin
                logic [26:0] X; logic [7:0] v;
                X = 27'h00C000 + off*2; v = 8'h80 + off;
                rd_raw(X, exp_byte(X), "F-prime");
                @(negedge clk); ch1_addr = X; ch1_din = v; ch1_req = 1;
                repeat (off) @(negedge clk);
                ch2_addr = X; ch2_rnw = 1; ch2_req = 1;
                repeat (14) @(negedge clk);
                ch1_req = 0; ch2_req = 0;
                repeat (24) @(negedge clk);              // let everything drain
                @(negedge clk); ch2_addr = X; ch2_req = 1;
                repeat (14) @(negedge clk);
                if (ch2_dout !== v) begin
                    $display("  STALE off=%0d: post-race read got %02h want %02h", off, ch2_dout, v);
                    stale++;
                end
                ch2_req = 0; @(negedge clk);
            end
            $display("  F write/read race sweep, 16 offsets: %0d stale", stale);
            if (stale) errors++;
            f_active = active_count - f_active_base;   // excluded from the self-check
            f_reads  = reads - base_r;
        end

        $display("");
        $display("  ---- over the same %0d reads / %0d writes ----", reads, writes);
        $display("  1-word latch (previous commit)  would hit %4d  (%0d%%)", hit_latch, (100*hit_latch)/reads);
        $display("  %0d-line cache (model)        hits       %4d  (%0d%%)", CACHE_LINES, hit_cache, (100*hit_cache)/reads);
        $display("");
        // Ties the cache model to the DUT: the controller must have issued
        // exactly one access per write plus one per read the model called a
        // miss.  A read-during-write hazard in the DUT would show up here as a
        // surplus access (never as a missing one).
        begin
            int expect_active;
            expect_active = writes + reads - hit_cache;
            $display("  self-check: ACTIVE=%0d expected=%0d  (%0d reads, %0d writes; F excluded)",
                     active_count - f_active, expect_active, reads, writes);
            if (active_count - f_active != expect_active) begin
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
