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
        .v_go(v_go), .tdm_ph(tdm_ph), .cpu_paced(1'b1),
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
    vdp vdp9968 (
        .reset_n(vdp_reset_n), .clk(clk_vdp), .initial_busy(1'b0),
        .bus_address(bus_address), .bus_ioreq(bus_ioreq), .bus_write(bus_write), .bus_valid(bus_valid),
        .bus_ready(bus_ready), .bus_wdata(bus_wdata), .bus_rdata(bus_rdata), .bus_rdata_en(bus_rdata_en),
        .int_n(),
        .vram_address(vram_address), .vram_write(vram_write), .vram_valid(vram_valid),
        .vram_wdata(vram_wdata), .vram_wdata_mask(vram_wdata_mask),
        .vram_rdata(vram_rdata), .vram_rdata_en(vram_rdata_en), .vram_refresh(),
        .display_hs(), .display_vs(), .display_en(), .display_r(), .display_g(), .display_b(),
        .force_highspeed(hs != 0),
        .ext_cmd_wr(1'b0), .ext_cmd_num(6'd0), .ext_cmd_data(8'd0), .ext_cmd_ce(),
        .button(2'b00),
        .pulse0(), .pulse1(), .pulse2(), .pulse3(), .pulse4(), .pulse5(), .pulse6(), .pulse7());

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
    task automatic io(input logic wr, input logic [2:0] port, input logic [7:0] d, output logic [7:0] q);
        @(negedge clk_vdp);
        bus_ioreq = 1; bus_address = port; bus_write = wr; bus_wdata = d; bus_valid = 1;
        begin
            int w = 0;
            do begin @(posedge clk_vdp); w++; end while (!bus_ready && w < 20000);
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
