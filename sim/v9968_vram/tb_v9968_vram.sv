`timescale 1ps/1ps
//  The real V9968 (rtl/video/v9968, unmodified) on sdram_tdm's V slot through v9968_link,
//  over the checking SDRAM model (sim/sdram_tdm/sdram_chk.sv).  2026-10-21, plan S2.
//
//  clk_sdram 7.760 ns, clk_vdp 11.640 ns, both rising at t = 0: they share an edge every
//  23.28 ns, as the PLL's outputs do.  A CPU task drives the V9968's bus: SCREEN 5,
//  display on, VRAM written through port 98h and read back, so the VRAM port carries
//  screen and sprite fetches, CPU reads and writes, and VDP-command-cache traffic.
//
//  Checks (every one counted; RESULT PASS needs all):
//    lat   every vram_rdata_en sampled exactly 8 clk_vdp after the request was (ip_sdram's
//          contract); histogram printed
//    data  the read word against a shadow of every byte written through the port (bytes
//          never written are not compared; count of compared bytes printed)
//    order every read answered, none unanswered at the end, no rdata_en without a read
//    drop / mis: v9968_link's monitors (request not taken / request off the frame grid)
//    cpu   the bytes read back through port 98h equal what was written
//  +ph=N is not a run-time knob: RELEASE_PH is a parameter, see run.sh (-GRELEASE_PH=N).
module altddio_out #(parameter extend_oe_disable = "OFF", intended_device_family = "",
    invert_output = "OFF", lpm_hint = "", lpm_type = "", oe_reg = "", power_up_high = "OFF",
    parameter int width = 1)
  (input [width-1:0] datain_h, datain_l, input outclock, output [width-1:0] dataout,
   input aclr, aset, oe, outclocken, sclr, sset);
    assign dataout = outclock ? datain_h : datain_l;
endmodule

module tb #(parameter int RELEASE_PH = 0);
    logic clk_sdram = 0, clk_vdp = 0;
    always #3880 clk_sdram = ~clk_sdram;
    always #5820 clk_vdp   = ~clk_vdp;

    int m128 = 1, ms = 3, nbytes = 4096, cmd = 0, hs = 0, scr = 5;
    initial begin
        void'($value$plusargs("m128=%d", m128));
        void'($value$plusargs("ms=%d", ms));
        void'($value$plusargs("bytes=%d", nbytes));
        void'($value$plusargs("cmd=%d", cmd));
        void'($value$plusargs("hs=%d", hs));      // V9968 high-speed command mode (force_highspeed)
        void'($value$plusargs("scr=%d", scr));    // SCREEN 5, 7 or 8
        void'($value$plusargs("scan=%d", scan));  // scanline_level 0..3 (MSX1 core change)
        void'($value$plusargs("sp3=%d", sp3));    // R#20 SP3 (sprite mode 3) in the +cmd=3 test
        void'($value$plusargs("demo=%d", demo));  // +cmd=3 with SUPER CAT's exact registers (oracle trace), overrides below
        void'($value$plusargs("r1=%h", r1)); void'($value$plusargs("r20=%h", r20)); void'($value$plusargs("r21=%h", r21));
        void'($value$plusargs("r25=%h", r25)); void'($value$plusargs("r8=%h", r8));
        void'($value$plusargs("sat=%s", satf)); void'($value$plusargs("satms=%d", satms));   // SP3 sprite test: SAT bytes -> 10000h, display on
        void'($value$plusargs("satpre=%d", satpre));
        void'($value$plusargs("ct55=%d", ct55));
        void'($value$plusargs("offat=%d", offat));
        void'($value$plusargs("wl=%d", wl));
        void'($value$plusargs("lnsw=%d", lnsw));
        void'($value$plusargs("aso=%d", aso));
        void'($value$plusargs("pollpad=%d", pollpad));
        void'($value$plusargs("ie1=%d", ie1)); void'($value$plusargs("disp=%d", disp)); void'($value$plusargs("ie1off=%d", ie1off));
        void'($value$plusargs("ie1line=%h", ie1line)); void'($value$plusargs("ie1r9=%h", ie1r9)); void'($value$plusargs("ie1dly=%d", ie1dly));
        void'($value$plusargs("ovs=%d", ovs)); void'($value$plusargs("ovsln=%d", ovsln)); void'($value$plusargs("ovscmd=%d", ovscmd));   // +ovs=N trials of Shaolin's overscan + display-off + HMMV/HMMM; +ovsln=0 control (no LN=0); +ovscmd=HMMMs per trial   // +ie1line=D2 +ie1r9=80: ASO's second split (line 210, 212 lines); +ie1dly=clk_vdp from int_n to the S#1 read
        void'($value$plusargs("rpl=%s", rplf)); void'($value$plusargs("rplscale=%d", rplscale));   // +rplscale=P: event times x P/100 (R800 runs ~1.8x openMSX between I/O)   // +rpl=<file>: replay an oracle window (tools: aso_win.txt), paced, reads not forced   // +ie1=N: ASO 224's first in-game wait, line IRQ taken as int_n (no polling); +disp=1 control: display on   // +aso: extra clk_vdp per S#1 poll (moves the read phase against the line match)        // >0: ASO 224's per-frame line-IRQ loop for that many frames
        void'($value$plusargs("lr_sx=%d", lr_sx)); void'($value$plusargs("lr_sy=%d", lr_sy));      // +lr_*: one LRMM with these
        void'($value$plusargs("lr_vx=%d", lr_vx)); void'($value$plusargs("lr_vy=%d", lr_vy));      //  start/vectors (SUPER CAT frames)      // >=0: km224's overscan trick: 212 lines, R#9 LN=0 written at screen line lnsw (0 = never: control)          // 0..6: the seven V9938-referenced workloads of rtl/video/VDP/sim/tb_vdpcmd7.vhd    // >=0: display on 20 ms, then R#1=00 lands offat clk_vdp after the selector's (phase 2, sub 0) edge, then the LRMM      // 1: sprite colour table 0FE00h..0FFFFh = 55h and SAT 10000h..1007Fh = 0 (the oracle's VRAM at the hang)  // 1: write the SAT bytes before the command, no display change (replay's exact state)
    end

    //  ── SDRAM controller + model ──────────────────────────────────────────
    wire [15:0] DQ; wire [12:0] A; wire [1:0] BA;
    wire nCS, nWE, nRAS, nCAS, CKE, SCLK, DQML, DQMH;
    logic init = 1;
    wire v_go, v_req, v_we, v_grant, v_rvalid;
    wire [15:0] v_addr; wire [31:0] v_wdata, v_rdata; wire [3:0] v_be, tdm_ph;
    wire [7:0] cd [4];
    sdram_tdm #(.CACHE_LINES(1024)) dut (
        .init(init), .clk(clk_sdram), .mode128(m128[0]), .mode64(1'b0), .v_en(1'b1),
        .v_go(v_go), .tdm_ph(tdm_ph), .tdm_run(), .cpu_paced(1'b1),
        .SDRAM_DQ(DQ), .SDRAM_A(A), .SDRAM_DQML(DQML), .SDRAM_DQMH(DQMH), .SDRAM_BA(BA),
        .SDRAM_nCS(nCS), .SDRAM_nWE(nWE), .SDRAM_nRAS(nRAS), .SDRAM_nCAS(nCAS), .SDRAM_CKE(CKE),
        .SDRAM_CLK(SCLK),
        .ch1_addr(27'd0), .ch1_dout(cd[0]), .ch1_din(8'd0), .ch1_req(1'b0), .ch1_rnw(1'b1), .ch1_ready(),
        .ch2_addr(27'd0), .ch2_dout(cd[1]), .ch2_din(8'd0), .ch2_req(1'b0), .ch2_rnw(1'b1), .ch2_ready(),
        .ch2_rdtog(), .ch2_hit(), .ch2_busy(),
        .ch3_addr(27'd0), .ch3_dout(cd[2]), .ch3_din(8'd0), .ch3_req(1'b0), .ch3_rnw(1'b1), .ch3_ready(),
        .ch3_done(),
        .ch4_addr(27'd0), .ch4_dout(cd[3]), .ch4_dout16(), .ch4_din(8'd0), .ch4_req(1'b0), .ch4_rnw(1'b1), .ch4_ready(),
        .v_req(v_req), .v_we(v_we), .v_addr(v_addr), .v_wdata(v_wdata), .v_be(v_be),
        .v_grant(v_grant), .v_rdata(v_rdata), .v_rvalid(v_rvalid)
    );
`ifdef ONECHIP
    sdram_chk #(.NCHIP(1), .COLS(512)) chip2 (
`else
    sdram_chk #(.NCHIP(2), .COLS(1024)) chip2 (
`endif
        .clk(SCLK), .dq(DQ), .a(A), .ba(BA), .ncs(nCS),
        .nras(nRAS), .ncas(nCAS), .nwe(nWE), .fpga_oe(dut.dq_oe_o));

    //  ── link + V9968 ──────────────────────────────────────────────────────
    wire        vdp_reset_n;
    wire [17:2] vram_address; wire vram_write, vram_valid, vram_rdata_en;
    wire [31:0] vram_wdata, vram_rdata; wire [3:0] vram_wdata_mask;
    wire [15:0] mon_drop, mon_mis;
    v9968_link #(.RELEASE_PH(RELEASE_PH)) link (
        .clk_sdram(clk_sdram), .clk_vdp(clk_vdp), .rst(init), .sdram_run(dut.run),
        .tdm_ph(tdm_ph), .v_go(v_go), .vdp_reset_n(vdp_reset_n),
        .vram_address(vram_address), .vram_write(vram_write), .vram_valid(vram_valid),
        .vram_wdata(vram_wdata), .vram_wdata_mask(vram_wdata_mask),
        .vram_rdata(vram_rdata), .vram_rdata_en(vram_rdata_en),
        .v_req(v_req), .v_we(v_we), .v_addr(v_addr), .v_wdata(v_wdata), .v_be(v_be),
        .v_grant(v_grant), .v_rdata(v_rdata), .v_rvalid(v_rvalid),
        .mon_drop(mon_drop), .mon_mis(mon_mis));

    logic [2:0] bus_address = 0; logic bus_ioreq = 0, bus_write = 0, bus_valid = 0;
    logic [7:0] bus_wdata = 0; wire bus_ready, bus_rdata_en; wire [7:0] bus_rdata;
    string satf = ""; int satms = 50, satpre = 0, ct55 = 0, offat = -1, wl = -1, lnsw = -1, lr_sx = -1, lr_sy = 0, lr_vx = 0, lr_vy = 0, aso = 0, pollpad = 0, ie1 = 0, disp = 0, ie1off = 0, ie1line = 'h68, ie1r9 = 'h00, ie1dly = 400, ovs = 0, ovsln = 1, ovscmd = 64;
    string rplf = ""; int rplscale = 100;
    int scan = 0, sp3 = 0, demo = 0, r1 = 0, r20 = 8'h1F, r21 = 8'h3A, r25 = 3, r8 = 8;
    wire d_hs, d_en; wire [7:0] d_r, d_g, d_b;
    //  scanlines: the sum of r+g+b over displayed pixels per line parity (lines counted
    //  at each hsync fall); the ratio dim/bright parity should be 1 - scan/4
    longint sl_sum [2]; int sl_par = 0; logic d_hs_q = 1'b1;
    always @(posedge clk_vdp) begin
        d_hs_q <= d_hs;
        if (d_hs_q && !d_hs) sl_par <= sl_par ^ 1;
        if (d_en) sl_sum[sl_par] += d_r + d_g + d_b;
    end
    final if (sl_sum[0] + sl_sum[1] > 0)
        $display("SCANLINE level %0d: line sums %0d / %0d, ratio %.3f (want %.3f)", scan, sl_sum[0], sl_sum[1],
                 real'(sl_sum[0] < sl_sum[1] ? sl_sum[0] : sl_sum[1]) / real'(sl_sum[0] < sl_sum[1] ? sl_sum[1] : sl_sum[0]),
                 1.0 - scan / 4.0);
    //  command waits (vdp_command.v): +w=a,b,...(12, order hmmc ymmm hmmm hmmv lmmc lmcm lmmm
    //  lmmv line srch pset point) or +v9938=1 for rtl/video/v9968_cmdwait.sv's table; default 40s
    logic [95:0] cmdw; int v9938 = 0; wire [95:0] cmdw_tab;
    v9968_cmdwait u_cw (.v9938(1'b1), .cmd_wait(cmdw_tab));
    initial begin
        string ws; int vals [12]; int n = 0, v = 0; bit any = 0;
        cmdw = {12{8'd40}};
        void'($value$plusargs("v9938=%d", v9938));
        if (v9938) cmdw = cmdw_tab;
        if ($value$plusargs("w=%s", ws)) begin
            foreach (ws[i]) begin
                if (ws[i] >= "0" && ws[i] <= "9") begin v = v * 10 + (ws[i] - "0"); any = 1; end
                else if (any) begin vals[n++] = v; v = 0; any = 0; end
            end
            if (any) vals[n++] = v;
            for (int i = 0; i < 12; i++) cmdw[95 - 8*i -: 8] = 8'(vals[i]);
        end
    end
    wire v_int_n;
    vdp vdp9968 (
        .reset_n(vdp_reset_n), .clk(clk_vdp), .initial_busy(1'b0),
        .bus_address(bus_address), .bus_ioreq(bus_ioreq), .bus_write(bus_write), .bus_valid(bus_valid),
        .bus_ready(bus_ready), .bus_wdata(bus_wdata), .bus_rdata(bus_rdata), .bus_rdata_en(bus_rdata_en),
        .int_n(v_int_n),
        .vram_address(vram_address), .vram_write(vram_write), .vram_valid(vram_valid),
        .vram_wdata(vram_wdata), .vram_wdata_mask(vram_wdata_mask),
        .vram_rdata(vram_rdata), .vram_rdata_en(vram_rdata_en), .vram_refresh(),
        .display_hs(d_hs), .display_vs(), .display_en(d_en), .display_r(d_r), .display_g(d_g), .display_b(d_b),
        .force_highspeed(hs != 0),
        .ext_cmd_wr(1'b0), .ext_cmd_num(6'd0), .ext_cmd_data(8'd0), .ext_cmd_ce(),
        .scanline_level(2'(scan)), .cmd_wait(cmdw),
        .button(2'b00),
        .pulse0(), .pulse1(), .pulse2(), .pulse3(), .pulse4(), .pulse5(), .pulse6(), .pulse7());

    `define SSG vdp9968.u_timing_control.u_ssg
    int aso_f = 0; logic f_q = 0;
    //  every line-match pulse and every FH clear while +aso runs (why a wait missed its FH)
    logic lh_q = 0;
    always @(posedge clk_vdp) if (aso > 0) begin
        if (`SSG.ff_intr_line) $display("ASO   match: screen %0d R#19=%02h R#23=%02h v_count %0d t=%0t", $signed(`SSG.w_screen_pos_y),
                                         vdp9968.u_cpu_interface.reg_interrupt_line, vdp9968.reg_vertical_offset, `SSG.ff_v_count, $time);
        lh_q <= vdp9968.u_cpu_interface.ff_line_interrupt;
        if (lh_q && !vdp9968.u_cpu_interface.ff_line_interrupt) $display("ASO   FH cleared at screen %0d t=%0t", $signed(`SSG.w_screen_pos_y), $time);
    end
    //  stale status read: an S#1 read that clears FH while the latched status byte (one
    //  clock old) still shows FH=0 -- the CPU sees 0 and the flag is gone.
    int stale_fh = 0;
    always @(posedge clk_vdp) if (vdp9968.u_cpu_interface.w_read && vdp9968.u_cpu_interface.ff_port1
                                  && vdp9968.u_cpu_interface.ff_status_register_pointer == 4'd1
                                  && vdp9968.u_cpu_interface.ff_line_interrupt
                                  && !vdp9968.u_cpu_interface.ff_status_register[0]) begin
        stale_fh++; $display("ASO   STALE S#1 read cleared FH unseen t=%0t", $time);
    end
    always @(posedge clk_vdp) begin
        f_q <= vdp9968.u_cpu_interface.ff_frame_interrupt;
        if (aso > 0 && vdp9968.u_cpu_interface.ff_frame_interrupt && !f_q) begin
            aso_f++;
            $display("ASO F raised at screen line %0d (v_count %0d), LN=%0d", $signed(`SSG.w_screen_pos_y), `SSG.ff_v_count, vdp9968.reg_212lines_mode);
        end
    end
    //  ── VRAM port checker (clk_vdp) ───────────────────────────────────────
    logic [7:0] shadow [0:262143];
    bit         known  [0:262143];
    longint kv = 0;                               // clk_vdp edge count
    longint q_k[$]; int q_a[$];
    int nrd = 0, nwr = 0, nbyte_cmp = 0, bad_lat = 0, bad_data = 0, bad_order = 0, noans = 0;
    int lat_hist[0:31];
    always @(posedge clk_vdp) begin
        kv++;
        if (vdp_reset_n) begin
            //  a read whose answer is past due and did not come: the V slot did not take it
            //  (refresh, link mon_drop); counted, not matched against a later answer
            while (q_k.size() != 0 && kv - q_k[0] > 8 && !(vram_rdata_en && kv - q_k[0] == 8)) begin
                void'(q_k.pop_front()); void'(q_a.pop_front()); noans++;
            end
            if (vram_rdata_en) begin
                if (q_k.size() == 0) begin
                    bad_order++;
                    if (bad_order <= 5) $display("TB ERR t=%0t rdata_en with no read outstanding", $time);
                end else begin
                    longint k0; int a; int d;
                    k0 = q_k.pop_front(); a = q_a.pop_front();
                    d = int'(kv - k0);
                    lat_hist[d > 31 ? 31 : d]++;
                    if (d != 8) begin
                        bad_lat++;
                        if (bad_lat <= 5) $display("TB ERR t=%0t read %05h answered %0d clk_vdp after its request (want 8)", $time, a*4, d);
                    end
                    for (int b = 0; b < 4; b++)
                        if (known[a*4+b]) begin
                            nbyte_cmp++;
                            if (vram_rdata[b*8 +: 8] !== shadow[a*4+b]) begin
                                bad_data++;
                                if (bad_data <= 5) $display("TB ERR t=%0t read %05h byte %0d = %02h, written %02h", $time, a*4, b, vram_rdata[b*8 +: 8], shadow[a*4+b]);
                            end
                        end
                end
            end
            if (vram_valid) begin
                if (vram_write) begin
                    nwr++;
                    for (int b = 0; b < 4; b++)
                        if (!vram_wdata_mask[b]) begin
                            shadow[{vram_address, 2'b00} + b] = vram_wdata[b*8 +: 8];
                            known [{vram_address, 2'b00} + b] = 1;
                        end
                end else begin
                    nrd++; q_k.push_back(kv); q_a.push_back(int'(vram_address));
                end
            end
        end
    end

    //  ── V-slot occupancy per TDM frame (plan S3, measurement 2) ─────────────
    //  At each frame boundary: did the V9968 request?  Runs of busy frames, and per
    //  7.8125 us window (84 frames) the number of idle frames, from the first display
    //  frame on (mon_on).  An idle frame is where the VRAM chip may refresh.
    bit  mon_on = 0;
    longint fr_n = 0, fr_idle = 0, run_busy = 0, run_max = 0, win_fr = 0, win_idle = 0, win_min = 1000, win_n = 0, win0 = 0;
    int  run_hist [0:9];          // busy-run length: 0,1,2,3,4-7,8-15,16-31,32-63,64-127,128+
    always @(posedge clk_sdram) if (mon_on && dut.run && tdm_ph == 4'd11) begin
        fr_n++; win_fr++;
        if (v_req) run_busy++;
        else begin
            int b;
            fr_idle++; win_idle++;
            b = run_busy < 4 ? int'(run_busy) : run_busy < 8 ? 4 : run_busy < 16 ? 5 : run_busy < 32 ? 6 : run_busy < 64 ? 7 : run_busy < 128 ? 8 : 9;
            run_hist[b]++;
            if (run_busy > run_max) run_max = run_busy;
            run_busy = 0;
        end
        if (win_fr == 84) begin
            if (win_idle == 0) win0++;
            if (win_idle < win_min) win_min = win_idle;
            win_n++; win_fr = 0; win_idle = 0;
        end
    end

    //  ── CPU bus (clk_vdp) ─────────────────────────────────────────────────
    int cpu_bad = 0, cpu_n = 0;
    //  CPU bus timing (plan S5, the adapter): clk_vdp from valid to the accepting edge
    //  (bus_ready), and from acceptance to bus_rdata_en on reads, per port
    int acc_max [8], rd_max [8], acc_n [8], rd_n [8];
    int rd_hist [0:15];
    task automatic io(input logic wr, input logic [2:0] port, input logic [7:0] d, output logic [7:0] q);
        @(negedge clk_vdp);
        bus_ioreq = 1; bus_address = port; bus_write = wr; bus_wdata = d; bus_valid = 1;
        begin
            int w = 0;
            do begin @(posedge clk_vdp); w++; end while (!bus_ready && w < 20000);
            if (w > acc_max[port]) acc_max[port] = w; acc_n[port]++;
            if (!bus_ready) begin
                //  the V9968 waits for a VRAM answer without a time limit: a read the port
                //  never answered (or answered off its time) hangs its bus for ever
                $display("TB ERR t=%0t bus_ready stuck low 20000 clk_vdp (a VRAM read never answered?) reads %0d, answered-late %0d, not answered %0d",
                         $time, nrd, bad_lat, noans);
                $display("V9968 VRAM RESULT FAIL (hung)");
                $finish;
            end
        end
        @(negedge clk_vdp); bus_valid = 0;
        q = 8'hxx;
        if (!wr) begin
            int w = 0;
            do begin @(posedge clk_vdp); w++; end while (!bus_rdata_en && w < 2000);
            q = bus_rdata;
            if (w > rd_max[port]) rd_max[port] = w; rd_n[port]++;
            rd_hist[w / 8 > 15 ? 15 : w / 8]++;
        end
        repeat (4) @(posedge clk_vdp);
        @(negedge clk_vdp); bus_ioreq = 0;
        repeat (40) @(posedge clk_vdp);         // a turbo-R800 OUT pair is ~0.5 us apart; 40 clk_vdp = 0.47 us
    endtask
    task automatic wreg(input int r, input logic [7:0] v);
        logic [7:0] q; io(1, 3'd1, v, q); io(1, 3'd1, 8'h80 | r[7:0], q);
    endtask
    task automatic set_addr(input logic [16:0] a, input bit wr);
        logic [7:0] q;
        wreg(14, {5'd0, a[16:14]});
        io(1, 3'd1, a[7:0], q);
        io(1, 3'd1, {2'b00, a[13:8]} | (wr ? 8'h40 : 8'h00), q);
    endtask

    logic [7:0] pat [0:65535];
    initial begin
        logic [7:0] q;
        int runs = 0;
        repeat (20) @(posedge clk_sdram);
        init = 0;
        wait (dut.run); $display("TB t=%0t sdram_tdm running", $time);
        wait (vdp_reset_n); $display("TB t=%0t V9968 out of reset", $time);
        repeat (2000) @(posedge clk_vdp);
        //  SCREEN 5, 212 lines, display on, sprites on, name table 0, sprite tables at 7600h/7A00h
        wreg(0, scr == 8 ? 8'h0E : scr == 7 ? 8'h0A : 8'h06); wreg(1, 8'h60); wreg(2, 8'h1F); wreg(5, 8'hEF); wreg(11, 8'h00);
        wreg(6, 8'h0F); wreg(8, 8'h08); wreg(9, 8'h80);
        $display("TB t=%0t registers written", $time);
        //  write nbytes through port 98h from 0, then read them back
        for (int i = 0; i < nbytes; i++) pat[i] = 8'($urandom);
        set_addr(17'h00000, 1);
        for (int i = 0; i < nbytes; i++) io(1, 3'd0, pat[i], q);
        set_addr(17'h00000, 0);
        for (int i = 0; i < nbytes; i++) begin
            io(0, 3'd0, 8'h00, q); cpu_n++;
            if (q !== pat[i]) begin
                cpu_bad++;
                if (cpu_bad <= 5) $display("TB ERR cpu read-back %05h = %02h, wrote %02h", i, q, pat[i]);
            end
        end
        //  let the screen fetch read it for a while; +cmd=1: keep the command engine busy
        //  (HMMV over the whole 256x212 page, re-issued every 2 ms) -- its VRAM writes take
        //  every slot the screen leaves
        mon_on = 1;
        //  +lnsw=N: display on in 212-line mode; in two consecutive frames R#9 = 00h (LN=0) is
        //  written when the V9968 is on screen line N (N=0: never, the control), then 80h again in
        //  the vertical blank.  Logged per line: screen_pos_y, so a jump is visible; and whether
        //  the active area went on past 211 (the trick's purpose).
        if (lnsw >= 0) begin
            //  one monitor over 4 frames: per line (end of each 2nd 31 kHz line) screen_pos_y and
            //  ff_v_active; a jump = any step other than +1 inside the visible part (0..250)
            int fr = 0, jumps = 0, act_last = -1, act_lines = 0; logic [9:0] prev = 10'h3FF;
            bit done = 0;
            wreg(9, 8'h80); wreg(1, 8'h40);
            wait (`SSG.w_screen_pos_y == 10'h3FF);
            fork
                begin
                    while (!done) begin
                        @(posedge clk_vdp);
                        if (`SSG.w_h_count_end && `SSG.ff_v_count[0]) begin
                            logic [9:0] y; y = `SSG.w_screen_pos_y;
                            if (y == 10'h3FF && prev != 10'h3FF) begin
                                $display("LNSW frame %0d (lnsw=%0d): jumps %0d, active lines %0d, last active line %0d", fr, lnsw, jumps, act_lines, act_last);
                                fr++; jumps = 0; act_last = -1; act_lines = 0;
                                if (fr == 4) done = 1;
                            end else if (prev < 10'd250 && y < 10'd250 && y != prev + 10'd1) begin
                                jumps++; $display("LNSW frame %0d: screen line %0d -> %0d", fr, prev, y);
                            end
                            if (`SSG.ff_v_active) begin act_lines++; act_last = int'(y); end
                            prev = y;
                        end
                    end
                end
                begin
                    for (int f = 1; f < 4; f++) begin
                        wait (`SSG.w_screen_pos_y == 10'd1);
                        if (lnsw > 0 && f >= 2) begin
                            wait (`SSG.w_screen_pos_y == 10'(lnsw));
                            wreg(9, 8'h00);
                            $display("LNSW frame %0d: R#9=00 written at line %0d, now line %0d", fr, lnsw, `SSG.w_screen_pos_y);
                            wait (`SSG.w_screen_pos_y == 10'd230);   // LN=0 tops out at 234
                            wreg(9, 8'h80);
                        end
                        wait (`SSG.w_screen_pos_y == 10'h3FF);
                    end
                end
            join
        end
        //  +aso=N: ASO 224's game frame (oracle trace, openMSX V9968/V9958 both run it): four
        //  line IRQs per frame driven like the game -- FH(219): R#19=68h, R#23=18h, IE1 on;
        //  FH(104+R#23): R#19=D2h, LN=1; FH(210+R#23): R#23=0, R#0 06h/16h, R#19=C6h, wait FH(198);
        //  then R#19=DBh, LN=0 (the overscan trick).  FH is polled on S#1 like the game (timeout
        //  one frame = "stuck").  A monitor logs every frame-interrupt (F) rise with its screen
        //  line: on the V9958 a frame whose LN goes 1 -> 0 between 192 and 212 has no F at all.
        //  +rpl=<file>: replay ASO 224's display-off window from the oracle trace, paced to its
        //  times.  Lines "t_ns W|R port(0-3) val 0", plus "0 W 9 reg val" for the register state
        //  at the start.  Reads are NOT forced: status bytes are compared with the oracle's
        //  (mismatches printed); a VDP bus that never answers ends the run (io task, "hung").
        //  After the last event: wait for int_n as +ie1 does (the game waits there for the
        //  line interrupt).
        if (rplf != "") begin
            int fd, n = 0, mis = 0, misce = 0, pt, a, b; longint tt, base; string d; logic [7:0] q;
            fd = $fopen(rplf, "r");
            if (fd == 0) begin $display("RPL cannot open %s", rplf); $finish; end
            base = $time;
            while ($fscanf(fd, "%d %s %d %h %h", tt, d, pt, a, b) == 5) begin
                if (pt == 9) begin wreg(a, 8'(b)); continue; end
                while (($time - base) < tt * 10 * rplscale) @(posedge clk_vdp);
                if (d == "W") io(1, 3'(pt), 8'(a), q);
                else begin
                    int ptr; ptr = vdp9968.u_cpu_interface.ff_status_register_pointer;
                    io(0, 3'(pt), 8'h00, q);
                    if (pt == 1 && q !== 8'(a)) begin
                        mis++;
                        if (ptr == 2 && q[0] != a[0]) misce++;
                        if (mis <= 40) $display("RPL t=%0.3f ms S#%0d core %02h oracle %02h", real'(tt) / 1e6, ptr, q, 8'(a));
                    end
                end
                n++;
                if (n % 5000 == 0) $display("RPL %0d events, t=%0.1f ms, CE=%0d", n, real'(tt) / 1e6, vdp9968.u_command.ff_command_execute);
            end
            $display("RPL done: %0d events, %0d status mismatches (%0d on S#2 CE)", n, mis, misce);
            begin longint t0; t0 = $time;
                while (v_int_n && ($time - t0) < 64'd25_000_000_000) @(posedge clk_vdp);
                $display("RPL RESULT: line interrupt %s (screen %0d, FH=%0d, CE=%0d)", v_int_n ? "NEVER came (stuck)" : "came",
                         $signed(`SSG.w_screen_pos_y), vdp9968.u_cpu_interface.ff_line_interrupt, vdp9968.u_command.ff_command_execute);
                $display("RPL int sources: F %0d&IE0 %0d | FH %0d&IE1 %0d | CE-end %0d&IE2 %0d | extregs locked %0d | t=%0.3f ms after the last event",
                         vdp9968.u_cpu_interface.ff_frame_interrupt, vdp9968.u_cpu_interface.ff_frame_interrupt_enable,
                         vdp9968.u_cpu_interface.ff_line_interrupt, vdp9968.u_cpu_interface.ff_line_interrupt_enable,
                         vdp9968.u_cpu_interface.ff_command_end_interrupt, vdp9968.u_cpu_interface.ff_command_end_interrupt_enable,
                         vdp9968.u_cpu_interface.ff_lock_extregs, real'($time - t0) / 1e9);
            end
        end
        //  +ie1=N: ASO 224's first in-game frame (oracle tr_aso.io, 555 ms after R#1=02): the game
        //  sets R#9=00, R#19=68h, R#0=16h with the display OFF (R#1=02, IE0 off) and does NOT poll:
        //  it waits for the line interrupt as a CPU interrupt.  Here int_n is watched (1.5-frame
        //  timeout = "stuck"); the handler then does what the game's does (R#15=1, read S#1,
        //  R#15=0) and re-arms the same line.  +disp=1 is the control with the display on.
        if (ie1 > 0) begin
            logic [7:0] st; int got = 0, stuck = 0, fh0 = 0;
            wreg(3, 8'hDA); wreg(4, 8'h00); wreg(6, 8'h0F); wreg(7, 8'h01); wreg(10, 8'h01); wreg(11, 8'h00);
            wreg(2, 8'h3F); wreg(5, 8'hBF); wreg(8, 8'h28); wreg(23, 8'h00); wreg(25, 8'h02); wreg(26, 8'h00); wreg(27, 8'h00);
            wreg(1, disp ? 8'h42 : 8'h02);
            wreg(9, 8'(ie1r9)); wreg(19, 8'(ie1line)); wreg(0, ie1off ? 8'h06 : 8'h16);   // +ie1off: negative control, IE1 off
            for (int fr = 0; fr < ie1; fr++) begin
                longint t0; t0 = $time;
                while (v_int_n && ($time - t0) < 64'd25_000_000_000) @(posedge clk_vdp);
                if (v_int_n) begin stuck++; $display("IE1 frame %0d: int_n never fell (stuck) FH=%0d screen %0d", fr,
                                                     vdp9968.u_cpu_interface.ff_line_interrupt, $signed(`SSG.w_screen_pos_y)); end
                else begin
                    got++;
                    $display("IE1 frame %0d: int_n low at screen line %0d t=%0t", fr, $signed(`SSG.w_screen_pos_y), $time);
                    repeat (ie1dly) @(posedge clk_vdp);   // IM1 entry -> S#1 read latency (ASO: ~48 us R800, ~87 us openMSX)
                    wreg(15, 8'h01); io(0, 3'd1, 8'h00, st); wreg(15, 8'h00);
                    if (!st[0]) begin fh0++; $display("IE1 frame %0d: handler read S#1=%02h (FH=0)", fr, st); end
                    if (!v_int_n) $display("IE1 frame %0d: int_n still low after the S#1 read", fr);
                    wreg(19, 8'(ie1line)); wreg(0, 8'h16);
                end
            end
            $display("IE1 RESULT: %0d of %0d line interrupts reached int_n, %0d stuck, %0d read FH=0 (line %02h, R#9 %02h, delay %0d clk, display %s)",
                     got, ie1, stuck, fh0, ie1line, ie1r9, ie1dly, disp ? "on" : "off");
        end
        if (aso > 0) begin
            logic [7:0] st; int stuck = 0, fmid = 0;
            wreg(0, 8'h06); wreg(1, 8'h62); wreg(9, 8'h80); wreg(23, 8'h00); wreg(8, 8'h28);
            wreg(19, 8'hDB); wreg(0, 8'h16);
            for (int fr = 0; fr < aso; fr++) begin
                int stage_ok [4];
                for (int k = 0; k < 4; k++) begin
                    int w = 0;
                    wreg(15, 8'h01);
                    begin longint t0; t0 = $time;   // timeout: 1.5 frames of real time
                    do begin io(0, 3'd1, 8'h00, st); w++; repeat (pollpad) @(posedge clk_vdp); end while (!st[0] && ($time - t0) < 64'd25_000_000_000); end
                    wreg(15, 8'h00);
                    if (!st[0]) begin stuck++; $display("ASO frame %0d stage %0d: FH never came (stuck)", fr, k); end
                    else $display("ASO frame %0d stage %0d: FH at screen line %0d (v_count %0d) t=%0t", fr, k, $signed(`SSG.w_screen_pos_y), `SSG.ff_v_count, $time);
                    $display("ASO   handler %0d starts t=%0t", k, $time);
                    case (k)
                    0: begin wreg(19, 8'h68); wreg(23, 8'h18); wreg(0, 8'h16); end
                    1: begin wreg(19, 8'hD2); wreg(9, 8'h80); end
                    2: begin wreg(23, 8'h00); wreg(0, 8'h06); wreg(0, 8'h16); wreg(19, 8'hC6); end
                    3: begin wreg(19, 8'hDB); wreg(9, 8'h00); end
                    endcase
                end
            end
            $display("ASO RESULT: %0d stuck waits, %0d frame interrupts (F) raised (see ASO F lines), %0d stale S#1 reads (pollpad %0d)", stuck, aso_f, stale_fh, pollpad);
        end
        //  +lr_sx=..: SUPER CAT's LRMM (SCREEN5, window x 0..255 y 1024..1791, 256x212 to page 0)
        //  with a given start and vectors.  The window is filled with 33h by HMMV first and the
        //  outside colour is 0Fh, so each destination byte tells inside (33h) / outside (FFh).
        if (lr_sx >= 0) begin
            logic [7:0] st; int n33 = 0, nff = 0, noth = 0;
            io(1, 3'd4, 8'h00, q);
            wreg(0, 8'h06); wreg(1, 8'h00); wreg(9, 8'h80); wreg(20, 8'h1F); wreg(21, 8'h3A); wreg(25, 8'h03);
            //  HMMV y 1024..1791 (768 lines) with 33h, in 3 strips of 256
            for (int k = 0; k < 3; k++) begin
                wreg(36, 8'h00); wreg(37, 8'h00); wreg(38, 8'h00); wreg(39, 8'(4 + k));
                wreg(40, 8'h00); wreg(41, 8'h01); wreg(42, 8'h00); wreg(43, 8'h01);
                wreg(44, 8'h33); wreg(45, 8'h00); wreg(46, 8'hC0); wreg(15, 8'h02);
                do io(0, 3'd1, 8'h00, st); while (st[0]);
            end
            wreg(51, 8'h00); wreg(52, 8'h00); wreg(53, 8'h00); wreg(54, 8'h04); wreg(55, 8'hFF); wreg(56, 8'h00); wreg(57, 8'hFF); wreg(58, 8'h06);
            wreg(47, 8'(lr_vx)); wreg(48, 8'(lr_vx >> 8)); wreg(49, 8'(lr_vy)); wreg(50, 8'(lr_vy >> 8));
            wreg(32, 8'(lr_sx)); wreg(33, 8'(lr_sx >> 8)); wreg(34, 8'(lr_sy)); wreg(35, 8'(lr_sy >> 8));
            wreg(36, 8'h00); wreg(37, 8'h00); wreg(38, 8'h00); wreg(39, 8'h00);
            wreg(40, 8'h00); wreg(41, 8'h01); wreg(42, 8'd212); wreg(43, 8'h00);
            wreg(44, 8'hFF); wreg(45, 8'h00); wreg(46, 8'h30); wreg(15, 8'h02);
            do io(0, 3'd1, 8'h00, st); while (st[0]);
            wreg(15, 8'h00);
            repeat (20000) @(posedge clk_vdp);
            for (int a = 0; a < 212 * 128; a++) begin
                if (!known[a]) noth++;
                else if (shadow[a] == 8'h33) n33++; else if (shadow[a] == 8'hFF) nff++; else noth++;
            end
            $display("LRMM sx=%0d sy=%0d vx=%0d vy=%0d: dest bytes inside(33h) %0d, outside(FFh) %0d, other/unwritten %0d of %0d",
                     lr_sx, lr_sy, lr_vx, lr_vy, n33, nff, noth, 212 * 128);
        end
        //  +wl=K: tb_vdpcmd7's workloads (SCREEN5, display + sprites on, 192 lines), timed in
        //  scanlines (63.556 us) against openMSX 21.0-245: HMMV 722.18, HMMM 1466.82, LMMV 1476.01,
        //  LMMM 1744.90, YMMM 1204.82, LINE x32 897.35, SRCH x32 670.97.  HMMV runs first (fills y=128).
        if (wl >= 0) begin
            int blk [7][15] = '{
                '{0,0, 0,0, 0,0, 128,0, 0,1, 128,0, 238,0, 8'hC0},
                '{0,0, 128,0, 0,0, 0,1, 0,1, 128,0, 0,0, 8'hD0},
                '{0,0, 0,0, 0,0, 128,0, 0,1, 64,0, 14,0, 8'h80},
                '{0,0, 128,0, 0,0, 0,1, 0,1, 64,0, 0,0, 8'h90},
                '{0,0, 128,0, 0,0, 0,1, 0,0, 128,0, 0,0, 8'hE0},
                '{0,0, 0,0, 0,0, 200,0, 255,0, 100,0, 15,0, 8'h70},
                '{0,0, 128,0, 0,0, 0,0, 0,0, 0,0, 10,0, 8'h60}};
            string nm [7] = '{"HMMV", "HMMM", "LMMV", "LMMM", "YMMM", "LINE", "SRCH"};
            real refl [7] = '{722.18, 1466.82, 1476.01, 1744.90, 1204.82, 897.35, 670.97};
            logic [7:0] st; longint tot;
            wreg(9, 8'h00); wreg(8, 8'h08); wreg(1, 8'h60);
            for (int k = 0; k < 7; k++) if (k == 0 || k == wl || wl == 7) begin
                tot = 0;
                for (int r = 0; r < (k >= 5 ? 32 : 1); r++) begin
                    longint t0;
                    for (int i = 0; i < 14; i++) wreg(32 + i, 8'(blk[k][i]));
                    t0 = $time; wreg(46, 8'(blk[k][14]));
                    wreg(15, 8'h02);
                    do io(0, 3'd1, 8'h00, st); while (st[0]);
                    tot += $time - t0;
                    wreg(15, 8'h00);
                end
                $display("WL %s: %0.2f lines (openMSX V9938 %0.2f, ratio %0.3f)", nm[k], real'(tot) / 63556000.0, refl[k], real'(tot) / 63556000.0 / refl[k]);
            end
        end
        //  +cmd=2: LMMM 256x212 copy (reads + writes through the port), +cmd=3: LRMM 256x212
        //  with the identity vector (V9968 extended command: port-4 unlock, window regs).
        //  Completion is polled on S#2 CE with a 100 ms limit; the port's unanswered-read
        //  count during the command is the figure of merit (the link has no backpressure).

        //  +ovs=N: Shaolin's Road V9968 (e809e2a): SCREEN5, R#20=1Fh (HS SVNS ILNS SP3 EPAL), R#21=0
        //  (256 KB), R#25=03h.  Every frame R#9 = 00h (LN=0) at screen line 200 and 80h at 223, so
        //  the active area runs to the end of the frame (+ovsln=0: the control, LN stays 1).  Trial k
        //  turns the display off (R#1=20h) at line (k*37)%262 of a frame, then HMMV x2 and +ovscmd
        //  HMMM 8x8 with random SY/DY up to 2047, the LN writes going on meanwhile; each command must
        //  finish within 50 ms.  The display comes back on (R#1=60h) after the trial.
        if (ovs > 0) begin
            int hung = 0, ncmd = 0, lnw = 0, ovfr = 0; logic [7:0] st; bit need0 = 0, need1 = 0, stop = 0;
            //  the game's per-frame LN writes, raised by a monitor and served by the bus owner below
            fork
                while (!stop) begin
                    @(posedge clk_vdp);
                    if (`SSG.w_h_count_end && `SSG.ff_v_count[0]) begin
                        if (`SSG.w_screen_pos_y == 10'd200) need0 = ovsln;
                        if (`SSG.w_screen_pos_y == 10'd223) need1 = ovsln;
                        if (`SSG.w_screen_pos_y == 10'h3FF) ovfr++;
                    end
                end
            join_none
            io(1, 3'd4, 8'h00, q);                                         // unlock R#20/R#21
            wreg(20, 8'h1F); wreg(21, 8'h00); wreg(25, 8'h03);
            wreg(0, 8'h06); wreg(2, 8'h1F); wreg(5, 8'hFF); wreg(11, 8'h07); wreg(6, 8'h0F); wreg(8, 8'h08);
            wreg(9, 8'h80); wreg(19, 8'h16); wreg(23, 8'h00); wreg(1, 8'h60);
            for (int k = 0; k < ovs; k++) begin
                int offl; offl = (k * 37) % 262;
                wait (`SSG.w_screen_pos_y == 10'h3FF); wait (`SSG.w_screen_pos_y == 10'd1);
                if (offl > 0) wait (`SSG.w_screen_pos_y == 10'(offl < 234 ? offl : 233));
                wreg(1, 8'h20);
                for (int c = 0; c < 2 + ovscmd; c++) begin
                    longint t0; bit busy; int y0, y1;
                    y0 = $urandom_range(0, 2047); y1 = $urandom_range(0, 2047);
                    if (need0) begin need0 = 0; wreg(9, 8'h00); lnw++; end
                    if (need1) begin need1 = 0; wreg(9, 8'h80); lnw++; end
                    if (c < 2) begin
                        wreg(36, 8'h00); wreg(37, 8'h00); wreg(38, 8'(y0)); wreg(39, 8'(y0 >> 8));
                        wreg(40, 8'h00); wreg(41, 8'h01); wreg(42, 8'hD4); wreg(43, 8'h00); wreg(44, 8'h11); wreg(46, 8'hC0);
                    end else begin
                        wreg(32, 8'($urandom_range(0, 31) * 8)); wreg(33, 8'h00); wreg(34, 8'(y0)); wreg(35, 8'(y0 >> 8));
                        wreg(36, 8'($urandom_range(0, 31) * 8)); wreg(37, 8'h00); wreg(38, 8'(y1)); wreg(39, 8'(y1 >> 8));
                        wreg(40, 8'd8); wreg(41, 8'h00); wreg(42, 8'd8); wreg(43, 8'h00); wreg(45, 8'h00); wreg(46, 8'hD0);
                    end
                    ncmd++; t0 = $time; wreg(15, 8'h02);
                    do begin
                        if (need0) begin need0 = 0; wreg(9, 8'h00); lnw++; end
                        if (need1) begin need1 = 0; wreg(9, 8'h80); lnw++; end
                        wreg(15, 8'h02); io(0, 3'd1, 8'h00, st); busy = st[0];
                    end while (busy && ($time - t0) < 64'd50_000_000_000);
                    wreg(15, 8'h00);
                    repeat ($urandom_range(0, 3000)) begin
                        @(posedge clk_vdp);
                        if (need0) begin need0 = 0; wreg(9, 8'h00); lnw++; end
                        if (need1) begin need1 = 0; wreg(9, 8'h80); lnw++; end
                    end
                    if (busy) begin hung++; $display("OVS trial %0d (display off at line %0d) command %0d %s STILL RUNNING", k, offl, c, c < 2 ? "HMMV" : "HMMM"); break; end
                end
                wreg(1, 8'h60);
            end
            stop = 1;
            $display("OVS RESULT: %0d hung of %0d commands in %0d trials, %0d frames, LN writes %0d (ovsln=%0d)", hung, ncmd, ovs, ovfr, lnw, ovsln);
        end
        if (cmd >= 2) begin
            longint t0; int w, noans0, nrd0, nwr0; logic [7:0] st;
            if (cmd == 3 && demo) begin
                //  SUPER CAT / COASTAL FLIGHT's state at its first LRMM (sim/v9968_replay hang)
                io(1, 3'd4, 8'h00, q);
                wreg(1, 8'(r1)); wreg(20, 8'(r20)); wreg(21, 8'(r21));
                wreg(0, 8'h06); wreg(2, 8'h1F); wreg(5, 8'h03); wreg(6, 8'h70); wreg(7, 8'h00); wreg(8, 8'(r8)); wreg(9, 8'h80);
                wreg(11, 8'h02); wreg(18, 8'h00); wreg(19, 8'h00); wreg(23, 8'h00); wreg(25, 8'(r25)); wreg(26, 8'h00); wreg(27, 8'h00);
                wreg(51, 8'h00); wreg(52, 8'h00); wreg(53, 8'h00); wreg(54, 8'h04); wreg(55, 8'hFF); wreg(56, 8'h00); wreg(57, 8'hFF); wreg(58, 8'h06);
                wreg(47, 8'h00); wreg(48, 8'h00); wreg(49, 8'h40); wreg(50, 8'h00);   // vx 0, vy 0.25: 90 deg, zoom 4
                wreg(32, 8'h9A); wreg(33, 8'h00); wreg(34, 8'h64); wreg(35, 8'h06);   // SX 9Ah, SY 664h
            end else if (cmd == 3) begin
                io(1, 3'd4, 8'h00, q);                    // unlock the extended registers
                wreg(20, 8'((hs ? 8'h01 : 8'h00) | (sp3 ? 8'h08 : 8'h00))); wreg(21, 8'h00);
                wreg(47, 8'h00); wreg(48, 8'h01); wreg(49, 8'h00); wreg(50, 8'h00);   // vx = 1.0, vy = 0
                wreg(51, 8'h00); wreg(52, 8'h00); wreg(53, 8'h00); wreg(54, 8'h01);   // window x 0.., y 256..
                wreg(55, 8'hFF); wreg(56, 8'h00); wreg(57, 8'hFF); wreg(58, 8'h01);   // ..255, ..511
            end
            if (!demo) begin wreg(32, 8'h00); wreg(33, 8'h00); wreg(34, 8'h00); wreg(35, 8'h01); end   // SX 0, SY 256
            if (cmd == 4) begin
                //  Go Figure's boot calibration (rtl/video/VDP/sim/tb_vdpcmd.vhd): SCREEN5 192 lines,
                //  display + sprites on, HMMM SX 20,SY 256 -> DX 30,DY 0, NX 28, NY 220 (3080 bytes).
                //  V9938 reference 251.5 lines; the game needs CE still set at its line-188 check
                //  (hardware boundary: a 255.8-line HMMM fails, 259.5 passes).
                wreg(9, 8'h00);
                wreg(32, 8'd20); wreg(33, 8'h00); wreg(34, 8'h00); wreg(35, 8'h01);
                wreg(36, 8'd30); wreg(37, 8'h00); wreg(38, 8'h00); wreg(39, 8'h00);
                wreg(40, 8'd28); wreg(41, 8'h00); wreg(42, 8'd220); wreg(43, 8'h00);
                wreg(44, 8'h00); wreg(45, 8'h00);
            end else begin
            wreg(36, 8'h00); wreg(37, 8'h00); wreg(38, 8'h00); wreg(39, 8'h00);       // DX 0, DY 0
            wreg(40, 8'h00); wreg(41, 8'h01); wreg(42, 8'hD4); wreg(43, 8'h00);       // NX 256, NY 212
            wreg(44, 8'h00); wreg(45, 8'h00);
            end
            if (ct55) begin
                wreg(14, 8'h03); io(1, 3'd1, 8'h00, q); io(1, 3'd1, 8'h7E, q);          // 0FE00h
                for (int i = 0; i < 512; i++) io(1, 3'd0, 8'h55, q);
                wreg(14, 8'h04); io(1, 3'd1, 8'h00, q); io(1, 3'd1, 8'h40, q);          // 10000h
                for (int i = 0; i < 128; i++) io(1, 3'd0, 8'h00, q);
            end
            if (offat >= 0) begin
                //  the display on with sprites running, then off at a chosen moment of the plane
                //  selector's 128-clock cycle: the write's second byte (81h) is what lands
                wreg(1, 8'h40);
                repeat (20 * 85909) @(posedge clk_vdp);
                io(1, 3'd1, 8'h00, q);                                     // R#1 value byte
                @(negedge clk_vdp); wait (vdp9968.u_timing_control.u_sprite.u_select_visible_planes.w_phase == 3'd2 && vdp9968.u_timing_control.u_sprite.u_select_visible_planes.w_sub_phase == 4'd0); @(posedge clk_vdp);
                repeat (offat) @(posedge clk_vdp);
                bus_ioreq = 1; bus_address = 3'd1; bus_write = 1; bus_wdata = 8'h81; bus_valid = 1;   // the register byte, raw
                @(posedge clk_vdp); while (!bus_ready) @(posedge clk_vdp);
                @(negedge clk_vdp); bus_valid = 0; repeat (2) @(posedge clk_vdp); @(negedge clk_vdp); bus_ioreq = 0; repeat (40) @(posedge clk_vdp);
                $display("OFFAT %0d: after display off the selector's ff_vram_valid = %0d (display_on %0d)", offat, vdp9968.u_timing_control.u_sprite.u_select_visible_planes.ff_vram_valid, vdp9968.reg_display_on);
            end
            if (satpre && satf != "") begin
                int f, v;
                f = $fopen(satf, "r");
                wreg(14, 8'h04); io(1, 3'd1, 8'h00, q); io(1, 3'd1, 8'h40, q);
                while ($fscanf(f, "%h", v) == 1) io(1, 3'd0, 8'(v), q);
                $fclose(f); satf = "";
            end
            noans0 = noans; nrd0 = nrd; nwr0 = nwr; t0 = $time;
            wreg(46, cmd == 3 ? 8'h30 : cmd == 4 ? 8'hD0 : 8'h90);                    // LRMM / HMMM / LMMM, IMP
            wreg(15, 8'h02);
            w = 0;
            do begin repeat (256) @(posedge clk_vdp); w += 256; io(0, 3'd1, 8'h00, st); end while (st[0] && w < 8600000);
            $display("CMD %s hs=%0d demo=%0d offat=%0d r1=%02h r20=%02h r21=%02h r25=%02h r8=%02h: %s after %0.3f ms = %0.1f lines; port reads %0d (not answered %0d), writes %0d; link dropped %0d off-grid %0d",
                     cmd == 3 ? "LRMM" : cmd == 4 ? "HMMM-GoFigure" : "LMMM", hs, demo, offat, r1, r20, r21, r25, r8, st[0] ? "STILL RUNNING" : "done", real'($time - t0) / 1e9, real'($time - t0) / 1e9 / 0.063556,
                     nrd - nrd0, noans - noans0, nwr - nwr0, mon_drop, mon_mis);
            $display(st[0] ? "CMD RESULT FAIL (did not finish)" : (noans - noans0 == 0 ? "CMD RESULT PASS" : "CMD RESULT FAIL (reads dropped)"));
            wreg(15, 8'h00);
            //  +sat=<hex bytes>: SUPER CAT's first sprite attribute upload, then the display on
            //  (R#1=40h, sprites on) for satms ms: does the SP3 sprite fetch get served by the link?
            if (satf != "") begin
                int f, v, n = 0, nrd1, noans1, drop1;
                f = $fopen(satf, "r");
                wreg(14, 8'h04); io(1, 3'd1, 8'h00, q); io(1, 3'd1, 8'h40, q);
                while ($fscanf(f, "%h", v) == 1) begin io(1, 3'd0, 8'(v), q); n++; end
                $fclose(f);
                wreg(1, 8'h40);
                nrd1 = nrd; noans1 = noans; drop1 = mon_drop;
                repeat (satms * 85909) @(posedge clk_vdp);
                $display("SAT test: %0d bytes at 10000h, display on %0d ms: port reads %0d, not answered %0d, link dropped %0d, off-grid %0d",
                         n, satms, nrd - nrd1, noans - noans1, mon_drop - drop1, mon_mis);
                $display(noans - noans1 == 0 ? "SAT RESULT PASS" : "SAT RESULT FAIL (sprite reads dropped)");
            end
        end
        for (int t = 0; t < ms; t += 2) begin
            if (cmd) begin
                wreg(36, 8'h00); wreg(37, 8'h00); wreg(38, 8'h00); wreg(39, 8'h00);
                wreg(40, 8'h00); wreg(41, scr == 7 ? 8'h02 : 8'h01); wreg(42, 8'hD4); wreg(43, 8'h00);
                wreg(44, 8'h5A); wreg(45, 8'h00); wreg(46, 8'hC0);
            end
            repeat (2 * 85909) @(posedge clk_vdp);
        end
        $display("  V slot use from the display on: %0d frames, %0d idle (%0.1f%%), longest busy run %0d frames",
                 fr_n, fr_idle, 100.0 * fr_idle / (fr_n > 0 ? fr_n : 1), run_max);
        $display("  busy-run lengths 0:%0d 1:%0d 2:%0d 3:%0d 4-7:%0d 8-15:%0d 16-31:%0d 32-63:%0d 64-127:%0d 128+:%0d",
                 run_hist[0], run_hist[1], run_hist[2], run_hist[3], run_hist[4], run_hist[5], run_hist[6], run_hist[7], run_hist[8], run_hist[9]);
        $display("  7.8125 us windows (84 frames): %0d, fewest idle frames in one %0d, windows with none %0d", win_n, win_min, win0);
        $display("V9968 VRAM  RELEASE_PH=%0d m128=%0d", RELEASE_PH, m128);
        $display("  port: reads %0d, writes %0d, bytes compared %0d", nrd, nwr, nbyte_cmp);
        $write  ("  latency (clk_vdp, request -> rdata_en):");
        for (int d = 0; d < 32; d++) if (lat_hist[d] != 0) $write(" %0d:%0d", d, lat_hist[d]);
        $display("");
        $display("  bad latency %0d, bad data %0d, reads not answered %0d, spurious %0d", bad_lat, bad_data, noans, bad_order);
        $display("  link: dropped (refresh) %0d, off-grid %0d", mon_drop, mon_mis);
        $display("  cpu read-back: %0d of %0d wrong", cpu_bad, cpu_n);
        for (int pp = 0; pp < 4; pp++)
            if (acc_n[pp] != 0) $display("  cpu bus port %0d: %0d accesses, accept <= %0d clk_vdp, %0d reads, read data <= %0d clk_vdp after accept",
                                          pp, acc_n[pp], acc_max[pp], rd_n[pp], rd_max[pp]);
        $write("  cpu read data latency histogram (8-clock bins):");
        for (int b = 0; b < 16; b++) if (rd_hist[b]) $write(" %0d-%0d:%0d", b*8, b*8+7, rd_hist[b]);
        $display("");
        $display("  chip: errors=%0d REFRESH=%0d", chip2.errs, chip2.nref);
`ifdef TDM_SIM_NO_VCHIP_REFRESH
        $display("  (TDM_SIM_NO_VCHIP_REFRESH: chip errors are the VRAM chip's missing refresh, not judged)");
`endif
        if (nrd > 1000 && nbyte_cmp > 1000 && bad_lat == 0 && bad_data == 0 && noans <= mon_drop && bad_order == 0
            && mon_mis == 0 && cpu_bad == 0 && cpu_n == nbytes
`ifndef TDM_SIM_NO_VCHIP_REFRESH
            && chip2.errs == 0
`endif
            )
            $display("V9968 VRAM RESULT PASS (dropped %0d: refresh, plan S3)", mon_drop);
        else
            $display("V9968 VRAM RESULT FAIL");
        $finish;
    end
endmodule
