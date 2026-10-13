`timescale 1ps/1ps
// sdram_tdm under random traffic: four channel agents and a VRAM agent against a
// reference memory, through the checking SDRAM model (sdram_chk.sv).
//
//   +m128=0|1  board map (1 chip / 2 chips)      +cycles=N  run length
//   +seed=N                                       +busy=P    request rate, % per cycle
//   +stock=1   ch2 behaves like T80s at 3.58 MHz: no handshake -- the request is
//              held 30 clocks and the byte is taken at a FIXED point, after edge
//              E0+DL (E0 = the edge that first sees the request; +dl=N, default 28,
//              measured in fullsys: window 232.8 ns, completion must be by W+29 =
//              E0+28).  Requests start on a 36-clock grid (one T-state = 3 frames),
//              3-5 T-states apart.  A read not complete by then is "LATE" and fails.
//
// Each agent owns a disjoint address region, so a reference memory per agent
// gives the exact expected read value (no cross-channel ordering to model).  The
// ch2 agent reads its own writes back, which is what exercises the read cache.
// Prints "TDM RESULT PASS|FAIL" and per channel: done, max latency in clocks.
module altddio_out #(parameter extend_oe_disable = "OFF", intended_device_family = "",
    invert_output = "OFF", lpm_hint = "", lpm_type = "", oe_reg = "", power_up_high = "OFF",
    parameter int width = 1)
  (input [width-1:0] datain_h, datain_l, input outclock, output [width-1:0] dataout,
   input aclr, aset, oe, outclocken, sclr, sset);
    assign dataout = outclock ? datain_h : datain_l;
endmodule

module tb;
    localparam int TCK = 7760;
    logic clk = 0;
    always #(TCK/2) clk = ~clk;

    int m64 = 0;                          // +m64=1: 64 MB board (build with -DCHIP64)
    int m128 = 0, ncyc = 200000, seed = 1, busy = 30, stock = 0, dl = 28, cpulow = 0;
    initial begin
        void'($value$plusargs("m128=%d", m128));
        void'($value$plusargs("cycles=%d", ncyc));
        void'($value$plusargs("seed=%d", seed));
        void'($value$plusargs("busy=%d", busy));
        void'($value$plusargs("stock=%d", stock));
        void'($value$plusargs("dl=%d", dl));
        void'($value$plusargs("cpulow=%d", cpulow));
        void'($value$plusargs("m64=%d", m64));
        void'($urandom(seed));
    end

    wire [15:0] DQ;
    wire [12:0] A;
    wire [1:0]  BA;
    wire nCS, nWE, nRAS, nCAS, CKE, SCLK, DQML, DQMH;
    logic init = 1;

    logic [26:0] c_addr [4];
    logic  [7:0] c_din  [4];
    logic        c_req  [4];
    logic        c_rnw  [4];
    wire   [7:0] c_dout [4];
    wire         c_ready[4];
    wire         ch2_hit, ch2_rdtog, ch3_done;
    wire  [15:0] ch4_dout16;

    logic        v_req = 0, v_we = 0;
    logic [15:0] v_addr = 0;
    logic [31:0] v_wdata = 0;
    logic  [3:0] v_be = 0;
    wire         v_grant, v_rvalid;
    wire  [31:0] v_rdata;

    sdram_tdm #(.CACHE_LINES(1024)) dut (
        .init(init), .clk(clk), .mode128(m128[0]), .mode64(m64[0]), .v_en(1'b1),
        .SDRAM_DQ(DQ), .SDRAM_A(A), .SDRAM_DQML(DQML), .SDRAM_DQMH(DQMH), .SDRAM_BA(BA),
        .SDRAM_nCS(nCS), .SDRAM_nWE(nWE), .SDRAM_nRAS(nRAS), .SDRAM_nCAS(nCAS), .SDRAM_CKE(CKE),
        .SDRAM_CLK(SCLK),
        .ch1_addr(c_addr[0]), .ch1_dout(c_dout[0]), .ch1_din(c_din[0]), .ch1_req(c_req[0]), .ch1_rnw(c_rnw[0]), .ch1_ready(c_ready[0]),
        .ch2_addr(c_addr[1]), .ch2_dout(c_dout[1]), .ch2_din(c_din[1]), .ch2_req(c_req[1]), .ch2_rnw(c_rnw[1]), .ch2_ready(c_ready[1]),
        .ch2_rdtog(ch2_rdtog), .ch2_hit(ch2_hit),
        .ch3_addr(c_addr[2]), .ch3_dout(c_dout[2]), .ch3_din(c_din[2]), .ch3_req(c_req[2]), .ch3_rnw(c_rnw[2]), .ch3_ready(c_ready[2]),
        .ch3_done(ch3_done),
        .ch4_addr(c_addr[3]), .ch4_dout(c_dout[3]), .ch4_dout16(ch4_dout16), .ch4_din(c_din[3]), .ch4_req(c_req[3]), .ch4_rnw(c_rnw[3]), .ch4_ready(c_ready[3]),
        .v_req(v_req), .v_we(v_we), .v_addr(v_addr), .v_wdata(v_wdata), .v_be(v_be),
        .v_grant(v_grant), .v_rdata(v_rdata), .v_rvalid(v_rvalid)
    );

`ifdef CHIP64
    sdram_chk #(.NCHIP(1), .COLS(1024)) chip2 (
`elsif ONECHIP
    sdram_chk #(.NCHIP(1), .COLS(512)) chip2 (
`else
    sdram_chk #(.NCHIP(2), .COLS(1024)) chip2 (
`endif.clk(SCLK), .dq(DQ), .a(A), .ba(BA), .ncs(nCS),
        .nras(nRAS), .ncas(nCAS), .nwe(nWE), .fpga_oe(dut.dq_oe_o));

    int bad = 0;
    task automatic fail(input string s);
        bad++;
        if (bad <= 20 || (s.substr(0,1) == "ch" && bad < 400)) $display("TDM ERR t=%0t %s", $time, s);
    endtask

    // ── regions: disjoint per agent, spread over rows with and without A12:A11 ──
    //  32 MB map: row[12:11] = a[22:21]; regions straddle 2 MB boundaries.
    //  128 MB map: all below 28 MB.  Each region 64 kB inside a 4 MB window so
    //  both row-bit classes and several banks are hit.
    function automatic logic [26:0] region_addr(int ag, int r);
        int base;
        //  +stock=1 with +cpulow=1: the CPU where a machine keeps its BIOS and RAM
        //  (0.25-1.25 MB: bank 0, row bits 00), next to ch1's region in the same bank
        //  +m64: ch4 lives at 24.5-28.5 MB, the range a 64 MB board moves to 32 MB
        if (ag == 3 && m64) return 27'h1880000 + ((r % 4) * 27'h0100000) + ($urandom % 16384);
        if (ag == 1 && stock && cpulow) return 27'h0040000 + ((r % 4) * 27'h0040000) + ($urandom % 16384);
        if (m128 == 0) base = ag * 27'h0500000 + 27'h0180000;   // 1.5, 6.5, 11.5, 16.5 MB ...
        else           base = ag * 27'h0600000 + 27'h0180000;   // up to ~19.5 MB, both chips
        return base + ((r % 4) * 27'h0100000) + ($urandom % 16384);
    endfunction

    byte ref_mem [int];
    int  done [4], lat_max [4], issued [4], nread [4], nhit = 0;
    int  nlate = 0, stock_lat_max = 0;
    int  gclk = 0;                       // clocks since start, for the T-state grid
    int  gph;                            // the grid's phase against the TDM frame: per seed
    initial begin #1; gph = $urandom % 36; void'($value$plusargs("gph=%d", gph)); end
    always @(posedge clk) gclk++;

    task automatic agent(int ag);
        int r = 0;
        logic [26:0] last = 0;

        wait (dut.run); repeat (30) @(posedge clk);
        forever begin
            logic [26:0] ad;
            logic rnw;
            logic [7:0] d;
            int t0, waited;
            bit  started;
            byte expect_v;
            bit  have_expect;
            if (($urandom % 100) >= busy) begin @(posedge clk); continue; end
            ad  = region_addr(ag, r++);
            //  ch2 reads back what it just touched half the time: the read cache's hits
            if (ag == 1 && last != 0 && ($urandom % 2 == 0)) ad = last;
            rnw = ($urandom % 3) != 0;
            d   = $urandom;
            last = ad;
            have_expect = ref_mem.exists(int'(ad));
            expect_v = have_expect ? ref_mem[int'(ad)] : 0;
            // a read of a never-written byte proves nothing; write it first
            if (rnw && !have_expect) rnw = 0;
            if (stock && ag == 1) begin
                //  next T-state boundary 3-5 T-states on (the grid has a fixed phase)
                int k;
                logic tog0, dn;
                int tdone;
                k = 3 + ($urandom % 3);
                while (gclk % 36 != gph) @(posedge clk);
                repeat ((k - 1) * 36) @(posedge clk);
                @(negedge clk);
                c_addr[ag] = ad; c_rnw[ag] = rnw; c_din[ag] = d; c_req[ag] = 1;
                @(posedge clk);                       // E0
                #1 tog0 = ch2_rdtog; dn = 0; tdone = -1;
                for (int e = 1; e <= dl; e++) begin
                    @(posedge clk); #1;
                    if (!dn && (ch2_rdtog != tog0 || ch2_hit)) begin dn = 1; tdone = e; end
                end
                if (rnw) begin                        // taken between E0+dl and E0+dl+1
                    nread[ag]++;
                    if (ch2_hit) nhit++;
                    if (!dn) begin
                        //  how late, and what the controller was doing (diagnosis only)
                        int e2;
                        string why;
                        why = $sformatf("rf_now=%b rf_next=%b prev_b=%0d prev_v=%0d", dut.rf_now, dut.rf_next, dut.prev_b, dut.prev_v);
                        for (e2 = dl + 1; e2 < 120; e2++) begin @(posedge clk); #1; if (ch2_rdtog != tog0) break; end
                        nlate++;
                        fail($sformatf("ch2 LATE (stock): read %h complete at E0+%0d, deadline E0+%0d (%s)", ad, e2, dl, why));
                        repeat (2) @(posedge clk);
                    end
                    else if (c_dout[ag] !== expect_v)
                        fail($sformatf("ch2 read %h = %h, expected %h", ad, c_dout[ag], expect_v));
                    if (tdone > stock_lat_max) stock_lat_max = tdone;
                end else ref_mem[int'(ad)] = d;
                repeat (30 - dl) @(posedge clk);
                c_req[ag] = 0;
                done[ag]++;
                continue;
            end
            @(negedge clk);
            c_addr[ag] = ad; c_rnw[ag] = rnw; c_din[ag] = d; c_req[ag] = 1;
            t0 = 0; started = 0;
            // ch1 / ch3 behave like memory_upload and the flash bridge: a request
            // one clk21m long (6 clocks), then ready polled once a clk21m, and
            // ready high at a poll 12+ clocks after the request = done.  ready
            // must therefore fall within 12 clocks of the request edge
            // (memory_upload.sv:542); the fall-and-rise wait below hid that.
            if (ag == 0 || ag == 2) begin
                repeat (6) @(posedge clk);
                c_req[ag] = 0; t0 = 6;
                forever begin
                    repeat (6) @(posedge clk); t0 += 6;
                    if (c_ready[ag]) break;
                    if (t0 > 2000) begin fail($sformatf("ch%0d stuck, addr %h rnw %0d", ag + 1, ad, rnw)); break; end
                end
            end else
            // done = ready fell and rose again, or (ch2 read) a cache hit
            forever begin
                @(posedge clk); t0++;
                if (!c_ready[ag]) started = 1;
                if (ag == 1 && rnw && ch2_hit) begin nhit++; break; end
                if (started && c_ready[ag]) break;
                if (t0 > 2000) begin fail($sformatf("ch%0d stuck, addr %h rnw %0d", ag + 1, ad, rnw)); break; end
            end
            c_req[ag] = 0;
            if (t0 > lat_max[ag]) lat_max[ag] = t0;
            done[ag]++;
            if (rnw) begin
                nread[ag]++;
                #1;
                if (c_dout[ag] !== expect_v)
                    fail($sformatf("ch%0d read %h = %h, expected %h", ag + 1, ad, c_dout[ag], expect_v));
            end else ref_mem[int'(ad)] = d;
            @(posedge clk);
        end
    endtask

    // ── why a ch2 read is slow (diagnosis, as in sim/fullsys/tb_msx.sv): clocks
    //    edge -> queued -> picked -> captured, and per passed-over G decision
    //    R refresh, B previous slot's bank, O another channel, - not queued yet
    int ts_cyc = 0, ts_e0 = -1, ts_q = -1, ts_p = -1;
    string ts_why = "";
    logic ts_rq_q = 0, ts_tog = 0, ts_req_q = 0;
    always @(posedge clk) begin
        ts_cyc++;
        ts_rq_q <= dut.ch2_rq; ts_req_q <= c_req[1];
        if (c_req[1] & c_rnw[1] & ~ts_req_q) begin ts_e0 = ts_cyc; ts_q = -1; ts_p = -1; ts_why = ""; ts_tog <= ch2_rdtog; end
        if (dut.ch2_rq & ~ts_rq_q & ts_q < 0 & ts_e0 >= 0) ts_q = ts_cyc;
        if (dut.run && (dut.ps[2] || dut.ps[6]) && ts_q >= 0 && ts_p < 0) begin
            if (dut.cand_ok[0]) ts_p = ts_cyc;
            else ts_why = {ts_why, (|dut.rf_now || (dut.ps[2] && |dut.rf_next)) ? "R"
                                 : (dut.prev_v && dut.cand_l[0].b == dut.prev_b && dut.cand_l[0].c == dut.prev_c) ? "B"
                                 : (|dut.cand_ok[3:1]) ? "O" : "-"};
        end
        if (ts_e0 >= 0 && ch2_rdtog != ts_tog && ts_p >= 0) begin
            if (stock && ts_cyc - ts_e0 > dl)
                $display("TDM SLOW t=%0t ch2 read %0d clk: queued +%0d picked +%0d, passed over [%s]",
                         $time, ts_cyc - ts_e0, ts_q - ts_e0, ts_p - ts_e0, ts_why);
            ts_e0 = -1;
        end
    end

    // ── VRAM agent: a request every frame, changed only after a grant ──
    logic [31:0] vref [int];
    int vdone = 0, vreads = 0, vden = 0;
    //  expected V reads in grant order: the result of one frame's read can arrive
    //  on the edge that grants the next (v_rvalid at the frame boundary)
    logic [31:0] vexp_q [$];
    logic [15:0] vexpa_q [$];
    task automatic vagent();

        wait (dut.run); repeat (30) @(posedge clk);
        forever begin
            v_addr  = $urandom % 4096;
            v_we    = ($urandom % 3) == 0 || !vref.exists(v_addr);
            v_wdata = $urandom;
            v_be    = v_we ? ($urandom % 16) : 4'hF;
            if (v_we && v_be == 0) v_be = 4'h5;
            v_req   = ($urandom % 100) < 90;
            // wait for the frame boundary that samples it (dut ph 11 -> 0)
            forever begin @(posedge clk); #1; if (dut.ph == 4'd0) break; end
            if (v_req && v_grant) begin
                vdone++;
                if (v_we) begin
                    logic [31:0] o = vref.exists(v_addr) ? vref[v_addr] : 32'h0;
                    for (int b = 0; b < 4; b++) if (v_be[b]) o[b*8 +: 8] = v_wdata[b*8 +: 8];
                    vref[v_addr] = o;
                end else begin
                    vexp_q.push_back(vref[v_addr]); vexpa_q.push_back(v_addr);
                end
            end else if (v_req) vden++;
            @(negedge clk);
        end
    endtask
    always @(posedge clk) if (v_rvalid) begin
        #1;
        if (vexp_q.size() == 0) fail("v_rvalid with no read outstanding");
        else begin
            logic [31:0] ex; logic [15:0] ea;
            ex = vexp_q.pop_front(); ea = vexpa_q.pop_front();
            vreads++;
            if (v_rdata !== ex) fail($sformatf("V read %h = %h, expected %h", ea, v_rdata, ex));
        end
    end

    initial begin
        for (int i = 0; i < 4; i++) begin c_req[i] = 0; c_addr[i] = 0; c_rnw[i] = 1; c_din[i] = 0; end
        repeat (10) @(posedge clk);
        init = 0;
        fork agent(0); agent(1); agent(2); agent(3); vagent(); join_none
        repeat (ncyc) @(posedge clk);
        $display("TDM m128=%0d busy=%0d seed=%0d cycles=%0d", m128, busy, seed, ncyc);
        for (int i = 0; i < 4; i++)
            $display("  ch%0d: done=%0d reads=%0d max latency=%0d clk", i + 1, done[i], nread[i], lat_max[i]);
        $display("  ch2 cache hits=%0d  V: granted=%0d reads checked=%0d refused=%0d", nhit, vdone, vreads, vden);
        if (stock) $display("  ch2 stock: grid phase %0d: LATE=%0d  completion max E0+%0d (deadline E0+%0d)", gph, nlate, stock_lat_max, dl);
        $display("  chip: ACT=%0d READ=%0d WRITE=%0d REFRESH=%0d ras_lockout=%0d errors=%0d",
                 chip2.nact, chip2.nrd, chip2.nwr, chip2.nref, chip2.ras_lockout, chip2.errs);
        if (bad == 0 && chip2.errs == 0 && done[0] > 0 && done[1] > 0 && done[2] > 0 && done[3] > 0
            && vreads > 0 && chip2.nref > 0 && nread[1] > 0)
            $display("TDM RESULT PASS");
        else
            $display("TDM RESULT FAIL (tb errors %0d, chip errors %0d)", bad, chip2.errs);
        $finish;
    end
endmodule
