`default_nettype none

// YMF278B PCM Engine v3 — Sequential Slot Machine (from-scratch redesign)
//
// See docs/pcm_engine_v3_design.md.  Replaces the v2 SCSP-style parallel
// pipeline whose multi-FSM coupling could wedge cpu_mem_busy permanently
// (vgmplay OPL4 freeze).  Function-level code (alu/eg packages) and the
// hardware-verified register/HF/key-retrig/TL-ramp semantics are carried
// over from v2; the pipeline/scheduler/memory architecture is new.
//
// Fixed schedule per audio frame (CYCLES_PER_FRAME = 1948 @ clk):
//   cycles    0..1727 : 24 slot windows × 72 cycles, fully sequential —
//                       one slot is processed start-to-finish in its window
//                       (load → step/EG math → blocking SDRAM fetches →
//                       decode/interp → gains → accumulate → writeback).
//   cycles 1728..1947 : service window — CPU mem op (reg 0x06) FIRST,
//                       unconditional, then one header fetch.
//
// BUSY bound by construction: a pending CPU mem op is serviced at the next
// service window at the latest (≤ 1 frame = 22.7 µs), plus opportunistically
// in any slot window's idle tail.  No coupling to header/slot FSM state.

import ymf278_pcm_alu_pkg::*;
import ymf278_pcm_eg_pkg::*;

module ymf278_pcm_engine2 #(
    parameter int CLK_HZ       = 85909090,
    parameter int SDRAM_RD_LAT = 6
) (
    input  wire        clk,
    input  wire        rst_n,

    // CPU Register Interface
    input  wire [7:0]  reg_addr,
    input  wire [7:0]  reg_data,
    input  wire        reg_wr,
    input  wire        reg_rd,
    output logic [7:0] cpu_mem_rd_data,
    output logic       cpu_mem_busy,
    output logic [7:0] reg02_readback,

    // SDRAM Direct Port (msx.sv ch4 bridge: edge-detected req, blocking)
    output logic [21:0] mem_addr,
    output logic        mem_rd_en,
    input  wire  [7:0]  mem_rd_data,
    input  wire  [15:0] mem_rd_data16,   // [7:0]=even byte, [15:8]=odd byte
    input  wire         mem_rd_valid,
    output logic        mem_wr_en,
    output logic [7:0]  mem_wr_data,
    input  wire         mem_busy,

    input  wire  [1:0]         pcm_vol,

    // Audio Output
    output logic signed [15:0] pcm_left,
    output logic signed [15:0] pcm_right,
    output logic               pcm_valid,

    // Debug observation ports (same set as v2 so existing TBs/overlay work)
    output logic [2:0]  dbg_wavetblhdr,
    output logic [23:0] dbg_hf_pending,
    output logic [8:0]  dbg_slot0_wave,
    output logic [9:0]  dbg_slot0_fn,
    output logic signed [3:0] dbg_slot0_oct,
    output logic        dbg_slot0_prvb,
    output logic        dbg_slot0_keyon,
    output logic        dbg_slot0_damp,
    output logic [3:0]  dbg_slot0_pan,
    output logic [3:0]  dbg_slot0_ar,
    output logic [3:0]  dbg_slot0_d1r,
    output logic [8:0]  dbg_slot5_wave,
    output logic [8:0]  dbg_slot23_wave,
    output logic [21:0] dbg_slot0_hdr_start,
    output logic [15:0] dbg_slot0_hdr_loop,
    output logic [15:0] dbg_slot0_hdr_end,
    output logic [2:0]  fm_mix_l_o,
    output logic [2:0]  fm_mix_r_o,
    output logic [1:0]  dbg_slot0_hdr_bits,
    output logic [15:0] dbg_slot0_dyn_pos,
    output logic [15:0] dbg_slot0_dyn_stepPtr,
    output logic [9:0]  dbg_slot0_dyn_env_vol,
    output logic [2:0]  dbg_slot0_dyn_env_state,
    output logic        dbg_stage_b_bytes_done,
    output logic        dbg_stage_advance,
    output logic        dbg_stage_b_valid,
    output logic [23:0] dbg_slot_keyon,
    output logic [23:0] dbg_slot_active,
    output logic [23:0] dbg_slot_envlive
);

// ═══════════════════════════════════════════════════════════════════════════
// Schedule constants
// ═══════════════════════════════════════════════════════════════════════════
localparam int CYCLES_PER_FRAME = 1948;
// Frame-end CPU reserve: the last CPU_RESERVE cycles of every frame belong to
// the CPU mem op service unconditionally (a slot still in flight is abandoned
// for this frame).  This is what makes BUSY ≤ 1 frame by CONSTRUCTION.
localparam int CPU_RESERVE      = 44;
localparam int CPU_RESERVE_AT   = CYCLES_PER_FRAME - CPU_RESERVE;

logic [10:0] frame_cycle;
logic [4:0]  cur_slot;       // next slot to dispatch (0..23, 24 = all done)
logic [23:0] eg_cnt;         // global EG clock (1 tick per frame)
logic [3:0]  tl_int_cnt;     // TL ramp phase: eg_cnt % 9
logic [1:0]  tl_int_step;    //               (eg_cnt / 9) % 3
wire         sample_start = (frame_cycle == CYCLES_PER_FRAME - 1);
wire         in_reserve   = (frame_cycle >= CPU_RESERVE_AT);

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        frame_cycle <= '0;
        eg_cnt      <= '0;
        tl_int_cnt  <= '0;
        tl_int_step <= '0;
    end else begin
        if (sample_start) begin
            frame_cycle <= '0;
            eg_cnt      <= eg_cnt + 24'd1;
            if (tl_int_cnt == 4'd8) begin
                tl_int_cnt  <= 4'd0;
                tl_int_step <= (tl_int_step == 2'd2) ? 2'd0 : tl_int_step + 2'd1;
            end else
                tl_int_cnt <= tl_int_cnt + 4'd1;
        end else
            frame_cycle <= frame_cycle + 11'd1;
    end
end

// ═══════════════════════════════════════════════════════════════════════════
// Slot state (identical structures to v2)
// ═══════════════════════════════════════════════════════════════════════════
typedef struct packed {
    logic [8:0]  wave;
    logic [9:0]  fn;
    logic signed [3:0] oct;
    logic [7:0]  tl;
    logic [3:0]  pan;
    logic        keyon;
    logic [3:0]  ar, d1r, d2r, rc, rr;
    logic [2:0]  am, vib, lfo_speed;
    logic        lfo_active;
    logic [3:0]  dl_idx;
    logic        damp, prvb;
} slot_regs_t;

typedef struct packed {
    logic [21:0] startAddr;
    logic [15:0] loopAddr;
    logic [15:0] endAddr;     // stored 2's-complement form (header bytes 5-6)
    logic [1:0]  bits;
} slot_header_t;

typedef struct packed {
    logic [15:0] pos;
    logic [15:0] stepPtr;
    logic [9:0]  env_vol;
    logic [2:0]  env_state;
    logic [17:0] lfo_cnt;
} slot_dyn_t;

slot_regs_t   ram_regs   [0:23];
slot_header_t ram_header [0:23];
slot_dyn_t    ram_dyn    [0:23];
logic [7:0]   tl_cur     [0:23];     // ramped TL (volume stage input)
logic [23:0]  tl_load;               // immediate-load request per slot
logic [23:0]  key_on_prev;
logic [23:0]  key_retrig;
// YMF278.cc:594-622 case 0 (wave-number write): if the slot is keyed on it does a
// full keyOnHelper (our key_retrig); if it is NOT keyed on it still does
// `stepPtr = 0; pos = 0;`.  We only had the keyed-on half, so a wave swapped onto a
// slot that is still RELEASING kept the old position and addressed
// new_start + stale_pos -> arbitrary memory = the documented "찍" burst.  Drivers hit
// this whenever they key-off then re-instrument before the release has died.
logic [23:0]  pos_rst;
logic [23:0]  hf_pending;
// Header-backfill dirty mask: openMSX backfills the envelope/LFO registers
// SYNCHRONOUSLY at the wave-number write, so software's writes AFTER the wave
// write survive.  Our header fetch is deferred (service window), so the
// backfill must skip any field the CPU wrote since the wave write — otherwise
// "wave# then params" sequences (every tracker/driver) lose their params.
// bit0=f5(lfo/vib) 1=f6(ar/d1r) 2=f7(dl/d2r) 3=f8(rc/rr) 4=f9(am)
logic [4:0]   bf_dirty [0:23];

logic [2:0]   wavetblhdr;
logic [2:0]   pcm_mix_l, pcm_mix_r;  // reg 0xF9
logic [2:0]   fm_mix_l,  fm_mix_r;   // reg 0xF8 (FM mix level — the FM half of the
                                       // same fade a driver does with 0xF9; without it the
                                       // FM keeps blaring at full level through a fade)

// Loop wrap (v2 next_pos_calc, verbatim)
function automatic [15:0] next_pos_calc(
    input [15:0] pos,
    input [15:0] inc,
    input [15:0] endAddr,
    input [15:0] loopAddr
);
    logic [16:0] p2;
    p2 = {1'b0, pos} + {1'b0, inc};
    if (({1'b0, p2[15:0]} + {1'b0, endAddr}) >= 17'h10000)
        p2 = p2 + {1'b0, endAddr} + {1'b0, loopAddr};
    return p2[15:0];
endfunction

// ═══════════════════════════════════════════════════════════════════════════
// Shared SDRAM requesters.  Ownership is disjoint by schedule (slot FSM during
// slot windows, service FSM in the service window / granted idle tails), so a
// simple OR-mux is safe.  Issues are gated on !mem_busy (the msx.sv ch4 bridge
// edge-detects requests from IDLE only).
// ═══════════════════════════════════════════════════════════════════════════
logic        sl_rd_req;   logic [21:0] sl_rd_addr;    // slot FSM read
logic        sv_rd_req;   logic [21:0] sv_rd_addr;    // service FSM read
logic        sv_wr_req;   logic [21:0] sv_wr_addr;    // service FSM write
logic [7:0]  sv_wr_dat;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        mem_addr    <= '0;
        mem_rd_en   <= 1'b0;
        mem_wr_en   <= 1'b0;
        mem_wr_data <= '0;
    end else begin
        // 1-cycle pulses; addr/data HOLD until next issue (bridge + SDRAM
        // sample them 1-2 cycles after the pulse).
        mem_rd_en <= 1'b0;
        mem_wr_en <= 1'b0;
        if (sl_rd_req) begin
            mem_addr  <= sl_rd_addr;
            mem_rd_en <= 1'b1;
        end else if (sv_rd_req) begin
            mem_addr  <= sv_rd_addr;
            mem_rd_en <= 1'b1;
        end else if (sv_wr_req) begin
            mem_addr    <= sv_wr_addr;
            mem_wr_en   <= 1'b1;
            mem_wr_data <= sv_wr_dat;
        end
    end
end

// ═══════════════════════════════════════════════════════════════════════════
// Slot FSM — one slot start-to-finish inside its 72-cycle window
// ═══════════════════════════════════════════════════════════════════════════
typedef enum logic [4:0] {
    SL_IDLE, SL_LOAD, SL_VIB, SL_VIB2, SL_STEP, SL_ADV, SL_POSB, SL_ADDR, SL_CHIT,
    SL_F_ISSUE, SL_F_WAIT, SL_DECODE, SL_INTERP, SL_EGRATE, SL_EGROM,
    SL_EGSTEP, SL_GAIN, SL_MUL1, SL_MUL2, SL_PAN, SL_ACC, SL_DONE, SL_STALL_HDR
} sl_state_t;
sl_state_t sl_state;

// Working registers for the in-flight slot
slot_regs_t   w_regs;
slot_header_t w_hdr;
slot_dyn_t    w_dyn;
logic [4:0]   w_slot;
logic         w_edge;                  // key-on edge (incl. retrig)
logic         w_posrst;   // dispatched copy of pos_rst[slot]
logic signed [15:0] w_vib;
logic [9:0]   w_vib_mag;               // |lfo offset| × depth (compute_vib stage 1)
logic         w_vib_neg;
logic [31:0]  w_step;
logic [15:0]  w_pos2, w_ptr2, w_posb;
logic [21:0]  w_a0, w_a1, w_a2;       // registered byte addrs of sample A
logic [21:0]  w_b0, w_b1, w_b2;       // registered byte addrs of sample B
logic         w_need_b;                // B bytes not covered by A's words
// fetched words: 0:wA0 1:wA0+1 2:wB0 3:wB0+1
logic [15:0]  w_word [0:3];
logic [1:0]   w_fidx;                  // fetch index 0..3
logic [1:0]   w_fcnt;                  // number of fetches to do (2 or 4) - 1
logic signed [15:0] w_sa, w_sb, w_interp;
logic [5:0]   w_rate;
logic [7:0]   w_shift, w_inc;
logic         w_do_upd;
logic [9:0]   w_new_vol;
logic [2:0]   w_new_state;
logic [8:0]   w_am;
// value ranges are ±0x8000 (gain = (0x8000·vmul)>>>vsh ≤ 0x8000; each cascaded
// ×gain>>>15 keeps |x| ≤ 0x8000) — 17-bit signed keeps the per-stage multiplier
// shallow (the 32×32 version missed clk_sdram by 0.28 ns).
logic signed [16:0] w_gain_e, w_gain_t;
logic signed [16:0] w_inner, w_vol_sample;
logic signed [23:0] w_l, w_r;

logic signed [23:0] accum_l, accum_r;

// ── Per-slot fetched-word cache ─────────────────────────────────────────────
// Low-pitched voices advance <1 sample per frame, so the SAME memory words are
// re-read every frame.  Cache the (up to) 4 fetched words per slot, tagged by
// ABSOLUTE word address (so stale data is impossible for ROM); invalidated
// wholesale on any CPU sample-RAM write.  This removes most SDRAM traffic for
// sustained voices — the property that lets 24 slots survive heavy ch2
// contention (v2 learned this the hard way).
logic [20:0] cache_tagA [0:23];
logic [20:0] cache_tagB [0:23];
logic [15:0] cache_w0 [0:23], cache_w1 [0:23], cache_w2 [0:23], cache_w3 [0:23];
logic [23:0] cache_vld;
// Did the fill that populated this entry actually FETCH the B pair?  A partial fill
// (need_b==0) still stores cache_w2/w3 from the shared w_word[] regs (possibly another
// slot's leftovers) and a cache_tagB, so a later need_b==1 request could match both tags
// and consume words that were never read.
logic [23:0] cache_hasb;
// Sequential cache-invalidate sweep state (see the walk in the slot always_ff).
logic [20:0] inv_word;
logic  [4:0] inv_idx;
logic        inv_run;
// Periodic cache-scrub round-robin pointer (see scrub block in the slot FSM).
logic [4:0]  cache_rr;

// CPU mem service request lines (driven by the CPU-mem block below; serviced
// by the service FSM and opportunistically in slot-window idle tails)
logic        cpu_rd_pend, cpu_wr_pend, cpu_rd_outstanding;
logic [23:0] cpu_mem_adr;
logic [7:0]  cpu_wr_data_latch;
logic        cpu_rd_issue, cpu_wr_issue;   // 1-cycle: service grants

// byte pick helper: select byte at address X from the fetched words
function automatic [7:0] pick_byte(
    input [21:0] x,
    input [21:0] a0, input [21:0] b0,
    input [15:0] wd0, input [15:0] wd1, input [15:0] wd2, input [15:0] wd3
);
    logic [20:0] wx, wa, wb;
    wx = x[21:1]; wa = a0[21:1]; wb = b0[21:1];
    if      (wx == wa)          return x[0] ? wd0[15:8] : wd0[7:0];
    else if (wx == wa + 21'd1)  return x[0] ? wd1[15:8] : wd1[7:0];
    else if (wx == wb)          return x[0] ? wd2[15:8] : wd2[7:0];
    else                        return x[0] ? wd3[15:8] : wd3[7:0];
endfunction

wire [21:0] addr_a0 = byte_addr(w_hdr.startAddr, w_pos2, w_hdr.bits, 2'd0);
wire [21:0] addr_a1 = byte_addr(w_hdr.startAddr, w_pos2, w_hdr.bits, 2'd1);
wire [21:0] addr_a2 = byte_addr(w_hdr.startAddr, w_pos2, w_hdr.bits, 2'd2);
wire [21:0] addr_b0 = byte_addr(w_hdr.startAddr, w_posb, w_hdr.bits, 2'd0);
wire [21:0] addr_b1 = byte_addr(w_hdr.startAddr, w_posb, w_hdr.bits, 2'd1);
wire [21:0] addr_b2 = byte_addr(w_hdr.startAddr, w_posb, w_hdr.bits, 2'd2);

// EG rate selection (v2 d1a semantics)
function automatic [5:0] eg_rate_sel(
    input slot_regs_t r,
    input [2:0]       st,
    input [9:0]       ev,
    input logic       edge_now
);
    if (edge_now)
        return calc_eg_rate(r.ar, r.rc, r.oct, r.fn);
    case (st)
        EG_ATT: return calc_eg_rate (r.ar,  r.rc, r.oct, r.fn);
        EG_DEC: return calc_decay_rate(r.d1r, r.rc, r.damp, r.prvb, ev, r.oct, r.fn);
        EG_SUS: return calc_decay_rate(r.d2r, r.rc, r.damp, r.prvb, ev, r.oct, r.fn);
        EG_REL: return calc_decay_rate(r.rr,  r.rc, r.damp, r.prvb, ev, r.oct, r.fn);
        default: return 6'd0;
    endcase
endfunction

// Sequential dispatch: the next slot starts as soon as the previous one
// finishes (variable-length turns).  A long SDRAM stall delays later slots
// instead of corrupting the current one; slots that don't fit before the
// frame-end CPU reserve are skipped for this frame (graceful degradation).
wire dispatch_now = (sl_state == SL_IDLE) && (cur_slot < 5'd24) && !in_reserve
                    && !sample_start;
wire [4:0]  ld_slot = cur_slot;
// whole-struct intermediates (iverilog can't access .field on a variable-
// indexed unpacked array element — same workaround as v2)
slot_regs_t ld_regs_c;
slot_dyn_t  ld_dyn_c;
always_comb begin
    ld_regs_c = ram_regs[ld_slot];
    ld_dyn_c  = ram_dyn[ld_slot];
end
wire        ld_edge_w = (ld_regs_c.keyon & ~key_on_prev[ld_slot])
                      | key_retrig[ld_slot];
wire        ld_run    = ((ld_dyn_c.env_state != EG_OFF) | ld_edge_w)
                      & ~hf_pending[ld_slot];
// wants to run, but its wave-header re-fetch is still pending → must stall and
// fetch the new header BEFORE playing (else the onset plays the stale prev-wave
// header = the direction-dependency glitch).
wire        ld_want_hdr = ((ld_dyn_c.env_state != EG_OFF) | ld_edge_w)
                        & hf_pending[ld_slot];

// opportunistic CPU service grant while the slot FSM idles between slots
wire sl_tail_idle = (sl_state == SL_IDLE);
// a slot is stalled waiting for its eager header fetch → let the service FSM
// run the header fetch NOW (the slot isn't touching the bus while stalled).
wire slot_stalled_hdr = (sl_state == SL_STALL_HDR);

always_ff @(posedge clk or negedge rst_n) begin
    logic [15:0] ptr_n;
    logic [15:0] inc_n;
    logic [10:0] env_idx;
    logic [9:0]  tl_idx;
    logic [7:0]  vmul_e, vmul_t;
    logic [4:0]  vsh_e, vsh_t;
    logic [10:0] vol_add;
    logic [5:0]  pl_g, pr_g;
    logic signed [33:0] mul_w;     // explicit wide product (the 17' cast must
                                   // not narrow the multiply context pre-shift)
    slot_dyn_t   dyn_wb;

    if (!rst_n) begin
        sl_state  <= SL_IDLE;
        sl_rd_req <= 1'b0;
        cur_slot  <= '0;     // (was uninitialized → X: frame-0 slots_done never
                             //  true → header fetches deferred one frame)
        accum_l   <= '0;
        accum_r   <= '0;
        cache_vld <= '0;
        cache_hasb <= '0;
        inv_run    <= 1'b0;
        inv_idx    <= 5'd0;
        cache_rr  <= '0;
        key_on_prev <= '0;
        pcm_left  <= '0;
        pcm_right <= '0;
        pcm_valid <= 1'b0;
        dyn_wb.pos       = 16'd0;
        dyn_wb.stepPtr   = 16'd0;
        dyn_wb.env_vol   = MAX_ATT_INDEX;
        dyn_wb.env_state = EG_OFF;
        dyn_wb.lfo_cnt   = 18'd0;
        for (int i = 0; i < 24; i++) ram_dyn[i] <= dyn_wb;
    end else begin
        sl_rd_req <= 1'b0;
        pcm_valid <= 1'b0;

        // CPU wrote sample RAM -> invalidate ONLY the entries whose cached words
        // cover the written address.  A blanket flush is catastrophic under a
        // streaming upload: a driver may rewrite a wave-table header block on every
        // screen transition and do it BEFORE muting, so all 24 voices are still keyed
        // on; flushing every cache on every byte then forces all of them to refetch
        // for the whole upload, and ch4 is LAST in the SDRAM arbiter -> voices lose
        // their slot budget and drop out (MSXdev25 GoFigure: 1536 bytes ~ 18 ms).
        //
        // Done SEQUENTIALLY: latch the written word address and walk one entry per
        // cycle with a SINGLE comparator.  CPU wave writes arrive at most ~1 per frame
        // (12 us pacing) so the 24-cycle sweep costs 1.2% of a 1948-cycle frame and
        // always finishes long before the next write, while the parallel form cost
        // ~2000 ALMs (24 entries x 4 words x 21 bits) and ate into the design's
        // worst-case slack.  An entry caches FOUR words -- w0@tagA, w1@tagA+1,
        // w2@tagB, w3@tagB+1 -- so all four are compared; tagB only counts when the
        // fill actually fetched the B pair (cache_hasb).
        if (cpu_wr_issue) begin
            inv_word <= sv_wr_addr[21:1];
            inv_idx  <= 5'd0;
            inv_run  <= 1'b1;
        end else if (inv_run) begin
            if (cache_tagA[inv_idx[4:0]]           == inv_word
             || (cache_tagA[inv_idx[4:0]] + 21'd1) == inv_word
             || (cache_hasb[inv_idx[4:0]]
                 && (cache_tagB[inv_idx[4:0]]           == inv_word
                  || (cache_tagB[inv_idx[4:0]] + 21'd1) == inv_word)))
                cache_vld[inv_idx[4:0]] <= 1'b0;
            if (inv_idx == 5'd23) inv_run <= 1'b0;
            else                  inv_idx <= inv_idx + 5'd1;
        end

        // ── frame output (independent of slot FSM state) ──
        if (sample_start) begin
            logic signed [23:0] osl, osr;
            logic [1:0] sh;
            sh  = 2'd3 - pcm_vol;
            osl = pcm_mix_gain(pcm_mix_l, accum_l >>> sh);
            osr = pcm_mix_gain(pcm_mix_r, accum_r >>> sh);
            pcm_left  <= (osl > 24'sd32767)  ? 16'sh7FFF :
                         (osl < -24'sd32768) ? 16'sh8000 : osl[15:0];
            pcm_right <= (osr > 24'sd32767)  ? 16'sh7FFF :
                         (osr < -24'sd32768) ? 16'sh8000 : osr[15:0];
            pcm_valid <= 1'b1;
            accum_l   <= '0;
            accum_r   <= '0;
            sl_state  <= SL_IDLE;     // abandon any in-flight slot at frame end
            cur_slot  <= '0;

            // ── Periodic cache scrub (bug mitigation, NOT a root fix) ──────────
            // A rare MARGINAL physical ch4 read can be latched into one slot's
            // word cache under a VALID tag.  For a sustained low-pitch voice the
            // absolute-address tag stays constant, so that single corrupt word
            // would replay every frame for SECONDS (one channel breaks up) until
            // pos advances past the tag or a CPU sample write invalidates the
            // cache.  To bound that, force-refetch one slot's cache every 32
            // frames in round-robin: every cached entry is refreshed within
            // 24×32 = 768 frames ≈ 17 ms, turning a multi-second breakup into a
            // brief tick.  The refetch returns identical data on a good read, so
            // playback (and the golden output) is bit-exact unchanged; this only
            // adds one forced refetch per 32 frames (~0.13 % extra ch4 reads).
            // The slot FSM is forced idle during the frame-end reserve, so no
            // cache_vld SET races this clear at sample_start.
            if (eg_cnt[4:0] == 5'd0) begin
                cache_vld[cache_rr] <= 1'b0;
                cache_rr <= (cache_rr == 5'd23) ? 5'd0 : cache_rr + 5'd1;
            end
        end

        case (sl_state)
            SL_IDLE: begin
                if (dispatch_now) begin
                    if (ld_run) begin
                        cur_slot <= cur_slot + 5'd1; // consume this slot's turn
                        w_slot <= ld_slot;
                        w_regs <= ram_regs[ld_slot];
                        w_hdr  <= ram_header[ld_slot];
                        w_dyn  <= ram_dyn[ld_slot];
                        w_edge <= ld_edge_w;
                        w_posrst <= pos_rst[ld_slot];
                        sl_state <= SL_VIB;
                    end else if (ld_want_hdr) begin
                        // wants to run but header re-fetch pending: stall (turn
                        // NOT consumed) and let the service FSM fetch the new
                        // header NOW, then play with it — openMSX-like eager load
                        // instead of deferring to the frame tail (= the onset fix).
                        sl_state <= SL_STALL_HDR;
                    end else begin
                        cur_slot <= cur_slot + 5'd1; // EG_OFF & no edge → skip
                    end
                end
            end

            SL_STALL_HDR: begin
                // hold until the service FSM stored this slot's header
                // (hf_pending clears on store), then dispatch with the new header.
                if (!hf_pending[ld_slot]) begin
                    cur_slot <= cur_slot + 5'd1;
                    w_slot <= ld_slot;
                    w_regs <= ram_regs[ld_slot];
                    w_hdr  <= ram_header[ld_slot];
                    w_dyn  <= ram_dyn[ld_slot];
                    w_edge <= ld_edge_w;
                    w_posrst <= pos_rst[ld_slot];
                    sl_state <= SL_VIB;
                end
            end

            // compute_vib split across two cycles — the full triangle-fold +
            // depth-mult + ×43691-reciprocal chain missed clk_sdram by ~1 ns
            // as a single cycle.
            SL_VIB: begin
                logic [5:0] fm6;
                logic [4:0] mag_fm;
                fm6 = w_dyn.lfo_cnt[17:12];
                if (fm6[4]) fm6 = fm6 ^ 6'h1F;            // triangle fold
                mag_fm    = fm6[5] ? (5'(fm6 & 6'h0F)) : {1'b0, fm6[3:0]};
                w_vib_neg <= fm6[5];
                w_vib_mag <= (w_regs.lfo_active && w_regs.vib != 3'd0)
                           ? 10'(mag_fm * vib_depth_rom(w_regs.vib))
                           : 10'd0;
                sl_state <= SL_VIB2;
            end

            SL_VIB2: begin
                logic [25:0] vscaled;
                logic [9:0]  vq;
                vscaled = w_vib_mag * 26'd43691;          // exact ÷12 reciprocal
                vq      = vscaled[25:16] >> 3;
                w_vib   <= w_vib_neg ? -$signed({6'd0, vq}) : $signed({6'd0, vq});
                sl_state <= SL_STEP;
            end

            SL_STEP: begin
                w_step <= calc_step(w_regs.oct, w_regs.fn, w_vib);
                sl_state <= SL_ADV;
            end

            SL_ADV: begin
                if (w_edge || w_posrst) begin
                    // key-on (or retrig): restart sample (v2: pos/stepPtr reset)
                    w_pos2 <= 16'd0;
                    w_ptr2 <= 16'd0;
                end else begin
                    ptr_n = w_dyn.stepPtr + w_step[15:0];
                    if (w_step[31:16] != 16'd0 || ptr_n < w_dyn.stepPtr) begin
                        inc_n = w_step[31:16] + (ptr_n < w_dyn.stepPtr ? 16'd1 : 16'd0);
                        w_pos2 <= next_pos_calc(w_dyn.pos, inc_n,
                                                w_hdr.endAddr, w_hdr.loopAddr);
                    end else
                        w_pos2 <= w_dyn.pos;
                    w_ptr2 <= ptr_n;
                end
                sl_state <= SL_POSB;
            end

            SL_POSB: begin
                w_posb <= next_pos_calc(w_pos2, 16'd1, w_hdr.endAddr, w_hdr.loopAddr);
                sl_state <= SL_ADDR;
            end

            SL_ADDR: begin
                // register all six byte addresses — byte_addr's ×3 multiply
                // (12-bit format) must not chain into the cache compare or
                // the decode muxes (failed clk_sdram by ~0.5 ns when it did)
                w_a0 <= addr_a0;  w_a1 <= addr_a1;  w_a2 <= addr_a2;
                w_b0 <= addr_b0;  w_b1 <= addr_b1;  w_b2 <= addr_b2;
                sl_state <= SL_CHIT;
            end

            SL_CHIT: begin
                logic need_b_c, hit_c;
                logic [21:0] b_last;
                // B covered by A's two words iff its bytes lie in [a0&~1, a0&~1+3].
                // The LAST byte of sample B is format-dependent: b1 for 16-bit
                // (byte_addr's b2 aliases b0 there), b2 for 12-bit, b0 for 8-bit.
                // Using b2 unconditionally missed b1 for 16-bit samples at ODD
                // start addresses → un-fetched word selected in SL_DECODE (X).
                b_last = (w_hdr.bits == 2'd2) ? w_b1 : w_b2;
                need_b_c = !((w_b0[21:1] >= w_a0[21:1]) &&
                             (b_last[21:1] <= w_a0[21:1] + 21'd1));
                w_need_b <= need_b_c;
                w_fidx   <= 2'd0;
                hit_c = cache_vld[w_slot]
                      && (cache_tagA[w_slot] == w_a0[21:1])
                      && (!need_b_c || (cache_hasb[w_slot]
                                        && cache_tagB[w_slot] == w_b0[21:1]));
                if (hit_c) begin
                    w_word[0] <= cache_w0[w_slot];
                    w_word[1] <= cache_w1[w_slot];
                    w_word[2] <= cache_w2[w_slot];
                    w_word[3] <= cache_w3[w_slot];
                    sl_state  <= SL_DECODE;
                end else
                    sl_state <= SL_F_ISSUE;
            end

            SL_F_ISSUE: begin
                if (!mem_busy && !mem_rd_en) begin
                    case (w_fidx)
                        2'd0: sl_rd_addr <= {w_a0[21:1], 1'b0};
                        2'd1: sl_rd_addr <= {w_a0[21:1] + 21'd1, 1'b0};
                        2'd2: sl_rd_addr <= {w_b0[21:1], 1'b0};
                        2'd3: sl_rd_addr <= {w_b0[21:1] + 21'd1, 1'b0};
                    endcase
                    sl_rd_req <= 1'b1;
                    sl_state  <= SL_F_WAIT;
                end
            end

            SL_F_WAIT: begin
                if (mem_rd_valid) begin
                    w_word[w_fidx] <= mem_rd_data16;
                    if ((w_fidx == 2'd1 && !w_need_b) || w_fidx == 2'd3) begin
                        // fill the slot's cache entry
                        cache_tagA[w_slot] <= w_a0[21:1];
                        cache_tagB[w_slot] <= w_b0[21:1];
                        cache_w0[w_slot] <= (w_fidx == 2'd0) ? mem_rd_data16 : w_word[0];
                        cache_w1[w_slot] <= (w_fidx == 2'd1) ? mem_rd_data16 : w_word[1];
                        cache_w2[w_slot] <= (w_fidx == 2'd2) ? mem_rd_data16 : w_word[2];
                        cache_w3[w_slot] <= (w_fidx == 2'd3) ? mem_rd_data16 : w_word[3];
                        // Don't validate a fill that completed while an invalidate
                        // sweep is in flight: its words may predate the CPU write the
                        // sweep is reacting to, and the sweep may already have passed
                        // this entry.  Costs at most one refetch per CPU write (which
                        // arrive ~1 per frame) and is stricter than the old 1-cycle
                        // blanket flush, which could re-validate such a fill.
                        cache_vld[w_slot] <= ~inv_run;
                        cache_hasb[w_slot] <= w_need_b;
                        sl_state <= SL_DECODE;
                    end else begin
                        w_fidx   <= w_fidx + 2'd1;
                        sl_state <= SL_F_ISSUE;
                    end
                end
            end

            SL_DECODE: begin
                w_sa <= decode_sample(
                    pick_byte(w_a0, w_a0, w_b0, w_word[0], w_word[1], w_word[2], w_word[3]),
                    pick_byte(w_a1, w_a0, w_b0, w_word[0], w_word[1], w_word[2], w_word[3]),
                    pick_byte(w_a2, w_a0, w_b0, w_word[0], w_word[1], w_word[2], w_word[3]),
                    w_pos2, w_hdr.bits);
                w_sb <= decode_sample(
                    pick_byte(w_b0, w_a0, w_b0, w_word[0], w_word[1], w_word[2], w_word[3]),
                    pick_byte(w_b1, w_a0, w_b0, w_word[0], w_word[1], w_word[2], w_word[3]),
                    pick_byte(w_b2, w_a0, w_b0, w_word[0], w_word[1], w_word[2], w_word[3]),
                    w_posb, w_hdr.bits);
                sl_state <= SL_INTERP;
            end

            SL_INTERP: begin
                w_interp <= calc_interp(w_sa, w_sb, w_ptr2);
                sl_state <= SL_EGRATE;
            end

            SL_EGRATE: begin
                w_rate <= eg_rate_sel(w_regs, w_dyn.env_state, w_dyn.env_vol, w_edge);
                sl_state <= SL_EGROM;
            end

            SL_EGROM: begin
                w_shift  <= eg_rate_shift_rom(w_rate);
                w_do_upd <= eg_do_update(eg_cnt, eg_rate_shift_rom(w_rate));
                w_inc    <= eg_inc_rom(7'(eg_rate_select_rom(w_rate)
                                       + {5'd0, eg_phase(eg_cnt, eg_rate_shift_rom(w_rate))}));
                sl_state <= SL_EGSTEP;
            end

            SL_EGSTEP: begin
                // v2 d1b transition logic, verbatim semantics
                w_new_vol   <= w_dyn.env_vol;
                w_new_state <= w_dyn.env_state;
                if (w_edge) begin
                    w_new_vol <= MAX_ATT_INDEX;
                    if (w_rate < 6'd63) w_new_state <= EG_ATT;
                    else begin
                        w_new_vol   <= MIN_ATT_INDEX;
                        w_new_state <= (w_regs.dl_idx != 4'h0) ? EG_DEC : EG_SUS;
                    end
                end else if (!w_regs.keyon && w_dyn.env_state != EG_OFF
                                           && w_dyn.env_state != EG_REL) begin
                    w_new_state <= EG_REL;
                end else begin
                    case (w_dyn.env_state)
                        EG_ATT: if (w_rate < 6'd63 && w_do_upd) begin
                            w_new_vol <= calc_attack_step(w_dyn.env_vol, w_inc);
                            if (calc_attack_step(w_dyn.env_vol, w_inc) <= MIN_ATT_INDEX) begin
                                w_new_vol   <= MIN_ATT_INDEX;
                                w_new_state <= (w_regs.dl_idx != 4'h0) ? EG_DEC : EG_SUS;
                            end
                        end
                        EG_DEC: if (w_do_upd) begin
                            vol_add = {1'b0, w_dyn.env_vol} + {3'd0, w_inc};
                            w_new_vol <= (vol_add > 11'h3FF) ? 10'h3FF : vol_add[9:0];
                            if (((vol_add > 11'h3FF) ? 10'h3FF : vol_add[9:0])
                                >= dl_tab_rom(w_regs.dl_idx)) begin
                                w_new_state <= (vol_add < {1'b0, MAX_ATT_INDEX})
                                             ? EG_SUS : EG_OFF;
                            end
                        end
                        EG_SUS, EG_REL: if (w_do_upd) begin
                            vol_add = {1'b0, w_dyn.env_vol} + {3'd0, w_inc};
                            if (vol_add >= {1'b0, MAX_ATT_INDEX}) begin
                                w_new_vol   <= MAX_ATT_INDEX;
                                w_new_state <= EG_OFF;
                            end else
                                w_new_vol <= vol_add[9:0];
                        end
                        default: ;
                    endcase
                end
                // tremolo (current lfo_cnt, pre-advance — ref order)
                w_am <= (w_regs.lfo_active && w_regs.am != 3'd0)
                      ? compute_am(w_dyn.lfo_cnt, w_regs.am)
                      : 9'd0;
                sl_state <= SL_GAIN;
            end

            SL_GAIN: begin
                // env + TL as two independent gains, each clipped at 0x280 (ref)
                env_idx = {1'b0, w_new_vol} + {2'd0, w_am};
                if (env_idx > 11'h280) env_idx = 11'h280;
                tl_idx  = {tl_cur[w_slot], 2'b00};
                vmul_e  = 8'h80 - {2'b0, env_idx[5:0]};
                vsh_e   = 5'(4'd7 + {1'b0, env_idx[9:6]});
                vmul_t  = 8'h80 - {2'b0, tl_idx[5:0]};
                vsh_t   = 5'(4'd7 + {1'b0, tl_idx[9:6]});
                w_gain_e <= (env_idx >= 11'h280) ? 17'sd0
                          : 17'((32'sh8000 * $signed({1'b0, vmul_e})) >>> vsh_e);
                w_gain_t <= (tl_idx  >= 10'h280) ? 17'sd0
                          : 17'((32'sh8000 * $signed({1'b0, vmul_t})) >>> vsh_t);
                sl_state <= SL_MUL1;
            end

            SL_MUL1: begin
                mul_w   = $signed(w_interp) * w_gain_e;
                w_inner <= 17'(mul_w >>> 15);
                sl_state <= SL_MUL2;
            end

            SL_MUL2: begin
                mul_w        = w_inner * w_gain_t;
                w_vol_sample <= 17'(mul_w >>> 15);
                sl_state <= SL_PAN;
            end

            SL_PAN: begin
                pl_g = pan_att_left (w_regs.pan);
                pr_g = pan_att_right(w_regs.pan);
                mul_w = w_vol_sample * $signed({1'b0, pl_g});
                w_l  <= 24'(mul_w >>> 5);
                mul_w = w_vol_sample * $signed({1'b0, pr_g});
                w_r  <= 24'(mul_w >>> 5);
                sl_state <= SL_ACC;
            end

            SL_ACC: begin
                accum_l <= accum_l + w_l;
                accum_r <= accum_r + w_r;
                // dyn writeback
                dyn_wb.pos       = w_pos2;
                dyn_wb.stepPtr   = w_ptr2;
                dyn_wb.env_vol   = w_new_vol;
                dyn_wb.env_state = w_new_state;
                dyn_wb.lfo_cnt   = w_regs.lfo_active
                                 ? ((w_dyn.lfo_cnt
                                     + {12'd0, lfo_period_rom(w_regs.lfo_speed)})
                                    & 18'h3FFFF)
                                 : 18'd0;
                ram_dyn[w_slot]     <= dyn_wb;
                key_on_prev[w_slot] <= w_regs.keyon;
                sl_state <= SL_DONE;
            end

            SL_DONE: sl_state <= SL_IDLE;
            default: sl_state <= SL_IDLE;
        endcase

        // Frame-end CPU reserve: abandon the in-flight slot so the CPU mem op
        // service always gets its guaranteed turn (no writeback — the slot
        // resumes from unchanged state next frame).
        if (in_reserve && sl_state != SL_IDLE)
            sl_state <= SL_IDLE;
    end
end

// ═══════════════════════════════════════════════════════════════════════════
// Service FSM — CPU mem op (unconditional, every frame) then header fetch.
// Also granted opportunistically while the slot FSM idles between slots.
// ═══════════════════════════════════════════════════════════════════════════
typedef enum logic [3:0] {
    SV_IDLE, SV_CPU_RD_ISSUE, SV_CPU_RD_WAIT, SV_CPU_WR_ISSUE, SV_CPU_WR_SETTLE,
    SV_HDR_PICK, SV_HDR_ISSUE, SV_HDR_WAIT, SV_HDR_STORE, SV_HDR_DRAIN, SV_HDR_DRAIN2
} sv_state_t;
sv_state_t sv_state;
logic [1:0]  sv_settle;

logic [4:0]  hf_cur_slot;
logic [8:0]  hf_cur_wave;
logic [2:0]  hf_widx;                 // header word index 0..6
logic [7:0]  hf_buf [0:13];           // 12 header bytes (+2 pad from 7 words)
logic [21:0] hf_base;
logic        hf_store_now;

// lowest pending slot (priority encoder)
logic       hf_found;
logic [4:0] hf_pick;
slot_regs_t hf_pick_regs_c;
wire [8:0]  hf_pick_wave_c = hf_pick_regs_c.wave;
always_comb begin
    hf_found = 1'b0;
    hf_pick  = 5'd0;
    for (int i = 23; i >= 0; i--)
        if (hf_pending[i]) begin
            hf_found = 1'b1;
            hf_pick  = 5'(i);
        end
end
always_comb hf_pick_regs_c = ram_regs[hf_pick];

wire [21:0] hf_base_calc = (hf_cur_wave < 9'd384 || wavetblhdr == 3'd0)
    ? 22'({13'd0, hf_cur_wave} * 22'd12)
    : 22'({wavetblhdr, 19'd0} + ({13'd0, (hf_cur_wave - 9'd384)} * 22'd12));

// service may run: in the service window always; in slot-window tails for CPU
// ops only (header fetch is too long to guarantee completion there).
// CPU op service: in the frame-end reserve ALWAYS (the slot FSM has been
// forced idle there), and opportunistically between slots.
// cur_slot increments at DISPATCH, so it reaches 24 while slot 23 is still running
// (and possibly mid-SDRAM-fetch).  Starting a header fetch then makes the untagged
// SV_HDR_WAIT latch the SLOT's sample word as header bytes -> garbage startAddr /
// loopAddr / bits plus a garbage envelope backfill on that voice.  Require the slot
// FSM to be idle as well.
wire slots_done  = (cur_slot == 5'd24) && (sl_state == SL_IDLE);
wire sv_can_cpu  = in_reserve | sl_tail_idle;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        sv_state   <= SV_IDLE;
        sv_settle  <= 2'd0;
        sv_rd_req  <= 1'b0;
        sv_wr_req  <= 1'b0;
        cpu_rd_issue <= 1'b0;
        cpu_wr_issue <= 1'b0;
        hf_widx    <= '0;
        hf_store_now <= 1'b0;
        hf_cur_slot <= '0;
        hf_cur_wave <= '0;
        hf_base    <= '0;
    end else begin
        sv_rd_req    <= 1'b0;
        sv_wr_req    <= 1'b0;
        cpu_rd_issue <= 1'b0;
        cpu_wr_issue <= 1'b0;
        hf_store_now <= 1'b0;

        case (sv_state)
            SV_IDLE: begin
                if (sv_can_cpu && cpu_rd_pend)
                    sv_state <= SV_CPU_RD_ISSUE;
                else if (sv_can_cpu && cpu_wr_pend)
                    sv_state <= SV_CPU_WR_ISSUE;
                else if (hf_found && frame_cycle < CPU_RESERVE_AT - 130
                         && (slot_stalled_hdr || slots_done)) begin
                    // need ~7×15+parse ≈ 110 cycles — only start when they fit.
                    // slot_stalled_hdr = a waiting slot wants its header NOW
                    // (eager, mid-frame); slots_done = the original frame-tail
                    // cleanup for pending-but-skipped (EG_OFF) slots.
                    hf_cur_slot <= hf_pick;
                    hf_cur_wave <= hf_pick_wave_c;
                    hf_widx     <= '0;
                    sv_state    <= SV_HDR_PICK;
                end
            end

            // ── CPU mem read (reg 0x06 prefetch) ──
            SV_CPU_RD_ISSUE: begin
                if (!mem_busy && !mem_rd_en) begin
                    sv_rd_addr   <= cpu_mem_adr[21:0];
                    sv_rd_req    <= 1'b1;
                    cpu_rd_issue <= 1'b1;       // clears pend, sets outstanding
                    sv_state     <= SV_CPU_RD_WAIT;
                end
            end
            SV_CPU_RD_WAIT: begin
                if (mem_rd_valid) sv_state <= SV_IDLE;   // buf latched below
            end

            // ── CPU mem write (reg 0x06) ──
            SV_CPU_WR_ISSUE: begin
                if (!mem_busy && !mem_rd_en && !mem_wr_en) begin
                    sv_wr_addr   <= cpu_mem_adr[21:0];
                    sv_wr_dat    <= cpu_wr_data_latch;
                    sv_wr_req    <= 1'b1;
                    cpu_wr_issue <= 1'b1;       // clears pend, bumps address
                    sv_state     <= SV_CPU_WR_SETTLE;
                end
            end
            SV_CPU_WR_SETTLE: begin
                // 2-cycle gap so the bridge leaves IDLE before the next issue
                // gate samples mem_busy.  Do NOT wait for mem_busy to RISE —
                // a zero-latency memory (TB model) never raises it (wedge).
                sv_settle <= sv_settle + 2'd1;
                if (sv_settle == 2'd2) begin
                    sv_settle <= 2'd0;
                    sv_state  <= SV_IDLE;
                end
            end

            // ── header fetch: 7 word reads cover 12 bytes at any alignment ──
            SV_HDR_PICK: begin
                hf_base  <= hf_base_calc;
                sv_state <= SV_HDR_ISSUE;
            end
            SV_HDR_ISSUE: begin
                if (!mem_busy && !mem_rd_en) begin
                    sv_rd_addr <= {hf_base[21:1] + 21'(hf_widx), 1'b0};
                    sv_rd_req  <= 1'b1;
                    sv_state   <= SV_HDR_WAIT;
                end
            end
            SV_HDR_WAIT: begin
                if (mem_rd_valid) begin
                    // distribute the word's two bytes into hf_buf by offset
                    logic [21:0] wbyte0;
                    logic signed [22:0] off;
                    wbyte0 = {hf_base[21:1] + 21'(hf_widx), 1'b0};
                    off    = $signed({1'b0, wbyte0}) - $signed({1'b0, hf_base});
                    if (off >= 0 && off <= 13)      hf_buf[off[3:0]]      <= mem_rd_data16[7:0];
                    if (off+1 >= 0 && off+1 <= 13)  hf_buf[off[3:0]+4'd1] <= mem_rd_data16[15:8];
                    if (hf_widx == 3'd6) sv_state <= SV_HDR_STORE;
                    else begin
                        hf_widx  <= hf_widx + 3'd1;
                        sv_state <= SV_HDR_ISSUE;
                    end
                end
            end
            SV_HDR_STORE: begin
                hf_store_now <= 1'b1;
                sv_state     <= SV_HDR_DRAIN;
            end
            // 1-cycle drain so hf_pending (cleared by hf_store_now, registered)
            // is seen low when SV_IDLE re-checks the gate — else SV_IDLE re-fires
            // a spurious second fetch (harmless when slots idle, but in the eager
            // stall path it collides on the shared read bus with the now-resumed
            // slot's sample reads → corrupted header).
            // 2 drain cycles: a slot leaving SL_STALL_HDR needs two (hf_pending
            // clears, then sl_state moves), and with a single drain SV_IDLE re-armed
            // a fetch in the very cycle the resumed slot started reading samples.
            SV_HDR_DRAIN:  sv_state <= SV_HDR_DRAIN2;
            SV_HDR_DRAIN2: sv_state <= SV_IDLE;
            default: sv_state <= SV_IDLE;
        endcase
    end
end

// header store + reg backfill (v2 HF_STORE semantics)
slot_header_t hf_hdr_built;
always_comb begin
    hf_hdr_built.bits      = hf_buf[0][7:6];
    hf_hdr_built.startAddr = {hf_buf[0][5:0], hf_buf[1], hf_buf[2]};
    hf_hdr_built.loopAddr  = {hf_buf[3], hf_buf[4]};
    hf_hdr_built.endAddr   = {hf_buf[5], hf_buf[6]};
end

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        for (int i = 0; i < 24; i++) ram_header[i] <= '0;
    end else if (hf_store_now) begin
        ram_header[hf_cur_slot] <= hf_hdr_built;
    end
end

// ═══════════════════════════════════════════════════════════════════════════
// CPU register decode (v2, carried over) + HF backfill of bytes 7..11
// ═══════════════════════════════════════════════════════════════════════════
wire [4:0]  wr_snum  = (reg_addr >= 8'h08) ? 5'((reg_addr - 8'h08) % 8'd24) : 5'd0;
wire [3:0]  wr_field = (reg_addr >= 8'h08) ? 4'((reg_addr - 8'h08) / 8'd24) : 4'd0;
wire        wr_slot_reg = reg_wr && (reg_addr >= 8'h08) && (reg_addr <= 8'hF7);

always_ff @(posedge clk or negedge rst_n) begin
    slot_regs_t reg_upd;
    logic [6:0] tl_t;

    if (!rst_n) begin
        wavetblhdr <= '0;
        pcm_mix_l  <= 3'd0;
        pcm_mix_r  <= 3'd0;
        fm_mix_l   <= 3'd0;
        fm_mix_r   <= 3'd0;
        for (int i = 0; i < 24; i++) ram_regs[i] <= '0;
        for (int i = 0; i < 24; i++) bf_dirty[i] <= '0;
    end else begin
        if (reg_wr && reg_addr == 8'h02)
            wavetblhdr <= reg_data[4:2];
        if (reg_wr && reg_addr == 8'hF8) begin
            fm_mix_l  <= reg_data[2:0];
            fm_mix_r  <= reg_data[5:3];
        end
        if (reg_wr && reg_addr == 8'hF9) begin
            pcm_mix_l <= reg_data[2:0];
            pcm_mix_r <= reg_data[5:3];
        end
        if (wr_slot_reg) begin
            reg_upd = ram_regs[wr_snum];
            // dirty tracking for deferred header backfill
            case (wr_field)
                4'd0: bf_dirty[wr_snum] <= 5'b0;
                4'd5: bf_dirty[wr_snum][0] <= 1'b1;
                4'd6: bf_dirty[wr_snum][1] <= 1'b1;
                4'd7: bf_dirty[wr_snum][2] <= 1'b1;
                4'd8: bf_dirty[wr_snum][3] <= 1'b1;
                4'd9: bf_dirty[wr_snum][4] <= 1'b1;
                default: ;
            endcase
            case (wr_field)
                4'd0: reg_upd.wave[7:0] = reg_data[7:0];
                4'd1: begin
                    reg_upd.wave[8] = reg_data[0];
                    reg_upd.fn[6:0] = reg_data[7:1];
                end
                4'd2: begin
                    reg_upd.fn[9:7] = reg_data[2:0];
                    reg_upd.prvb    = reg_data[3];
                    reg_upd.oct     = $signed(reg_data[7:4]);
                end
                4'd3: begin
                    tl_t = reg_data[7:1];
                    reg_upd.tl = (tl_t != 7'h7F) ? {1'b0, tl_t} : 8'hFF;
                end
                4'd4: begin
                    reg_upd.pan        = reg_data[4] ? 4'd8 : reg_data[3:0];
                    reg_upd.damp       = reg_data[6];
                    reg_upd.keyon      = reg_data[7];
                    reg_upd.lfo_active = ~reg_data[5];
                end
                4'd5: begin
                    reg_upd.lfo_speed = reg_data[5:3];
                    reg_upd.vib       = reg_data[2:0];
                end
                4'd6: begin
                    reg_upd.ar  = reg_data[7:4];
                    reg_upd.d1r = reg_data[3:0];
                end
                4'd7: begin
                    reg_upd.dl_idx = reg_data[7:4];
                    reg_upd.d2r    = reg_data[3:0];
                end
                4'd8: begin
                    reg_upd.rc = reg_data[7:4];
                    reg_upd.rr = reg_data[3:0];
                end
                4'd9: reg_upd.am = reg_data[2:0];
                default: ;
            endcase
            ram_regs[wr_snum] <= reg_upd;
        end

        // HF backfill (header bytes 7..11 → slot envelope/LFO regs).  CPU
        // write to the SAME slot in the same cycle: backfill wins for its
        // fields (chip "don't access during LD" rule); different slot: both
        // land (separate array elements).
        if (hf_store_now) begin
            slot_regs_t hf_upd;
            logic [4:0] dly;
            if (wr_slot_reg && wr_snum == hf_cur_slot)
                hf_upd = reg_upd;
            else
                hf_upd = ram_regs[hf_cur_slot];
            dly = bf_dirty[hf_cur_slot];
            if (!dly[0]) begin
                hf_upd.lfo_speed = hf_buf[7][5:3];
                hf_upd.vib       = hf_buf[7][2:0];
            end
            if (!dly[1]) begin
                hf_upd.ar        = hf_buf[8][7:4];
                hf_upd.d1r       = hf_buf[8][3:0];
            end
            if (!dly[2]) begin
                hf_upd.dl_idx    = hf_buf[9][7:4];
                hf_upd.d2r       = hf_buf[9][3:0];
            end
            if (!dly[3]) begin
                hf_upd.rc        = hf_buf[10][7:4];
                hf_upd.rr        = hf_buf[10][3:0];
            end
            if (!dly[4])
                hf_upd.am        = hf_buf[11][2:0];
            ram_regs[hf_cur_slot] <= hf_upd;
        end
    end
end

// hf_pending: set on wave-LSB write only (openMSX case 0).  Field 1 changes
// wave bit8/FN but must NOT reload the header — the load happens when the
// LSB is written afterwards.  vgmplay's clock-compensation rewrites FN
// (fields 1/2) continuously; reloading here muted/reset slots every write.
wire wr_sets_hf = wr_slot_reg && (wr_field == 4'd0);
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) hf_pending <= '0;
    else begin
        if (hf_store_now)  hf_pending[hf_cur_slot] <= 1'b0;
        if (wr_sets_hf)    hf_pending[wr_snum]     <= 1'b1;  // set wins
    end
end

// key_retrig (v2, carried over): two sources matching openMSX writeRegDirect.
wire retrig_consume = (sl_state == SL_ACC);   // slot processed with edge consumed
always_ff @(posedge clk or negedge rst_n) begin
    slot_regs_t cur_r;
    logic       wr_retrig;
    cur_r = ram_regs[wr_snum];
    wr_retrig = wr_slot_reg && (
                    ((wr_field == 4'd4) && reg_data[7] && !cur_r.keyon)
                 || ((wr_field == 4'd0) && cur_r.keyon)
                );
    if (!rst_n) key_retrig <= '0;
    else begin
        if (retrig_consume && w_edge) key_retrig[w_slot] <= 1'b0;
        if (wr_retrig)                key_retrig[wr_snum] <= 1'b1;  // set wins
    end
    if (!rst_n) pos_rst <= '0;
    else begin
        if (retrig_consume && w_posrst) pos_rst[w_slot] <= 1'b0;
        if (wr_slot_reg && (wr_field == 4'd0) && !cur_r.keyon)
            pos_rst[wr_snum] <= 1'b1;                              // set wins
    end
end

// TL ramp (v2, carried over): one step per slot per frame, 9-sample phase.
wire wr_tl_load = wr_slot_reg && (wr_field == 4'd3) && reg_data[0];
always_ff @(posedge clk or negedge rst_n) begin
    slot_regs_t r_tl;
    r_tl = ram_regs[ld_slot];
    if (!rst_n) begin
        for (int i = 0; i < 24; i++) tl_cur[i] <= 8'd0;
        tl_load <= '0;
    end else begin
        if (dispatch_now) begin
            if (tl_load[ld_slot])
                tl_cur[ld_slot] <= r_tl.tl;
            else if (tl_int_cnt == 4'd0) begin
                if (tl_int_step == 2'd0) begin
                    if (tl_cur[ld_slot] < r_tl.tl) tl_cur[ld_slot] <= tl_cur[ld_slot] + 8'd1;
                end else begin
                    if (tl_cur[ld_slot] > r_tl.tl) tl_cur[ld_slot] <= tl_cur[ld_slot] - 8'd1;
                end
            end
            tl_load[ld_slot] <= 1'b0;
        end
        if (wr_tl_load) tl_load[wr_snum] <= 1'b1;   // set wins
    end
end

// ═══════════════════════════════════════════════════════════════════════════
// CPU memory access regs (v2 semantics; service is the new bounded scheduler)
// ═══════════════════════════════════════════════════════════════════════════
logic reg02_mem_access_mode, reg02_mem_type;
logic [7:0] cpu_mem_rd_buf;

wire cpu_adr_set_l = reg_wr && (reg_addr == 8'h05);
wire cpu_rd_06     = reg_rd && (reg_addr == 8'h06);
wire cpu_wr_06     = reg_wr && (reg_addr == 8'h06);

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        reg02_mem_access_mode <= 1'b0;
        reg02_mem_type        <= 1'b0;
    end else if (reg_wr && reg_addr == 8'h02) begin
        reg02_mem_access_mode <= reg_data[0];
        reg02_mem_type        <= reg_data[1];
    end
end

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) cpu_mem_adr <= '0;
    else begin
        if (reg_wr && reg_addr == 8'h03) cpu_mem_adr[23:16] <= reg_data;
        if (reg_wr && reg_addr == 8'h04) cpu_mem_adr[15:8]  <= reg_data;
        if (cpu_adr_set_l)               cpu_mem_adr[7:0]   <= reg_data;
        if (cpu_rd_06 && !cpu_adr_set_l)       cpu_mem_adr <= cpu_mem_adr + 24'd1;
        if (cpu_wr_issue && !cpu_adr_set_l)    cpu_mem_adr <= cpu_mem_adr + 24'd1;
    end
end

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) cpu_wr_data_latch <= '0;
    else if (cpu_wr_06) cpu_wr_data_latch <= reg_data;
end

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        cpu_rd_pend <= 1'b0;
        cpu_wr_pend <= 1'b0;
    end else begin
        if (cpu_rd_issue) cpu_rd_pend <= 1'b0;
        if (cpu_adr_set_l || cpu_rd_06) cpu_rd_pend <= 1'b1;   // prefetch
        if (cpu_wr_issue) cpu_wr_pend <= 1'b0;
        if (cpu_wr_06)    cpu_wr_pend <= 1'b1;
    end
end

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) cpu_rd_outstanding <= 1'b0;
    else begin
        if (cpu_rd_issue) cpu_rd_outstanding <= 1'b1;
        else if (mem_rd_valid && cpu_rd_outstanding) cpu_rd_outstanding <= 1'b0;
    end
end

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) cpu_mem_rd_buf <= '0;
    else if (mem_rd_valid && cpu_rd_outstanding) cpu_mem_rd_buf <= mem_rd_data;
end

assign cpu_mem_rd_data = cpu_mem_rd_buf;
assign cpu_mem_busy    = cpu_rd_pend | cpu_wr_pend | cpu_rd_outstanding;
assign reg02_readback  = {3'b001, wavetblhdr, reg02_mem_type, reg02_mem_access_mode};

// ═══════════════════════════════════════════════════════════════════════════
// Debug ports
// ═══════════════════════════════════════════════════════════════════════════
slot_regs_t   dbg_s0, dbg_s5, dbg_s23;
slot_header_t dbg_h0;
slot_dyn_t    dbg_d0;
always_comb begin
    dbg_s0  = ram_regs[0];
    dbg_s5  = ram_regs[5];
    dbg_s23 = ram_regs[23];
    dbg_h0  = ram_header[0];
    dbg_d0  = ram_dyn[0];
end
assign fm_mix_l_o = fm_mix_l;
assign fm_mix_r_o = fm_mix_r;
assign dbg_wavetblhdr  = wavetblhdr;
assign dbg_hf_pending  = hf_pending;
assign dbg_slot0_wave  = dbg_s0.wave;
assign dbg_slot0_fn    = dbg_s0.fn;
assign dbg_slot0_oct   = dbg_s0.oct;
assign dbg_slot0_prvb  = dbg_s0.prvb;
assign dbg_slot0_keyon = dbg_s0.keyon;
assign dbg_slot0_damp  = dbg_s0.damp;
assign dbg_slot0_pan   = dbg_s0.pan;
assign dbg_slot0_ar    = dbg_s0.ar;
assign dbg_slot0_d1r   = dbg_s0.d1r;
assign dbg_slot5_wave  = dbg_s5.wave;
assign dbg_slot23_wave = dbg_s23.wave;
assign dbg_slot0_hdr_start = dbg_h0.startAddr;
assign dbg_slot0_hdr_loop  = dbg_h0.loopAddr;
assign dbg_slot0_hdr_end   = dbg_h0.endAddr;
assign dbg_slot0_hdr_bits  = dbg_h0.bits;
assign dbg_slot0_dyn_pos       = dbg_d0.pos;
assign dbg_slot0_dyn_stepPtr   = dbg_d0.stepPtr;
assign dbg_slot0_dyn_env_vol   = dbg_d0.env_vol;
assign dbg_slot0_dyn_env_state = dbg_d0.env_state;
// v3 window-completion telemetry (same contract the TBs measure: at each
// window advance, was a slot dispatched last window and did it finish?)
logic win_had_slot, win_done, win_start_d;
wire   turn_advance = dispatch_now;     // new turn starting (prev turn's flags valid)
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        win_had_slot <= 1'b0;
        win_done     <= 1'b0;
        win_start_d  <= 1'b0;
    end else begin
        win_start_d <= turn_advance;
        if (win_start_d) begin            // clear AFTER TBs sampled at advance
            win_had_slot <= 1'b0;
            win_done     <= 1'b0;
        end
        if (sl_state == SL_VIB) win_had_slot <= 1'b1;   // slot dispatched
        if (sl_state == SL_ACC) win_done     <= 1'b1;   // slot completed
    end
end
assign dbg_stage_b_bytes_done  = win_done;
assign dbg_stage_advance       = turn_advance;
assign dbg_stage_b_valid       = win_had_slot;

genvar gi;
generate
    for (gi = 0; gi < 24; gi++) begin : g_dbg
        slot_regs_t r_g;
        slot_dyn_t  d_g;
        always_comb begin
            r_g = ram_regs[gi];
            d_g = ram_dyn[gi];
        end
        assign dbg_slot_keyon[gi]   = r_g.keyon;
        assign dbg_slot_active[gi]  = (d_g.env_state != EG_OFF);
        assign dbg_slot_envlive[gi] = (d_g.env_state != EG_OFF)
                                    && (d_g.env_vol < MAX_ATT_INDEX);
    end
endgenerate

endmodule
`default_nettype wire
