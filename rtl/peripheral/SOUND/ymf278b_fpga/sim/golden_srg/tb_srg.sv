// Golden-comparison TB for srg320's YMF278B PCM engine (YMF278B.sv, commit
// 28ddb1b of srg320/Arcade-PsikyoSH2_MiSTer).  Plays the same scenario scripts
// as ../golden (tb_golden_pcm.sv) and writes one "<L> <R>" line per 44.1 kHz
// output sample, so the result can go through the same comparators.
//
// plusargs:
//   +script=<file>  lines: <frame> <addr_hex> <data_hex> [<apply_cycle>]
//   +mem=<file>     $readmemh byte file (mem.hex from gen_pcm_testdata.py)
//   +frames=<n>     output samples to write
//   +out=<file>
//   +ldwait=1       after a wave-number write (08h-1Fh) poll the status port
//                   until LD clears before the next register write, as a
//                   driver honouring the datasheet would (default 0)
//   +memlat=1       wave memory answers one clock after MA changes instead of
//                   combinationally (sensitivity check; default 0)
//   +idle=<n>       let the chip run n output samples after reset before the
//                   scenario starts (moves its free-running EG counter SCNT;
//                   default 0)
//   +pre=<file>     extra writes applied after NEW2 is set, before frame 1
//                   (same format; frame column ignored)
//
// Clocking.  The chip advances on CE; CLK_DIV (/4) and CYCLE_NUM (/8) make one
// slot 32 CE and one output sample 24*32 = 768 CE.  44.1 kHz therefore needs
// CE = 33.8688 MHz (the real chip's master clock).  As in PSH2.sv the CE is
// CLK/2 (SYS_CE_R = toggling CLK_DIV), so CLK = 67.7376 MHz, 1536 CLK/sample.
// Only the ratio matters to the samples; the TB does not use absolute time.
//
// Frame convention (same as tb_golden_pcm.sv): writes for frame N are issued
// during frame N-1 at apply_cycle/1948 of the frame, and the stream line k is
// the PCM value latched at the k-th output event.  Any pipeline latency of the
// chip shows up as a constant lag that the comparator measures and reports.
`timescale 1ns/1ps

module tb_srg;
    localparam int CLK_PER_SAMPLE = 1536;
    logic clk = 0;
    always #7.38 clk = ~clk;            // 67.7 MHz (value irrelevant)

    logic ce = 0;
    always @(posedge clk) ce <= ~ce;    // PSH2.sv: SYS_CE_R = CLK_DIV toggle

    logic rst_n = 0, ic_n = 0;
    logic [2:0] A = 0;
    logic [7:0] DI = 0;
    wire  [7:0] DO;
    logic RD_N = 1, WR_N = 1, CS_N = 1;
    wire  IRQ_N;
    wire [20:0] MA;
    logic [7:0] MDI;
    wire [7:0] MDO;
    wire MRD_N, MWR_N;
    wire [9:0] MCS_N;
    wire [15:0] o0l, o0r, o1l, o1r, o2l, o2r;

    YMF278B dut (
        .CLK(clk), .RST_N(rst_n), .EN(1'b1), .CE(ce),
        .A(A), .DI(DI), .DO(DO), .RD_N(RD_N), .WR_N(WR_N), .CS_N(CS_N), .IC_N(ic_n),
        .IRQ_N(IRQ_N),
        .MA(MA), .MDI(MDI), .MDO(MDO), .MRD_N(MRD_N), .MWR_N(MWR_N), .MCS_N(MCS_N),
        .OUT0_L(o0l), .OUT0_R(o0r), .OUT1_L(o1l), .OUT1_R(o1r), .OUT2_L(o2l), .OUT2_R(o2r),
        .SND_EN(3'b111), .MONO(1'b0)
    );

    // ── wave memory: 4 MB, 22-bit byte address ─────────────────────────────
    // MA is the low 21 bits; MCS_N[0] = ~(A21 == 0) = A21 (PSH2.sv VER<=1 uses
    // {1'b0, MCS_N[0], MA} the same way).  Unwritten bytes read 0xFF, as in
    // openMSX for unmapped memory and in ref278.cpp past the end of mem.bin.
    logic [7:0] mem [0:4194303];
    wire  [21:0] maddr = {MCS_N[0], MA};
    int MEMLAT = 0;
    logic [7:0] mdi_q;
    always @(posedge clk) begin
        mdi_q <= mem[maddr];
        if (!MWR_N) mem[maddr] <= MDO;       // CPU writes through reg 06h
    end
    assign MDI = (MEMLAT != 0) ? mdi_q : mem[maddr];
    // log every CPU write that reaches the wave memory (reg 06h path)
    logic mwr_n_d = 1'b1;
    always @(posedge clk) begin
        mwr_n_d <= MWR_N;
        if (!MWR_N && mwr_n_d) $display("MEMWR %06h %02h", maddr, MDO);
    end

    // ── script ─────────────────────────────────────────────────────────────
    int s_frame [0:16383];
    int s_addr  [0:16383];
    int s_data  [0:16383];
    int s_wcyc  [0:16383];
    int n_writes = 0;
    int p_addr [0:1023];
    int p_data [0:1023];
    int n_pre = 0;
    int frames = 100;
    int LDWAIT = 0;
    int n_ldpolls = 0;
    int fd_out;
    int cur_frame = -1;          // index of the output sample being generated
    int frame_clk = 0;           // clocks since the last output event
    logic started = 0;

    task automatic load_script(input string f, input bit pre);
        int fd, fr, ad, da, wc, code;
        string ln;
        fd = $fopen(f, "r");
        if (fd == 0) begin $display("FATAL: no script %s", f); $finish; end
        while ($fgets(ln, fd)) begin
            code = $sscanf(ln, "%d %h %h %d", fr, ad, da, wc);
            if (code >= 3) begin
                if (pre) begin p_addr[n_pre] = ad; p_data[n_pre] = da; n_pre++; end
                else begin
                    s_frame[n_writes] = fr; s_addr[n_writes] = ad; s_data[n_writes] = da;
                    s_wcyc[n_writes] = (((code == 4) ? wc : 1000) * CLK_PER_SAMPLE + 974) / 1948;
                    n_writes++;
                end
            end
        end
        $fclose(fd);
    endtask

    // one CPU bus write: CS_N/WR_N low for 4 clocks (2 CE), high for 4.
    // The chip edge-detects WR_N on CE (WR_N_OLD), so >= 1 CE low and >= 1 CE
    // high between writes is required.
    task automatic bus_wr(input [2:0] a, input [7:0] d);
        @(negedge clk); A = a; DI = d; CS_N = 0; WR_N = 0;
        repeat (4) @(negedge clk);
        WR_N = 1; CS_N = 1;
        repeat (4) @(negedge clk);
    endtask

    // register write via the wave port: A=4 address, A=5 data.  REG_WR is
    // consumed (and REG_A must still be valid) at the next CYCLE1_CE, which
    // comes every 8 CE = 16 clocks; wait 24 clocks so REG_A/REG_D cannot be
    // overwritten before the chip has used them.
    task automatic reg_wr(input [7:0] a, input [7:0] d);
        bus_wr(3'd4, a);
        bus_wr(3'd5, d);
        repeat (24) @(negedge clk);
        if (LDWAIT != 0 && a >= 8'h08 && a <= 8'h1F) begin
            // status reads at A=0 until LD clears.  DO = {6'b0, LD|LD2,
            // BUSY|BUSY2} for A != 5; LD2 (set by the NEW2 write) is only
            // cleared by the rising RD_N of a status read, so real reads are
            // needed, not just looking at DO.
            int polls = 0;
            logic [7:0] st;
            do begin
                bus_rd(3'd0, st);
                polls++;
            end while (st[1] && polls < 100000);
            n_ldpolls += polls;
        end
    endtask

    task automatic bus_rd(input [2:0] a, output logic [7:0] d);
        @(negedge clk); A = a; CS_N = 0; RD_N = 0;
        repeat (4) @(negedge clk);
        d = DO;
        RD_N = 1;
        repeat (1) @(negedge clk);
        CS_N = 1;
        repeat (4) @(negedge clk);
    endtask

    initial begin
        string script_f, mem_f, out_f, pre_f;
        if (!$value$plusargs("script=%s", script_f)) script_f = "script.txt";
        if (!$value$plusargs("mem=%s", mem_f))       mem_f    = "mem.hex";
        if (!$value$plusargs("out=%s", out_f))       out_f    = "out_srg.txt";
        void'($value$plusargs("frames=%d", frames));
        void'($value$plusargs("ldwait=%d", LDWAIT));
        void'($value$plusargs("memlat=%d", MEMLAT));
        for (int i = 0; i < 4194304; i++) mem[i] = 8'hFF;
        $readmemh(mem_f, mem);
        load_script(script_f, 0);
        if ($value$plusargs("pre=%s", pre_f)) load_script(pre_f, 1);
        $display("script: %0d writes (+%0d pre), %0d frames, ldwait=%0d memlat=%0d",
                 n_writes, n_pre, frames, LDWAIT, MEMLAT);
        fd_out = $fopen(out_f, "w");

        repeat (20) @(negedge clk);
        rst_n = 1;
        repeat (20) @(negedge clk);
        ic_n = 1;
        // the chip clears its slot registers in the first 24-slot pass (RST);
        // give it two full samples.
        repeat (2 * CLK_PER_SAMPLE) @(negedge clk);
        // NEW2: FM bank-1 register 05h bit1 (A=2 address 05h, A=3 data 03h).
        // Without it the chip ignores A=4/A=5 (REG_A/REG_D are gated by NEW2).
        bus_wr(3'd2, 8'h05);
        bus_wr(3'd3, 8'h03);
        repeat (16) @(negedge clk);
        for (int i = 0; i < n_pre; i++) reg_wr(p_addr[i][7:0], p_data[i][7:0]);
        begin
            int idle = 0;
            void'($value$plusargs("idle=%d", idle));
            repeat (idle * CLK_PER_SAMPLE) @(negedge clk);
        end
        // align: start the frame count on the next output event
        started = 1;
    end

    // output event: PCM_L/PCM_R are latched when OP7.SLOT == 0, CYCLE_NUM[2:1]
    // == 0 and CYCLE1_CE (end of the 24-slot accumulation).  The TB samples
    // OUT1 (raw PCM sum, TrimWave-saturated, no MIXPCM) one clock later.
    wire pcm_evt = (dut.OP7.SLOT == 5'd0) && (dut.CYCLE_NUM[2:1] == 2'b00) && dut.CYCLE1_CE;
    logic pcm_evt_d = 0;
    always @(posedge clk) begin
        pcm_evt_d <= pcm_evt && started;
        frame_clk <= pcm_evt ? 0 : frame_clk + 1;
        if (pcm_evt_d) begin
            if (cur_frame >= 0) $fdisplay(fd_out, "%0d %0d", $signed(o1l), $signed(o1r));
            cur_frame <= cur_frame + 1;
            if (cur_frame + 1 >= frames) begin
                $fclose(fd_out);
                $display("SRG: %0d frames done, %0d LD status polls", frames, n_ldpolls);
                $finish;
            end
        end
    end

    // writes for frame N go out during frame N-1 at their apply cycle; they
    // are serialized (a CPU can only do one at a time), so a burst can spill
    // past the frame boundary -- that is what a real CPU would do too.
    initial begin
        wait (started);
        for (int wi = 0; wi < n_writes; wi++) begin
            while (!(cur_frame >= s_frame[wi] ||
                     (cur_frame == s_frame[wi] - 1 && frame_clk >= s_wcyc[wi])))
                @(negedge clk);
            reg_wr(s_addr[wi][7:0], s_data[wi][7:0]);
        end
    end

    initial begin
        #20s;
        $display("FATAL: timeout");
        $finish;
    end
endmodule
