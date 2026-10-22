`timescale 1ps/1ps
//  V9968 replay bench (2026-10-22): the openMSX-V9968 quasi-oracle's VDP I/O trace
//  (~/data/v9968_oracle/iotrace.tcl: "t_ns W|R port value") replayed into the real
//  V9968 (rtl/video/v9968) on sdram_tdm's V slot, as in sim/v9968_vram.
//
//  Replay rules (no time pacing: the trace's own waits are re-created, not its clock):
//    W  : the write, as soon as the V9968 takes it (bus_ready)
//    R 98 : the read is done; the byte is compared with the oracle's (vram_rd_bad)
//    R 99 : the status read is done; if the oracle's value differs in the bits a
//           program polls on (S#0 F, S#2 CE/VR/HR: mask 0xC1 on bits 7,6,0) the read is
//           repeated until the V9968 shows the same bits, or SYNC_TO clk_vdp pass
//           (sync_miss counted).  This keeps "after VBLANK" / "after the command" exact.
//    R 9A-9C : done, value not judged.
//  Frame dumps: +dump=K1,K2,...: after the K-th write to R#2 (the page flip) the next
//  complete frame's native pixels (before the upscan, indexed by screen_pos_x/y) go to
//  <out>/frame_K.ppm (320x240: x -32..287, y -14..225).  cmp.py aligns and compares
//  them with the oracle's screenshot taken after the same flip count.
module altddio_out #(parameter extend_oe_disable = "OFF", intended_device_family = "",
    invert_output = "OFF", lpm_hint = "", lpm_type = "", oe_reg = "", power_up_high = "OFF",
    parameter int width = 1)
  (input [width-1:0] datain_h, datain_l, input outclock, output [width-1:0] dataout,
   input aclr, aset, oe, outclocken, sclr, sset);
    assign dataout = outclock ? datain_h : datain_l;
endmodule

module tb #(parameter int RELEASE_PH = 5);
    logic clk_sdram = 0, clk_vdp = 0;
    always #3880 clk_sdram = ~clk_sdram;
    always #5820 clk_vdp   = ~clk_vdp;

    string trace = "", out = "/tmp/v9968_replay", dumps = "";
    int m128 = 1, sync_to = 1500000;             // ~2 frames of clk_vdp (1.43 M per frame)
    int pace = 1, gen_poll = 1;   // gen_poll: wait for the bits the oracle saw change at a poll loop's exit                                // 1: replay each event no earlier than its trace time (gaps > 1 ms
                                                 //    before the port-4 unlock are cut to 1 ms: the BIOS boot is idle)
    initial begin
        void'($value$plusargs("trace=%s", trace));
        void'($value$plusargs("out=%s", out));
        void'($value$plusargs("dump=%s", dumps));
        void'($value$plusargs("m128=%d", m128));
        void'($value$plusargs("sync_to=%d", sync_to)); void'($value$plusargs("pace=%d", pace)); void'($value$plusargs("genpoll=%d", gen_poll));
    end

    //  ── SDRAM controller + model (as sim/v9968_vram) ──────────────────────
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
    sdram_chk #(.NCHIP(2), .COLS(1024)) chip2 (
        .clk(SCLK), .dq(DQ), .a(A), .ba(BA), .ncs(nCS),
        .nras(nRAS), .ncas(nCAS), .nwe(nWE), .fpga_oe(dut.dq_oe_o));

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
    wire d_hs, d_en; wire [7:0] d_r, d_g, d_b;
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
    vdp vdp9968 (
        .reset_n(vdp_reset_n), .clk(clk_vdp), .initial_busy(1'b0),
        .bus_address(bus_address), .bus_ioreq(bus_ioreq), .bus_write(bus_write), .bus_valid(bus_valid),
        .bus_ready(bus_ready), .bus_wdata(bus_wdata), .bus_rdata(bus_rdata), .bus_rdata_en(bus_rdata_en),
        .int_n(),
        .vram_address(vram_address), .vram_write(vram_write), .vram_valid(vram_valid),
        .vram_wdata(vram_wdata), .vram_wdata_mask(vram_wdata_mask),
        .vram_rdata(vram_rdata), .vram_rdata_en(vram_rdata_en), .vram_refresh(),
        .display_hs(d_hs), .display_vs(), .display_en(d_en), .display_r(d_r), .display_g(d_g), .display_b(d_b),
        .force_highspeed(1'b0),
        .ext_cmd_wr(1'b0), .ext_cmd_num(6'd0), .ext_cmd_data(8'd0), .ext_cmd_ce(),
        .scanline_level(2'd0), .cmd_wait(cmdw),
        .button(2'b00),
        .pulse0(), .pulse1(), .pulse2(), .pulse3(), .pulse4(), .pulse5(), .pulse6(), .pulse7());

    //  ── VRAM port latency check (ip_sdram's contract, as sim/v9968_vram) ──
    longint kv = 0; longint q_k[$]; int bad_lat = 0, noans = 0, nrd = 0;
    always @(posedge clk_vdp) begin
        kv++;
        if (vdp_reset_n) begin
            while (q_k.size() != 0 && kv - q_k[0] > 8 && !(vram_rdata_en && kv - q_k[0] == 8)) begin
                void'(q_k.pop_front()); noans++;
            end
            if (vram_rdata_en && q_k.size() != 0) begin
                if (kv - q_k[0] != 8) bad_lat++;
                void'(q_k.pop_front());
            end
            if (vram_valid && !vram_write) begin nrd++; q_k.push_back(kv); end
        end
    end

    //  ── command engine monitor: CE edges with the time (first 60) ───────
    wire ce_w = vdp9968.w_status_command_execute;
    logic ce_q = 0; longint ce_t0 = 0; int ce_n = 0, ce_rd0 = 0, ce_wr0 = 0, nwr = 0;
    always @(posedge clk_vdp) if (vdp_reset_n && vram_valid && vram_write) nwr++;
    //  who asks for the port: valid pulses per source inside the VRAM interface
    int src_scr = 0, src_spr = 0, src_cmd = 0, src_cpu = 0, src_port = 0;
    always @(posedge clk_vdp) if (vdp_reset_n) begin
        if (vdp9968.u_vram_interface.screen_mode_vram_valid) src_scr++;
        if (vdp9968.u_vram_interface.sprite_vram_valid)      src_spr++;
        if (vdp9968.u_vram_interface.command_vram_valid)     src_cmd++;
        if (vdp9968.u_vram_interface.cpu_vram_valid)         src_cpu++;
        if (vram_valid)                          src_port++;
    end
    int s_scr0 = 0, s_spr0 = 0, s_cmd0 = 0, s_cpu0 = 0, s_port0 = 0, noans0 = 0;
    //  the first port requests after a command starts: address and who (sprite/screen/cmd)
    int req_log = 0; bit req_arm = 0;
    //  armed by the first unanswered read instead (the flood's onset), not the command start
    int noans_q = 0;
    always @(posedge clk_vdp) begin
        if (ce_w && noans != noans_q && !req_arm2) begin req_arm2 = 1; req_log = 0; $display("  first unanswered read at t+%0d clk of the command", ($time - ce_t0) / 11640); end
        noans_q = noans;
    end
    bit req_arm2 = 0;
    always @(posedge clk_vdp) if (req_arm2 && vram_valid && req_log < 40) begin
        req_log++;
        $display("  req %0d t+%0d clk: %s %05h  spr %0d scr %0d cmd %0d", req_log, ($time - ce_t0) / 11640, vram_write ? "W" : "R", {vram_address, 2'b00},
                 vdp9968.u_vram_interface.sprite_vram_valid, vdp9968.u_vram_interface.screen_mode_vram_valid, vdp9968.u_vram_interface.command_vram_valid);
    end
    always @(posedge clk_vdp) begin
        ce_q <= ce_w;
        if (ce_w && !ce_q) begin ce_t0 = $time; ce_rd0 = nrd; ce_wr0 = nwr; s_scr0 = src_scr; s_spr0 = src_spr; s_cmd0 = src_cmd; s_cpu0 = src_cpu; s_port0 = src_port; noans0 = noans; end
        if (!ce_w && ce_q) begin
            ce_n++;
            if (ce_n <= 60) $display("REPLAY command #%0d ran %0.3f ms: %0d VRAM reads, %0d writes (CE fall t=%0t, after %0d flips)",
                                     ce_n, real'($time - ce_t0) / 1e9, nrd - ce_rd0, nwr - ce_wr0, $time, flips);
        end
    end

    //  ── grid phase: link.ph at requests the V slot granted vs. all requests ───
    int ph_req [8], ph_grant [8]; logic [2:0] ph_q [0:3];
    always @(posedge clk_vdp) if (vdp_reset_n && vram_valid) ph_req[link.ph]++;
    always @(posedge clk_sdram) if (v_grant) ph_grant[link.ph]++;     // granted: the boundary edge after the request's edge
    final begin
        $write("GRID link.ph at requests:"); for (int i = 0; i < 8; i++) $write(" %0d:%0d", i, ph_req[i]); $display("");
        $write("GRID link.ph at grants  :"); for (int i = 0; i < 8; i++) $write(" %0d:%0d", i, ph_grant[i]); $display("");
    end

    //  ── CPU bus ───────────────────────────────────────────────────────────
    int hung = 0, slow_max = 0, slow_port = 0, slow_wr = 0;
    task automatic io(input logic wr, input logic [2:0] port, input logic [7:0] d, output logic [7:0] q);
        int w;
        @(negedge clk_vdp);
        bus_ioreq = 1; bus_address = port; bus_write = wr; bus_wdata = d; bus_valid = 1;
        w = 0;
        do begin @(posedge clk_vdp); w++; end while (!bus_ready && w < 8600000);
        if (w > slow_max) begin slow_max = w; slow_port = port; slow_wr = wr; end
        if (!bus_ready) begin
            $display("TB ERR t=%0t bus_ready stuck low 8600000 clk_vdp (100 ms) on %s port %0d data %02h (event %0d, flips %0d, CE %0d for %0.3f ms, %0d commands done)",
                     $time, wr ? "write" : "read", port, d, n_ev, flips, ce_w, ce_w ? real'($time - ce_t0) / 1e9 : 0.0, ce_n); hung = 1;
            $display("  command engine: state %0d cmd %0d ecom %0d hs %0d  nx %0d ny %0d dx %0d dy %0d sx %0d sy %0d  vx %04h vy %04h  window x %0d..%0d y %0d..%0d  cache_valid %0d  SAT base %05h SPT base %05h sprite_disable %0d sp3 %0d display_on %0d",
                     vdp9968.u_command.ff_state, vdp9968.u_command.ff_command, vdp9968.u_command.reg_ext_command_mode, vdp9968.u_command.reg_command_high_speed_mode,
                     vdp9968.u_command.ff_nx, vdp9968.u_command.ff_ny, vdp9968.u_command.ff_dx, vdp9968.u_command.ff_dy,
                     vdp9968.u_command.ff_sx, vdp9968.u_command.ff_sy, vdp9968.u_command.reg_vx, vdp9968.u_command.reg_vy,
                     vdp9968.u_command.reg_wsx, vdp9968.u_command.reg_wex, vdp9968.u_command.reg_wsy, vdp9968.u_command.reg_wey, vdp9968.u_command.ff_cache_vram_valid,
                     vdp9968.reg_sprite_attribute_table_base, vdp9968.reg_sprite_pattern_generator_table_base, vdp9968.reg_sprite_disable, vdp9968.reg_sprite_mode3, vdp9968.reg_display_on);
            $display("  sprite plane selector: ff_vram_valid %0d plane_count %0d (display_on %0d): a request level held while the display is off starves the command (vdp_vram_interface issue priority)",
                     vdp9968.u_timing_control.u_sprite.u_select_visible_planes.ff_vram_valid, vdp9968.u_timing_control.u_sprite.u_select_visible_planes.ff_plane_count, vdp9968.reg_display_on);
            $display("  during this command: %0d VRAM reads, %0d writes; port reads not answered %0d (total %0d), bad latency %0d", nrd - ce_rd0, nwr - ce_wr0, noans - noans0, noans, bad_lat);
            $display("  request pulses during it: screen %0d sprite %0d command %0d cpu %0d -> port valid cycles %0d (clk_vdp elapsed %0d)",
                     src_scr - s_scr0, src_spr - s_spr0, src_cmd - s_cmd0, src_cpu - s_cpu0, src_port - s_port0, ($time - ce_t0) / 11640);
            $display("V9968 REPLAY RESULT FAIL (hung)"); $finish;
        end
        @(negedge clk_vdp); bus_valid = 0;
        q = 8'hxx;
        if (!wr) begin
            w = 0;
            do begin @(posedge clk_vdp); w++; end while (!bus_rdata_en && w < 20000);
            q = bus_rdata;
        end
        repeat (2) @(posedge clk_vdp);
        @(negedge clk_vdp); bus_ioreq = 0;
        repeat (6) @(posedge clk_vdp);          // ~0.1 us between accesses (R800 OUT pairs are ~0.5 us)
    endtask

    //  ── frame dump: native pixels indexed by screen position ─────────────
    //  (vdp9968.w_vdp_* lag w_screen_pos_x by a fixed few pixels; cmp.py aligns)
    logic [7:0] fr [0:239][0:319][0:2];
    logic [7:0] fo [0:479][0:799][0:2];
    int   dump_list[$]; int want_flip = -1; bit dumping = 0, armed = 0; int frames_seen = 0;
    int   flips = 0, dumped = 0;
    function automatic void parse_dumps();
        int v = 0; bit any = 0;
        foreach (dumps[i]) begin
            if (dumps[i] >= "0" && dumps[i] <= "9") begin v = v * 10 + (dumps[i] - "0"); any = 1; end
            else if (any) begin dump_list.push_back(v); v = 0; any = 0; end
        end
        if (any) dump_list.push_back(v);
    endfunction
    wire signed [13:0] spx = vdp9968.w_screen_pos_x;
    wire signed [9:0]  spy = vdp9968.w_screen_pos_y;
    wire        [9:0]  vc  = vdp9968.w_v_count;
    logic [9:0] vc_q = 0;
    always @(posedge clk_vdp) begin
        vc_q <= vc;
        if (vc == 10'd0 && vc_q != 10'd0) begin          // a frame starts
            if (dumping) begin
                int f; string fn;
                fn = $sformatf("%s/frame_%0d.ppm", out, want_flip);
                f = $fopen(fn, "w");
                $fwrite(f, "P6\n320 240\n255\n");
                for (int y = 0; y < 240; y++) for (int x = 0; x < 320; x++)
                    $fwrite(f, "%c%c%c", fr[y][x][0], fr[y][x][1], fr[y][x][2]);
                $fclose(f);
                $display("REPLAY dump after flip %0d -> %s (t=%0t)  R#0 mode %0d display_on %0d 212 %0d name_base %05h backdrop %02h voff %0d",
                         want_flip, fn, $time, vdp9968.reg_screen_mode, vdp9968.reg_display_on, vdp9968.reg_212lines_mode,
                         {vdp9968.reg_pattern_name_table_base, 10'd0}, vdp9968.reg_backdrop_color, vdp9968.reg_vertical_offset);
                //  the same frame as the 800x480 output (after upscan / video_out)
                fn = $sformatf("%s/frame_%0d_out.ppm", out, want_flip);
                f = $fopen(fn, "w");
                $fwrite(f, "P6\n800 480\n255\n");
                for (int y = 0; y < 480; y++) for (int x = 0; x < 800; x++)
                    $fwrite(f, "%c%c%c", fo[y][x][0], fo[y][x][1], fo[y][x][2]);
                $fclose(f);
                dumping = 0; dumped++;
                if (dump_list.size() != 0) want_flip = dump_list.pop_front(); else want_flip = -1;
            end else if (armed) begin dumping = 1; armed = 0; end
        end
        if (dumping && d_en) begin
            int x, y;
            x = (int'(vdp9968.w_h_count) - 748) >> 1; y = int'(vdp9968.w_v_count) - 14;
            if (x >= 0 && x < 800 && y >= 0 && y < 480) begin fo[y][x][0] = d_r; fo[y][x][1] = d_g; fo[y][x][2] = d_b; end
        end
        if (dumping && spx[3:0] == 4'hF) begin
            int x, y;
            x = int'(spx[13:4]) + 32; y = int'(spy) + 14;
            if (x >= 0 && x < 320 && y >= 0 && y < 240) begin
                fr[y][x][0] = vdp9968.w_vdp_r; fr[y][x][1] = vdp9968.w_vdp_g; fr[y][x][2] = vdp9968.w_vdp_b;
            end
        end
    end

    //  ── VRAM shadow: every byte written through the V9968's VRAM port (CPU and commands);
    //  +vdump=K1,K2: at the K-th R#2 write dump 00000-1FFFF to <out>/vram_K.bin, the same
    //  moment as the oracle's flipvram.tcl (byte compare, palette- and render-independent)
    logic [7:0] vsh [0:262143];
    initial for (int i = 0; i < 262144; i++) vsh[i] = 8'h00;
    always @(posedge clk_vdp) if (vdp_reset_n && vram_valid && vram_write)
        for (int b = 0; b < 4; b++) if (!vram_wdata_mask[b]) vsh[{vram_address, 2'b00} + b] = vram_wdata[b*8 +: 8];
    string vdumps = ""; int vd_list[$];
    initial begin
        void'($value$plusargs("vdump=%s", vdumps));
        begin int v = 0; bit any = 0; foreach (vdumps[i]) begin
            if (vdumps[i] >= "0" && vdumps[i] <= "9") begin v = v * 10 + (vdumps[i] - "0"); any = 1; end
            else if (any) begin vd_list.push_back(v); v = 0; any = 0; end end
          if (any) vd_list.push_back(v); end
    end
    task automatic vram_dump(input int k);
        int f; f = $fopen($sformatf("%s/vram_%0d.bin", out, k), "wb");
        for (int i = 0; i < 262144; i++) $fwrite(f, "%c", vsh[i]);   // 256 KB: the LRMM source atlas is at 20000h-3FFFFh
        $fclose(f);
        $display("REPLAY vram dump at flip %0d (t=%0t)", k, $time);
    endtask

    //  ── the replay ────────────────────────────────────────────────────────
    int n_ev = 0, n_w = 0, n_r98 = 0, n_r99 = 0, rd_bad = 0, sync_miss = 0, sync_wait = 0, vr_fresh = 0;
    logic [7:0] last_99_w = 8'h00; bit second_byte = 0;     // R#2 detection: value then 82h
    int   run_len = 0; logic [7:0] run_first = 8'h00; bit run_ce = 0; logic [3:0] sreg = 4'd0;   // poll runs
    logic [7:0] run_ov_prev = 8'h00, run_ov_last = 8'h00; bit run_ov_ok = 0;                   // oracle peeks of the run
    longint t_prev = -1, t_skip = 0, t_sim0 = 0; bit unlocked = 0;                                // pacing
    initial begin
        int f, rc; longint t; string rw; int port, val; logic [7:0] q;
        parse_dumps();
        if (dump_list.size() != 0) want_flip = dump_list.pop_front();
        repeat (20) @(posedge clk_sdram);
        init = 0;
        wait (dut.run);
        wait (vdp_reset_n); $display("TB t=%0t V9968 out of reset", $time);
        repeat (2000) @(posedge clk_vdp);
        f = $fopen(trace, "r");
        begin   // the first event's trace time maps to now
            int rc0; longint t0; string rw0; int p0, v0;
            rc0 = $fscanf(f, "%d %s %h %h\n", t0, rw0, p0, v0); $rewind(f);
            t_skip = t0; t_sim0 = $time;
        end
        if (f == 0) begin $display("V9968 REPLAY RESULT FAIL (no trace %s)", trace); $finish; end
        while (!$feof(f)) begin
            rc = $fscanf(f, "%d %s %h %h\n", t, rw, port, val);
            if (rc < 3) continue;
            n_ev++;
            port = port & 8'hFF;
            if (port < 8'h98 || port > 8'h9C) continue;
            if (pace) begin
                //  trace time -> sim time: sim = t - t_skip; idle gaps before the unlock are skipped
                longint due;
                if (t_prev >= 0 && !unlocked && t - t_prev > 1000000) t_skip += (t - t_prev) - 1000000;
                t_prev = t;
                due = (t - t_skip) * 1000 + t_sim0;        // ps
                if (due > $time) #(due - $time);
                if (rw == "W" && port == 8'h9C) unlocked = 1;
            end
            //  (before this event) end of a poll run: a run of >= 2 reads is a wait loop that exited on its last
            //  read -- re-create the exit condition in the RTL: polled CE (any hint CE=1,
            //  or the RTL saw CE=1) -> until CE=0; else S#2 VR -> until VR=1; S#0 -> F=1.
            if (!(rw == "R" && port == 8'h99) && run_len != 0) begin
                begin
                    int w = 0; bit ok = 0;
                    io(0, 3'd1, 8'h00, q);
                    //  a VR loop that iterated started outside VBLANK: in the RTL it must
                    //  see a fresh VBLANK too (the oracle's CPU work between frames took
                    //  time; the replay's writes take none), so leave a VBLANK first.
                    //  A run of 1 (the oracle was already in VBLANK: its command ended
                    //  there) still waits for VBLANK here -- the RTL's command may end
                    //  earlier in the frame.
                    if (run_len >= 2 && sreg != 4'd0 && !(run_ce || run_first[0]) && q[6]) begin
                        while (q[6] && w < sync_to) begin repeat (32) @(posedge clk_vdp); w += 32; io(0, 3'd1, 8'h00, q); end
                        vr_fresh++;
                    end
                    while (!ok && w < sync_to) begin
                        //  a run of >= 2 whose oracle peeks changed at the end: wait for the
                        //  changed bits (any status register: FH, HR, VR, CE, TR, F ...)
                        if (gen_poll && run_len >= 2 && run_ov_ok && (run_ov_last ^ run_ov_prev) != 8'h00)
                            ok = ((q ^ run_ov_last) & (run_ov_last ^ run_ov_prev)) == 8'h00;
                        else if (sreg == 4'd0)         ok = q[7];                 // F
                        else if (sreg == 4'd1)         ok = 1'b1;                 // S#1 single read: no wait
                        else if (run_ce || run_first[0]) ok = !q[0];             // CE
                        else                           ok = q[6];                 // VR
                        if (!ok) begin repeat (32) @(posedge clk_vdp); w += 32; io(0, 3'd1, 8'h00, q); end
                    end
                    if (w > 0) sync_wait++;
                    if (!ok) begin
                        sync_miss++;
                        if (sync_miss <= 5) $display("REPLAY poll run not satisfied: sreg %0d run %0d first %02h last %02h (event %0d, after %0d flips)", sreg, run_len, run_first, q, n_ev, flips);
                    end
                end
                run_len = 0; run_ce = 0;
            end
            if (rw == "W") begin
                n_w++;
                io(1, 3'(port - 8'h98), 8'(val), q);
                if (port == 8'h99) begin
                    if (second_byte) begin
                        if (val[7:6] == 2'b10 && val[5:0] == 6'd2) begin   // R#2
                            flips++;
                            if (flips == want_flip) armed = 1;
                            foreach (vd_list[j]) if (vd_list[j] == flips) vram_dump(flips);
                        end
                        second_byte = 0;
                    end else begin last_99_w = 8'(val); second_byte = 1; end
                end
            end else begin
                if (port == 8'h98) begin
                    n_r98++;
                    io(0, 3'd0, 8'h00, q);
                    if (rc >= 4 && q !== 8'(val)) begin
                        rd_bad++;
                        if (rd_bad <= 5) $display("REPLAY vram read #%0d: rtl %02h oracle %02h (event %0d)", n_r98, q, val, n_ev);
                    end
                end else if (port == 8'h99) begin
                    //  A status poll.  The oracle's logged value is a peek taken at the
                    //  scheduler's time, which lags the CPU by up to a line or so, so it is
                    //  only a hint of WHAT was polled, not of the exit value.  The loop is
                    //  replayed as a run (see end_run below).
                    n_r99++;
                    io(0, 3'd1, 8'h00, q);
                    if (run_len == 0) begin run_first = q; run_ov_ok = 0; end
                    if (rc >= 4) begin run_ov_prev = (run_len == 0) ? 8'(val) : run_ov_last; run_ov_last = 8'(val); run_ov_ok = 1; end
                    run_len++;
                    if (rc >= 4 && val[0]) run_ce = 1;
                    second_byte = 0;      // a status read ends a register pair (as the VDP does)
                end else io(0, 3'(port - 8'h98), 8'h00, q);
            end
            if (rw == "W" && port == 8'h99 && !second_byte && 8'(val) == 8'h8F) sreg = last_99_w[3:0];   // R#15 written
            if (want_flip < 0 && !dumping && !armed && dumped > 0) break;   // all dumps done
        end
        $fclose(f);
        repeat (6000000) @(posedge clk_vdp);         // ~4 frames: the last dump
        $display("V9968 REPLAY  events %0d (writes %0d, reads 98h %0d, 99h %0d), page flips %0d, dumps %0d",
                 n_ev, n_w, n_r98, n_r99, flips, dumped);
        $display("  vram reads: %0d of %0d differ from the oracle", rd_bad, n_r98);
        $display("  slowest bus accept: %0d clk_vdp (%s port %0d)", slow_max, slow_wr ? "write" : "read", slow_port);
        $display("  status polls: %0d runs waited, %0d left a VBLANK first, %0d missed (>%0d clk_vdp)", sync_wait, vr_fresh, sync_miss, sync_to);
        $display("  port: reads %0d, bad latency %0d, not answered %0d; link dropped %0d, off-grid %0d; chip errors %0d",
                 nrd, bad_lat, noans, mon_drop, mon_mis, chip2.errs);
        if (bad_lat == 0 && mon_mis == 0 && chip2.errs == 0 && !hung)
            $display("V9968 REPLAY RESULT PASS (judge the frames with cmp.py)");
        else
            $display("V9968 REPLAY RESULT FAIL");
        $finish;
    end
endmodule
