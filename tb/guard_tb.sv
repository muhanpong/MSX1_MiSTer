// Guard/latch interaction testbench.
//
// Instantiates the real sdram.sv together with a copy of msx.sv's fast-read
// bus guard (guard_cnt / hs_* / guard_open, P3+P4) and checks the property the
// P4 change must preserve:
//
//     guard_open is NEVER high while ch2_dout is not yet the requested byte.
//
// It also measures how many clk21m cycles each read takes to release, for
// misses (closed loop via ch2_rdtog) and for latch hits (via ch2_hit).
//
// The guard block below is a transcription of rtl/msx.sv; keep them in step.

`timescale 1ns/1ps

module guard_tb #(parameter P4 = 1);   // P4=0: guard as before the ch2_hit change

    // clk_sdram 85.909 MHz, clk21m = /4 lagging by 60 degrees (pll.v)
    logic clk = 0;
    always #5.82 clk = ~clk;
    logic clk21m = 0;
    initial begin
        #(2 * 5.82 * 4 / 6);            // 60 degrees of one clk21m period
        forever #(2 * 5.82 * 2) clk21m = ~clk21m;
    end

    logic init = 1;

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

    sdram #(.CACHE_LINES(8192)) dut (
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

    // ---- transcription of msx.sv's fast SDRAM-read guard (P3 + P4) ------------
    // Simplified to the fast-read branch: guard_slow=0, cpu_turbo=1, wr_n=1,
    // sdram_ce & ram_rnw = the request itself.
    wire  bus_cycle = ch2_req;
    wire  bus_xfer  = ch2_req;
    logic [3:0] guard_cnt = 4'd0;
    always @(posedge clk21m)
        if (~bus_cycle)          guard_cnt <= 4'd0;
        else if (bus_xfer && guard_cnt != 4'hF) guard_cnt <= guard_cnt + 4'd1;

    wire hs_win = bus_xfer;
    logic hs_armed = 1'b0, hs_done = 1'b0, hs_tog0 = 1'b0;
    always @(posedge clk21m) begin
        if (~hs_win) begin
            hs_armed <= 1'b0;
            hs_done  <= 1'b0;
        end else if (~hs_armed) begin
            hs_armed <= 1'b1;
            hs_tog0  <= ch2_rdtog;
        end else if (ch2_rdtog != hs_tog0) hs_done <= 1'b1;
    end

    wire guard_open = hs_done | (P4 ? ch2_hit : 1'b0) | (&guard_cnt);
    // ---------------------------------------------------------------------------

    function automatic [15:0] exp_word(input [26:0] a);
        exp_word = ({a[24:23], a[14:10], a[9:1]}) ^ 16'hA5C3;
    endfunction
    function automatic [7:0] exp_byte(input [26:0] a);
        logic [15:0] wv; wv = exp_word(a);
        exp_byte = a[0] ? wv[15:8] : wv[7:0];
    endfunction

    int errors = 0;

    // One read: raise the request on a clk21m edge (as msx.sv would), then on
    // every clk21m edge check the safety property and note the first cycle
    // guard_open is high.  Returns that cycle count and whether the hit path
    // fired.
    task automatic cpu_read(input [26:0] a, input [7:0] want, input string tag,
                            output int open_at, output bit via_hit, output bit watchdog);
        open_at = -1; via_hit = 0; watchdog = 0;
        @(posedge clk21m); #1;
        ch2_addr = a; ch2_rnw = 1; ch2_req = 1;
        for (int c = 1; c <= 20; c++) begin
            @(posedge clk21m); #1;
            if (guard_open && ch2_dout !== want) begin
                $display("  VIOLATION %s cycle %0d: guard_open=1 but dout=%02h want=%02h",
                         tag, c, ch2_dout, want);
                errors++;
            end
            if (guard_open && open_at < 0) begin
                open_at = c;
                via_hit = ch2_hit;
                watchdog = &guard_cnt;
            end
        end
        if (ch2_dout !== want) begin
            $display("  FAIL %s final dout=%02h want=%02h", tag, ch2_dout, want);
            errors++;
        end
        ch2_req = 0;
        @(posedge clk21m); #1;
    endtask

    task automatic cpu_write(input [26:0] a, input [7:0] d);
        @(posedge clk21m); #1;
        ch2_addr = a; ch2_din = d; ch2_rnw = 0; ch2_req = 1;
        repeat (6) @(posedge clk21m);
        #1 ch2_req = 0;
        @(posedge clk21m); #1;
    endtask

    int oa; bit vh, wd;
    task automatic show(input string what, input int oa, input bit vh, input bit wd);
        $display("  %-38s release @ clk21m %2d   %s", what, oa,
                 wd ? "WATCHDOG" : vh ? "hit path" : "closed loop (rdtog)");
    endtask

    initial begin
        repeat (20) @(posedge clk21m);
        init = 0;
        wait (ch2_ready === 1'b1);
        repeat (10) @(posedge clk21m);
        $display("P4 (guard opens on ch2_hit) = %0d", P4);

        cpu_read (27'h004000, exp_byte(27'h004000), "miss-1",  oa, vh, wd); show("miss  (cold)",              oa, vh, wd);
        cpu_read (27'h004001, exp_byte(27'h004001), "hit-1",   oa, vh, wd); show("hit   (paired byte)",       oa, vh, wd);
        cpu_read (27'h004002, exp_byte(27'h004002), "miss-2",  oa, vh, wd); show("miss  (next word)",         oa, vh, wd);
        cpu_read (27'h004003, exp_byte(27'h004003), "hit-2",   oa, vh, wd); show("hit   (paired byte)",       oa, vh, wd);
        cpu_read (27'h004003, exp_byte(27'h004003), "hit-3",   oa, vh, wd); show("hit   (same byte again)",   oa, vh, wd);
        cpu_write(27'h004002, 8'h77);
        cpu_read (27'h004003, exp_byte(27'h004003), "miss-3",  oa, vh, wd); show("miss  (after write to word)", oa, vh, wd);
        cpu_read (27'h004002, 8'h77,                "hit-4",   oa, vh, wd); show("hit   (reads written byte)", oa, vh, wd);
        cpu_write(27'h004100, 8'h55);
        cpu_read (27'h004003, exp_byte(27'h004003), "hit-5",   oa, vh, wd); show("hit   (after unrelated write)", oa, vh, wd);

        $display("");
        if (errors) $display("RESULT: %0d violation(s)", errors);
        else        $display("RESULT: guard never opened on stale data");
        $finish;
    end
endmodule
