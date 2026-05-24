`default_nettype none

// YMF278B PCM Engine v2 — SCSP-Style Parallel Pipeline
//
// Architecture:
//   24 slots, each given an 8-cycle "window" once per audio frame.  Four
//   pipeline stages (A/B/C/D) operate on different slots in the same window:
//
//     slot N   in Stage A at  N*8 .. N*8+7
//     slot N-1 in Stage B at  N*8 .. N*8+7   (advanced from Stage A at N*8-1)
//     slot N-2 in Stage C at  N*8 .. N*8+7
//     slot N-3 in Stage D at  N*8 .. N*8+7
//
// Each stage's output register is latched at slot_phase==7 (end of window)
// and consumed by the next stage during the next window.  Stage A's input
// (BRAM read) is issued at slot_phase==0 of its own window.
//
// Pipeline drain: after slot 23 dispatches at frame_cycle 184..191, the
// remaining in-flight slots (B/C/D) drain through cycles 192..215.  The
// stage-advance pulse keeps firing every 8 cycles so they finish.
//
// SDRAM port owned by Stage B (sample fetches), HF FSM and CPU writes use
// the port during the long idle window (cycle ~216 onward).

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
    output logic               pcm_valid
);

    // ════════════════════════════════════════════════════════════════════════
    // Frame and slot scheduler
    // ════════════════════════════════════════════════════════════════════════
    localparam int CYCLES_PER_SLOT      = 8;
    localparam int TOTAL_SLOTS          = 24;
    localparam int SLOT_DISPATCH_CYCLES = TOTAL_SLOTS * CYCLES_PER_SLOT; // 192
    localparam int CYCLES_PER_FRAME     = 1948;

    logic [10:0] frame_cycle;
    logic [4:0]  cur_slot;
    logic [2:0]  slot_phase;
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
                if (slot_phase == 3'd7) begin
                    slot_phase <= '0;
                    if (cur_slot != 5'd23) cur_slot <= cur_slot + 5'd1;
                end else begin
                    slot_phase <= slot_phase + 3'd1;
                end
            end
        end
    end

    wire in_dispatch_window = (frame_cycle < SLOT_DISPATCH_CYCLES);
    wire sample_start       = (frame_cycle == CYCLES_PER_FRAME - 1);
    // dispatch_now: a new slot enters Stage A
    wire dispatch_now       = (slot_phase == 3'd0) && in_dispatch_window;
    // stage_advance: pulses at the end of every 8-cycle window, including the
    // drain windows after dispatch is done (so in-flight slots finish).
    wire stage_advance      = (slot_phase == 3'd7);

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

    typedef struct packed {
        logic            valid;
        logic [4:0]      slot;
        slot_regs_t      regs;
        slot_header_t    header;
        slot_dyn_t       dyn;       // pos/stepPtr updated for current sample
        logic [15:0]     next_pos;  // for sample B interpolation
    } stage_b_pkt_t;

    typedef struct packed {
        logic            valid;
        logic [4:0]      slot;
        slot_regs_t      regs;
        slot_dyn_t       dyn;       // pos/stepPtr from Stage B
        logic signed [15:0] interp;
    } stage_c_pkt_t;

    stage_a_pkt_t stage_a_reg;   // latched at dispatch_now, held for 8 cycles
    stage_b_pkt_t stage_b_reg;   // latched at stage_advance
    stage_c_pkt_t stage_c_reg;   // latched at stage_advance

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
    // Stage B — TODO: step calc, addresses, SDRAM requests
    // For now just forwards.
    // ════════════════════════════════════════════════════════════════════════
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stage_b_reg <= '0;
        end else if (stage_advance) begin
            stage_b_reg.valid    <= stage_a_reg.valid;
            stage_b_reg.slot     <= stage_a_reg.slot;
            stage_b_reg.regs     <= stage_a_reg.regs;
            stage_b_reg.header   <= stage_a_reg.header;
            stage_b_reg.dyn      <= stage_a_reg.dyn;
            stage_b_reg.next_pos <= 16'd0;  // TODO
        end
    end

    // ════════════════════════════════════════════════════════════════════════
    // Stage C — TODO: decode + interpolate
    // ════════════════════════════════════════════════════════════════════════
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stage_c_reg <= '0;
        end else if (stage_advance) begin
            stage_c_reg.valid  <= stage_b_reg.valid;
            stage_c_reg.slot   <= stage_b_reg.slot;
            stage_c_reg.regs   <= stage_b_reg.regs;
            stage_c_reg.dyn    <= stage_b_reg.dyn;
            stage_c_reg.interp <= 16'sd0;   // TODO
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
    // CPU register writes (TODO — fully decode reg_addr)
    // ════════════════════════════════════════════════════════════════════════
    logic [2:0]  wavetblhdr;
    logic [23:0] hf_pending;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wavetblhdr <= '0;
            hf_pending <= '0;
            for (int i = 0; i < 24; i++) ram_regs[i] <= '0;
        end else begin
            if (reg_wr) begin
                if (reg_addr == 8'h02) wavetblhdr <= reg_data[4:2];
                // TODO: reg 0x08..0xF7 → ram_regs[slot] fields.
            end
        end
    end

    // ════════════════════════════════════════════════════════════════════════
    // SDRAM port stubs
    // ════════════════════════════════════════════════════════════════════════
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mem_addr    <= '0;
            mem_rd_en   <= 1'b0;
            mem_wr_en   <= 1'b0;
            mem_wr_data <= '0;
        end else begin
            mem_rd_en <= 1'b0;
            mem_wr_en <= 1'b0;
            // TODO: Stage B drives mem_rd_en during slot_phase 1..6.
            // TODO: HF FSM drives mem_addr/mem_rd_en outside dispatch window.
            // TODO: CPU write FIFO drives mem_wr_en outside dispatch window.
        end
    end

    // ════════════════════════════════════════════════════════════════════════
    // Initial values for ram_header (simulation only — real SRAM/BRAM starts
    // at 0 in Quartus anyway)
    // ════════════════════════════════════════════════════════════════════════
    initial begin
        for (int i = 0; i < 24; i++) ram_header[i] = '0;
    end

endmodule

`default_nettype wire
