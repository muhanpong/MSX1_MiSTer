`default_nettype none

// YMF278B PCM Engine v2 — SCSP-Style Parallel Pipeline
//
// Architecture:
//   24 slots, each given a 64-cycle "window" once per audio frame.  Four
//   pipeline stages (A/B/C/D) operate on different slots in the same window:
//
//     slot N   in Stage A at  N*64 .. N*64+63
//     slot N-1 in Stage B at  N*64 .. N*64+63
//     slot N-2 in Stage C at  N*64 .. N*64+63
//     slot N-3 in Stage D at  N*64 .. N*64+63
//
// Each stage's output register is latched at slot_phase==63 (end of window)
// and consumed by the next stage during the next window.  Stage A's input
// (BRAM read) is issued at slot_phase==0 of its own window.  Stage B runs
// a serial SDRAM sequencer that issues up to 4 byte fetches with proper
// req→ready handshake pacing (msx.sv bridge serializes one transaction at
// a time, ~10-15 cycles round-trip per byte).
//
// Pipeline drain: after slot 23 dispatches at frame_cycle 1472..1535, the
// remaining in-flight slots (B/C/D) drain through cycles 1536..1727.
// Total pipeline window = 27*64 = 1728 cycles; frame budget = 1948 cycles.
// Remaining ~220 cycles is slack for HF fetches, CPU writes, refresh.
//
// SDRAM port owned by Stage B (sample fetches), HF FSM and CPU writes use
// the port during the long idle window (cycle ~1728 onward).

// Import ALU + EG packages (was instance dot calls; Quartus 17.1 doesn't
// support cross-module function calls, so we use SV packages instead).
import ymf278_pcm_alu_pkg::*;
import ymf278_pcm_eg_pkg::*;

module ymf278_pcm_engine #(
    parameter int CLK_HZ       = 85909090,
    parameter int SDRAM_RD_LAT = 6        // SDRAM round-trip latency (cycles)
) (
    input  wire        clk,
    input  wire        rst_n,

    // CPU Register Interface
    input  wire [7:0]  reg_addr,
    input  wire [7:0]  reg_data,
    input  wire        reg_wr,
    input  wire        reg_rd,
    output logic [7:0] cpu_mem_rd_data,   // value returned for reg 0x06 read
    output logic       cpu_mem_busy,      // 1 while CPU mem op in flight
    output logic [7:0] reg02_readback,    // value returned for reg 0x02 read

    // SDRAM Direct Port
    output logic [21:0] mem_addr,
    output logic        mem_rd_en,
    input  wire  [7:0]  mem_rd_data,
    // Full 16-bit SDRAM word for the address issued (the controller always
    // reads a 16-bit word; mem_rd_data is just one byte of it).  Stage B uses
    // this to fetch 2 bytes per transaction (burst-via-word), cutting the
    // per-slot SDRAM reads from 5 single bytes to 3 words.  Layout for an
    // even byte address A:  [7:0]=mem[A], [15:8]=mem[A+1].
    input  wire  [15:0] mem_rd_data16,
    input  wire         mem_rd_valid,
    output logic        mem_wr_en,
    output logic [7:0]  mem_wr_data,
    // High while the msx.sv ch4 bridge has a transaction in flight.  Stage B
    // gates its mem_rd_en pulse on !mem_busy so the bridge (which edge-detects
    // on IDLE only) does not silently drop a new slot's request when the
    // previous slot's read is still outstanding.
    input  wire         mem_busy,

    // Audio Output
    output logic signed [15:0] pcm_left,
    output logic signed [15:0] pcm_right,
    output logic               pcm_valid,

    // Debug observation ports (testbench only — flattened slot 0/5/23 regs +
    // wavetblhdr + hf_pending).  Optimized away when unused in synthesis.
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

    // ram_header[0] mirror for HF FSM verification
    output logic [21:0] dbg_slot0_hdr_start,
    output logic [15:0] dbg_slot0_hdr_loop,
    output logic [15:0] dbg_slot0_hdr_end,
    output logic [1:0]  dbg_slot0_hdr_bits,

    // ram_dyn[0] mirror — for tb_long_run / overlay diagnostics.  Flat (not
    // struct) so external testbenches can read individual fields without
    // hierarchical struct-array references (iverilog limitation).
    output logic [15:0] dbg_slot0_dyn_pos,
    output logic [15:0] dbg_slot0_dyn_stepPtr,
    output logic [9:0]  dbg_slot0_dyn_env_vol,
    output logic [2:0]  dbg_slot0_dyn_env_state,
    // stage_b_bytes_done success indicator (high during slot's window after
    // all 5 bytes latched).  Useful for H6 timing-budget counter in tb.
    output logic        dbg_stage_b_bytes_done,
    output logic        dbg_stage_advance,
    output logic        dbg_stage_b_valid
);

    // ════════════════════════════════════════════════════════════════════════
    // Frame and slot scheduler
    // ════════════════════════════════════════════════════════════════════════
    localparam int CYCLES_PER_SLOT      = 64;
    localparam int TOTAL_SLOTS          = 24;
    localparam int SLOT_DISPATCH_CYCLES = TOTAL_SLOTS * CYCLES_PER_SLOT;   // 1536
    localparam int PIPELINE_END         = SLOT_DISPATCH_CYCLES + 3*CYCLES_PER_SLOT; // 1728
    localparam int CYCLES_PER_FRAME     = 1948;

    logic [10:0] frame_cycle;
    logic [4:0]  cur_slot;
    logic [5:0]  slot_phase;
    logic [23:0] eg_cnt;

    // Forward decl: reg 0x02 bit0 (memory-access mode).  Driven in the CPU mem
    // block far below.  Per YMF278B spec the channels stop while this is set so
    // the CPU has the full sample-memory bandwidth for upload — we halt slot
    // dispatch and open the SDRAM access window continuously while it is high.
    logic        reg02_mem_access_mode;

    // Stage-B carryover: if a slot's SDRAM reads aren't finished by the end of
    // its 64-cycle window, stall the pipeline (hold slot_phase at 63) until
    // they complete instead of force-restarting and discarding them.  Slow
    // slots borrow time from the frame's slack + idle/fast slots; the hard
    // 64-cycle per-slot deadline (the sustain "budget cliff") is removed.
    // b_busy: Stage B sequencer is mid-read (declared/driven after b_state).
    // stall_cnt caps the stall as an anti-deadlock guard (stuck bridge) →
    // force-advance like the original behavior.
    logic        b_busy;
    logic [6:0]  stall_cnt;
    localparam int MAX_STALL = 127;
    wire         pipe_advance = (!b_busy) || (stall_cnt >= MAX_STALL);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            frame_cycle <= '0;
            cur_slot    <= '0;
            slot_phase  <= '0;
            eg_cnt      <= '0;
            stall_cnt   <= '0;
        end else begin
            if (frame_cycle == CYCLES_PER_FRAME - 1) begin
                frame_cycle <= '0;
                cur_slot    <= '0;
                slot_phase  <= '0;
                stall_cnt   <= '0;
                eg_cnt      <= eg_cnt + 24'd1;
            end else begin
                frame_cycle <= frame_cycle + 11'd1;
                if (slot_phase == 6'd63) begin
                    // End of slot window: advance only when Stage B has
                    // finished this slot's reads (or the stall guard fires).
                    // Otherwise hold here (stall) and let the reads complete.
                    if (pipe_advance) begin
                        slot_phase <= '0;
                        stall_cnt  <= '0;
                        if (cur_slot != 5'd23) cur_slot <= cur_slot + 5'd1;
                    end else begin
                        stall_cnt <= stall_cnt + 7'd1;
                    end
                end else begin
                    slot_phase <= slot_phase + 6'd1;
                end
            end
        end
    end

    wire in_dispatch_window = (frame_cycle < SLOT_DISPATCH_CYCLES);
    wire in_pipeline_window = (frame_cycle < PIPELINE_END);
    wire sample_start       = (frame_cycle == CYCLES_PER_FRAME - 1);
    // dispatch_now: a new slot enters Stage A.  Suppressed while the CPU is in
    // memory-access mode (channels stop per spec) so Stage B drains to B_IDLE
    // and frees the SDRAM bus for CPU upload.
    wire dispatch_now       = (slot_phase == 6'd0) && in_dispatch_window && !reg02_mem_access_mode;
    // stage_advance: pulses at the end of every 64-cycle window, including the
    // drain windows after dispatch is done (so in-flight slots finish).
    // Suppressed after pipeline drain so HF/CPU FSMs can use SDRAM uninterrupted.
    wire stage_advance      = (slot_phase == 6'd63) && pipe_advance && in_pipeline_window;

    // ════════════════════════════════════════════════════════════════════════
    // Per-slot state RAMs
    // ════════════════════════════════════════════════════════════════════════
    typedef struct packed {
        logic [8:0]  wave;
        logic [9:0]  fn;
        logic signed [3:0] oct;
        logic [7:0]  tl;
        logic [3:0]  pan;
        logic        keyon;
        logic [3:0]  ar, d1r, d2r, rc, rr;
        logic [2:0]  am, vib, lfo_speed;
        logic [3:0]  dl_idx;
        logic        damp, prvb;
    } slot_regs_t;

    typedef struct packed {
        logic [21:0] startAddr;
        logic [15:0] loopAddr;
        logic [15:0] endAddr;
        logic [1:0]  bits;
    } slot_header_t;

    typedef struct packed {
        logic [15:0] pos;
        logic [15:0] stepPtr;
        logic [9:0]  env_vol;
        logic [2:0]  env_state;
    } slot_dyn_t;

    slot_regs_t   ram_regs   [0:23];
    slot_header_t ram_header [0:23];
    slot_dyn_t    ram_dyn    [0:23];

    logic [23:0] key_on_prev;

    // ════════════════════════════════════════════════════════════════════════
    // Pipeline registers between stages
    // ════════════════════════════════════════════════════════════════════════
    typedef struct packed {
        logic            valid;
        logic [4:0]      slot;
        slot_regs_t      regs;
        slot_header_t    header;
        slot_dyn_t       dyn;
    } stage_a_pkt_t;

    // 6 byte addresses packed as one 132-bit word for stage register friendliness.
    typedef struct packed {
        logic [21:0] a0, a1, a2, b0, b1, b2;
    } byte_addrs_t;

    typedef struct packed {
        logic            valid;
        logic [4:0]      slot;
        slot_regs_t      regs;
        slot_header_t    header;
        slot_dyn_t       dyn;        // pos/stepPtr updated for current sample
        logic [15:0]     next_pos;   // for sample B interpolation
        byte_addrs_t     addrs;
        // 5 bytes filled by sequencer: a0, a1, a2, b0, b1.
        //   8-bit  : uses bytes[0] (sample A), bytes[3] (sample B)
        //   12-bit : uses bytes[0,1,2] (chunk for sample A);
        //            p odd → bytes[3,4] for sample B's NEXT chunk
        //            p even → reuses bytes[0,1,2] (same chunk)
        //   16-bit : uses bytes[0,1] (sample A), bytes[3,4] (sample B)
        logic [4:0][7:0] bytes;
    } stage_b_pkt_t;

    typedef struct packed {
        logic            valid;
        logic [4:0]      slot;
        slot_regs_t      regs;
        slot_dyn_t       dyn;       // pos/stepPtr from Stage B
        logic [4:0][7:0] bytes;
        logic signed [15:0] interp;
    } stage_c_pkt_t;

    stage_a_pkt_t stage_a_reg;   // latched at dispatch_now, held for 8 cycles
    stage_b_pkt_t stage_b_reg;   // latched at stage_advance
    stage_c_pkt_t stage_c_reg;   // latched at stage_advance

    // ALU + EG functions/tasks are imported as packages above — no
    // module instances needed.

    // ════════════════════════════════════════════════════════════════════════
    // Stage A — dispatch + BRAM read
    // Activates at slot_phase==0 of each in-dispatch slot.  Reads BRAMs and
    // latches into stage_a_reg, which then holds the value for the entire
    // 8-cycle window until Stage B picks it up at stage_advance.
    // ════════════════════════════════════════════════════════════════════════
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stage_a_reg <= '0;
        end else if (dispatch_now) begin
            stage_a_reg.valid  <= 1'b1;
            stage_a_reg.slot   <= cur_slot;
            stage_a_reg.regs   <= ram_regs[cur_slot];
            stage_a_reg.header <= ram_header[cur_slot];
            stage_a_reg.dyn    <= ram_dyn[cur_slot];
        end else if (stage_advance) begin
            // Once Stage B has copied us, mark our slot as drained for the
            // next cycle.  Stage B re-reads stage_a_reg on the same cycle so
            // the data is still observed.
            stage_a_reg.valid <= 1'b0;
        end
    end

    // ════════════════════════════════════════════════════════════════════════
    // Stage B — step calc + addresses + SDRAM requests
    //
    // At stage_advance entry, stage_a_reg is latched into a new stage_b
    // packet (with computed step/new_pos/addresses).  During Stage B's
    // 8-cycle window, slot_phase 1..6 drive mem_addr / mem_rd_en for the
    // 6 byte fetches (A0,A1,A2,B0,B1,B2).
    //
    // Step + address calculation is combinational from stage_a_reg.
    // ════════════════════════════════════════════════════════════════════════

    // Combinational: compute next pos given current dyn + step.
    // Loop wrap: pos + endAddr >= 0x10000 → pos += endAddr + loopAddr.
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

    // Combinational computation off stage_a_reg — Stage A → Stage B inputs
    // (calc_step + step accumulation + next_pos_calc).  The byte_addr
    // multiplies that previously chained off these signals are moved one
    // cycle later via next_pos_r / next_pos_for_b_r below; without this
    // pipelining the full chain failed clk_sdram (86 MHz) timing by ~11 ns
    // (worst path: stage_a_reg.regs.oct → ... → stage_b_reg.addrs.b1).
    logic [31:0]      next_step_full;
    logic [15:0]      next_stepPtr;
    logic [15:0]      next_pos;
    logic [15:0]      next_pos_for_b;
    byte_addrs_t      next_addrs;

    // Registered intermediates — second pipeline stage of Stage A→B.  These
    // shadow the combinational results above with 1-cycle delay; byte_addr
    // below reads from them so the multiplier chain starts at a register
    // boundary.  Settles within 2 cycles of dispatch_now, long before
    // stage_advance at slot_phase 63.
    logic [15:0]      next_pos_r;
    logic [15:0]      next_pos_for_b_r;
    logic [15:0]      next_stepPtr_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            next_pos_r       <= '0;
            next_pos_for_b_r <= '0;
            next_stepPtr_r   <= '0;
        end else begin
            next_pos_r       <= next_pos;
            next_pos_for_b_r <= next_pos_for_b;
            next_stepPtr_r   <= next_stepPtr;
        end
    end

    always_comb begin
        // VIB=0 for now; TODO wire up LFO VIB output
        next_step_full = calc_step(stage_a_reg.regs.oct,
                                       stage_a_reg.regs.fn,
                                       16'sh0);

        // Step accumulation: pos advances when stepPtr overflows.
        // For 16-bit stepPtr with step[15:0] increment.
        next_stepPtr = stage_a_reg.dyn.stepPtr + next_step_full[15:0];
        if (next_step_full[31:16] != 16'd0
            || next_stepPtr < stage_a_reg.dyn.stepPtr) begin
            // Whole-sample advance
            logic [15:0] inc;
            inc = next_step_full[31:16]
                + (next_stepPtr < stage_a_reg.dyn.stepPtr ? 16'd1 : 16'd0);
            next_pos = next_pos_calc(stage_a_reg.dyn.pos, inc,
                                     stage_a_reg.header.endAddr,
                                     stage_a_reg.header.loopAddr);
        end else begin
            next_pos = stage_a_reg.dyn.pos;
        end

        // next_pos_for_b = next_pos + 1 (with loop wrap).
        // Use REGISTERED next_pos_r as source to break the long carry chain:
        // the original chain (oct → calc_step → Add5 → Add7 → Add8 (next_pos)
        // → Add11 (next_pos_for_b) → next_pos_for_b_r) was 11 logic levels
        // and missed timing by ~5 ns.  By sourcing from next_pos_r the
        // Add11 chain starts at a register boundary, so this combinational
        // result settles in 1 cycle instead of being chained.  next_pos_for_b_r
        // is thus 2 cycles after stage_a_reg latch (was 1), well within the
        // 64-cycle slot window before stage_advance consumes it.
        next_pos_for_b = next_pos_calc(next_pos_r, 16'd1,
                                       stage_a_reg.header.endAddr,
                                       stage_a_reg.header.loopAddr);

        // 6 byte addresses — driven from REGISTERED next_pos_r /
        // next_pos_for_b_r (Stage A→B split second cycle).  startAddr and
        // bits stay combinational from stage_a_reg (short paths into the
        // final base+offset add inside byte_addr).
        next_addrs.a0 = byte_addr(stage_a_reg.header.startAddr,
                                       next_pos_r, stage_a_reg.header.bits, 2'd0);
        next_addrs.a1 = byte_addr(stage_a_reg.header.startAddr,
                                       next_pos_r, stage_a_reg.header.bits, 2'd1);
        next_addrs.a2 = byte_addr(stage_a_reg.header.startAddr,
                                       next_pos_r, stage_a_reg.header.bits, 2'd2);
        next_addrs.b0 = byte_addr(stage_a_reg.header.startAddr,
                                       next_pos_for_b_r, stage_a_reg.header.bits, 2'd0);
        next_addrs.b1 = byte_addr(stage_a_reg.header.startAddr,
                                       next_pos_for_b_r, stage_a_reg.header.bits, 2'd1);
        next_addrs.b2 = byte_addr(stage_a_reg.header.startAddr,
                                       next_pos_for_b_r, stage_a_reg.header.bits, 2'd2);
    end

    // ────────────────────────────────────────────────────────────────────────
    // Stage B serial SDRAM sequencer (burst-via-word, adaptive).
    // States: IDLE → ISSUE → WAIT_VALID → NEXT (latch) → ISSUE / DONE.
    //
    // Sample A needs 3 consecutive bytes a0,a1,a2 (12-bit chunk); sample B
    // needs b0,b1.  The SDRAM already returns a full 16-bit word per access,
    // so we read words, not single bytes.
    //
    //   Common case (next_pos = pos+1): b0,b1 sit within 5 bytes of a0, so a
    //   single 3-word window [WB .. WB+5], WB = a0 & ~1, covers all five
    //   logical bytes → 3 reads.
    //   Loop wrap: next_pos jumps to loopAddr, so b0,b1 are far from a0.  We
    //   detect this (sb_split) and fetch sample B as its own 1 extra word pair
    //   into raw[4..7] → 4 reads.  Without this the sample straddling the loop
    //   point was corrupted (audible as a buzz/"damped string" on sustained,
    //   short-loop instruments).
    //
    // Each logical byte is selected from raw[] by a precomputed index, so
    // decode_sample below is unchanged.  3 reads (vs 5 single bytes) in the
    // common case keeps the SDRAM-latency headroom; 4 only at loop wraps.
    // ────────────────────────────────────────────────────────────────────────
    typedef enum logic [2:0] {
        B_IDLE, B_ISSUE, B_WAIT_VALID, B_NEXT, B_DONE
    } b_state_t;

    b_state_t   b_state;
    logic [1:0] b_word_idx;     // 0..3
    logic [21:0] b_addr_sel;

    // Stage-B busy (mid-read) — drives the scheduler carryover stall above.
    // B_IDLE = no slot / nothing to read; B_DONE = reads finished.  Anything
    // else means the sequencer is still fetching this slot's words.
    always_comb b_busy = (b_state != B_IDLE) && (b_state != B_DONE);

    // raw[0..5] = A-window mem[WB..WB+5]; raw[6..7] = extra B-window word pair
    // (only when sb_split).  b bytes live at raw[sb_b_idx]/[sb_b_idx+1].
    logic [7:0]  b_raw [0:7];
    logic [21:0] sb_wb;        // a0 & ~1  (A-window base)
    logic [21:0] sb_wbb;       // b0 & ~1  (B-window base, used when split)
    logic        sb_off_a0;    // a0 & 1   (a1,a2 = +1,+2)
    logic [2:0]  sb_b_idx;     // raw[] index of b0  (b1 = +1)
    logic        sb_split;     // sample B not contiguous with A (loop wrap)

    // Forward declaration: hf_active is asserted by HF FSM (defined below)
    // when it owns the SDRAM bus.  Used here to gate mem_rd_valid away from
    // Stage B's byte latch so HF's response data doesn't leak in.
    // Likewise, cpu_rd_outstanding gates Stage B away from CPU-bound valids.
    logic hf_active;
    logic cpu_rd_outstanding;   // forward decl; driven in CPU mem block below
    wire  mem_rd_valid_b = mem_rd_valid && !hf_active && !cpu_rd_outstanding;

    // Word read address:
    //   idx 0,1,2 → A-window  WB + {0,2,4}
    //   idx 3     → B-window  WBb + 2   (idx 2 already issued WBb when split)
    // When split, idx 2 reads WBb (not WB+4) so raw[4,5] hold the B word pair.
    always_comb begin
        case (b_word_idx)
            2'd0:    b_addr_sel = sb_wb;
            2'd1:    b_addr_sel = sb_wb + 22'd2;
            2'd2:    b_addr_sel = sb_split ? sb_wbb : (sb_wb + 22'd4);
            default: b_addr_sel = sb_wbb + 22'd2;   // idx 3 (split only)
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            b_state    <= B_IDLE;
            b_word_idx <= '0;
        end else if (stage_advance) begin
            // New slot enters Stage B every stage_advance.  Restart sequencer
            // regardless of previous state — this guarantees forward progress
            // even if prior slot didn't finish.
            if (stage_a_reg.valid) begin
                b_state    <= B_ISSUE;
                b_word_idx <= 2'd0;
            end else begin
                b_state <= B_IDLE;
            end
        end else begin
            case (b_state)
                B_IDLE:       ;   // wait for stage_advance
                // Hold B_ISSUE until the ch4 bridge is idle.  If we transition
                // while mem_busy is high, the arbiter has been suppressing
                // mem_rd_en — so the bridge never saw a rising edge for this
                // slot, and B_WAIT_VALID would wait forever (deadlock).
                B_ISSUE:      if (!mem_busy) b_state <= B_WAIT_VALID;
                B_WAIT_VALID: if (mem_rd_valid_b) b_state <= B_NEXT;
                B_NEXT: begin
                    // 3 words normally; 4 when sample B is split off (loop wrap).
                    if (b_word_idx == (sb_split ? 2'd3 : 2'd2)) b_state <= B_DONE;
                    else begin
                        b_word_idx <= b_word_idx + 2'd1;
                        b_state    <= B_ISSUE;
                    end
                end
                B_DONE:       ;   // hold until stage_advance
            endcase
        end
    end

    // ────────────────────────────────────────────────────────────────────────
    // Stage B output register: latched at stage_advance from Stage A pkt +
    // combinational step calc; bytes filled as sequencer returns them.
    // ────────────────────────────────────────────────────────────────────────
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stage_b_reg <= '0;
        end else if (stage_advance) begin
            stage_b_reg.valid    <= stage_a_reg.valid;
            stage_b_reg.slot     <= stage_a_reg.slot;
            stage_b_reg.regs     <= stage_a_reg.regs;
            stage_b_reg.header   <= stage_a_reg.header;
            // Use registered intermediates (Stage A→B split): matches
            // next_addrs above so position-and-address pair are consistent.
            stage_b_reg.dyn.pos       <= next_pos_r;
            stage_b_reg.dyn.stepPtr   <= next_stepPtr_r;
            stage_b_reg.dyn.env_vol   <= stage_a_reg.dyn.env_vol;
            stage_b_reg.dyn.env_state <= stage_a_reg.dyn.env_state;
            stage_b_reg.next_pos <= next_pos_for_b_r;
            stage_b_reg.addrs    <= next_addrs;
            stage_b_reg.bytes    <= '0;   // unused now; decode reads b_raw
            // Latch A-window base + offsets, and decide split for sample B.
            //   WB = a0 & ~1; off_a0 = a0 & 1; a1,a2 follow.
            //   contiguous when b0 ∈ [WB, WB+5] → b at raw[b0-WB].
            //   else split → B fetched into raw[4..7], b at raw[4 + (b0&1)].
            sb_wb     <= {next_addrs.a0[21:1], 1'b0};
            sb_wbb    <= {next_addrs.b0[21:1], 1'b0};
            sb_off_a0 <= next_addrs.a0[0];
            if (next_addrs.b0 >= {next_addrs.a0[21:1], 1'b0} &&
                (next_addrs.b0 - {next_addrs.a0[21:1], 1'b0}) <= 22'd5) begin
                sb_split <= 1'b0;
                sb_b_idx <= 3'(next_addrs.b0 - {next_addrs.a0[21:1], 1'b0});
            end else begin
                sb_split <= 1'b1;
                sb_b_idx <= 3'd4 + {2'd0, next_addrs.b0[0]};
            end
        end else if (b_state == B_WAIT_VALID && mem_rd_valid_b) begin
            // Each word read returns 2 consecutive bytes:
            //   [7:0]  = mem[base + 2*k]      (even byte)
            //   [15:8] = mem[base + 2*k + 1]  (odd byte)
            // idx 0,1,2 fill raw[0..5] (A-window, or raw[4,5]=B-window word0
            // when split); idx 3 fills raw[6,7] (B-window word1, split only).
            b_raw[{b_word_idx, 1'b0}] <= mem_rd_data16[7:0];
            b_raw[{b_word_idx, 1'b1}] <= mem_rd_data16[15:8];
        end
    end

    // Stage B "done" indicator (combinational): true when sequencer has
    // collected all 4 bytes, or the slot is idle.
    wire stage_b_bytes_done = (b_state == B_DONE)
                            || (b_state == B_IDLE && !stage_b_reg.valid);

    // ════════════════════════════════════════════════════════════════════════
    // Stage C — decode fetched bytes into samples A/B, linear interpolate.
    //
    // 5-byte buffer layout:
    //   bytes[0,1,2] = chunk for sample A (3 consecutive bytes)
    //   bytes[3,4]   = first 2 bytes of NEXT chunk (sample B if p odd)
    //
    // Decode per format:
    //   8-bit  : A = decode(bytes[0], ...);  B = decode(bytes[3], ...)
    //   12-bit : A = decode(bytes[0..2], p, fmt);
    //            B = (p odd) decode(bytes[3..4], p+1) — next chunk
    //                (p even) decode(bytes[0..2], p+1)  — same chunk
    //   16-bit : A = decode(bytes[0,1], ...);  B = decode(bytes[3,4], ...)
    // ════════════════════════════════════════════════════════════════════════
    logic signed [15:0] samp_a, samp_b;
    logic signed [15:0] interp_val;

    // Reconstruct the 5 logical bytes from the burst buffer.  a0,a1,a2 live in
    // the A-window at offset off_a0; b0,b1 at the precomputed sb_b_idx (either
    // inside the A-window when contiguous, or in raw[4..7] when split).
    // Identical semantics to the old stage_b_reg.bytes[0..4], so the decode
    // below is unchanged.
    wire [7:0] sbb0 = b_raw[{2'd0, sb_off_a0}];
    wire [7:0] sbb1 = b_raw[3'(sb_off_a0) + 3'd1];
    wire [7:0] sbb2 = b_raw[3'(sb_off_a0) + 3'd2];
    wire [7:0] sbb3 = b_raw[sb_b_idx];
    wire [7:0] sbb4 = b_raw[sb_b_idx + 3'd1];

    always_comb begin
        case (stage_b_reg.header.bits)
            2'd0: begin // 8-bit
                samp_a = decode_sample(sbb0, 8'h00, 8'h00,
                                            stage_b_reg.dyn.pos, 2'd0);
                samp_b = decode_sample(sbb3, 8'h00, 8'h00,
                                            stage_b_reg.next_pos, 2'd0);
            end
            2'd1: begin // 12-bit
                samp_a = decode_sample(sbb0, sbb1, sbb2,
                                            stage_b_reg.dyn.pos, 2'd1);
                if (stage_b_reg.dyn.pos[0]) begin
                    // p odd → p+1 even → sample B's chunk = next chunk (bytes[3,4])
                    // decode_sample for even-pos: uses b0 + (b1<<4)&0xF0
                    samp_b = decode_sample(sbb3, sbb4, 8'h00,
                                                stage_b_reg.next_pos, 2'd1);
                end else begin
                    // p even → p+1 odd → sample B in SAME chunk (bytes[0..2])
                    samp_b = decode_sample(sbb0, sbb1, sbb2,
                                                stage_b_reg.next_pos, 2'd1);
                end
            end
            2'd2: begin // 16-bit
                samp_a = decode_sample(sbb0, sbb1, 8'h00,
                                            stage_b_reg.dyn.pos, 2'd2);
                samp_b = decode_sample(sbb3, sbb4, 8'h00,
                                            stage_b_reg.next_pos, 2'd2);
            end
            default: begin
                samp_a = 16'sd0;
                samp_b = 16'sd0;
            end
        endcase
        interp_val = calc_interp(samp_a, samp_b, stage_b_reg.dyn.stepPtr);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stage_c_reg <= '0;
        end else if (stage_advance) begin
            stage_c_reg.valid  <= stage_b_reg.valid && stage_b_bytes_done;
            stage_c_reg.slot   <= stage_b_reg.slot;
            stage_c_reg.regs   <= stage_b_reg.regs;
            stage_c_reg.dyn    <= stage_b_reg.dyn;
            stage_c_reg.bytes  <= stage_b_reg.bytes;
            stage_c_reg.interp <= interp_val;
        end
    end

    // ════════════════════════════════════════════════════════════════════════
    // Stage D — 3-cycle pipeline: EG → Vol → Pan/Accumulate
    //
    // The 1-cycle combinational chain (process_eg → calc_vol → pan_mul →
    // accumulate) failed timing at 85.9MHz with -34ns slack on a Cyclone V
    // (multipliers + barrel shifts chained = ~45ns).  Split into 3 register
    // stages so each cycle has at most one multiplier-class operation.
    //
    //   D1 (latches at stage_advance):
    //     - key_on edge detection
    //     - process_eg (uses calc_eg_rate / calc_attack_step ROM+mults)
    //     - register: d1_pkt = {slot, pan, tl, interp, dyn, eg_state, eg_vol,
    //                            key_on_edge}
    //
    //   D2 (1 cycle later):
    //     - calc_vol(interp, eg_vol, tl)  (32-bit mult + barrel shift)
    //     - register: d2_pkt = {slot, pan, dyn, eg_state, eg_vol, vol_sample,
    //                            key_on_edge}
    //
    //   D3 (2 cycles later):
    //     - pan_att_left/right + 32×6 multiplier + 24-bit accumulator
    //     - ram_dyn writeback
    //
    // Master framer (also in D3 block but unconditional): at sample_start,
    // push master_accum → pcm_left/right + pcm_valid; reset accums.
    // ════════════════════════════════════════════════════════════════════════
    logic signed [23:0] master_accum_left;
    logic signed [23:0] master_accum_right;

    // D1a packet: process_eg's deep combinational chain is split here.  D1a
    // pre-computes rate / shift_v / sel_v / do_update so D1b only does the
    // final phase/inc/vol update.  Required for clk_sdram (86 MHz) timing
    // closure — the original single-cycle process_eg call is ~15-20 LUT
    // levels + DSP, way over the 11.6 ns budget.
    typedef struct packed {
        logic                 valid;
        logic [4:0]           slot;
        slot_regs_t           regs;          // forwarded to D1b
        logic [2:0]           cur_state;     // env_state at D1a entry
        logic [9:0]           cur_vol;       // env_vol  at D1a entry
        slot_dyn_t            new_dyn;       // forwarded to d1_pkt
        logic signed [15:0]   interp;        // forwarded to d1_pkt
        logic [5:0]           rate;          // pre-computed: state-dispatched rate
        logic [7:0]           shift_v;       // pre-computed: eg_rate_shift_rom(rate)
        logic [7:0]           sel_v;         // pre-computed: eg_rate_select_rom(rate)
        logic                 do_update;     // pre-computed: eg_do_update(eg_cnt, shift_v)
        logic [7:0]           inc_v;         // pre-computed: eg_inc_rom(sel + phase)
        logic                 key_on_edge;
    } d1a_pkt_t;

    typedef struct packed {
        logic                 valid;
        logic [4:0]           slot;
        logic [3:0]           pan;
        logic [7:0]           tl;
        logic signed [15:0]   interp;
        slot_dyn_t            new_dyn;       // pos/stepPtr from Stage C
        logic [2:0]           next_eg_state;
        logic [9:0]           next_eg_vol;
        logic                 key_on_edge;
    } d1_pkt_t;

    typedef struct packed {
        logic                 valid;
        logic [4:0]           slot;
        logic [3:0]           pan;
        slot_dyn_t            new_dyn;
        logic [2:0]           eg_state;
        logic [9:0]           eg_vol;
        logic                 key_on_edge;
        logic signed [15:0]   interp;        // forward to D2b
        logic                 silent;
        logic signed [31:0]   tmp_vol;       // (0x8000 * vol_mul) >>> vol_shift
    } d2a_pkt_t;

    typedef struct packed {
        logic                 valid;
        logic [4:0]           slot;
        logic [3:0]           pan;
        slot_dyn_t            new_dyn;
        logic [2:0]           eg_state;
        logic [9:0]           eg_vol;
        logic signed [31:0]   vol_sample;
        logic                 key_on_edge;
    } d2_pkt_t;

    d1a_pkt_t d1a_pkt;
    d1_pkt_t  d1_pkt;
    d2a_pkt_t d2a_pkt;
    d2_pkt_t  d2_pkt;

    // ── D1a: rate selection + first ROM lookups + do_update ─────────────────
    // Splits process_eg's combinational chain.  D1a does the rate/shift/sel
    // computations (deeper chain due to calc_eg_rate / calc_decay_rate
    // multiplies and ROM lookups), D1b does phase + inc + final vol update.
    always_ff @(posedge clk or negedge rst_n) begin
        logic [5:0]  rate_v;
        logic [7:0]  shift_vv, sel_vv;
        logic        du_v;
        logic        edge_now;
        logic [2:0]  phase_vv;
        logic [7:0]  inc_vv;

        rate_v   = 6'd0;
        shift_vv = 8'd0;
        sel_vv   = 8'd0;
        du_v     = 1'b0;
        edge_now = 1'b0;
        phase_vv = 3'd0;
        inc_vv   = 8'd0;

        if (!rst_n) begin
            d1a_pkt     <= '0;
            key_on_prev <= '0;
        end else begin
            d1a_pkt.valid <= 1'b0;
            if (stage_advance && stage_c_reg.valid) begin
                edge_now = stage_c_reg.regs.keyon & ~key_on_prev[stage_c_reg.slot];
                key_on_prev[stage_c_reg.slot] <= stage_c_reg.regs.keyon;

                // State-dispatched rate selection (matches process_eg's prologue).
                // Attack rate is also used for the "key_on edge from EG_OFF" path.
                if (edge_now && stage_c_reg.dyn.env_state == EG_OFF) begin
                    rate_v = calc_eg_rate(stage_c_reg.regs.ar,
                                          stage_c_reg.regs.rc,
                                          stage_c_reg.regs.oct,
                                          stage_c_reg.regs.fn);
                end else begin
                    case (stage_c_reg.dyn.env_state)
                        EG_ATT: rate_v = calc_eg_rate(
                                    stage_c_reg.regs.ar,  stage_c_reg.regs.rc,
                                    stage_c_reg.regs.oct, stage_c_reg.regs.fn);
                        EG_DEC: rate_v = calc_decay_rate(
                                    stage_c_reg.regs.d1r, stage_c_reg.regs.rc,
                                    stage_c_reg.regs.damp, stage_c_reg.regs.prvb,
                                    stage_c_reg.dyn.env_vol,
                                    stage_c_reg.regs.oct, stage_c_reg.regs.fn);
                        EG_SUS: rate_v = calc_decay_rate(
                                    stage_c_reg.regs.d2r, stage_c_reg.regs.rc,
                                    stage_c_reg.regs.damp, stage_c_reg.regs.prvb,
                                    stage_c_reg.dyn.env_vol,
                                    stage_c_reg.regs.oct, stage_c_reg.regs.fn);
                        EG_REL: rate_v = calc_decay_rate(
                                    stage_c_reg.regs.rr,  stage_c_reg.regs.rc,
                                    stage_c_reg.regs.damp, stage_c_reg.regs.prvb,
                                    stage_c_reg.dyn.env_vol,
                                    stage_c_reg.regs.oct, stage_c_reg.regs.fn);
                        default: rate_v = 6'd0;
                    endcase
                end

                shift_vv = eg_rate_shift_rom(rate_v);
                sel_vv   = eg_rate_select_rom(rate_v);
                du_v     = eg_do_update(eg_cnt, shift_vv);
                // Pre-compute phase + ROM lookup so D1b's critical chain
                // starts at d1a_pkt.inc_v instead of eg_cnt → shift → ROM.
                phase_vv = eg_phase(eg_cnt, shift_vv);
                inc_vv   = eg_inc_rom(7'(sel_vv + {5'd0, phase_vv}));

                d1a_pkt.valid       <= 1'b1;
                d1a_pkt.slot        <= stage_c_reg.slot;
                d1a_pkt.regs        <= stage_c_reg.regs;
                d1a_pkt.cur_state   <= stage_c_reg.dyn.env_state;
                d1a_pkt.cur_vol     <= stage_c_reg.dyn.env_vol;
                d1a_pkt.new_dyn     <= stage_c_reg.dyn;
                d1a_pkt.interp      <= stage_c_reg.interp;
                d1a_pkt.rate        <= rate_v;
                d1a_pkt.shift_v     <= shift_vv;
                d1a_pkt.sel_v       <= sel_vv;
                d1a_pkt.do_update   <= du_v;
                d1a_pkt.inc_v       <= inc_vv;
                d1a_pkt.key_on_edge <= edge_now;
            end
        end
    end

    // ── D1b: final vol/state update ─────────────────────────────────────────
    // phase + eg_inc_rom moved into D1a (registered as d1a_pkt.inc_v) to
    // cut the deep eg_cnt → ShiftRight → ROM → Mult chain.
    always_ff @(posedge clk or negedge rst_n) begin
        logic [10:0] vol_add;
        logic [9:0]  new_vol;
        logic [2:0]  new_state;

        vol_add   = 11'd0;
        new_vol   = 10'd0;
        new_state = 3'd0;

        if (!rst_n) begin
            d1_pkt <= '0;
        end else begin
            d1_pkt.valid <= 1'b0;
            if (d1a_pkt.valid) begin
                // Defaults: hold prior state if no update path taken
                new_vol   = d1a_pkt.cur_vol;
                new_state = d1a_pkt.cur_state;

                if (d1a_pkt.key_on_edge && d1a_pkt.cur_state == EG_OFF) begin
                    // Start of note: jump to attack (or skip straight to SUS/DEC
                    // if rate==63 means instant attack).
                    new_vol = MAX_ATT_INDEX;
                    if (d1a_pkt.rate < 6'd63) new_state = EG_ATT;
                    else begin
                        new_vol = MIN_ATT_INDEX;
                        new_state = (d1a_pkt.regs.dl_idx != 4'h0) ? EG_DEC : EG_SUS;
                    end
                end else if (!d1a_pkt.regs.keyon && d1a_pkt.cur_state != EG_OFF) begin
                    new_state = EG_REL;
                end else begin
                    case (d1a_pkt.cur_state)
                        EG_ATT: begin
                            if (d1a_pkt.rate < 6'd63 && d1a_pkt.do_update) begin
                                new_vol = calc_attack_step(d1a_pkt.cur_vol, d1a_pkt.inc_v);
                                if (new_vol <= MIN_ATT_INDEX) begin
                                    new_vol   = MIN_ATT_INDEX;
                                    new_state = (d1a_pkt.regs.dl_idx != 4'h0)
                                              ? EG_DEC : EG_SUS;
                                end
                            end
                        end
                        EG_DEC: begin
                            if (d1a_pkt.do_update) begin
                                vol_add = {1'b0, d1a_pkt.cur_vol} + {3'd0, d1a_pkt.inc_v};
                                new_vol = (vol_add > 11'h3FF) ? 10'h3FF
                                                              : vol_add[9:0];
                                if (new_vol >= dl_tab_rom(d1a_pkt.regs.dl_idx)) begin
                                    new_state = (new_vol < MAX_ATT_INDEX)
                                              ? EG_SUS : EG_OFF;
                                end
                            end
                        end
                        EG_SUS: begin
                            if (d1a_pkt.do_update) begin
                                vol_add = {1'b0, d1a_pkt.cur_vol} + {3'd0, d1a_pkt.inc_v};
                                if (vol_add >= {1'b0, MAX_ATT_INDEX}) begin
                                    new_vol   = MAX_ATT_INDEX;
                                    new_state = EG_OFF;
                                end else new_vol = vol_add[9:0];
                            end
                        end
                        EG_REL: begin
                            if (d1a_pkt.do_update) begin
                                vol_add = {1'b0, d1a_pkt.cur_vol} + {3'd0, d1a_pkt.inc_v};
                                if (vol_add >= {1'b0, MAX_ATT_INDEX}) begin
                                    new_vol   = MAX_ATT_INDEX;
                                    new_state = EG_OFF;
                                end else new_vol = vol_add[9:0];
                            end
                        end
                        default: ;
                    endcase
                end

                d1_pkt.valid         <= 1'b1;
                d1_pkt.slot          <= d1a_pkt.slot;
                d1_pkt.pan           <= d1a_pkt.regs.pan;
                d1_pkt.tl            <= d1a_pkt.regs.tl;
                d1_pkt.interp        <= d1a_pkt.interp;
                d1_pkt.new_dyn       <= d1a_pkt.new_dyn;
                d1_pkt.next_eg_state <= new_state;
                d1_pkt.next_eg_vol   <= new_vol;
                d1_pkt.key_on_edge   <= d1a_pkt.key_on_edge;
            end
        end
    end

    // ── D2a: calc_vol stage 1 — compute tmp = (0x8000 * vol_mul) >>> vol_shift
    //    Splits calc_vol's two-multiplier chain.  Originally one cycle had
    //    32×8 mult → barrel shift → 16×32 mult → fixed shift (>>>15), which
    //    was the critical -10ns path.  Register tmp here, do sample×tmp next.
    always_ff @(posedge clk or negedge rst_n) begin
        logic [10:0] total_atten;
        logic [7:0]  vol_mul;
        logic [4:0]  vol_shift;
        // init for latch avoidance
        total_atten = 11'd0;
        vol_mul     = 8'd0;
        vol_shift   = 5'd0;

        if (!rst_n) begin
            d2a_pkt <= '0;
        end else begin
            d2a_pkt.valid <= d1_pkt.valid;
            if (d1_pkt.valid) begin
                total_atten = {1'b0, d1_pkt.next_eg_vol} + {1'b0, d1_pkt.tl, 2'b00};
                vol_mul     = 8'h80 - {2'b0, total_atten[5:0]};
                vol_shift   = 5'(4'd7 + {1'b0, total_atten[9:6]});

                d2a_pkt.slot        <= d1_pkt.slot;
                d2a_pkt.pan         <= d1_pkt.pan;
                d2a_pkt.new_dyn     <= d1_pkt.new_dyn;
                d2a_pkt.eg_state    <= d1_pkt.next_eg_state;
                d2a_pkt.eg_vol      <= d1_pkt.next_eg_vol;
                d2a_pkt.key_on_edge <= d1_pkt.key_on_edge;
                d2a_pkt.interp      <= d1_pkt.interp;
                d2a_pkt.silent      <= (total_atten >= 11'h280);
                d2a_pkt.tmp_vol     <= (32'sh8000 * $signed({1'b0, vol_mul})) >>> vol_shift;
            end
        end
    end

    // ── D2b: calc_vol stage 2 — vol_sample = (interp × tmp_vol) >>> 15
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            d2_pkt <= '0;
        end else begin
            d2_pkt.valid <= d2a_pkt.valid;
            if (d2a_pkt.valid) begin
                d2_pkt.slot        <= d2a_pkt.slot;
                d2_pkt.pan         <= d2a_pkt.pan;
                d2_pkt.new_dyn     <= d2a_pkt.new_dyn;
                d2_pkt.eg_state    <= d2a_pkt.eg_state;
                d2_pkt.eg_vol      <= d2a_pkt.eg_vol;
                d2_pkt.key_on_edge <= d2a_pkt.key_on_edge;
                d2_pkt.vol_sample  <= d2a_pkt.silent ? 32'sd0
                    : ($signed(d2a_pkt.interp) * d2a_pkt.tmp_vol) >>> 15;
            end
        end
    end

    // ── D3: pan_mul + accumulate + ram_dyn writeback + master framer ───────
    always_ff @(posedge clk or negedge rst_n) begin
        logic [5:0]            pan_l_gain, pan_r_gain;
        logic signed [23:0]    left_sample, right_sample;
        slot_dyn_t             dyn_upd;
        slot_dyn_t             dyn_reset;

        // Init to avoid latch
        pan_l_gain   = 6'd0;
        pan_r_gain   = 6'd0;
        left_sample  = 24'd0;
        right_sample = 24'd0;

        if (!rst_n) begin
            master_accum_left  <= '0;
            master_accum_right <= '0;
            pcm_left  <= '0;
            pcm_right <= '0;
            pcm_valid <= 1'b0;
            dyn_reset.pos       = 16'd0;
            dyn_reset.stepPtr   = 16'd0;
            dyn_reset.env_vol   = 10'h280;
            dyn_reset.env_state = 3'd0;
            for (int i = 0; i < 24; i++) ram_dyn[i] <= dyn_reset;
        end else begin
            pcm_valid <= 1'b0;

            if (d2_pkt.valid) begin
                pan_l_gain = pan_att_left (d2_pkt.pan);
                pan_r_gain = pan_att_right(d2_pkt.pan);
                left_sample  = 24'((d2_pkt.vol_sample * 32'($signed({26'd0, pan_l_gain}))) >>> 5);
                right_sample = 24'((d2_pkt.vol_sample * 32'($signed({26'd0, pan_r_gain}))) >>> 5);
                master_accum_left  <= master_accum_left  + left_sample;
                master_accum_right <= master_accum_right + right_sample;

                dyn_upd            = d2_pkt.new_dyn;
                dyn_upd.env_state  = d2_pkt.eg_state;
                dyn_upd.env_vol    = d2_pkt.eg_vol;
                if (d2_pkt.key_on_edge) begin
                    dyn_upd.pos     = 16'd0;
                    dyn_upd.stepPtr = 16'd0;
                end
                ram_dyn[d2_pkt.slot] <= dyn_upd;
            end

            if (sample_start) begin
                // Master_accum is 24-bit signed.  Per-slot post-vol/pan
                // output is ~16-bit signed (~±32767).  With 24 slots the
                // accumulator can reach ~±786432 = ~20-bit.
                //
                // Taking [15:0] (no scaling) saturates as soon as 2 slots
                // play at full volume — exactly what we observed on hw
                // (peak 0 dBFS distortion).
                //
                // Take [19:4] = master_accum >>> 4: single slot peak ≈
                // -24 dB, 8 simultaneous slots ≈ -6 dB, 16 slots ≈ 0 dB
                // (graceful saturation only beyond that).
                if (master_accum_left[23:19] == 5'b00000
                 || master_accum_left[23:19] == 5'b11111) begin
                    pcm_left <= master_accum_left[19:4];
                end else begin
                    pcm_left <= master_accum_left[23] ? 16'sh8000 : 16'sh7FFF;
                end
                if (master_accum_right[23:19] == 5'b00000
                 || master_accum_right[23:19] == 5'b11111) begin
                    pcm_right <= master_accum_right[19:4];
                end else begin
                    pcm_right <= master_accum_right[23] ? 16'sh8000 : 16'sh7FFF;
                end
                pcm_valid <= 1'b1;
                master_accum_left  <= '0;
                master_accum_right <= '0;
            end
        end
    end

    // ════════════════════════════════════════════════════════════════════════
    // CPU register writes
    //
    // YMF278B PCM register map (port 0x7E/7F, address space 0x00-0xFF):
    //   0x02            : wavetable header offset (bits[4:2])
    //   0x03-0x06       : memory address registers (CPU↔PCM RAM)   [TODO]
    //   0x08..0xF7      : 24 slots × 10 fields = 240 regs
    //                     wr_snum  = (addr - 0x08) % 24
    //                     wr_field = (addr - 0x08) / 24
    //     field 0  : wave[7:0]                                  → +hf_pending
    //     field 1  : wave[8] | fn[6:0]<<1                       → +hf_pending
    //     field 2  : fn[9:7] | prvb<<3 | oct<<4
    //     field 3  : tl<<1 | tl_load_imm
    //     field 4  : pan[3:0] | mute(8) | damp<<6 | keyon<<7
    //     field 5  : vib[2:0] | lfo_speed[5:3]
    //     field 6  : d1r[3:0] | ar[7:4]
    //     field 7  : d2r[3:0] | dl_idx[7:4]
    //     field 8  : rr[3:0]  | rc[7:4]
    //     field 9  : am[2:0]
    // ════════════════════════════════════════════════════════════════════════
    logic [2:0]  wavetblhdr;
    logic [23:0] hf_pending;

    // Forward declarations for HF FSM signals (defined fully later) so the
    // CPU register decoder can reference hf_state/hf_cur_slot/hf_buf when
    // implementing the auto-backfill of slot regs at HF_STORE time.
    typedef enum logic [2:0] { HF_IDLE, HF_REQ, HF_WAIT, HF_STORE } hf_state_t;
    hf_state_t   hf_state;
    logic [4:0]  hf_cur_slot;
    logic [8:0]  hf_cur_wave;
    logic [3:0]  hf_byte_idx;
    logic [7:0]  hf_buf [0:11];

    wire [4:0]  wr_snum  = (reg_addr >= 8'h08) ? 5'((reg_addr - 8'h08) % 8'd24) : 5'd0;
    wire [3:0]  wr_field = (reg_addr >= 8'h08) ? 4'((reg_addr - 8'h08) / 8'd24) : 4'd0;
    wire        wr_slot_reg = reg_wr && (reg_addr >= 8'h08) && (reg_addr <= 8'hF7);

    // hf_pending is driven by a dedicated always_ff (below) to avoid
    // multi-driver between the CPU decoder (sets bit on wave write) and
    // the HF FSM (clears bit on pickup).

    always_ff @(posedge clk or negedge rst_n) begin
        // Read-modify-write of the slot reg struct (iverilog rejects partial
        // bit assignment into an unpacked-array element indexed by variable).
        slot_regs_t reg_upd;
        logic [6:0] tl_t;

        if (!rst_n) begin
            wavetblhdr <= '0;
            for (int i = 0; i < 24; i++) ram_regs[i] <= '0;
        end else begin
            if (reg_wr && reg_addr == 8'h02) begin
                wavetblhdr <= reg_data[4:2];
            end
            if (wr_slot_reg) begin
                reg_upd = ram_regs[wr_snum];
                case (wr_field)
                    4'd0: begin
                        reg_upd.wave[7:0] = reg_data[7:0];
                    end
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
                        // TL with load-immediate flag (bit 0).  Skip TL ramp
                        // logic from legacy v1 (sr_TLdest/sr_TL) — directly
                        // load the destination value.  TODO: implement TL ramp.
                        tl_t = reg_data[7:1];
                        reg_upd.tl = (tl_t != 7'h7F) ? {1'b0, tl_t} : 8'hFF;
                    end
                    4'd4: begin
                        reg_upd.pan   = reg_data[4] ? 4'd8 : reg_data[3:0];
                        reg_upd.damp  = reg_data[6];
                        reg_upd.keyon = reg_data[7];
                        // TODO: lfo_active/lfo_reset (reg_data[5]) needs LFO engine
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

            // ────────────────────────────────────────────────────────────
            // Header auto-backfill on HF_STORE (chip spec behavior).
            // Per YMF278B datasheet + openMSX YMF278.cc:610-614: writing a
            // wave number triggers the chip to load the 12-byte header from
            // external memory, and bytes 7..11 are auto-written back into
            // the slot's LFO/VIB/AR/D1R/DL/D2R/RC/RR/AM registers.  MB and
            // most yrw801-using software rely on these header defaults and
            // don't write those fields from the CPU side.
            //
            // If a CPU write to the same slot's fields lands in the same
            // cycle, the HF backfill wins (matches "do not access during
            // LD=1" rule).  Different slot — both writes commit (memory).
            if (hf_state == HF_STORE) begin
                slot_regs_t hf_upd;
                // If a CPU write to this same slot lands this cycle, pick up
                // its just-modified blocking value (`reg_upd`) so that wave/
                // fn/oct/pan/keyon/tl set by the CPU on this cycle are NOT
                // lost when the HF NBA to `ram_regs[hf_cur_slot]` fires after
                // the CPU NBA.  Otherwise read the latched value as before.
                if (wr_slot_reg && wr_snum == hf_cur_slot)
                    hf_upd = reg_upd;
                else
                    hf_upd = ram_regs[hf_cur_slot];
                hf_upd.lfo_speed = hf_buf[7][5:3];
                hf_upd.vib       = hf_buf[7][2:0];
                hf_upd.ar        = hf_buf[8][7:4];
                hf_upd.d1r       = hf_buf[8][3:0];
                hf_upd.dl_idx    = hf_buf[9][7:4];
                hf_upd.d2r       = hf_buf[9][3:0];
                hf_upd.rc        = hf_buf[10][7:4];
                hf_upd.rr        = hf_buf[10][3:0];
                hf_upd.am        = hf_buf[11][2:0];
                ram_regs[hf_cur_slot] <= hf_upd;
            end
        end
    end

    // ════════════════════════════════════════════════════════════════════════
    // Header Fetch (HF) FSM
    //
    // When the CPU writes wave[7:0] or wave[8]/fn[6:0] for a slot, hf_pending
    // bit is set.  This FSM walks the pending bits, reading the 12-byte
    // sample header from PCM ROM and writing ram_header[slot].
    //
    // Address (matches openMSX YMF278.cc + legacy v1):
    //   wave < 384 || wavetblhdr == 0:
    //     addr = wave * 12 + byte_idx
    //   else:
    //     addr = (wavetblhdr << 19) + (wave - 384) * 12 + byte_idx
    //
    // Time budget: idle frame window = CYCLES_PER_FRAME - PIPELINE_END = 220
    // cycles.  12 bytes × ~7 cycles (5-cycle bridge round-trip + state ovhd)
    // = ~84 cycles for one slot's HF.  Plenty of slack.
    //
    // SDRAM arbitration: HF only runs when (frame_cycle >= PIPELINE_END), so
    // Stage B sequencer is idle (B_IDLE/B_DONE).  The mem_addr/mem_rd_en mux
    // below gives HF priority during the idle window; mem_rd_valid is gated
    // away from Stage B while HF_WAIT is active.
    // ════════════════════════════════════════════════════════════════════════
    // (hf_state, hf_cur_slot, hf_cur_wave, hf_byte_idx, hf_buf declared
    //  earlier near wavetblhdr — needed by CPU decoder for HF backfill.)

    // Combinational HF byte address (depends on cur_wave/byte_idx).
    wire [21:0] hf_addr_comb = (hf_cur_wave < 9'd384 || wavetblhdr == 3'd0)
        ? 22'(({13'd0, hf_cur_wave} * 22'd12) + {18'd0, hf_byte_idx})
        : 22'({wavetblhdr, 19'd0}
            + ({13'd0, (hf_cur_wave - 9'd384)} * 22'd12)
            + {18'd0, hf_byte_idx});

    // Priority-encode lowest-numbered hf_pending bit.
    logic [4:0]  hf_picked;
    logic        hf_found;
    always_comb begin
        hf_picked = 5'd0;
        hf_found  = 1'b0;
        for (int i = 0; i < 24; i++) begin
            if (hf_pending[i] && !hf_found) begin
                hf_picked = 5'(i);
                hf_found  = 1'b1;
            end
        end
    end

    // Normally the CPU/HF SDRAM window is the frame tail [PIPELINE_END, end).
    // In memory-access mode the audio pipeline is halted (dispatch suppressed),
    // so the bus is free the whole frame — open the window continuously so CPU
    // reg 0x06 uploads issue immediately and none are lost between frame tails.
    wire hf_window_open = (frame_cycle >= PIPELINE_END) || reg02_mem_access_mode;
    assign hf_active    = (hf_state == HF_REQ) || (hf_state == HF_WAIT);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hf_state    <= HF_IDLE;
            hf_cur_slot <= '0;
            // hf_cur_wave reset handled by its dedicated always_ff
            hf_byte_idx <= '0;
            for (int i = 0; i < 12; i++) hf_buf[i] <= '0;
        end else begin
            case (hf_state)
                HF_IDLE: if (hf_window_open && hf_found && !cpu_rd_outstanding) begin
                    hf_cur_slot <= hf_picked;
                    // hf_cur_wave is loaded by a separate always_ff (uses
                    // hf_picked_regs intermediate due to iverilog limitation).
                    hf_byte_idx <= 4'd0;
                    hf_state    <= HF_REQ;
                end
                HF_REQ: begin
                    // Address is driven combinationally from hf_addr_comb;
                    // arbiter latches mem_addr/mem_rd_en this same cycle.
                    hf_state <= HF_WAIT;
                end
                HF_WAIT: if (mem_rd_valid) begin
                    hf_buf[hf_byte_idx] <= mem_rd_data;
                    if (hf_byte_idx == 4'd11) begin
                        hf_state <= HF_STORE;
                    end else begin
                        hf_byte_idx <= hf_byte_idx + 4'd1;
                        hf_state    <= HF_REQ;
                    end
                end
                HF_STORE: begin
                    // ram_header write happens in its own always_ff (below)
                    // because iverilog can't mix unpacked-array writes with
                    // this FSM's RMW.  HF_STORE is just a 1-cycle marker.
                    hf_state <= HF_IDLE;
                end
                default: hf_state <= HF_IDLE;
            endcase
        end
    end

    // Fetch wave number on HF_IDLE → HF_REQ transition (slot picked combinationally).
    // Done via a separate always_ff that reads ram_regs[hf_picked].wave through
    // a typed struct intermediate (iverilog limitation).
    slot_regs_t hf_picked_regs;
    always_comb hf_picked_regs = ram_regs[hf_picked];

    // Load hf_cur_wave when entering HF_REQ (slot picked at HF_IDLE).
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) hf_cur_wave <= '0;
        else if (hf_state == HF_IDLE && hf_window_open && hf_found)
            hf_cur_wave <= hf_picked_regs.wave;
    end

    // ram_header write + hf_pending clear at HF_STORE.
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
        end else if (hf_state == HF_STORE) begin
            ram_header[hf_cur_slot] <= hf_hdr_built;
            // TODO: also override ram_regs[hf_cur_slot] LFO/AR/D1R/DL/D2R/
            // RC/RR/AM from hf_buf[7..11].  Skipped for v2 MVP — CPU writes
            // typically supersede these defaults anyway.
        end
    end

    // Consolidated hf_pending driver: CPU decoder sets bit on wave write
    // (field 0 or 1); HF FSM clears bit when it picks the slot.  If both
    // happen same cycle for same slot, SET wins (the new write was issued
    // after the pick, so the pending request must persist).
    wire wr_sets_hf = wr_slot_reg && (wr_field == 4'd0 || wr_field == 4'd1);
    wire hf_pick_now = (hf_state == HF_IDLE) && hf_window_open && hf_found;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hf_pending <= '0;
        end else begin
            if (hf_pick_now) hf_pending[hf_picked] <= 1'b0;
            if (wr_sets_hf)  hf_pending[wr_snum]   <= 1'b1; // wins over clear
        end
    end

    // ════════════════════════════════════════════════════════════════════════
    // CPU memory access (registers 0x02 mode/type, 0x03-0x05 address, 0x06 data)
    //
    // Per YMF278B spec:
    //   - reg 0x02 [0] = memory_access_mode (1 = CPU mem access; channels stop)
    //   - reg 0x02 [1] = memory_type (0 = ROM only, 1 = SRAM + ROM)
    //   - reg 0x03/04/05 latch a 24-bit memory address (high → mid → low)
    //   - reg 0x05 write completes address setting + triggers initial prefetch
    //   - reg 0x06 read returns the prefetched byte and starts the next prefetch
    //   - reg 0x06 write queues a write to that address
    //   - The address auto-increments after each 0x06 access
    //
    // Implementation: a low-priority requester on the SDRAM port, scheduled
    // only when HF FSM and Stage B sequencer are both idle.
    // cpu_rd_outstanding declared earlier near mem_rd_valid_b.
    // ════════════════════════════════════════════════════════════════════════
    logic        reg02_mem_type;
    logic [23:0] cpu_mem_adr;
    logic        cpu_rd_pend;
    logic        cpu_wr_pend;
    logic [7:0]  cpu_wr_data_latch;
    logic [7:0]  cpu_mem_rd_buf;

    wire cpu_adr_set_l = reg_wr && (reg_addr == 8'h05);
    wire cpu_rd_06     = reg_rd && (reg_addr == 8'h06);
    wire cpu_wr_06     = reg_wr && (reg_addr == 8'h06);

    wire cpu_issue_ok = hf_window_open
                     && (hf_state == HF_IDLE)
                     && (b_state == B_IDLE || b_state == B_DONE)
                     && !cpu_rd_outstanding;
    wire cpu_rd_issue_now = cpu_rd_pend && cpu_issue_ok;
    wire cpu_wr_issue_now = cpu_wr_pend && cpu_issue_ok && !cpu_rd_pend; // RD prio

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reg02_mem_access_mode <= 1'b0;
            reg02_mem_type        <= 1'b0;
        end else if (reg_wr && reg_addr == 8'h02) begin
            reg02_mem_access_mode <= reg_data[0];
            reg02_mem_type        <= reg_data[1];
        end
    end

    // cpu_mem_adr — 24-bit address.
    //   reads: increment at the 06H reg_rd (pipelined — returns the OLD
    //          buffered byte; next prefetch reads the NEW address).
    //   writes: increment AT ISSUE time (cpu_wr_issue_now), not at 06H reg_wr,
    //          so that mem_addr at issue still equals the address the CPU
    //          intended.  Incrementing at reg_wr would push the write a byte
    //          past the target.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) cpu_mem_adr <= '0;
        else begin
            if (reg_wr && reg_addr == 8'h03) cpu_mem_adr[23:16] <= reg_data;
            if (reg_wr && reg_addr == 8'h04) cpu_mem_adr[15:8]  <= reg_data;
            if (cpu_adr_set_l)               cpu_mem_adr[7:0]   <= reg_data;
            if (cpu_rd_06 && !cpu_adr_set_l)        cpu_mem_adr <= cpu_mem_adr + 24'd1;
            if (cpu_wr_issue_now && !cpu_adr_set_l) cpu_mem_adr <= cpu_mem_adr + 24'd1;
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
            if (cpu_rd_issue_now) cpu_rd_pend <= 1'b0;
            if (cpu_adr_set_l || cpu_rd_06) cpu_rd_pend <= 1'b1;
            if (cpu_wr_issue_now) cpu_wr_pend <= 1'b0;
            if (cpu_wr_06) cpu_wr_pend <= 1'b1;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) cpu_rd_outstanding <= 1'b0;
        else begin
            if (cpu_rd_issue_now) cpu_rd_outstanding <= 1'b1;
            else if (mem_rd_valid && cpu_rd_outstanding) cpu_rd_outstanding <= 1'b0;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) cpu_mem_rd_buf <= '0;
        else if (mem_rd_valid && cpu_rd_outstanding) cpu_mem_rd_buf <= mem_rd_data;
    end

    assign cpu_mem_rd_data = cpu_mem_rd_buf;
    assign cpu_mem_busy    = cpu_rd_pend | cpu_wr_pend | cpu_rd_outstanding;

    // Reg 0x02 read-back (per YMF278B datasheet page 14):
    //   D7-D5 = device ID (3'b001 = 0x20 nibble pattern, D5=1, D6=0, D7=0)
    //   D4-D2 = wave-table header (wavetblhdr)
    //   D1    = memory type
    //   D0    = memory access mode
    // Software that wrote any non-zero mode/type/hdr value back expects to
    // read it back here.  Hardcoding 0x20 (as we did before) made strict
    // device-probe code fail.
    assign reg02_readback = {3'b001, wavetblhdr, reg02_mem_type, reg02_mem_access_mode};

    // ════════════════════════════════════════════════════════════════════════
    // SDRAM port arbitration: HF (high prio during idle window) vs Stage B
    // vs CPU mem access (lowest).
    // Both sources drive a 1-cycle mem_rd_en pulse with addr; msx.sv bridge
    // edge-detects rd_en and captures addr on rising edge.
    // ════════════════════════════════════════════════════════════════════════
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mem_addr    <= '0;
            mem_rd_en   <= 1'b0;
            mem_wr_en   <= 1'b0;
            mem_wr_data <= '0;
        end else begin
            // mem_rd_en/mem_wr_en pulse 1 cycle.  mem_addr/mem_wr_data
            // HOLD until the next issue — this is essential because the
            // msx.sv bridge transitions IDLE→state1 one cycle after seeing
            // ms_mem_wr_req, and the SDRAM controller then samples ch4_din
            // one more cycle later (on its own ch4_req edge detect).  By
            // that point the engine has long dropped the rd/wr enable, so
            // the address and data must remain stable.
            // (Comment above the wr_data default — "latch inference" — was
            //  inaccurate; always_ff cannot infer latches.  Removed.)
            mem_rd_en   <= 1'b0;
            mem_wr_en   <= 1'b0;

            if (hf_state == HF_REQ) begin
                mem_addr  <= hf_addr_comb;
                mem_rd_en <= 1'b1;
            end else if (b_state == B_ISSUE && !mem_busy) begin
                // mem_busy guard: if the ch4 bridge is still processing the
                // previous read (state 1/2/3), edge-detect on IDLE would
                // silently drop our pulse.  Hold until bridge returns to IDLE.
                mem_addr  <= b_addr_sel;
                mem_rd_en <= 1'b1;
            end else if (cpu_wr_issue_now) begin
                mem_addr    <= cpu_mem_adr[21:0];
                mem_wr_en   <= 1'b1;
                mem_wr_data <= cpu_wr_data_latch;
            end else if (cpu_rd_issue_now) begin
                mem_addr  <= cpu_mem_adr[21:0];
                mem_rd_en <= 1'b1;
            end
        end
    end

    // (mem_rd_valid_b — the HF-gated valid signal for Stage B — is declared
    // earlier as a forward reference near the Stage B sequencer.)

    // ════════════════════════════════════════════════════════════════════════
    // Debug output ports — flatten select per-slot reg fields for testbench
    // observation.  Synthesis tools will optimize these away when unused.
    //
    // iverilog quirk: can't access `.field` on an unpacked-array-of-packed-
    // struct element directly.  Stage through typed intermediate signals.
    // ════════════════════════════════════════════════════════════════════════
    slot_regs_t   dbg_slot0_struct, dbg_slot5_struct, dbg_slot23_struct;
    slot_header_t dbg_slot0_hdr_struct;
    slot_dyn_t    dbg_slot0_dyn_struct;
    always_comb begin
        dbg_slot0_struct     = ram_regs[0];
        dbg_slot5_struct     = ram_regs[5];
        dbg_slot23_struct    = ram_regs[23];
        dbg_slot0_hdr_struct = ram_header[0];
        dbg_slot0_dyn_struct = ram_dyn[0];
    end

    assign dbg_wavetblhdr  = wavetblhdr;
    assign dbg_hf_pending  = hf_pending;
    assign dbg_slot0_wave  = dbg_slot0_struct.wave;
    assign dbg_slot0_fn    = dbg_slot0_struct.fn;
    assign dbg_slot0_oct   = dbg_slot0_struct.oct;
    assign dbg_slot0_prvb  = dbg_slot0_struct.prvb;
    assign dbg_slot0_keyon = dbg_slot0_struct.keyon;
    assign dbg_slot0_damp  = dbg_slot0_struct.damp;
    assign dbg_slot0_pan   = dbg_slot0_struct.pan;
    assign dbg_slot0_ar    = dbg_slot0_struct.ar;
    assign dbg_slot0_d1r   = dbg_slot0_struct.d1r;
    assign dbg_slot5_wave  = dbg_slot5_struct.wave;
    assign dbg_slot23_wave = dbg_slot23_struct.wave;
    assign dbg_slot0_hdr_start = dbg_slot0_hdr_struct.startAddr;
    assign dbg_slot0_hdr_loop  = dbg_slot0_hdr_struct.loopAddr;
    assign dbg_slot0_hdr_end   = dbg_slot0_hdr_struct.endAddr;
    assign dbg_slot0_hdr_bits  = dbg_slot0_hdr_struct.bits;
    assign dbg_slot0_dyn_pos       = dbg_slot0_dyn_struct.pos;
    assign dbg_slot0_dyn_stepPtr   = dbg_slot0_dyn_struct.stepPtr;
    assign dbg_slot0_dyn_env_vol   = dbg_slot0_dyn_struct.env_vol;
    assign dbg_slot0_dyn_env_state = dbg_slot0_dyn_struct.env_state;
    assign dbg_stage_b_bytes_done  = stage_b_bytes_done;
    assign dbg_stage_advance       = stage_advance;
    assign dbg_stage_b_valid       = stage_b_reg.valid;

    // ════════════════════════════════════════════════════════════════════════
    // Initial values for ram_header (simulation only — real SRAM/BRAM starts
    // at 0 in Quartus anyway)
    // ════════════════════════════════════════════════════════════════════════
    initial begin
        for (int i = 0; i < 24; i++) ram_header[i] = '0;
    end

endmodule

`default_nettype wire
