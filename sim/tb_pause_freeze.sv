// [현행화 2026-08-15] 본 TB가 실증한 vdp18 pause 비디오 동결(HIGH-1)은 MSX1.sv의
// ce_10m7_p/ce_5m39_n 게이트 해제로 수정 반영됨. 아래 서술은 수정 전 상태 기준.
// Supplementary adversarial TB (A4 review) — pause-symbol behavior when the
// video timing FREEZES during pause.
//
// Rationale: MSX1.sv:460-464 gates ce_10m7_p/ce_5m39_n/... with ~msx_pause,
// and in vdp18 (MSX1-machine) mode the whole video chain runs off those
// enables (rtl/msx.sv:518 clk_en_10m7_i, :474 ce_pix = ce_5m39_n).  So the
// moment msx_pause=1 on an MSX1 machine: hblank/vblank/ce_pix all freeze.
// The main TB (tb_pause_overlay.sv) free-runs video timing during pause,
// which models only the V9938 path (vdp runs on raw CLK21M, rtl/msx.sv:551).
//
// F1: sanity — running video, pause+OSD → symbol on (matches main TB)
// F2: freeze timing at pause, close OSD → sym_hold NEVER decays (18 forever);
//     spec S2 "OSD close → 18 frames then gone" is unimplementable without
//     vblank ticks.  (DUT-observable half of the system-level finding.)
// F3: h_cnt frozen with ce_pix=0 → pixel coordinates never advance; the one
//     frozen coordinate is all the downstream (CE_PIXEL-sampled) path could
//     ever see.  Symbol pixels are never streamed out.
// F4: missed-event-at-pause-onset — key event lands well before pause_in
//     rises (hotkey-pause: key SPI transaction, then status update ms later)
//     → the 1-cycle evt pulse is gone, no reload, symbol never shows.
//     (Near-simultaneous arrival ≤1 clk apart IS caught — the event path has
//     one more pipeline stage than the pause path — verified separately.)
`timescale 1ns/1ps

module tb_pause_freeze;

reg clk = 0;
always #23 clk = ~clk;

// ── freezable video timing generator (mimics ce-gated vdp18) ───────────────
localparam VISW  = 256;
localparam HBL_W = 86;
localparam VIS_L = 192;
localparam VBL_L = 45;

reg frozen = 0;                       // = msx_pause gating the VDP enables
integer hc = 0, vc = 0;
always @(posedge clk) if (!frozen) begin
    if (hc >= VISW + HBL_W - 1) begin
        hc <= 0;
        vc <= (vc >= VIS_L + VBL_L - 1) ? 0 : vc + 1;
    end else
        hc <= hc + 1;
end
wire hblank = (hc >= VISW);
wire vblank = (vc >= VIS_L);
wire ce_pix = !frozen;                // vdp18: ce_5m39_n & ~msx_pause

reg  [7:0] Rin = 8'h55, Gin = 8'hAA, Bin = 8'h33;
wire [7:0] Rout, Gout, Bout;
reg        pause_in = 0, osd_in = 0, key_in = 0, mouse_in = 0;
reg  [5:0] joy0_in = '0, joy1_in = '0;

debug_overlay dut (
    .CLK_VIDEO(clk), .ce_pix(ce_pix), .hblank(hblank), .vblank(vblank),
    .R_in(Rin), .G_in(Gin), .B_in(Bin),
    .R_out(Rout), .G_out(Gout), .B_out(Bout),
    .en(1'b0),
    .dbg_pcm_valid(1'b0), .dbg_opl3_valid(1'b0),
    .dbg_mem_nonzero(1'b0), .dbg_interp_nonzero(1'b0),
    .dbg_pcm_level(16'sd0), .dbg_new2(1'b0),
    .dbg_keyon_count(5'd0), .dbg_accum_cnt(5'd0), .dbg_env_min(10'd0),
    .dbg_slot_keyon(24'd0), .dbg_slot_active(24'd0), .dbg_slot_envlive(24'd0),
    .dbg_wait_stuck(1'b0), .dbg_irq_stuck(1'b0), .dbg_cpu_nom1(1'b0),
    .dbg_ack_stopped(1'b0), .dbg_intack_stop(1'b0), .dbg_iff_stuck_off(1'b0),
    .dbg_int_refused(1'b0),
    .dbg_pc_snap(16'd0), .dbg_pc_vec(16'd0), .dbg_pc_now(16'd0),
    .dbg_im_i(16'd0), .dbg_watch_pc(16'd0), .dbg_watch_dc(16'd0),
    .dbg_int_ghost(1'b0),
    .pause_in(pause_in), .osd_in(osd_in),
    .key_tgl_in(key_in), .mouse_tgl_in(mouse_in),
    .joy0_in(joy0_in), .joy1_in(joy1_in)
);

integer pass = 0, fail = 0;
task check(input cond, input [511:0] name);
    begin
        if (cond) begin pass = pass + 1; $display("PASS: %0s", name); end
        else      begin fail = fail + 1; $display("FAIL: %0s", name); end
    end
endtask

localparam integer FRAME_CLKS = (VISW+HBL_W)*(VIS_L+VBL_L);
integer h_snap;

initial begin
    // settle: two full lines so line_w latches
    repeat (VISW*3) @(posedge clk);

    // F1: running video, pause+OSD → symbol on
    pause_in = 1; osd_in = 1;
    repeat (5) @(posedge clk);
    check(dut.symbol_on === 1'b1 && dut.sym_hold == 6'd36, "F1 running video: pause+OSD symbol on");

    // freeze mid-visible-line (park outside blanking first)
    do @(posedge clk); while (hblank || vblank);
    frozen = 1;                     // vdp18 reality: msx_pause gates the VDP
    repeat (5) @(posedge clk);

    // F2: close OSD; spec wants exactly 18 frame-ticks then gone.
    osd_in = 0;
    repeat (40*FRAME_CLKS) @(posedge clk);   // 40 frame-times of wall clock
    check(dut.sym_hold == 6'd36 && dut.symbol_on === 1'b1,
          "F2 frozen video: 40 frame-times later sym_hold STILL 18 (no expiry possible)");

    // F3: pixel stream halted — h_cnt cannot move without ce_pix
    h_snap = dut.h_cnt;
    repeat (1000) @(posedge clk);
    check(dut.h_cnt == h_snap[10:0], "F3 frozen video: h_cnt pinned (no pixels ever streamed)");

    // unpause clears (and unfreezes, as msx_pause deasserts)
    pause_in = 0; frozen = 0;
    repeat (4) @(posedge clk);
    check(dut.symbol_on === 1'b0 && dut.sym_hold == 5'd0, "F2b unpause: cleared");

    // F4: key event well before pause onset (hotkey-pause) → event missed
    repeat (20) @(posedge clk);
    key_in = ~key_in;               // the hotkey press event reaches the core...
    repeat (50) @(posedge clk);     // ...separate SPI transactions: ms-scale gap
    pause_in = 1;                   // status-toggle pause lands afterwards
    repeat (10) @(posedge clk);
    check(dut.symbol_on === 1'b0 && dut.sym_hold == 5'd0,
          "F4 event-before-pause-onset missed: symbol never shows (observation)");
    pause_in = 0;

    $display("---------------------------------------------");
    $display("RESULT: %0d passed, %0d failed", pass, fail);
    $finish;
end

initial begin
    #1_000_000_000;
    $display("TIMEOUT"); $finish;
end

endmodule
