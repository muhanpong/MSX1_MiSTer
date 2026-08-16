// TB for the pause-symbol logic added to rtl/debug_overlay.sv
// (docs/pause_overlay_spec.md V1 / docs/pause_overlay_design.md §11).
//
// Video model: vdp18-style — ce_pix=1 every clock, visible width `visible_w`
// h-ticks (default 256), 86-clock hblank, 192 visible lines + 45 vblank lines.
//
// Scenarios:
//   T0  reset settle: symbol off, line_w self-measured, wide=0
//   T1  pause OFF + input spam → stays off (I2)
//   T2  pause ON + OSD open → constant show across frames, en(status[48])=0 (I3/I9)
//   T3  OSD close → exactly 18 vblank ticks visible, gone on the 18th (I4)
//   T4  key / mouse / joy0 / joy1 each reload to 18 mid-countdown, then expiry (I6)
//   T5  OSD reopen from hidden → immediate show (I7)
//   T6  unpause → immediate off + counter cleared (I8)
//   T7  input spam every clock: counter saturates at 18, never overflows (I6)
//   T8  pixel sampling en=0: bars white, box black, outside passthrough (S1/I9)
//   T9  en=1: panel renders AND symbol renders — independence (I10)
//   T10 wide line (512 ticks): sym_wide=1, symbol at doubled h_cnt coords (I15)
`timescale 1ns/1ps

module tb_pause_overlay;

reg clk = 0;
always #23 clk = ~clk;              // ~21.7 MHz — frequency-agnostic logic anyway

// ── video timing generator ──────────────────────────────────────────────────
integer visible_w = 256;            // h-ticks per visible line (T10 sets 512)
localparam HBL_W   = 86;
localparam VIS_L   = 192;
localparam VBL_L   = 45;

integer hc = 0, vc = 0;
always @(posedge clk) begin
    if (hc >= visible_w + HBL_W - 1) begin
        hc <= 0;
        vc <= (vc >= VIS_L + VBL_L - 1) ? 0 : vc + 1;
    end else
        hc <= hc + 1;
end
wire hblank = (hc >= visible_w);
wire vblank = (vc >= VIS_L);

// ── DUT hookup ──────────────────────────────────────────────────────────────
reg  [7:0] Rin = 8'h55, Gin = 8'hAA, Bin = 8'h33;
wire [7:0] Rout, Gout, Bout;
reg        en = 0;
reg        pause_in = 0, osd_in = 0, key_in = 0, mouse_in = 0;
reg  [5:0] joy0_in = '0, joy1_in = '0;

debug_overlay dut (
    .CLK_VIDEO(clk), .ce_pix(1'b1), .hblank(hblank), .vblank(vblank),
    .R_in(Rin), .G_in(Gin), .B_in(Bin),
    .R_out(Rout), .G_out(Gout), .B_out(Bout),
    .en(en),
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

// ── helpers ─────────────────────────────────────────────────────────────────
integer pass = 0, fail = 0;
task check(input cond, input [511:0] name);
    begin
        if (cond) begin pass = pass + 1; $display("PASS: %0s", name); end
        else      begin fail = fail + 1; $display("FAIL: %0s", name); end
    end
endtask

reg vbl_d = 1;
always @(posedge clk) vbl_d <= vblank;
task wait_frame_tick;                       // returns just after a vblank-rise edge
    begin
        do @(posedge clk); while (!(vblank && !vbl_d));
    end
endtask

task wait_px(input integer vy, input integer hx);  // park on a visible pixel
    begin
        do @(posedge clk);
        while (!(dut.v_cnt == vy[7:0] && dut.h_cnt == hx[10:0] && !hblank && !vblank));
        #1;                                  // let comb outputs settle
    end
endtask

// continuous overflow monitor (T7 and everywhere else)
reg overflow_err = 0;
always @(posedge clk) if (dut.sym_hold > 6'd36) overflow_err = 1;

// ── test sequence ───────────────────────────────────────────────────────────
initial begin
    // T0: settle two lines so line_w latches
    repeat (visible_w*3) @(posedge clk);
    check(dut.symbol_on === 1'b0 && dut.sym_hold == 5'd0, "T0 reset: symbol off, hold=0");
    check(dut.line_w == 11'd256 && dut.sym_wide === 1'b0, "T0 line_w self-measured 256, wide=0");

    // T1: pause OFF + input spam of every source → never shows
    repeat (20) begin key_in = ~key_in; mouse_in = ~mouse_in; @(posedge clk); end
    joy0_in = 6'h3F; joy1_in = 6'h15;
    repeat (10) @(posedge clk);
    joy0_in = '0; joy1_in = '0;
    repeat (10) @(posedge clk);
    check(dut.symbol_on === 1'b0 && dut.sym_hold == 5'd0, "T1 pause OFF: input spam ignored");

    // T2: pause ON + OSD open (en=0 throughout → status[48]=0 behavior)
    pause_in = 1; osd_in = 1;
    repeat (5) @(posedge clk);
    check(dut.symbol_on === 1'b1, "T2 pause+OSD: symbol on within a few clocks");
    repeat (3) wait_frame_tick; #1;
    check(dut.symbol_on === 1'b1 && dut.sym_hold == 6'd36, "T2 OSD held open 3 frames: still on, hold pinned at 18");

    // T3: OSD close right after a tick → exactly 18 more ticks of show
    wait_frame_tick;
    osd_in = 0;
    repeat (5) @(posedge clk);
    check(dut.symbol_on === 1'b1 && dut.sym_hold == 6'd36, "T3 OSD closed: still on, hold=18");
    repeat (35) wait_frame_tick; #1;
    check(dut.symbol_on === 1'b1 && dut.sym_hold == 6'd1, "T3 after 17 ticks: still on, hold=1");
    wait_frame_tick; #1;
    check(dut.symbol_on === 1'b0 && dut.sym_hold == 5'd0, "T3 after 18th tick: symbol gone");

    // T4: reload by each input source mid-countdown
    osd_in = 1; repeat (5) @(posedge clk);
    wait_frame_tick;                         // align transitions to a tick
    osd_in = 0; repeat (5) @(posedge clk);
    repeat (10) wait_frame_tick; #1;
    check(dut.sym_hold == 6'd26, "T4 pre: 10 ticks down, hold=26");
    key_in = ~key_in; repeat (5) @(posedge clk);
    check(dut.sym_hold == 6'd36, "T4 key toggle reloads to 18");
    repeat (3) wait_frame_tick; #1;
    check(dut.sym_hold == 6'd33, "T4 mid: hold=33");
    mouse_in = ~mouse_in; repeat (5) @(posedge clk);
    check(dut.sym_hold == 6'd36, "T4 mouse toggle reloads to 18");
    repeat (2) wait_frame_tick;
    joy0_in = 6'b000001; repeat (5) @(posedge clk);
    check(dut.sym_hold == 6'd36, "T4 joy0 change reloads to 18");
    repeat (2) wait_frame_tick;
    joy1_in = 6'b100000; repeat (5) @(posedge clk);
    check(dut.sym_hold == 6'd36, "T4 joy1 change reloads to 18");
    repeat (35) wait_frame_tick; #1;
    check(dut.symbol_on === 1'b1 && dut.sym_hold == 6'd1, "T4 expiry: on until hold=1");
    wait_frame_tick; #1;
    check(dut.symbol_on === 1'b0 && dut.sym_hold == 5'd0, "T4 expiry: gone after 18 ticks since last event");

    // T5: OSD reopen from hidden → immediate show (level, no edge needed)
    osd_in = 1; repeat (5) @(posedge clk);
    check(dut.symbol_on === 1'b1, "T5 OSD reopen: immediate show");

    // T6: unpause → immediate off + counter clear (from OSD-open show state)
    pause_in = 0; repeat (4) @(posedge clk);
    check(dut.symbol_on === 1'b0 && dut.sym_hold == 5'd0, "T6 unpause: immediate off, hold cleared");
    osd_in = 0; repeat (5) @(posedge clk);

    // T7: saturation — event every clock for 100 clocks, counter must cap at 18
    pause_in = 1; repeat (5) @(posedge clk);
    repeat (100) begin
        key_in = ~key_in; mouse_in = ~mouse_in; joy0_in = joy0_in + 6'd1;
        @(posedge clk);
    end
    repeat (5) @(posedge clk);               // drain sync pipeline
    check(!overflow_err && dut.sym_hold == 6'd36, "T7 input spam: counter saturates at 18, no overflow");

    // T8: pixel sampling (en=0), symbol held visible via OSD open
    osd_in = 1; repeat (5) @(posedge clk);
    wait_px(30, 230);
    check(Rout == 8'hFF && Gout == 8'hFF && Bout == 8'hFF, "T8 (v30,h230) bar1: white");
    wait_px(30, 238);
    check(Rout == 8'hFF && Gout == 8'hFF && Bout == 8'hFF, "T8 (v30,h238) bar2: white");
    wait_px(30, 233);
    check(Rout == 8'h00 && Gout == 8'h00 && Bout == 8'h00, "T8 (v30,h233) gap: black box");
    wait_px(27, 230);
    check(Rout == 8'h00 && Gout == 8'h00 && Bout == 8'h00, "T8 (v27,h230) above bars: black box");
    wait_px(30, 200);
    check(Rout == Rin && Gout == Gin && Bout == Bin, "T8 (v30,h200) left of box: passthrough");
    wait_px(30, 245);
    check(Rout == Rin && Gout == Gin && Bout == Bin, "T8 (v30,h245) right of box: passthrough");
    wait_px(50, 230);
    check(Rout == Rin && Gout == Gin && Bout == Bin, "T8 (v50,h230) below box: passthrough");
    wait_px(5, 5);
    check(Rout == Rin && Gout == Gin && Bout == Bin, "T8 en=0: no panel at (v5,h5)");

    // T9: en=1 — panel and symbol coexist, independent
    en = 1; repeat (5) @(posedge clk);
    wait_px(5, 5);
    check(!(Rout == Rin && Gout == Gin && Bout == Bin), "T9 en=1: panel renders at (v5,h5)");
    wait_px(30, 230);
    check(Rout == 8'hFF && Gout == 8'hFF && Bout == 8'hFF, "T9 en=1: symbol bar still white");
    en = 0;

    // T10: wide line (V9938-style 512 h-ticks) → wide=1, doubled coordinates
    visible_w = 512;
    repeat (2) wait_frame_tick;              // let hc wrap + line_w re-latch
    check(dut.line_w == 11'd512 && dut.sym_wide === 1'b1, "T10 line_w=512 detected, wide=1");
    wait_px(30, 460);                        // px = 460>>1 = 230 → bar1
    check(Rout == 8'hFF && Gout == 8'hFF && Bout == 8'hFF, "T10 (v30,h460) bar1 at doubled X: white");
    wait_px(30, 468);                        // px = 234 → gap
    check(Rout == 8'h00 && Gout == 8'h00 && Bout == 8'h00, "T10 (v30,h468) gap: black box");
    wait_px(30, 230);                        // px = 115 → far outside symbol
    check(Rout == Rin && Gout == Gin && Bout == Bin, "T10 (v30,h230) old narrow coord: passthrough");

    // final unpause sanity in wide mode
    pause_in = 0; osd_in = 0; repeat (4) @(posedge clk);
    check(dut.symbol_on === 1'b0 && dut.sym_hold == 5'd0, "T10 unpause in wide mode: off");

    $display("---------------------------------------------");
    $display("RESULT: %0d passed, %0d failed", pass, fail);
    if (fail == 0) $display("ALL TESTS PASSED");
    $finish;
end

// watchdog
initial begin
    #1_000_000_000; // 1 s sim time (~60 frames of 3.7 ms are needed)
    $display("TIMEOUT"); $finish;
end

endmodule
