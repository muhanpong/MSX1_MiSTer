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
    if (!vbl_prev && vblank) v_cnt <= '0;
    else if (hbl_prev && !hblank && !vblank) v_cnt <= v_cnt + 8'd1;
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

logic [23:0] pv;      // reg-probe panel row value (comb temp)
logic        pb;      // current bit

// ─── Render ──────────────────────────────────────────────────────────────────
localparam PW = 11'd66;
`ifdef MOONSOUND_DIAG
localparam PH = 8'd106; // 13 rows: PCM rows + freeze detectors + forensic PC/IM/watch rows
`else
localparam PH = 8'd58;  // 7 rows: PCM diagnosis + ch4 latency probe
`endif
wire in_panel = en && !hblank && !vblank && (h_cnt < PW) && (v_cnt < PH) && !drew_this_line;
wire border   = (h_cnt == 11'd0) || (h_cnt == PW-1) || (v_cnt == 8'd0) || (v_cnt == PH-1);
wire [7:0] px = h_cnt[7:0] - 8'd1;
wire [7:0] py = v_cnt       - 8'd1;
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
    pv = 24'd0; pb = 1'b0;
    if (in_panel) begin
        if (border) begin
            R_out = 8'h00; G_out = 8'h00; B_out = 8'h00;
        end else begin
            R_out = 8'h10; G_out = 8'h10; B_out = 8'h10;
            if (py < 8'd8) begin        // ROM Base Set — green=set, red=missing
                R_out = base_sync[1] ? 8'h00 : 8'hFF;
                G_out = base_sync[1] ? 8'hFF : 8'h00;
                B_out = 8'h00;
            end else if (py < 8'd16) begin // PCM valid — green
                R_out = 8'h00; G_out = (pcm_hold > 0) ? 8'hFF : 8'h40; B_out = 8'h00;
            end else if (py < 8'd24) begin // PCM level — yellow bar
                if (px < {2'd0, level_bar}) begin R_out=8'hFF; G_out=8'hE0; B_out=8'h00; end
                else begin R_out=8'h20; G_out=8'h20; B_out=8'h20; end
            end else if (py < 8'd32) begin // NEW2 — cyan
                R_out = 8'h00;
                G_out = new2_sync[1] ? 8'hFF : 8'h30;
                B_out = new2_sync[1] ? 8'hFF : 8'h30;
            end else if (py < 8'd40) begin // PER-SLOT voice map (peak-held):
                // green = keyon & producing, RED = keyon & DEAD, gray = off.
                if (slot_ok && dead_mask[slot_idx])      begin R_out=8'hFF; G_out=8'h00; B_out=8'h00; end
                else if (slot_ok && keyon_s2[slot_idx])  begin R_out=8'h00; G_out=8'hFF; B_out=8'h00; end
                else if (slot_ok)                        begin R_out=8'h20; G_out=8'h20; B_out=8'h20; end
            end else if (py < 8'd48) begin // DEAD-VOICE COUNT — red bar (length = #dead)
                if (px < dead_w) begin R_out=8'hFF; G_out=8'h00; B_out=8'h00; end
                else             begin R_out=8'h20; G_out=8'h20; B_out=8'h20; end
`ifdef MOONSOUND_DIAG
            end else if (py < 8'd56) begin // FREEZE DETECTORS — 7 segments (9px each):
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
            end else if (py < 8'd64) begin // PC SNAPSHOT at green latch — 16 bits, MSB left, 4px/bit
                if (px < 8'd64) begin
                    if (pcs_s2[4'd15 - px[7:2]]) begin R_out=8'hFF; G_out=8'hFF; B_out=8'hFF; end
                    else                          begin R_out=8'h18; G_out=8'h18; B_out=8'h18; end
                end
            end else if (py < 8'd72) begin // VECTOR-TARGET PC — light green bits
                if (px < 8'd64) begin
                    if (pcl_s2[4'd15 - px[7:2]]) begin R_out=8'h80; G_out=8'hFF; B_out=8'h80; end
                    else                          begin R_out=8'h10; G_out=8'h20; B_out=8'h10; end
                end
            end else if (py < 8'd80) begin // LIVE PC — light blue bits
                if (px < 8'd64) begin
                    if (pcn_s2[4'd15 - px[7:2]]) begin R_out=8'h80; G_out=8'hC0; B_out=8'hFF; end
                    else                          begin R_out=8'h10; G_out=8'h14; B_out=8'h20; end
                end
            end else if (py < 8'd88) begin // IM+I at last INTA — amber bits
                if (px < 8'd64) begin
                    if (imi_s2[4'd15 - px[7:2]]) begin R_out=8'hFF; G_out=8'hC0; B_out=8'h40; end
                    else                          begin R_out=8'h20; G_out=8'h18; B_out=8'h08; end
                end
            end else if (py < 8'd96) begin // WATCH PC — pink bits (writer of table+0x100)
                if (px < 8'd64) begin
                    if (wpc_s2[4'd15 - px[7:2]]) begin R_out=8'hFF; G_out=8'h60; B_out=8'hA0; end
                    else                          begin R_out=8'h20; G_out=8'h0C; B_out=8'h14; end
                end
            end else begin                 // WATCH {data,count} — violet bits
                if (px < 8'd64) begin
                    if (wdc_s2[4'd15 - px[7:2]]) begin R_out=8'hC0; G_out=8'h80; B_out=8'hFF; end
                    else                          begin R_out=8'h18; G_out=8'h10; B_out=8'h20; end
                end
            end
`else
            end else if (py < 8'd56) begin // CH4 SDRAM LATENCY (measurement build)
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
    // ── reg-probe panel (diagnostic): 4 bit-strip rows, bottom-left, en-gated.
    // rows y 120..151 (8px each), 24 bits x 2px (MSB left), colors:
    //   row0 probe_r2 (red), row1 probe_r23 (green), row2 probe_r0 (amber),
    //   row3 {8'h00, probe_frame} (cyan).  bit=1 -> bright, 0 -> dim.
    if (en && !hblank && !vblank && v_cnt >= 8'd120 && v_cnt < 8'd152 && h_cnt < 11'd48) begin
        case (v_cnt[4:3])
            2'd0: pv = probe_r2;
            2'd1: pv = probe_r23;
            2'd2: pv = probe_r0;
            default: pv = {8'h00, probe_frame};
        endcase
        pb = pv[5'd23 - h_cnt[5:1]];
        case (v_cnt[4:3])
            2'd0: begin R_out = pb ? 8'hFF : 8'h30; G_out = 8'h00; B_out = 8'h00; end
            2'd1: begin R_out = 8'h00; G_out = pb ? 8'hFF : 8'h30; B_out = 8'h00; end
            2'd2: begin R_out = pb ? 8'hFF : 8'h30; G_out = pb ? 8'hC0 : 8'h24; B_out = 8'h00; end
            default: begin R_out = 8'h00; G_out = pb ? 8'hFF : 8'h30; B_out = pb ? 8'hFF : 8'h30; end
        endcase
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
