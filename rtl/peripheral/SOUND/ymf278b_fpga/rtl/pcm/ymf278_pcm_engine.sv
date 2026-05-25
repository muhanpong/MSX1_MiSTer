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

    // SDRAM Direct Port
    output logic [21:0] mem_addr,
    output logic        mem_rd_en,
    input  wire  [7:0]  mem_rd_data,
    input  wire         mem_rd_valid,
    output logic        mem_wr_en,
    output logic [7:0]  mem_wr_data,

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
    output logic [8:0]  dbg_slot23_wave
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

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            frame_cycle <= '0;
            cur_slot    <= '0;
            slot_phase  <= '0;
            eg_cnt      <= '0;
        end else begin
            if (frame_cycle == CYCLES_PER_FRAME - 1) begin
                frame_cycle <= '0;
                cur_slot    <= '0;
                slot_phase  <= '0;
                eg_cnt      <= eg_cnt + 24'd1;
            end else begin
                frame_cycle <= frame_cycle + 11'd1;
                if (slot_phase == 6'd63) begin
                    slot_phase <= '0;
                    if (cur_slot != 5'd23) cur_slot <= cur_slot + 5'd1;
                end else begin
                    slot_phase <= slot_phase + 6'd1;
                end
            end
        end
    end

    wire in_dispatch_window = (frame_cycle < SLOT_DISPATCH_CYCLES);
    wire in_pipeline_window = (frame_cycle < PIPELINE_END);
    wire sample_start       = (frame_cycle == CYCLES_PER_FRAME - 1);
    // dispatch_now: a new slot enters Stage A
    wire dispatch_now       = (slot_phase == 6'd0) && in_dispatch_window;
    // stage_advance: pulses at the end of every 64-cycle window, including the
    // drain windows after dispatch is done (so in-flight slots finish).
    // Suppressed after pipeline drain so HF/CPU FSMs can use SDRAM uninterrupted.
    wire stage_advance      = (slot_phase == 6'd63) && in_pipeline_window;

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
        logic [3:0][7:0] bytes;      // a0, a1, b0, b1 — filled by sequencer
    } stage_b_pkt_t;

    typedef struct packed {
        logic            valid;
        logic [4:0]      slot;
        slot_regs_t      regs;
        slot_dyn_t       dyn;       // pos/stepPtr from Stage B
        logic [3:0][7:0] bytes;
        logic signed [15:0] interp;
    } stage_c_pkt_t;

    stage_a_pkt_t stage_a_reg;   // latched at dispatch_now, held for 8 cycles
    stage_b_pkt_t stage_b_reg;   // latched at stage_advance
    stage_c_pkt_t stage_c_reg;   // latched at stage_advance

    // ALU instance for combinational functions (calc_step, byte_addr, etc.)
    ymf278_pcm_alu alu();

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

    // Combinational computation off stage_a_reg
    logic [31:0]      next_step_full;
    logic [15:0]      next_stepPtr;
    logic [15:0]      next_pos;
    logic [15:0]      next_pos_for_b;
    byte_addrs_t      next_addrs;

    always_comb begin
        // VIB=0 for now; TODO wire up LFO VIB output
        next_step_full = alu.calc_step(stage_a_reg.regs.oct,
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

        // next_pos_for_b = next_pos + 1 (with loop wrap)
        next_pos_for_b = next_pos_calc(next_pos, 16'd1,
                                       stage_a_reg.header.endAddr,
                                       stage_a_reg.header.loopAddr);

        // 6 byte addresses
        next_addrs.a0 = alu.byte_addr(stage_a_reg.header.startAddr,
                                       next_pos, stage_a_reg.header.bits, 2'd0);
        next_addrs.a1 = alu.byte_addr(stage_a_reg.header.startAddr,
                                       next_pos, stage_a_reg.header.bits, 2'd1);
        next_addrs.a2 = alu.byte_addr(stage_a_reg.header.startAddr,
                                       next_pos, stage_a_reg.header.bits, 2'd2);
        next_addrs.b0 = alu.byte_addr(stage_a_reg.header.startAddr,
                                       next_pos_for_b, stage_a_reg.header.bits, 2'd0);
        next_addrs.b1 = alu.byte_addr(stage_a_reg.header.startAddr,
                                       next_pos_for_b, stage_a_reg.header.bits, 2'd1);
        next_addrs.b2 = alu.byte_addr(stage_a_reg.header.startAddr,
                                       next_pos_for_b, stage_a_reg.header.bits, 2'd2);
    end

    // ────────────────────────────────────────────────────────────────────────
    // Stage B serial SDRAM sequencer.
    // States: IDLE → ISSUE → WAIT_VALID → NEXT (latch) → ISSUE / DONE.
    // Issues a 1-cycle mem_rd_en pulse (msx.sv bridge uses edge detection),
    // waits for mem_rd_valid, latches into stage_b_reg.bytes[idx], advances.
    // ────────────────────────────────────────────────────────────────────────
    typedef enum logic [2:0] {
        B_IDLE, B_ISSUE, B_WAIT_VALID, B_NEXT, B_DONE
    } b_state_t;

    b_state_t   b_state;
    logic [1:0] b_byte_idx;     // 0..3
    logic [21:0] b_addr_sel;

    always_comb begin
        case (b_byte_idx)
            2'd0: b_addr_sel = stage_b_reg.addrs.a0;
            2'd1: b_addr_sel = stage_b_reg.addrs.a1;
            2'd2: b_addr_sel = stage_b_reg.addrs.b0;
            2'd3: b_addr_sel = stage_b_reg.addrs.b1;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            b_state    <= B_IDLE;
            b_byte_idx <= '0;
        end else if (stage_advance) begin
            // New slot enters Stage B every stage_advance.  Restart sequencer
            // regardless of previous state — this guarantees forward progress
            // even if prior slot didn't finish.
            if (stage_a_reg.valid) begin
                b_state    <= B_ISSUE;
                b_byte_idx <= 2'd0;
            end else begin
                b_state <= B_IDLE;
            end
        end else begin
            case (b_state)
                B_IDLE:       ;   // wait for stage_advance
                B_ISSUE:      b_state <= B_WAIT_VALID;
                B_WAIT_VALID: if (mem_rd_valid) b_state <= B_NEXT;
                B_NEXT: begin
                    if (b_byte_idx == 2'd3) b_state <= B_DONE;
                    else begin
                        b_byte_idx <= b_byte_idx + 2'd1;
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
            stage_b_reg.dyn.pos       <= next_pos;
            stage_b_reg.dyn.stepPtr   <= next_stepPtr;
            stage_b_reg.dyn.env_vol   <= stage_a_reg.dyn.env_vol;
            stage_b_reg.dyn.env_state <= stage_a_reg.dyn.env_state;
            stage_b_reg.next_pos <= next_pos_for_b;
            stage_b_reg.addrs    <= next_addrs;
            stage_b_reg.bytes    <= '0;
        end else if (b_state == B_WAIT_VALID && mem_rd_valid) begin
            case (b_byte_idx)
                2'd0: stage_b_reg.bytes[0] <= mem_rd_data;
                2'd1: stage_b_reg.bytes[1] <= mem_rd_data;
                2'd2: stage_b_reg.bytes[2] <= mem_rd_data;
                2'd3: stage_b_reg.bytes[3] <= mem_rd_data;
            endcase
        end
    end

    // Stage B "done" indicator (combinational): true when sequencer has
    // collected all 4 bytes, or the slot is idle.
    wire stage_b_bytes_done = (b_state == B_DONE)
                            || (b_state == B_IDLE && !stage_b_reg.valid);

    // ════════════════════════════════════════════════════════════════════════
    // Stage C — decode fetched bytes into samples A/B, linear interpolate.
    //
    // Buffer layout (filled by Stage B sequencer):
    //   bytes[0] = byte_addr(p,   fmt, 0)   ─┐  "sample A bytes"
    //   bytes[1] = byte_addr(p,   fmt, 1)   ─┘
    //   bytes[2] = byte_addr(p+1, fmt, 0)   ─┐  "sample B bytes"
    //   bytes[3] = byte_addr(p+1, fmt, 1)   ─┘
    //
    // alu.decode_sample(b0,b1,b2,p,fmt):
    //   8-bit  : sample = {b0, 8'h0}            (uses b0)
    //   12-bit : packed (uses b0,b1,b2)         ← needs 3rd byte we don't fetch
    //   16-bit : sample = {b0, b1}              (uses b0,b1)
    //
    // For 8/16-bit our layout is correct.  For 12-bit, b2 input is zeroed —
    // produces wrong nibble in samples.  TODO: fetch 3rd byte or adjust
    // byte_addr semantics to pack 4 consecutive bytes for 12-bit chunks.
    // ════════════════════════════════════════════════════════════════════════
    logic signed [15:0] samp_a, samp_b;
    logic signed [15:0] interp_val;

    always_comb begin
        samp_a = alu.decode_sample(
            stage_b_reg.bytes[0],
            stage_b_reg.bytes[1],
            8'h00,                       // TODO 12-bit b2
            stage_b_reg.dyn.pos,
            stage_b_reg.header.bits
        );
        samp_b = alu.decode_sample(
            stage_b_reg.bytes[2],
            stage_b_reg.bytes[3],
            8'h00,                       // TODO 12-bit b2
            stage_b_reg.next_pos,
            stage_b_reg.header.bits
        );
        interp_val = alu.calc_interp(samp_a, samp_b, stage_b_reg.dyn.stepPtr);
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
    // Stage D — TODO: EG, volume, pan, accumulate, BRAM writeback
    // Also: master output framer (pushes pcm_left/right at sample_start).
    // ════════════════════════════════════════════════════════════════════════
    logic signed [23:0] master_accum_left;
    logic signed [23:0] master_accum_right;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            master_accum_left  <= '0;
            master_accum_right <= '0;
            pcm_left  <= '0;
            pcm_right <= '0;
            pcm_valid <= 1'b0;
            key_on_prev <= '0;
            begin
                slot_dyn_t dyn_reset;
                dyn_reset.pos       = 16'd0;
                dyn_reset.stepPtr   = 16'd0;
                dyn_reset.env_vol   = 10'h280;
                dyn_reset.env_state = 3'd0;
                for (int i = 0; i < 24; i++) ram_dyn[i] <= dyn_reset;
            end
        end else begin
            pcm_valid <= 1'b0;

            // Writeback updated dyn at the boundary between Stage C/D
            // (Stage D entry).  TODO: write the *processed* dyn from Stage D
            // logic, not the C carry-through.
            if (stage_advance && stage_c_reg.valid) begin
                ram_dyn[stage_c_reg.slot] <= stage_c_reg.dyn;
            end

            if (sample_start) begin
                pcm_left  <= master_accum_left[23:8];
                pcm_right <= master_accum_right[23:8];
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

    wire [4:0]  wr_snum  = (reg_addr >= 8'h08) ? 5'((reg_addr - 8'h08) % 8'd24) : 5'd0;
    wire [3:0]  wr_field = (reg_addr >= 8'h08) ? 4'((reg_addr - 8'h08) / 8'd24) : 4'd0;
    wire        wr_slot_reg = reg_wr && (reg_addr >= 8'h08) && (reg_addr <= 8'hF7);

    always_ff @(posedge clk or negedge rst_n) begin
        // Read-modify-write of the slot reg struct (iverilog rejects partial
        // bit assignment into an unpacked-array element indexed by variable).
        slot_regs_t reg_upd;
        logic [6:0] tl_t;

        if (!rst_n) begin
            wavetblhdr <= '0;
            hf_pending <= '0;
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
                        hf_pending[wr_snum] <= 1'b1;
                    end
                    4'd1: begin
                        reg_upd.wave[8] = reg_data[0];
                        reg_upd.fn[6:0] = reg_data[7:1];
                        hf_pending[wr_snum] <= 1'b1;
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
        end
    end

    // ════════════════════════════════════════════════════════════════════════
    // SDRAM port arbitration (SCSP-style priority).  Currently only Stage B
    // drives the port; HF and CPU write FSMs will use the idle window
    // (frame_cycle >= PIPELINE_END) once implemented.
    // ════════════════════════════════════════════════════════════════════════
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mem_addr    <= '0;
            mem_rd_en   <= 1'b0;
            mem_wr_en   <= 1'b0;
            mem_wr_data <= '0;
        end else begin
            mem_rd_en   <= 1'b0;
            mem_wr_en   <= 1'b0;

            // Stage B sequencer pulse: 1 cycle of mem_rd_en when in B_ISSUE.
            if (b_state == B_ISSUE) begin
                mem_addr  <= b_addr_sel;
                mem_rd_en <= 1'b1;
            end
            // TODO: HF FSM drives mem_addr/mem_rd_en when frame_cycle >= PIPELINE_END.
            // TODO: CPU write FIFO drives mem_wr_en when frame_cycle >= PIPELINE_END.
        end
    end

    // ════════════════════════════════════════════════════════════════════════
    // Debug output ports — flatten select per-slot reg fields for testbench
    // observation.  Synthesis tools will optimize these away when unused.
    //
    // iverilog quirk: can't access `.field` on an unpacked-array-of-packed-
    // struct element directly.  Stage through typed intermediate signals.
    // ════════════════════════════════════════════════════════════════════════
    slot_regs_t dbg_slot0_struct, dbg_slot5_struct, dbg_slot23_struct;
    always_comb begin
        dbg_slot0_struct  = ram_regs[0];
        dbg_slot5_struct  = ram_regs[5];
        dbg_slot23_struct = ram_regs[23];
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

    // ════════════════════════════════════════════════════════════════════════
    // Initial values for ram_header (simulation only — real SRAM/BRAM starts
    // at 0 in Quartus anyway)
    // ════════════════════════════════════════════════════════════════════════
    initial begin
        for (int i = 0; i < 24; i++) ram_header[i] = '0;
    end

endmodule

`default_nettype wire
