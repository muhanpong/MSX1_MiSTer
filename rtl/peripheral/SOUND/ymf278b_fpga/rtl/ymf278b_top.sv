// YMF278B (OPL4) Top-Level
// Integrates YMF262 (OPL3 FM) + YMF278 (PCM wave) with I/O port arbitration.
// Targets MSX MoonSound cartridge I/O map: WAVE=0x7E/7F, FM=0xC4-0xC7
`default_nettype none

module ymf278b_top #(
    parameter int CLK_HZ     = 33868800,
    parameter int CLK_OPL3   = 14318180  // OPL3 master clock (14.318MHz)
) (
    input  wire        clk,          // 33.8688 MHz master
    input  wire        clk_opl3,     // 14.318 MHz for OPL3 core
    input  wire        rst_n,

    // CPU I/O bus
    input  wire [7:0]  io_port,
    input  wire [7:0]  io_data_in,
    input  wire        io_wr,
    input  wire        io_rd,
    output logic [7:0] io_data_out,
    output logic       io_ack,

    // Direct (bridge-free) FM status path: live status byte out, and a pulse
    // in when the host served a direct status read (consumes the NEW2 one-shot).
    output wire  [7:0] status_export,
    input  wire        status_rd_notify,

    // External memory bus (for PCM sample data)
    output logic [21:0] mem_addr,
    output logic        mem_rd_req,
    input  wire  [7:0]  mem_rd_data,
    input  wire  [15:0] mem_rd_data16,
    input  wire         mem_rd_valid,
    output logic        mem_wr_req,
    output logic [7:0]  mem_wr_data,
    input  wire         mem_busy,

    // Audio output
    output logic signed [15:0] audio_left,
    output logic signed [15:0] audio_right,
    output logic               audio_valid,

    // IRQ (from OPL3 timers)
    output logic       irq_n,

    // Audio mute controls (for debugging)
    input  wire        pcm_mute,
    input  wire        fm_mute,
    input  wire  [2:0] pcm_vol,    // OSD OPL4 PCM trim, 5 steps; see pcm_pre()/pcm_post()
    input  wire  [2:0] fm_vol,     // OSD OPL4 FM  trim, 5 steps; see fm_gain()

    // Debug outputs (clk_sdram domain)
    output wire        dbg_pcm_valid,
    output wire        dbg_opl3_valid,
    output wire signed [15:0] dbg_pcm_level,
    output wire        dbg_new2,
    output wire [4:0]  dbg_keyon_count,
    output wire [4:0]  dbg_accum_cnt,
    output wire [9:0]  dbg_env_min,
    output wire        dbg_mem_nonzero,
    output wire        dbg_pcm_base_set,
    output wire [23:0] dbg_slot_keyon,
    output wire [23:0] dbg_slot_active,
    output wire [23:0] dbg_slot_envlive,
    // slot-0 multi-probe taps (causal-chain capture in msx.sv)
    output wire [21:0] dbg_slot0_hdr_start,      // committed startAddr (header)
    output wire [15:0] dbg_slot0_dyn_pos,        // sample position
    output wire [9:0]  dbg_slot0_dyn_env_vol,    // envelope attenuation (loudness)
    output wire [2:0]  dbg_slot0_dyn_env_state,  // EG state
    output logic       dbg_ack_stopped   // reg4 (timer ack) writes stopped reaching OPL3
);

// ─── OPL3 core (gtaylormb opl3.sv) ───────────────────────────────────
// The opl3 module uses its own internal clock divider to hit ~49.7kHz.
// We use it at 14.318MHz to get the standard OPL3 sample rate.
logic [7:0]  opl3_status;
logic        opl3_sample_valid;
logic signed [23:0] opl3_left, opl3_right;

// OPL3 register write signals from ymf278b_regs
logic [8:0]  opl3_reg_addr;
logic [7:0]  opl3_reg_data;
logic        opl3_reg_wr;
logic        opl3_status_rd;
logic        opl3_reg_rd;
logic [7:0]  opl3_reg_dout;

// NEW2 bit — from OPL3 register 0x105[1]
logic        new2;

// Register file from OPL3 (we tap register 0x105 via a small shadow)
logic [7:0]  opl3_reg_shadow [0:1];  // bank1[0x05]
always_ff @(posedge clk) begin
    // MUST clear on reset: a real YMF278B powers up / resets with NEW2 = 0.  If the
    // shadow survives a warm MSX reset, NEW2 stays 1, so a driver that re-runs its
    // detection writes reg 105h = 03h and produces NO rising edge -> the one-shot
    // device-ID (status = 02h) is never re-armed, and the first status read (the
    // driver's earlier BUSY check) has already consumed the one armed at reset.
    // Detection then reads 00h where it requires 02h and reports the chip as broken
    // until the core is reloaded (MSXdev25 GoFigure: ":-( Incomplete OPL4 support").
    if (!rst_n)
        opl3_reg_shadow[0] <= 8'h00;
    else if (opl3_reg_wr && opl3_reg_addr == 9'h105)
        opl3_reg_shadow[0] <= opl3_reg_data;
end
assign new2 = opl3_reg_shadow[0][1];

// Ack-reach detector (clk): latch if, WHILE the OPL irq is asserted (ft1 set →
// irq_n low), no reg4 (timer-control) write reaches the OPL3 write stage for too
// long (>~3ms).  Gating on irq_n means it only fires when an ack IS needed but
// isn't arriving — not in the idle/boot state (irq deasserted, no reg4 traffic).
//   dbg_ack_stopped LIT during the freeze => irq stuck AND ack never reaches here
//                                            → bridge/ymf278b_regs drop the ack
//   dbg_ack_stopped OFF during the freeze => the reg4 ack DOES reach here (resets
//                                            the gap) → afifo/timers drop/ignore it
logic [17:0] ack_gap_cnt;
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        ack_gap_cnt     <= 0;
        dbg_ack_stopped <= 0;
    end else begin
        if (opl3_reg_wr && opl3_reg_addr == 9'd4) ack_gap_cnt <= 0;  // ack reached → reset
        else if (irq_n)                           ack_gap_cnt <= 0;  // irq idle → not relevant
        else if (~&ack_gap_cnt)                   ack_gap_cnt <= ack_gap_cnt + 1'b1;
        if (&ack_gap_cnt) dbg_ack_stopped <= 1'b1;
    end
end

// OPL3 chip instantiation (gtaylormb opl3_fpga)
// host_if uses edge detection (wr_p1 && !wr_p2), so consecutive-cycle writes are dropped.
// Three-stage write protocol to meet the afifo write edge requirement:
//   Cycle 0 (wr):  cs_n=0, address[0]=0 → address-mode write (register number + bank)
//   Cycle 1 (d1):  cs_n=1                → idle gap (creates falling edge for d2)
//   Cycle 2 (d2):  cs_n=0, address[0]=1 → data-mode write (register value)
// clk_host=clk (clk_sdram): afifo write side matches the domain of opl3_reg_wr signals.
logic opl3_reg_wr_d1, opl3_reg_wr_d2;
always_ff @(posedge clk) begin
    opl3_reg_wr_d1 <= opl3_reg_wr;
    opl3_reg_wr_d2 <= opl3_reg_wr_d1;
end

logic [7:0] opl3_status_raw;

opl3 u_opl3 (
    .clk          (clk_opl3),
    .clk_host     (clk),           // host write signals are in clk (clk_sdram) domain
    .clk_dac      (clk_opl3),
    .ic_n         (rst_n),
    // cs_n/wr_n: active on wr (address phase) and d2 (data phase); d1 is idle gap
    .cs_n         (~(opl3_reg_wr | opl3_reg_wr_d2 | opl3_reg_rd)),
    .rd_n         (~opl3_reg_rd),
    .wr_n         (~(opl3_reg_wr | opl3_reg_wr_d2)),
    // wr: address[0]=0 (address mode); d2: address[0]=1 (data mode)
    .address      (opl3_reg_wr ? {opl3_reg_addr[8], 1'b0}   // address phase
                               : {opl3_reg_addr[8], 1'b1}),  // data phase (d2)
    .din          (opl3_reg_wr ? opl3_reg_addr[7:0] : opl3_reg_data),
    .dout         (opl3_reg_dout),
    .sample_valid (opl3_sample_valid),
    .sample_l     (opl3_left),
    .sample_r     (opl3_right),
    .led          (),
    .irq_n        (irq_n),
    .status_o     (opl3_status_raw)
);

// OPL3 status (timer1/2 overflow + IRQ) crosses from the OPL3 clock domain
// (clk_opl3) to clk (clk_sdram), where ymf278b_regs serves the CPU status
// read.  2-FF synchronizer; the status changes slowly (timer rates) and the
// CPU polls it repeatedly, so a rare incoherent multi-bit sample is harmless.
logic [7:0] opl3_status_s1, opl3_status_s2;
always_ff @(posedge clk) begin
    opl3_status_s1 <= opl3_status_raw;
    opl3_status_s2 <= opl3_status_s1;
end

// ─── PCM wave engine ─────────────────────────────────────────────────
logic [7:0]  pcm_reg_addr, pcm_reg_data;
logic        pcm_reg_wr, pcm_reg_rd;
logic [7:0]  pcm_reg_dout;
logic signed [15:0] pcm_left, pcm_right;
logic               pcm_valid;

// Memory interface
logic [21:0] pcm_mem_addr;
logic        pcm_mem_rd_req;
logic [7:0]  pcm_cpu_mem_reg, pcm_cpu_mem_data;
logic        pcm_cpu_mem_wr, pcm_cpu_mem_rd;
logic [7:0]  pcm_cpu_mem_rd_data;
logic        pcm_cpu_mem_ack;
logic        pcm_reg_rd_done;

wire [7:0] pcm_cpu_mem_rd_data_w;
wire       pcm_cpu_mem_busy_w;
wire [7:0] pcm_reg02_readback_w;

ymf278_pcm_engine2 #(
    .CLK_HZ (CLK_HZ)
) u_pcm (
    .clk             (clk),
    .rst_n           (rst_n),

    // CPU Register Interface — reg 0x06 read path now wired through to engine
    .reg_addr        (pcm_reg_addr),
    .reg_data        (pcm_reg_data),
    .reg_wr          (pcm_reg_wr),
    .reg_rd          (pcm_reg_rd),
    .cpu_mem_rd_data (pcm_cpu_mem_rd_data_w),
    .cpu_mem_busy    (pcm_cpu_mem_busy_w),
    .reg02_readback  (pcm_reg02_readback_w),

    // SDRAM Direct Port
    .mem_addr        (mem_addr),
    .mem_rd_en       (mem_rd_req),
    .mem_rd_data     (mem_rd_data),
    .mem_rd_data16   (mem_rd_data16),
    .mem_rd_valid    (mem_rd_valid),
    .mem_wr_en       (mem_wr_req),
    .mem_wr_data     (mem_wr_data),
    .mem_busy        (mem_busy),

    // Audio Output
    .pcm_vol         (pcm_pre(pcm_vol)),  // pre-saturation shift (sh = 3 - this); see pcm_pre()
    .pcm_left        (pcm_left),
    .pcm_right       (pcm_right),
    .pcm_valid       (pcm_valid),

    // Debug observation ports (unused at top level — synthesis optimizes away)
    .dbg_wavetblhdr  (),
    .dbg_hf_pending  (),
    .dbg_slot0_wave  (),
    .dbg_slot0_fn    (),
    .dbg_slot0_oct   (),
    .dbg_slot0_prvb  (),
    .dbg_slot0_keyon (),
    .dbg_slot0_damp  (),
    .dbg_slot0_pan   (),
    .dbg_slot0_ar    (),
    .dbg_slot0_d1r   (),
    .dbg_slot5_wave  (),
    .dbg_slot23_wave (),
    .dbg_slot0_hdr_start (dbg_slot0_hdr_start),
    .dbg_slot0_hdr_loop  (),
    .fm_mix_l_o          (fm_mix_l),
    .fm_mix_r_o          (fm_mix_r),
    .dbg_slot0_hdr_end   (),
    .dbg_slot0_hdr_bits  (),
    .dbg_slot0_dyn_pos      (dbg_slot0_dyn_pos),
    .dbg_slot0_dyn_env_vol  (dbg_slot0_dyn_env_vol),
    .dbg_slot0_dyn_env_state(dbg_slot0_dyn_env_state),
    .dbg_slot_keyon  (dbg_slot_keyon),
    .dbg_slot_active (dbg_slot_active),
    .dbg_slot_envlive(dbg_slot_envlive)
);

// CPU register read mux.
//   reg 0x02 — Device ID (D7-D5 = 3'b001 = 0x20) OR'd with the latched write
//              bits (wavetblhdr / mem_type / mem_access_mode).  Some software
//              writes those bits then reads back expecting them reflected
//              (e.g. mem_type=1 → readback 0x22).
//   reg 0x06 — PCM RAM/ROM byte prefetched by the engine.
//   others   — return 0 (write-only by spec).
// pcm_reg_addr is stable (latched in opl4latch); pcm_reg_rd is a 1-cycle pulse
// that doesn't line up with regs.sv's io_data_out capture, so don't gate on it.
assign pcm_reg_dout    = (pcm_reg_addr == 8'h02) ? pcm_reg02_readback_w :
                         (pcm_reg_addr == 8'h06) ? pcm_cpu_mem_rd_data_w :
                                                    8'h00;
assign pcm_reg_rd_done = 1'b1; // Engine prefetches; CPU reads return immediately.
                               // Real chip uses BUSY status (D0) — TODO if needed.

// Unused legacy debug signals
assign dbg_keyon_count = 5'd0;
assign dbg_accum_cnt   = 5'd0;
assign dbg_env_min     = 10'd0;
assign dbg_mem_nonzero = 1'b0;

// ─── Register decode ─────────────────────────────────────────────────
logic busy_reg, load_busy_reg;

ymf278b_regs #(
    .CLK_HZ (CLK_HZ)
) u_regs (
    .clk            (clk),
    .rst_n          (rst_n),
    .io_port        (io_port),
    .io_data_in     (io_data_in),
    .io_wr          (io_wr),
    .io_rd          (io_rd),
    .io_data_out    (io_data_out),
    .io_ack         (io_ack),
    .new2           (new2),
    .opl3_reg_addr  (opl3_reg_addr),
    .opl3_reg_data  (opl3_reg_data),
    .opl3_reg_wr    (opl3_reg_wr),
    .opl3_status_rd (opl3_status_rd),
    .opl3_reg_rd    (opl3_reg_rd),
    .opl3_status    (opl3_status),
    .opl3_reg_dout  (opl3_reg_dout),
    .pcm_reg_addr   (pcm_reg_addr),
    .pcm_reg_data   (pcm_reg_data),
    .pcm_reg_wr     (pcm_reg_wr),
    .pcm_reg_rd     (pcm_reg_rd),
    .pcm_reg_dout   (pcm_reg_dout),
    .pcm_reg_rd_done(pcm_reg_rd_done),
    .pcm_cpu_mem_busy(pcm_cpu_mem_busy_w),
    .busy           (busy_reg),
    .status_live    (status_export),
    .status_rd_notify(status_rd_notify),
    .load_busy      (load_busy_reg)
);

// Real OPL3 status (synchronized) — replaces the old 0x00 stub that broke
// timer-based chip detection in MoonSound software (e.g. MBwave).
assign opl3_status = opl3_status_s2;

// ─── Audio mixing ─────────────────────────────────────────────────────
// OPL3 at ~49.7kHz drives the output rate; latest PCM sample is held and added.
logic signed [15:0] pcm_left_hold, pcm_right_hold;

// ── OPL4 output gain (OSD) ────────────────────────────────────
// Calibrated 2026-08-21 against a measured reference, not by ear.
//
// Reference level: openMSX playing SCMD "Out Run -Passing Breeze-" on an
// FS-A1ST -- the balance that sounds right -- gives SCC RMS -22.6 dBFS and
// MSX-MUSIC RMS -21.6 dBFS.  openMSX's own extension configs weight MoonSound
// <volume>17000 against SCC+/FMPAC 13000, i.e. +2.3 dB, so MoonSound's target
// is RMS ~= -20.3 dBFS.
//
// Measured source levels (golden model re-rendered WITHOUT saturation, so the
// true pre-clip amplitude is visible; FM via Nuked-OPL3):
//                       PCM peak   PCM RMS   FM RMS
//   MoonDriver TIME'S UP!  +11.0     -5.9     (no FM)
//   encounter the unkn.    +11.4     -5.9      -20.6
//   GoFigure (game)         +1.0    -20.1      -31.4
// The two music-disk pieces agree to 0.1 dB and overshoot full scale by 11 dB;
// GoFigure is simply mixed ~12 dB quieter in BOTH chips (its own choice, and
// it is quiet on real hardware too).  Hence a 5-step scale whose ends cover
// both camps: -8 lands the music disks at -22.0 dBFS clip-free, +8 lands
// GoFigure at -20.1 dBFS.
//
// PCM net gain is split in two, because the engine saturates to 16 bit
// INTERNALLY (ymf278_pcm_engine2.sv, frame output) -- a post-saturation trim
// would only make the clipping quieter, never undo it.  So most of the
// attenuation is done by the engine's own pre-saturation shift (6 dB steps,
// sh = 3 - pcm_vol) and the remainder by the multiplier here.  That way the
// clip point always sits at the final level instead of 12 dB above it.
//
// Defaults are the FIRST menu entry (MiSTer status resets to 0):
//   PCM -4dB  = net -12 dB, the loudest setting that clips 0.00% on all three
//   FM   0dB  = net  -4 dB, music-disk median lands at -21.7 dBFS
//
// The multiply keeps its own pipeline stage: chained onto fm_mix_gain()'s x3
// it would grow a combinational cloud in the clk_sdram domain, which is
// exactly what broke SDRAM_DQ IOB packing once before.

// Engine pre-saturation shift selector: engine computes sh = 3 - pcm_vol,
// so 2'd3 -> 0 dB, 2'd2 -> -6.02, 2'd1 -> -12.04, 2'd0 -> -18.06 dB.
function automatic [1:0] pcm_pre(input [2:0] sel);
    case (sel)
        3'd1: pcm_pre = 2'd0;   // "-8dB"  sh 3  -18.06
        3'd2: pcm_pre = 2'd2;   // "0dB"   sh 1   -6.02
        3'd3: pcm_pre = 2'd2;   // "+4dB"  sh 1   -6.02
        3'd4: pcm_pre = 2'd3;   // "+8dB"  sh 0    0.00
        default: pcm_pre = 2'd1;// "-4dB"  sh 2  -12.04  <- default / out of range
    endcase
endfunction
// Post-saturation remainder, x/128.  net = pre + 20*log10(post/128).
function automatic [11:0] pcm_post(input [2:0] sel);
    case (sel)
        3'd1: pcm_post = 12'd162;   // "-8dB"  +2.06 -> net -16.0
        3'd2: pcm_post = 12'd102;   // "0dB"   -1.98 -> net  -8.0
        3'd3: pcm_post = 12'd162;   // "+4dB"  +2.06 -> net  -4.0
        3'd4: pcm_post = 12'd128;   // "+8dB"   0.00 -> net   0.0
        default: pcm_post = 12'd129;// "-4dB"  +0.07 -> net -12.0  <- default
    endcase
endfunction
// FM has no internal saturation stage of its own, so one multiplier suffices.
function automatic [11:0] fm_gain(input [2:0] sel);
    case (sel)
        3'd1: fm_gain = 12'd81;     // "0dB"    -3.98 dB  <- the measured-neutral point
        3'd2: fm_gain = 12'd51;     // "-4dB"   -8.00 dB
        3'd3: fm_gain = 12'd32;     // "-8dB"  -12.04 dB
        3'd4: fm_gain = 12'd128;    // "+4dB"    0.00 dB
        default: fm_gain = 12'd203; // "+8dB"   +4.02 dB  <- menu entry 0 = OSD default
    endcase
endfunction
localparam int GAIN_SH = 7;
logic signed [29:0] fm_l_mul, fm_r_mul, pc_l_mul, pc_r_mul;  // stage-1 registered products
logic signed [21:0] sum_l, sum_r;                            // stage-2 combinational
logic               gain_v_q;

// FM/PCM mute mux — zero the respective path when muted.
// The FM level also follows wave register 0xF8 (FM MIX_CTRL), the FM twin of the
// 0xF9 PCM mix level.  Drivers fade BOTH together (GoFigure writes 0xF9 then
// DEC B -> 0xF8 with the same value); with 0xF8 unimplemented the PCM half faded
// on schedule while the FM half stayed at full level right through a song change,
// so the outgoing track blared over the transition until the new song's key-off
// blast silenced it.
logic [2:0] fm_mix_l, fm_mix_r;
function automatic signed [16:0] fm_mix_gain(input [2:0] idx, input signed [16:0] x);
    logic signed [20:0] x3;
    x3 = $signed(x) * 21'sd3;
    case (idx)
        3'd0: return x;                  // x1
        3'd1: return 17'(x3 >>> 2);      // x3/4
        3'd2: return x >>> 1;            // x1/2
        3'd3: return 17'(x3 >>> 3);      // x3/8
        3'd4: return x >>> 2;            // x1/4
        3'd5: return 17'(x3 >>> 4);      // x3/16
        3'd6: return x >>> 3;            // x1/8
        default: return 17'sd0;          // mute
    endcase
endfunction
logic signed [16:0] opl3_l_eff, opl3_r_eff;
assign opl3_l_eff    = fm_mute  ? 17'sh0 : fm_mix_gain(fm_mix_l, $signed({opl3_left[20],  opl3_left[20:5]}));
assign opl3_r_eff    = fm_mute  ? 17'sh0 : fm_mix_gain(fm_mix_r, $signed({opl3_right[20], opl3_right[20:5]}));

// ─── DIAGNOSTIC MODE ────────────────────────────────────────────────────
// User reports overlay row 2 (PCM valid) OFF on hardware even after
// stretching dbg_pcm_valid to 32 cycles.  This means pcm_valid TRULY
// never pulses — engine's frame_cycle counter is not reaching 1947.
//
// To isolate whether the problem is (a) clk_sdram/rst_n at engine input,
// or (b) something inside the engine, route a FREE-RUNNING counter MSB
// to dbg_pcm_valid.  This counter lives in ymf278b_top (not engine),
// using the SAME clk and rst_n that feed the engine.
//
//   alive_counter[22] toggles every 2^22 / 85.9M ≈ 49ms → 10Hz blink
//
// Result interpretation (overlay row 2):
//   - BRIGHT GREEN constantly  → clk + rst_n + signal path all OK
//                                 → bug is INSIDE engine (e.g., frame_cycle
//                                   stuck, Stage D D3 always_ff not firing,
//                                   etc.).  TODO: deeper engine debug.
//   - STILL OFF / dim          → clk_sdram or rst_n is not reaching
//                                 ymf278b_top properly, or overlay path
//                                 is broken at a level we haven't checked.
//
// REVERT this after diagnosis — production should drive from pcm_valid.
// dbg_pcm_valid stretched to 32 clk_sdram cycles (~372ns) after each
// pcm_valid pulse so the 21MHz CDC in debug_overlay can reliably catch
// it.  Without stretching, a single-cycle 11.6ns pulse has only ~25%
// capture probability per dst clock edge, which can give visually OFF
// readings even when engine is running.  Does NOT affect audio path.
logic [4:0] dbg_pcm_valid_cnt;
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) dbg_pcm_valid_cnt <= 5'd0;
    else if (pcm_valid) dbg_pcm_valid_cnt <= 5'd31;
    else if (dbg_pcm_valid_cnt != 5'd0) dbg_pcm_valid_cnt <= dbg_pcm_valid_cnt - 5'd1;
end
assign dbg_pcm_valid  = pcm_valid | (dbg_pcm_valid_cnt != 5'd0);
assign dbg_opl3_valid = opl3_sample_valid;
assign dbg_pcm_level  = pcm_left_hold;
assign dbg_new2       = new2;

always_ff @(posedge clk) begin
    audio_valid <= 1'b0;
    gain_v_q    <= 1'b0;
    if (pcm_valid) begin
        pcm_left_hold  <= pcm_left;
        pcm_right_hold <= pcm_right;
    end
    // Stage 1 — apply the per-path OSD gain.  Nothing else shares this cycle,
    // so the multiply never chains onto fm_mix_gain()'s x3.
    if (opl3_sample_valid) begin
        fm_l_mul <= $signed(opl3_l_eff) * $signed({1'b0, fm_gain(fm_vol)});
        fm_r_mul <= $signed(opl3_r_eff) * $signed({1'b0, fm_gain(fm_vol)});
        pc_l_mul <= (pcm_mute ? 30'sh0 : $signed({pcm_left_hold [15], pcm_left_hold })
                                         * $signed({1'b0, pcm_post(pcm_vol)}));
        pc_r_mul <= (pcm_mute ? 30'sh0 : $signed({pcm_right_hold[15], pcm_right_hold})
                                         * $signed({1'b0, pcm_post(pcm_vol)}));
        gain_v_q <= 1'b1;
    end
    // Stage 2 — descale, sum, saturate ONCE to 16-bit signed.  Worst case after
    // >>>7 is FM +-65536*203/128 = +-103936 and PCM +-32768*162/128 = +-41472,
    // so the sum needs 19 bits incl. sign; 22 is comfortable.
    if (gain_v_q) begin
        sum_l = 22'(fm_l_mul >>> GAIN_SH) + 22'(pc_l_mul >>> GAIN_SH);
        sum_r = 22'(fm_r_mul >>> GAIN_SH) + 22'(pc_r_mul >>> GAIN_SH);
        audio_left  <= (sum_l >  22'sd32767) ? 16'sh7FFF :
                       (sum_l < -22'sd32768) ? 16'sh8000 : sum_l[15:0];
        audio_right <= (sum_r >  22'sd32767) ? 16'sh7FFF :
                       (sum_r < -22'sd32768) ? 16'sh8000 : sum_r[15:0];
        audio_valid <= 1'b1;
    end
end

endmodule
`default_nettype wire
