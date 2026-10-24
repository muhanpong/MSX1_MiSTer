`timescale 1ps/1ps
//  Geo3D frame time on this core's integration: geo3d_bus (rtl/video/geo3d, v2.0) wired as
//  in rtl/msx.sv (ports 5/7 of the V9968 host bus, ext_cmd_* into the V9968), the V9968
//  (rtl/video/v9968) on sdram_tdm's V slot through v9968_link, over the SDRAM model.
//  clk_sdram 7.760 ns, clk_vdp 11.640 ns, clk_geo 23.28 ns, all rising together at 5.82 ns
//  (one PLL, phase 0).
//
//  Stimulus: upstream's tb_system.v format (geo3d/sim, written by z80/run_demo_z80.py from
//  the real Z80 program):  W sel b | R | F n | V reg val | C | X addr b | D y0
//    W  geo3d port write (sel 0: index port 5, 1: data port 7)
//    R  poll geo3d status (port 5 read) until bit0 = 0; timed (the frame's RUN -> idle)
//    V  V9968 register write through port 99h (value, 80h|reg)
//    C  wait for CE = 0 (the V9968's command-busy, as upstream's tb waits on ce)
//    X  VRAM byte write through ports 99h/98h (address set only when not sequential)
//    D  page flip: R#2 = page (upstream dumps VRAM here; the display shows that page)
//  Setup before the stream, as the Z80 program does: SCREEN 5 (R#0=06 R#1=40 R#2=1F R#7=0
//  R#8=0A R#9=80), port 4 = 00 (unlock), R#21 = 00 (V9968 mode), R#20 = +r20 (default 01:
//  high-speed commands).  cmd_wait = rtl/video/v9968_cmdwait.sv, +v9938=1 for the V9938 table.
//
//  Output per R: "FRAME n run_ns T ce_clk C stall_clk S cmd_acc A"
//    ce_clk    clk_vdp with the command engine's CE = 1 during the RUN
//    stall_clk clk_vdp with the command cache's VRAM request valid and not ready
//    cmd_acc   command-cache VRAM accesses (valid & ready) during the RUN
module altddio_out #(parameter extend_oe_disable = "OFF", intended_device_family = "",
    invert_output = "OFF", lpm_hint = "", lpm_type = "", oe_reg = "", power_up_high = "OFF",
    parameter int width = 1)
  (input [width-1:0] datain_h, datain_l, input outclock, output [width-1:0] dataout,
   input aclr, aset, oe, outclocken, sclr, sset);
    assign dataout = outclock ? datain_h : datain_l;
endmodule

module tb #(parameter int RELEASE_PH = 5);
    logic clk_sdram = 0, clk_vdp = 0, clk_geo = 0;
    always #3880 clk_sdram = ~clk_sdram;
    always #5820 clk_vdp   = ~clk_vdp;
    initial begin #5820; forever begin clk_geo = ~clk_geo; #11640; end end

    string stimf = "texdemo_sys.txt";
    int r20 = 1, v9938 = 0, pace = 3, maxfr = 1000000, disp = 1;
    initial begin
        void'($value$plusargs("stim=%s", stimf));
        void'($value$plusargs("r20=%h", r20));      // R#20 (bit0 = high-speed commands)
        void'($value$plusargs("v9938=%d", v9938));  // cmd_wait table: 0 V9968 (OSD default), 1 V9938
        void'($value$plusargs("pace=%d", pace));    // clk_vdp after each bus access (upstream tb: 3)
        void'($value$plusargs("frames=%d", maxfr)); // stop after this many R
        void'($value$plusargs("disp=%d", disp));    // 1: display on (R#1=40), 0: off
    end

    //  ── SDRAM controller + model ──────────────────────────────────────────
    wire [15:0] DQ; wire [12:0] A; wire [1:0] BA;
    wire nCS, nWE, nRAS, nCAS, CKE, SCLK, DQML, DQMH;
    logic init = 1;
    wire v_go, v_req, v_we, v_grant, v_rvalid;
    wire [15:0] v_addr; wire [31:0] v_wdata, v_rdata; wire [3:0] v_be, tdm_ph;
    wire [7:0] cd [4];
    sdram_tdm #(.CACHE_LINES(1024)) dut (
        .init(init), .clk(clk_sdram), .mode128(1'b1), .mode64(1'b0), .v_en(1'b1),
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

    //  ── link + V9968 + geo3d (bus sharing as rtl/msx.sv) ───────────────────
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
    logic [7:0] bus_wdata = 0;
    wire bus_ready, bus_rdata_en; wire [7:0] bus_rdata;
    wire geo_hit, geo_ready, geo_rdata_en, geo_cmd_wr, geo_busy;
    wire [7:0] geo_rdata, geo_cmd_data; wire [5:0] geo_cmd_num;
    wire vdp_bus_ready, vdp_bus_rdata_en, vdp_ext_ce; wire [7:0] vdp_bus_rdata;
    geo3d_bus #(.PORT_INDEX(3'd5), .PORT_DATA(3'd7)) u_geo3d (
        .clk(clk_vdp), .clk_eng(clk_geo), .reset_n(vdp_reset_n),
        .bus_address(bus_address), .bus_ioreq(bus_ioreq), .bus_write(bus_write),
        .bus_valid(bus_valid), .bus_wdata(bus_wdata),
        .hit(geo_hit), .bus_ready(geo_ready), .bus_rdata(geo_rdata), .bus_rdata_en(geo_rdata_en),
        .cmd_wr(geo_cmd_wr), .cmd_num(geo_cmd_num), .cmd_data(geo_cmd_data), .cmd_ce(vdp_ext_ce),
        .run_busy(geo_busy));
    assign bus_ready    = geo_hit ? geo_ready : vdp_bus_ready;
    assign bus_rdata_en = geo_rdata_en | vdp_bus_rdata_en;
    assign bus_rdata    = geo_rdata_en ? geo_rdata : vdp_bus_rdata;

    wire [95:0] cmdw;
    v9968_cmdwait u_cw (.v9938(v9938 != 0), .cmd_wait(cmdw));
    vdp vdp9968 (
        .reset_n(vdp_reset_n), .clk(clk_vdp), .initial_busy(1'b0),
        .bus_address(bus_address), .bus_ioreq(bus_ioreq), .bus_write(bus_write),
        .bus_valid(bus_valid & ~geo_hit), .bus_ready(vdp_bus_ready), .bus_wdata(bus_wdata),
        .bus_rdata(vdp_bus_rdata), .bus_rdata_en(vdp_bus_rdata_en),
        .int_n(),
        .vram_address(vram_address), .vram_write(vram_write), .vram_valid(vram_valid),
        .vram_wdata(vram_wdata), .vram_wdata_mask(vram_wdata_mask),
        .vram_rdata(vram_rdata), .vram_rdata_en(vram_rdata_en), .vram_refresh(),
        .display_hs(), .display_vs(), .display_en(), .display_r(), .display_g(), .display_b(),
        .force_highspeed(1'b0),
        .ext_cmd_wr(geo_cmd_wr), .ext_cmd_num(geo_cmd_num), .ext_cmd_data(geo_cmd_data), .ext_cmd_ce(vdp_ext_ce),
        .scanline_level(2'd0), .cmd_wait(cmdw),
        .button(2'b00),
        .pulse0(), .pulse1(), .pulse2(), .pulse3(), .pulse4(), .pulse5(), .pulse6(), .pulse7());

    //  ── counters over a RUN ────────────────────────────────────────────────
    bit in_run = 0;
    longint ce_clk = 0, stall_clk = 0, cmd_acc = 0, geo_clk = 0;
    always @(posedge clk_vdp) if (in_run) begin
        if (vdp_ext_ce) ce_clk++;
        if (geo_busy) geo_clk++;
        if (vdp9968.w_command_vram_valid && !vdp9968.w_command_vram_ready) stall_clk++;
        if (vdp9968.w_command_vram_valid &&  vdp9968.w_command_vram_ready) cmd_acc++;
    end

    //  ── host bus ──────────────────────────────────────────────────────────
    task automatic io(input logic wr, input logic [2:0] port, input logic [7:0] d, output logic [7:0] q);
        int w;
        @(negedge clk_vdp);
        bus_ioreq = 1; bus_address = port; bus_write = wr; bus_wdata = d; bus_valid = 1;
        w = 0;
        do begin @(posedge clk_vdp); w++; end while (!bus_ready && w < 2000000);
        if (!bus_ready) begin $display("TB ERR bus_ready stuck t=%0t", $time); $finish; end
        @(negedge clk_vdp); bus_valid = 0;
        q = 8'hxx;
        if (!wr) begin
            w = 0;
            do begin @(posedge clk_vdp); w++; end while (!bus_rdata_en && w < 2000);
            q = bus_rdata;
        end
        @(negedge clk_vdp); bus_ioreq = 0;
        repeat (pace) @(negedge clk_vdp);
    endtask
    task automatic wreg(input int r, input logic [7:0] v);
        logic [7:0] q; io(1, 3'd1, v, q); io(1, 3'd1, 8'h80 | r[7:0], q);
    endtask

    initial begin
        int fd, rc, p1, p2, frames, nr, nx, nxs; logic [7:0] q, st; string op;
        longint t0, tmax, tsum; int vaddr;
        repeat (20) @(posedge clk_sdram);
        init = 0;
        wait (dut.run); wait (vdp_reset_n);
        repeat (2000) @(posedge clk_vdp);
        wreg(0, 8'h06); wreg(1, disp ? 8'h40 : 8'h00); wreg(2, 8'h1F); wreg(7, 8'h00); wreg(8, 8'h0A); wreg(9, 8'h80);
        io(1, 3'd4, 8'h00, q);                       // port 4 bit7 = 0: unlock R#20/R#21
        wreg(21, 8'h00); wreg(20, 8'(r20));
        $display("TB setup done t=%0t (r20=%02h v9938=%0d pace=%0d disp=%0d RELEASE_PH=%0d)", $time, r20, v9938, pace, disp, RELEASE_PH);
        fd = $fopen(stimf, "r");
        if (fd == 0) begin $display("TB ERR cannot open %s", stimf); $finish; end
        frames = 0; nr = 0; nx = 0; nxs = 0; tmax = 0; tsum = 0; vaddr = -1;
        while (!$feof(fd) && nr < maxfr) begin
            rc = $fscanf(fd, "%s", op);
            if (rc != 1) continue;
            case (op)
                "W": begin rc = $fscanf(fd, "%d %h", p1, p2); io(1, p1[0] ? 3'd7 : 3'd5, 8'(p2), q); end
                "R": begin
                    ce_clk = 0; stall_clk = 0; cmd_acc = 0; geo_clk = 0;
                    t0 = $time; in_run = 1;
                    st = 8'h01;
                    while (st[0]) io(0, 3'd5, 8'h00, st);
                    in_run = 0;
                    $display("FRAME %0d run_ns %0d ce_clk %0d stall_clk %0d cmd_acc %0d geo_busy_clk %0d",
                             nr, ($time - t0) / 1000, ce_clk, stall_clk, cmd_acc, geo_clk);
                    if ($time - t0 > tmax) tmax = $time - t0;
                    tsum += $time - t0;
                    nr++;
                end
                "F": begin rc = $fscanf(fd, "%d", p1); frames++; end
                "V": begin rc = $fscanf(fd, "%d %h", p1, p2); wreg(p1, 8'(p2)); end
                "C": begin
                    repeat (4) @(negedge clk_vdp);
                    while (vdp_ext_ce) @(negedge clk_vdp);
                end
                "X": begin
                    rc = $fscanf(fd, "%h %h", p1, p2);
                    if (p1 != vaddr) begin
                        wreg(14, 8'(p1 >> 14));
                        io(1, 3'd1, 8'(p1), q);
                        io(1, 3'd1, 8'h40 | 8'((p1 >> 8) & 8'h3F), q);
                        nxs++;
                    end
                    io(1, 3'd0, 8'(p2), q);
                    vaddr = (p1 + 1) & 32'h3FFFF;
                    nx++;
                end
                "D": begin rc = $fscanf(fd, "%d", p1); wreg(2, 8'h1F | 8'(((p1 / 256) & 3) << 5)); end
                default: ;
            endcase
        end
        $display("TB done: %0d RUNs, %0d VRAM bytes (%0d address sets), longest RUN %0.3f ms, mean %0.3f ms",
                 nr, nx, nxs, real'(tmax) / 1e9, nr ? real'(tsum) / 1e9 / nr : 0.0);
        $display("TB link: dropped %0d off-grid %0d; chip errors %0d", mon_drop, mon_mis, chip2.errs);
        $finish;
    end
endmodule
