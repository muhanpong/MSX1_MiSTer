// Debug overlay — status panel, top-left corner.
// 4 indicator rows × 8px each + 2px border = 34px tall.
`default_nettype none

module debug_overlay (
    input  wire        CLK_VIDEO,
    input  wire        ce_pix,
    input  wire        hblank,
    input  wire        vblank,
    input  wire [7:0]  R_in, G_in, B_in,
    output reg  [7:0]  R_out, G_out, B_out,
    input  wire        en,
    input  wire        dbg_pcm_valid,
    input  wire        dbg_opl3_valid,
    input  wire        dbg_mem_nonzero,       // Unused legacy
    input  wire        dbg_interp_nonzero,    // Used for base_set
    input  wire signed [15:0] dbg_pcm_level,
    input  wire        dbg_new2,
    input  wire [4:0]  dbg_keyon_count,       // Unused legacy
    input  wire [4:0]  dbg_accum_cnt,         // Unused legacy
    input  wire [9:0]  dbg_env_min,           // Unused legacy
    input  wire [23:0] dbg_slot_keyon,        // per-slot host key-on
    input  wire [23:0] dbg_slot_active,       // per-slot produced output (window)
    input  wire [23:0] dbg_slot_envlive,      // per-slot envelope still expected to sound
    input  wire        dbg_wait_stuck,        // WAIT_n held low too long (deadlock)
    input  wire        dbg_irq_stuck,         // OPL irq held asserted too long (storm)
    input  wire        dbg_cpu_nom1,          // no opcode fetch too long (CPU halt)
    input  wire        dbg_ack_stopped,       // reg4 timer-ack writes stopped reaching OPL3
    input  wire        dbg_intack_stop,       // CPU not taking the asserted OPL IRQ
    input  wire        dbg_iff_stuck_off,     // irq asserted while IFF1==0 (EI unreached)
    input  wire        dbg_int_refused,       // irq asserted, IFF1==1, no INTA (T80 refusal)
    input  wire [15:0] dbg_pc_snap,           // PC at last IFF1-fall before green latch
    input  wire [15:0] dbg_pc_vec,            // handler-entry PC after last INTA
    input  wire [15:0] dbg_pc_now,            // live PC
    input  wire [15:0] dbg_trap_from,         // PC of the last opcode fetch before PC=0000
    input  wire [15:0] dbg_trap_prev,         // the one before that
    input  wire [15:0] dbg_trap_sp,           // SP at the trap
    input  wire [15:0] dbg_trap_b10,          // Konami banks {b1,b0} at the trap
    input  wire [15:0] dbg_trap_b32,          // Konami banks {b3,b2} at the trap
    input  wire [15:0] dbg_trap_cnt,          // {times PC hit 0000, bus strobes at freeze}
    input  wire [15:0] dbg_trap_bus,          // CPU address bus frozen at the trap
    input  wire [15:0] dbg_spin,              // RST 38 spin iterations (0 on a healthy machine)
    input  wire [15:0] dbg_a8_pc,             // PC of the last OUT (A8)
    input  wire [15:0] dbg_a8_vc,             // {A8 value written, A8 write count}
    input  wire [15:0] dbg_ppi_a8,            // {PPI port A at trap, PPI port A live}
    input  wire [15:0] dbg_a8r_vc,            // {last value read from A8, #zero reads}
    input  wire [15:0] dbg_a8r_pc,            // PC of the first A8 read that returned 00
    input  wire [15:0] dbg_ppi_ctl,           // {ms, reverted, jt8255 ctrl[6:0], reset count[6:0]}
    input  wire [15:0] dbg_ab_vc,             // {last AB mode-set value, mode-set count}
    input  wire [15:0] dbg_ab_pc,             // PC of the last AB mode-set write
    input  wire [15:0] dbg_jmp0,              // bus fetch addr before the first post-boot 0000 fetch
    input  wire [15:0] dbg_im_i,              // {IM, 6'b0, I} at last INTA
    input  wire [15:0] dbg_watch_pc,          // PC of last write to table byte 257
    input  wire [15:0] dbg_watch_dc,          // {data, count} of that write
    input  wire        dbg_int_ghost,         // fatal IFF1-fall had no INTA
    // ── Pause-symbol inputs (docs/pause_overlay_design.md §5 wiring table) ──
    input  wire        pause_in,              // msx_pause (level)
    input  wire        osd_in,                // OSD_STATUS (level)
    input  wire        key_tgl_in,            // ps2_key[10] — flips per keyboard event
    input  wire        mouse_tgl_in,          // ps2_mouse[24] — flips per mouse packet
    input  wire [5:0]  joy0_in,               // joypad 0 (all-digital momentary bits)
    input  wire [5:0]  joy1_in,               // joypad 1 (all-digital momentary bits)
    // reg-probe display (Zanac R#2 wedge hunt): {val8, frame16} + live frame
    input  wire [23:0] probe_r2,
    input  wire [23:0] probe_r23,
    input  wire [23:0] probe_r0,
    input  wire [15:0] probe_frame
);

// ─── CDC sync ───────────────────────────────────────────────────────────────────────
logic [1:0] pcm_sync, opl3_sync, new2_sync;
logic [1:0] base_sync;
logic [15:0] lvl_sync1, lvl_sync2;

always_ff @(posedge CLK_VIDEO) begin
    pcm_sync      <= {pcm_sync[0],   dbg_pcm_valid};
    opl3_sync     <= {opl3_sync[0],  dbg_opl3_valid};
    new2_sync     <= {new2_sync[0],  dbg_new2};
    base_sync     <= {base_sync[0],  dbg_interp_nonzero}; // base_set
    lvl_sync1   <= dbg_pcm_level;   lvl_sync2   <= lvl_sync1;
end

// Per-slot masks (slow-changing) — 2-FF CDC into the video clock.
logic [23:0] keyon_s1, keyon_s2, active_s1, active_s2, envlive_s1, envlive_s2;
logic [9:0]  env_s1, env_s2;                            // ch4 latency probe (measurement)
logic [1:0]  wstk_s, istk_s, nom1_s, astp_s, iack_s;   // freeze-detector latches, CDC into video clk
logic [1:0]  ioff_s, irfs_s;                            // IFF1-split detectors
logic [15:0] pcs_s1, pcs_s2, pcl_s1, pcl_s2;            // PC snapshot / vec
logic [15:0] tfr_s1,tfr_s2, tpv_s1,tpv_s2, tsp_s1,tsp_s2, tb1_s1,tb1_s2, tb3_s1,tb3_s2, tct_s1,tct_s2;
logic [15:0] tbu_s1,tbu_s2;
logic [15:0] spn_s1,spn_s2, apc_s1,apc_s2, avc_s1,avc_s2, ppa_s1,ppa_s2;
logic [15:0] rvc_s1,rvc_s2, rpc_s1,rpc_s2;
logic [15:0] pct_s1,pct_s2;
logic [15:0] abv_s1,abv_s2, abp_s1,abp_s2;
logic [15:0] jm0_s1,jm0_s2;
logic [15:0] pcn_s1, pcn_s2, imi_s1, imi_s2;            // live PC / IM+I
logic [15:0] wpc_s1, wpc_s2, wdc_s1, wdc_s2;            // watchpoint PC / data+count
logic [1:0]  gho_s;                                      // ghost acceptance
always_ff @(posedge CLK_VIDEO) begin
    keyon_s1   <= dbg_slot_keyon;    keyon_s2   <= keyon_s1;
    active_s1  <= dbg_slot_active;   active_s2  <= active_s1;
    envlive_s1 <= dbg_slot_envlive;  envlive_s2 <= envlive_s1;
    env_s1     <= dbg_env_min;       env_s2     <= env_s1;
`ifdef MOONSOUND_DIAG
    wstk_s     <= {wstk_s[0], dbg_wait_stuck};
    istk_s     <= {istk_s[0], dbg_irq_stuck};
    nom1_s     <= {nom1_s[0], dbg_cpu_nom1};
    astp_s     <= {astp_s[0], dbg_ack_stopped};
    iack_s     <= {iack_s[0], dbg_intack_stop};
    ioff_s     <= {ioff_s[0], dbg_iff_stuck_off};
    irfs_s     <= {irfs_s[0], dbg_int_refused};
    gho_s      <= {gho_s[0],  dbg_int_ghost};
    pcs_s1     <= dbg_pc_snap;   pcs_s2 <= pcs_s1;
    pcl_s1     <= dbg_pc_vec;    pcl_s2 <= pcl_s1;
    pcn_s1     <= dbg_pc_now;    pcn_s2 <= pcn_s1;
    tfr_s1 <= dbg_trap_from; tfr_s2 <= tfr_s1;
    tpv_s1 <= dbg_trap_prev; tpv_s2 <= tpv_s1;
    tsp_s1 <= dbg_trap_sp;   tsp_s2 <= tsp_s1;
    tb1_s1 <= dbg_trap_b10;  tb1_s2 <= tb1_s1;
    tb3_s1 <= dbg_trap_b32;  tb3_s2 <= tb3_s1;
    tct_s1 <= dbg_trap_cnt;  tct_s2 <= tct_s1;
    tbu_s1 <= dbg_trap_bus;  tbu_s2 <= tbu_s1;
    spn_s1 <= dbg_spin;      spn_s2 <= spn_s1;
    apc_s1 <= dbg_a8_pc;     apc_s2 <= apc_s1;
    avc_s1 <= dbg_a8_vc;     avc_s2 <= avc_s1;
    ppa_s1 <= dbg_ppi_a8;    ppa_s2 <= ppa_s1;
    rvc_s1 <= dbg_a8r_vc;    rvc_s2 <= rvc_s1;
    rpc_s1 <= dbg_a8r_pc;    rpc_s2 <= rpc_s1;
    pct_s1 <= dbg_ppi_ctl;   pct_s2 <= pct_s1;
    abv_s1 <= dbg_ab_vc;     abv_s2 <= abv_s1;
    abp_s1 <= dbg_ab_pc;     abp_s2 <= abp_s1;
    jm0_s1 <= dbg_jmp0;      jm0_s2 <= jm0_s1;
    imi_s1     <= dbg_im_i;      imi_s2 <= imi_s1;
    wpc_s1     <= dbg_watch_pc;  wpc_s2 <= wpc_s1;
    wdc_s1     <= dbg_watch_dc;  wdc_s2 <= wdc_s1;
`endif
end

// ─── Hold counters (8/frame decay) ───────────────────────────────────────────
logic [7:0] pcm_hold, opl3_hold;
logic vblank_prev;
always_ff @(posedge CLK_VIDEO) begin
    vblank_prev <= vblank;
    if (pcm_sync[1])   pcm_hold   <= 8'hFF;
    else if (!vblank_prev && vblank && pcm_hold > 0)
        pcm_hold <= (pcm_hold > 8'd8) ? pcm_hold - 8'd8 : 8'd0;
    if (opl3_sync[1])  opl3_hold  <= 8'hFF;
    else if (!vblank_prev && vblank && opl3_hold > 0)
        opl3_hold <= (opl3_hold > 8'd8) ? opl3_hold - 8'd8 : 8'd0;
end

// Bar computations
wire [15:0] abs_lvl = lvl_sync2[15] ? (~lvl_sync2 + 16'd1) : lvl_sync2;

logic [15:0] pcm_peak;
always_ff @(posedge CLK_VIDEO) begin
    if (abs_lvl > pcm_peak) pcm_peak <= abs_lvl;
end
wire [5:0] level_bar = pcm_peak[13:8];

// ─── Pixel position ──────────────────────────────────────────────────────────
logic [10:0] h_cnt;
logic [7:0]  v_cnt;
logic hbl_prev, vbl_prev;
logic drew_this_line;

always_ff @(posedge CLK_VIDEO) begin
    hbl_prev <= hblank;  vbl_prev <= vblank;
    if (!vbl_prev && vblank) begin
        v_cnt <= '0; row <= 6'd0; lir <= 3'd0;
    end else if (hbl_prev && !hblank && !vblank) begin
        v_cnt <= v_cnt + 8'd1;
        // Row tracking for the panel: content rows are ROWH lines tall and
        // start at line 1 (line 0 is the top border).  `row` is the band
        // index used by the whole render chain -- band height is one constant
        // instead of the old hard-coded 8-line py thresholds.
        if (v_cnt == 8'd0) begin row <= 6'd0; lir <= 3'd0; end
        else if (lir == ROWH-1) begin row <= row + 6'd1; lir <= 3'd0; end
        else lir <= lir + 3'd1;
    end
    if (hblank) begin h_cnt <= '0; drew_this_line <= 1'b0; end
    else if (ce_pix && h_cnt < 11'd2047) h_cnt <= h_cnt + 11'd1;
end

// ─── Pause symbol (⏸, top-right) ─────────────────────────────────────────────
// Fully independent of the `en`/status[48] panel gate (spec S4).
// NOTE (design §6): all six *_in ports are sourced in the clk21m domain and
// CLK_VIDEO == clk21m (MSX1.sv:609), so the 2-FF stages below are a defensive
// pipeline, not a true CDC.  The multi-bit joy inequality compares are only
// safe because source and destination clocks are identical; if CLK_VIDEO is
// ever separated from clk21m, the joy compares must be redesigned
// (source-domain toggle or gray coding / handshake).
logic       pause_q1, pause_q2;
logic       osd_q1,   osd_q2;
logic       key_q1,   key_q2,   key_q3;
logic       mouse_q1, mouse_q2, mouse_q3;
logic [5:0] joy0_q1,  joy0_q2,  joy0_q3;
logic [5:0] joy1_q1,  joy1_q2,  joy1_q3;

always_ff @(posedge CLK_VIDEO) begin
    pause_q1 <= pause_in;     pause_q2 <= pause_q1;
    osd_q1   <= osd_in;       osd_q2   <= osd_q1;
    key_q1   <= key_tgl_in;   key_q2   <= key_q1;    key_q3   <= key_q2;
    mouse_q1 <= mouse_tgl_in; mouse_q2 <= mouse_q1;  mouse_q3 <= mouse_q2;
    joy0_q1  <= joy0_in;      joy0_q2  <= joy0_q1;   joy0_q3  <= joy0_q2;
    joy1_q1  <= joy1_in;      joy1_q2  <= joy1_q1;   joy1_q3  <= joy1_q2;
end

// Input event = keyboard/mouse event-toggle flip or any joypad bit change.
wire sym_input_evt = (key_q2 ^ key_q3) | (mouse_q2 ^ mouse_q3)
                   | (joy0_q2 != joy0_q3) | (joy1_q2 != joy1_q3);

// 18-frame reload counter (design §7).  Frame tick = vblank rising edge (C5,
// reuses vblank_prev above).  Priority: pause-OFF clear > OSD-open constant
// reload > input reload > per-frame decay.  Reload value 18 caps the counter,
// so input spam cannot overflow the 5-bit register.
logic [5:0] sym_hold;                            // 36 frames ≈ 0.6 s @60 Hz
always_ff @(posedge CLK_VIDEO) begin
    if (!pause_q2)          sym_hold <= 6'd0;    // pause OFF → clear
    else if (osd_q2)        sym_hold <= 6'd36;   // OSD open → constant reload
    else if (sym_input_evt) sym_hold <= 6'd36;   // input event → reload
    else if (!vblank_prev && vblank && sym_hold != 6'd0)
                            sym_hold <= sym_hold - 6'd1;
end

// pause_q2 gate makes unpause hide the symbol combinationally, same clock.
wire symbol_on = pause_q2 && (osd_q2 || sym_hold != 6'd0);

// Fade-out: 4 discrete alpha steps over the last 8 frames of the hold
// (remaining >=8 or OSD open → opaque; 7..6 → 3/4; 5..4 → 2/4; 3..0 → 1/4).
// Blend is shift-add only (x1/4, x2/4, x3/4, x4/4) — no multipliers.
wire [1:0] sym_alpha = (osd_q2 || sym_hold >= 6'd8) ? 2'd3 :
                       (sym_hold >= 6'd6)           ? 2'd2 :
                       (sym_hold >= 6'd4)           ? 2'd1 : 2'd0;

function automatic [7:0] sym_blend(input [7:0] fg, input [7:0] bg,
                                   input [1:0] a);
    logic signed [9:0] d;
    logic signed [9:0] t;
    begin
        d = $signed({2'b00, fg}) - $signed({2'b00, bg});
        case (a)
            2'd3: t = d;                       // 4/4
            2'd2: t = (d >>> 1) + (d >>> 2);   // 3/4
            2'd1: t = (d >>> 1);               // 2/4
            default: t = (d >>> 2);            // 1/4
        endcase
        sym_blend = 8'($signed({2'b00, bg}) + t);
    end
endfunction

// Line-width self-measurement → X scale (design §3.4): latch h_cnt at hblank
// entry (first hblank cycle still holds the final count; h_cnt clears next
// cycle, so the h_cnt!=0 guard yields one capture per line).  wide=1 means
// 2 h_cnt counts per display pixel (V9938/V9958 ~DHClk path, line_w 480..583
// vs 240..284 for vdp18 — threshold 384 splits the two clusters).
logic [10:0] line_w = 11'd256;
always_ff @(posedge CLK_VIDEO) begin
    if (hblank && h_cnt != 11'd0) line_w <= h_cnt;
end
wire        sym_wide = (line_w >= 11'd384);
wire [10:0] sym_px   = sym_wide ? {1'b0, h_cnt[10:1]} : h_cnt;

// Symbol geometry in display-pixel units (design §3.4):
//   black box  x∈[226,242) y∈[26,45]; white bars x∈[228,232)∪[236,240) y∈[28,43].
wire in_sym  = symbol_on && !hblank && !vblank
            && (v_cnt >= 8'd26)    && (v_cnt <= 8'd45)
            && (sym_px >= 11'd226) && (sym_px < 11'd242);
wire sym_bar = (v_cnt >= 8'd28) && (v_cnt <= 8'd43)
            && ((sym_px >= 11'd228 && sym_px < 11'd232)
             || (sym_px >= 11'd236 && sym_px < 11'd240));

logic        pb;      // reg-probe current bit (comb temp)

// ─── Render ──────────────────────────────────────────────────────────────────
localparam PW = 11'd66;
`ifdef MOONSOUND_DIAG
// 34 bands (13 base + 17 diag + 4 reg-probe) x 7 lines + top/bottom border.
// Band height dropped 8 -> 7 so the reg-probe rows fit INSIDE the panel and
// the whole stack stays within the ~245-line visible area.
localparam [2:0] ROWH = 3'd7;
localparam PH = 8'd240;   // 1 + 34*7 + 1
`else
localparam [2:0] ROWH = 3'd8;
localparam PH = 8'd58;  // 7 rows: PCM diagnosis + ch4 latency probe
`endif
logic [5:0] row; logic [2:0] lir;   // band index / line-in-row (see v_cnt block)
wire in_panel = en && !hblank && !vblank && (h_cnt < PW) && (v_cnt < PH) && !drew_this_line;
// Left border column removed (2026-09-01, user request): content starts at
// h_cnt 0, flush with the scanline.  Top/bottom/right edges keep their frame.
wire border   = (h_cnt == PW-1) || (v_cnt == 8'd0) || (v_cnt == PH-1);
wire [7:0] px = h_cnt[7:0];
wire [4:0] slot_idx = px[5:1];   // 2px per slot → slot 0..23
wire       slot_ok  = (px < 8'd48);
// Dead voices = a genuine failure: keyed-on AND the envelope still expects to
// sound (not EG_OFF / not clipped to silence) AND yet produced no output for
// the whole window.  Gating on envlive removes the false reds from voices that
// legitimately decayed to silence with key-on still held (e.g. percussive/
// piano-like instruments the driver never sends key-off for).
wire [23:0] dead_mask = keyon_s2 & envlive_s2 & ~active_s2;
// Manual popcount ($countones isn't synthesizable in Quartus 17.1).
logic [5:0] dead_cnt;
always_comb begin
    dead_cnt = 6'd0;
    for (int i = 0; i < 24; i++) dead_cnt = dead_cnt + {5'd0, dead_mask[i]};
end
wire [7:0] dead_w = {1'b0, dead_cnt, 1'b0};   // dead count * 2 px

// ch4 SDRAM read-integrity CANARY error count (via dbg_env_min).
// 0  = green stub (no ch4 read corruption under playback load) = GOOD.
// >0 = RED bar grows with the corruption count = ROOT CAUSE CONFIRMED.
wire       can_err  = (env_s2 != 10'd0);
wire [7:0] lat_w    = can_err ? ((env_s2 > 10'd60) ? 8'd60 : (env_s2[7:0] + 8'd4)) : 8'd2;
wire       lat_mid  = can_err;   // yellow/red when any error
wire       lat_hi   = can_err;   // red

always_comb begin
    R_out = R_in; G_out = G_in; B_out = B_in;
    pb = 1'b0;
    if (in_panel) begin
        if (border) begin
            R_out = 8'h00; G_out = 8'h00; B_out = 8'h00;
        end else begin
            R_out = 8'h10; G_out = 8'h10; B_out = 8'h10;
            if (row < 6'd1) begin        // ROM Base Set — green=set, red=missing
                R_out = base_sync[1] ? 8'h00 : 8'hFF;
                G_out = base_sync[1] ? 8'hFF : 8'h00;
                B_out = 8'h00;
            end else if (row < 6'd2) begin // PCM valid — green
                R_out = 8'h00; G_out = (pcm_hold > 0) ? 8'hFF : 8'h40; B_out = 8'h00;
            end else if (row < 6'd3) begin // PCM level — yellow bar
                if (px < {2'd0, level_bar}) begin R_out=8'hFF; G_out=8'hE0; B_out=8'h00; end
                else begin R_out=8'h20; G_out=8'h20; B_out=8'h20; end
            end else if (row < 6'd4) begin // NEW2 — cyan
                R_out = 8'h00;
                G_out = new2_sync[1] ? 8'hFF : 8'h30;
                B_out = new2_sync[1] ? 8'hFF : 8'h30;
            end else if (row < 6'd5) begin // PER-SLOT voice map (peak-held):
                // green = keyon & producing, RED = keyon & DEAD, gray = off.
                if (slot_ok && dead_mask[slot_idx])      begin R_out=8'hFF; G_out=8'h00; B_out=8'h00; end
                else if (slot_ok && keyon_s2[slot_idx])  begin R_out=8'h00; G_out=8'hFF; B_out=8'h00; end
                else if (slot_ok)                        begin R_out=8'h20; G_out=8'h20; B_out=8'h20; end
            end else if (row < 6'd6) begin // DEAD-VOICE COUNT — red bar (length = #dead)
                if (px < dead_w) begin R_out=8'hFF; G_out=8'h00; B_out=8'h00; end
                else             begin R_out=8'h20; G_out=8'h20; B_out=8'h20; end
`ifdef MOONSOUND_DIAG
            end else if (row < 6'd7) begin // FREEZE DETECTORS — 7 segments (9px each):
                // [WAIT red][IRQ magenta][noM1 white][ACK-STOP yellow][INTACK-STOP cyan]
                // [IFF-OFF green][REFUSED orange]
                if (px < 8'd8) begin                   // WAIT deadlock
                    if (wstk_s[1]) begin R_out=8'hFF; G_out=8'h00; B_out=8'h00; end
                    else           begin R_out=8'h20; G_out=8'h00; B_out=8'h00; end
                end else if (px < 8'd16) begin         // IRQ storm
                    if (istk_s[1]) begin R_out=8'hFF; G_out=8'h00; B_out=8'hFF; end
                    else           begin R_out=8'h20; G_out=8'h00; B_out=8'h20; end
                end else if (px < 8'd24) begin         // CPU halt (no M1)
                    if (nom1_s[1]) begin R_out=8'hFF; G_out=8'hFF; B_out=8'hFF; end
                    else           begin R_out=8'h20; G_out=8'h20; B_out=8'h20; end
                end else if (px < 8'd32) begin         // ACK writes stopped reaching OPL3
                    if (astp_s[1]) begin R_out=8'hFF; G_out=8'hE0; B_out=8'h00; end
                    else           begin R_out=8'h20; G_out=8'h1C; B_out=8'h00; end
                end else if (px < 8'd40) begin         // CPU not taking the asserted IRQ
                    if (iack_s[1]) begin R_out=8'h00; G_out=8'hFF; B_out=8'hFF; end
                    else           begin R_out=8'h00; G_out=8'h20; B_out=8'h20; end
                end else if (px < 8'd48) begin         // IFF1==0 stuck (EI unreached) — GREEN
                    if (ioff_s[1]) begin R_out=8'h00; G_out=8'hFF; B_out=8'h00; end
                    else           begin R_out=8'h00; G_out=8'h20; B_out=8'h00; end
                end else if (px < 8'd56) begin         // IFF1==1 yet refused — ORANGE
                    if (irfs_s[1]) begin R_out=8'hFF; G_out=8'h80; B_out=8'h00; end
                    else           begin R_out=8'h20; G_out=8'h10; B_out=8'h00; end
                end else begin                         // GHOST acceptance — PINK
                    if (gho_s[1])  begin R_out=8'hFF; G_out=8'h40; B_out=8'h80; end
                    else           begin R_out=8'h20; G_out=8'h08; B_out=8'h10; end
                end
            end else if (row < 6'd8) begin // PC SNAPSHOT at green latch — 16 bits, MSB left, 4px/bit
                if (px < 8'd64) begin
                    if (pcs_s2[4'd15 - px[7:2]]) begin R_out=8'hFF; G_out=8'hFF; B_out=8'hFF; end
                    else                          begin R_out=8'h18; G_out=8'h18; B_out=8'h18; end
                end
            end else if (row < 6'd9) begin // VECTOR-TARGET PC — light green bits
                if (px < 8'd64) begin
                    if (pcl_s2[4'd15 - px[7:2]]) begin R_out=8'h80; G_out=8'hFF; B_out=8'h80; end
                    else                          begin R_out=8'h10; G_out=8'h20; B_out=8'h10; end
                end
            end else if (row < 6'd10) begin // LIVE PC — light blue bits
                if (px < 8'd64) begin
                    if (pcn_s2[4'd15 - px[7:2]]) begin R_out=8'h80; G_out=8'hC0; B_out=8'hFF; end
                    else                          begin R_out=8'h10; G_out=8'h14; B_out=8'h20; end
                end
            end else if (row < 6'd11) begin // IM+I at last INTA — amber bits
                if (px < 8'd64) begin
                    if (imi_s2[4'd15 - px[7:2]]) begin R_out=8'hFF; G_out=8'hC0; B_out=8'h40; end
                    else                          begin R_out=8'h20; G_out=8'h18; B_out=8'h08; end
                end
            end else if (row < 6'd12) begin // WATCH PC — pink bits (writer of table+0x100)
                if (px < 8'd64) begin
                    if (wpc_s2[4'd15 - px[7:2]]) begin R_out=8'hFF; G_out=8'h60; B_out=8'hA0; end
                    else                          begin R_out=8'h20; G_out=8'h0C; B_out=8'h14; end
                end
            end else if (row < 6'd13) begin // WATCH {data,count} — violet bits
                if (px < 8'd64) begin
                    if (wdc_s2[4'd15 - px[7:2]]) begin R_out=8'hC0; G_out=8'h80; B_out=8'hFF; end
                    else                          begin R_out=8'h18; G_out=8'h10; B_out=8'h20; end
                end
            // ── PC-TRAP rows (docs/pc_trap_overlay.md) ───────────────────────
            end else if (row < 6'd14) begin // TRAP: PC that jumped to 0000 — bright red
                if (px < 8'd64) begin
                    if (tfr_s2[4'd15 - px[7:2]]) begin R_out=8'hFF; G_out=8'h30; B_out=8'h30; end
                    else                          begin R_out=8'h28; G_out=8'h08; B_out=8'h08; end
                end
            end else if (row < 6'd15) begin // TRAP: the fetch before that — dim red
                if (px < 8'd64) begin
                    if (tpv_s2[4'd15 - px[7:2]]) begin R_out=8'hC0; G_out=8'h50; B_out=8'h50; end
                    else                          begin R_out=8'h20; G_out=8'h08; B_out=8'h08; end
                end
            end else if (row < 6'd16) begin // TRAP: SP — orange
                if (px < 8'd64) begin
                    if (tsp_s2[4'd15 - px[7:2]]) begin R_out=8'hFF; G_out=8'hA0; B_out=8'h20; end
                    else                          begin R_out=8'h20; G_out=8'h14; B_out=8'h04; end
                end
            end else if (row < 6'd17) begin // TRAP: banks {b1,b0} — cyan
                if (px < 8'd64) begin
                    if (tb1_s2[4'd15 - px[7:2]]) begin R_out=8'h00; G_out=8'hFF; B_out=8'hFF; end
                    else                          begin R_out=8'h00; G_out=8'h20; B_out=8'h20; end
                end
            end else if (row < 6'd18) begin // TRAP: banks {b3,b2} — dim cyan
                if (px < 8'd64) begin
                    if (tb3_s2[4'd15 - px[7:2]]) begin R_out=8'h40; G_out=8'hC0; B_out=8'hC0; end
                    else                          begin R_out=8'h00; G_out=8'h18; B_out=8'h18; end
                end
            end else if (row < 6'd19) begin // {death count, bus strobes} — white
                if (px < 8'd64) begin
                    if (tct_s2[4'd15 - px[7:2]]) begin R_out=8'hFF; G_out=8'hFF; B_out=8'hFF; end
                    else                          begin R_out=8'h18; G_out=8'h18; B_out=8'h18; end
                end
            end else if (row < 6'd20) begin // TRAP: address bus at the freeze — magenta
                if (px < 8'd64) begin
                    if (tbu_s2[4'd15 - px[7:2]]) begin R_out=8'hFF; G_out=8'h40; B_out=8'hFF; end
                    else                          begin R_out=8'h20; G_out=8'h08; B_out=8'h20; end
                end
            end else if (row < 6'd21) begin // RST 38 SPIN COUNT — bright yellow
                if (px < 8'd64) begin          // ANY non-zero value here = the spin
                    if (spn_s2[4'd15 - px[7:2]]) begin R_out=8'hFF; G_out=8'hFF; B_out=8'h00; end
                    else                          begin R_out=8'h20; G_out=8'h20; B_out=8'h00; end
                end
            end else if (row < 6'd22) begin // PPI port A {at trap, live} — light green
                if (px < 8'd64) begin          // which primary slot each page sees
                    if (ppa_s2[4'd15 - px[7:2]]) begin R_out=8'h80; G_out=8'hFF; B_out=8'h80; end
                    else                          begin R_out=8'h10; G_out=8'h20; B_out=8'h10; end
                end
            end else if (row < 6'd23) begin // PC of the last OUT (A8) — orange-red
                if (px < 8'd64) begin
                    if (apc_s2[4'd15 - px[7:2]]) begin R_out=8'hFF; G_out=8'h60; B_out=8'h00; end
                    else                          begin R_out=8'h20; G_out=8'h0C; B_out=8'h00; end
                end
            end else if (row < 6'd24) begin // {A8 value, A8 write count} — blue
                if (px < 8'd64) begin          // count==0 + changed PPI = CORE BUG
                    if (avc_s2[4'd15 - px[7:2]]) begin R_out=8'h60; G_out=8'h80; B_out=8'hFF; end
                    else                          begin R_out=8'h0C; G_out=8'h10; B_out=8'h20; end
                end
            end else if (row < 6'd25) begin // {last IN A,(A8) value, #zero reads} — rose
                if (px < 8'd64) begin          // low byte NON-ZERO = the smoking gun
                    if (rvc_s2[4'd15 - px[7:2]]) begin R_out=8'hFF; G_out=8'h30; B_out=8'h80; end
                    else                          begin R_out=8'h28; G_out=8'h06; B_out=8'h14; end
                end
            end else if (row < 6'd26) begin // RAMPAGE ORIGIN — lime (bus-based)
                // fetch addr right BEFORE the first post-boot M1 fetch from the
                // never-executed RAM holes (C000-E67F / E800-F37F).  cart addr =
                // ROM jumped/fell through there; BIOS = via BIOS; RAM = earlier.
                if (px < 8'd64) begin
                    if (rpc_s2[4'd15 - px[7:2]]) begin R_out=8'hB0; G_out=8'hFF; B_out=8'h00; end
                    else                          begin R_out=8'h1C; G_out=8'h28; B_out=8'h00; end
                end
            end else if (row < 6'd27) begin // {ms, rv, jt8255 ctrl, reset cnt} — white
                // MSB-first cells, left to right:
                //   cell 0        = word bit 15 = MS   (a mode-set was executed)
                //   cell 1        = word bit 14 = RV   (ctrl seen back at 1b AFTER
                //                                       a mode-set -- THE FINISH BIT,
                //                                       survives laundering)
                //   cells 2..8    = ctrl[6:0]; ISINA is ctrl[4] = word bit 11 =
                //                   *** CELL 4 FROM THE LEFT ***
                //   cells 9..15   = reset count[6:0]
                // Healthy boot: MS=1, RV=0, ctrl=02h (ISINA cell dark).
                //   RV=1                    -> the PPI lost its mode word: glitch class
                //   MS=1 & ISINA=1          -> 82h ran, PPI in input mode NOW
                //   MS=0 & ISINA=1          -> 82h never landed
                if (px < 8'd64) begin
                    if (pct_s2[4'd15 - px[7:2]]) begin R_out=8'hFF; G_out=8'hFF; B_out=8'hFF; end
                    else                          begin R_out=8'h1E; G_out=8'h1E; B_out=8'h1E; end
                end
            end else if (row < 6'd28) begin // {AB mode-set value, count} — spring green
                if (px < 8'd64) begin          // count>=2 = something beyond boot wrote AB
                    if (abv_s2[4'd15 - px[7:2]]) begin R_out=8'h00; G_out=8'hDC; B_out=8'hA0; end
                    else                          begin R_out=8'h00; G_out=8'h28; B_out=8'h1C; end
                end
            end else if (row < 6'd29) begin // PC of the last AB mode-set — salmon
                if (px < 8'd64) begin          // healthy = 042Ah (BIOS init), anything else = rampage
                    if (abp_s2[4'd15 - px[7:2]]) begin R_out=8'hFF; G_out=8'h78; B_out=8'hB4; end
                    else                          begin R_out=8'h28; G_out=8'h0C; B_out=8'h18; end
                end
            end else if (row < 6'd30) begin // WHO JUMPED TO 0000 — ice blue (bus-based)
                if (px < 8'd64) begin          // fetch addr right before the first 0000 fetch
                    if (jm0_s2[4'd15 - px[7:2]]) begin R_out=8'h80; G_out=8'hE0; B_out=8'hFF; end
                    else                          begin R_out=8'h10; G_out=8'h1C; B_out=8'h28; end
                end
            // ── reg-probe rows, folded INTO the panel (2026-09-01).  Formerly a
            // separate block at h_cnt 80..127 drawn over the game; now bands
            // 30..33.  24 bits x 2px, MSB left, bright=1/dim=0.
            end else if (row < 6'd31) begin // probe_r2 — red
                if (px < 8'd48) begin
                    pb = probe_r2[5'd23 - {1'b0, px[5:1]}];
                    R_out = pb ? 8'hFF : 8'h30; G_out = 8'h00; B_out = 8'h00;
                end
            end else if (row < 6'd32) begin // probe_r23 — green
                if (px < 8'd48) begin
                    pb = probe_r23[5'd23 - {1'b0, px[5:1]}];
                    R_out = 8'h00; G_out = pb ? 8'hFF : 8'h30; B_out = 8'h00;
                end
            end else if (row < 6'd33) begin // probe_r0 — amber
                if (px < 8'd48) begin
                    pb = probe_r0[5'd23 - {1'b0, px[5:1]}];
                    R_out = pb ? 8'hFF : 8'h30; G_out = pb ? 8'hC0 : 8'h24; B_out = 8'h00;
                end
            end else begin                 // probe frame — cyan (16 bits, 2px each)
                if (px < 8'd32) begin
                    pb = probe_frame[4'd15 - px[4:1]];
                    R_out = 8'h00; G_out = pb ? 8'hFF : 8'h30; B_out = pb ? 8'hFF : 8'h30;
                end
            end
`else
            end else if (row < 6'd7) begin // CH4 SDRAM LATENCY (measurement build)
                // peak-held max ch4 round-trip cycles since reset.
                // green <24 (fits idle), yellow <72 (within slot window),
                // red >=72 (exceeds per-slot fetch budget → voice drops).
                if (px < {3'd0, lat_w}) begin
                    R_out = lat_mid ? 8'hFF : 8'h00;
                    G_out = lat_hi  ? 8'h00 : (lat_mid ? 8'hE0 : 8'hFF);
                    B_out = 8'h00;
                end else begin R_out=8'h20; G_out=8'h20; B_out=8'h20; end
            end
`endif
        end
    end
    // Pause symbol — independent of the in_panel/`en` gate above (spec S4);
    // regions never overlap (panel h_cnt<66, symbol sym_px>=226).
    if (in_sym) begin
        if (sym_bar) begin
            R_out = sym_blend(8'hFF, R_in, sym_alpha);
            G_out = sym_blend(8'hFF, G_in, sym_alpha);
            B_out = sym_blend(8'hFF, B_in, sym_alpha);
        end else begin
            R_out = sym_blend(8'h00, R_in, sym_alpha);
            G_out = sym_blend(8'h00, G_in, sym_alpha);
            B_out = sym_blend(8'h00, B_in, sym_alpha);
        end
    end
end

endmodule
`default_nettype wire
