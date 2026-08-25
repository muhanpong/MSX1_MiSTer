// YMF278 PCM Engine Top — 24-slot time-multiplexed PCM synthesizer
// 44.1kHz sample rate; slot register file in flop arrays; sub-modules pipelined.
`default_nettype none

module ymf278_pcm_top #(
    parameter int CLK_HZ = 33868800
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire [7:0]  reg_addr,
    input  wire [7:0]  reg_data,
    input  wire        reg_wr,
    input  wire        reg_rd,
    output logic [7:0] reg_dout,

    output logic [21:0] mem_addr,
    output logic        mem_rd_req,
    input  wire  [7:0]  mem_rd_data,
    input  wire         mem_rd_valid,

    output logic [7:0]  cpu_mem_reg,
    output logic [7:0]  cpu_mem_data,
    output logic        cpu_mem_wr,
    output logic        cpu_mem_rd,
    input  wire  [7:0]  cpu_mem_rd_data,
    input  wire         cpu_mem_ack,
    output logic        reg_rd_done,    // pulses when a reg 3-6 read has fresh data in reg_dout

    output logic signed [15:0] pcm_left,
    output logic signed [15:0] pcm_right,
    output logic               pcm_valid,
    output logic [4:0]         keyon_count,   // number of active key-on slots (debug)
    output logic [4:0]         dbg_accum_cnt, // channels that produced samples last period
    output logic [9:0]         dbg_env_min,   // minimum env_for_vol seen (0=loud, 0x280=silent)
    output logic               dbg_mem_nonzero,   // 1 if any SDRAM read returned non-zero
    output logic               dbg_interp_nonzero // 1 if interpolator ever output non-zero
);

// ─── Sample-rate timing ───────────────────────────────────────────────
localparam int SAMPLE_DIV      = CLK_HZ / 44100;
localparam int CYCLES_PER_SLOT = SAMPLE_DIV / 24;

logic [$clog2(SAMPLE_DIV)-1:0]      sample_cnt;
logic [4:0]                          slot_idx;
logic [$clog2(CYCLES_PER_SLOT)-1:0] slot_cnt;
logic        slot_start;
logic        sample_start;
logic [23:0] eg_cnt;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        sample_cnt   <= '0;
        slot_idx     <= 5'd0;
        slot_cnt     <= '0;
        slot_start   <= 1'b0;
        sample_start <= 1'b0;
        eg_cnt       <= 24'd0;
    end else begin
        slot_start   <= 1'b0;
        sample_start <= 1'b0;
        sample_cnt   <= sample_cnt + 1;
        if (sample_cnt == SAMPLE_DIV - 1) begin
            sample_cnt   <= '0;
            eg_cnt       <= eg_cnt + 24'd1;
            sample_start <= 1'b1;
            
            // Synchronize slots to sample boundary
            slot_cnt     <= '0;
            slot_start   <= 1'b1;
            slot_idx     <= 5'd0;
        end else begin
            slot_cnt <= slot_cnt + 1;
            if (slot_cnt == CYCLES_PER_SLOT - 1) begin
                slot_cnt   <= '0;
                slot_start <= 1'b1;
                slot_idx   <= (slot_idx == 5'd23) ? 5'd0 : slot_idx + 5'd1;
            end
        end
    end
end

// ─── TL interpolation counters ────────────────────────────────────────
logic [3:0] tl_int_cnt;
logic [1:0] tl_int_step;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        tl_int_cnt  <= 4'd0;
        tl_int_step <= 2'd0;
    end else if (sample_start) begin
        if (tl_int_cnt == 4'd8) begin
            tl_int_cnt  <= 4'd0;
            tl_int_step <= (tl_int_step == 2'd2) ? 2'd0 : tl_int_step + 2'd1;
        end else begin
            tl_int_cnt <= tl_int_cnt + 4'd1;
        end
    end
end

// ─── dl_tab ROM ───────────────────────────────────────────────────────
logic [9:0] dl_tab_rom [0:15];
initial begin
    dl_tab_rom[ 0]=10'h000; dl_tab_rom[ 1]=10'h020;
    dl_tab_rom[ 2]=10'h040; dl_tab_rom[ 3]=10'h060;
    dl_tab_rom[ 4]=10'h080; dl_tab_rom[ 5]=10'h0A0;
    dl_tab_rom[ 6]=10'h0C0; dl_tab_rom[ 7]=10'h0E0;
    dl_tab_rom[ 8]=10'h100; dl_tab_rom[ 9]=10'h120;
    dl_tab_rom[10]=10'h140; dl_tab_rom[11]=10'h160;
    dl_tab_rom[12]=10'h180; dl_tab_rom[13]=10'h1A0;
    dl_tab_rom[14]=10'h1C0; dl_tab_rom[15]=10'h3E0;
end

// ─── Per-slot register file (24 slots, flat arrays) ──────────────────
logic [8:0]  sr_wave      [0:23];
logic [9:0]  sr_FN        [0:23];
logic signed [3:0] sr_OCT [0:23];
logic [7:0]  sr_TL        [0:23];
logic [7:0]  sr_TLdest    [0:23];
logic [3:0]  sr_pan       [0:23];
logic [3:0]  sr_AR        [0:23];
logic [3:0]  sr_D1R       [0:23];
logic [3:0]  sr_D2R       [0:23];
logic [3:0]  sr_RR        [0:23];
logic [3:0]  sr_RC        [0:23];
logic [3:0]  sr_DL_idx    [0:23];
logic [2:0]  sr_lfo_speed [0:23];
logic [2:0]  sr_vib       [0:23];
logic [2:0]  sr_AM        [0:23];
logic        sr_keyon      [0:23];
logic        sr_DAMP       [0:23];
logic        sr_PRVB       [0:23];
logic        sr_lfo_active [0:23];
logic        sr_lfo_reset  [0:23];
logic [1:0]  sr_bits       [0:23];
logic [21:0] sr_startAddr  [0:23];
logic [15:0] sr_loopAddr   [0:23];
logic [15:0] sr_endAddr    [0:23];
logic [15:0] sr_stepPtr    [0:23];
logic [15:0] sr_pos        [0:23];

integer _si;
initial begin
    for (_si = 0; _si < 24; _si = _si + 1) begin
        sr_wave[_si]      = 9'd0;  sr_FN[_si]    = 10'd0;
        sr_OCT[_si]       = 4'sd0; sr_TL[_si]    = 8'd0;
        sr_TLdest[_si]    = 8'd0;  sr_pan[_si]   = 4'd0;
        sr_AR[_si]        = 4'd0;  sr_D1R[_si]   = 4'd0;
        sr_D2R[_si]       = 4'd0;  sr_RR[_si]    = 4'd0;
        sr_RC[_si]        = 4'd15; sr_DL_idx[_si]= 4'd0;
        sr_lfo_speed[_si] = 3'd0;  sr_vib[_si]   = 3'd0;
        sr_AM[_si]        = 3'd0;
        sr_keyon[_si]     = 1'b0;  sr_DAMP[_si]  = 1'b0;
        sr_PRVB[_si]      = 1'b0;  sr_lfo_active[_si] = 1'b0;
        sr_lfo_reset[_si] = 1'b0;  sr_bits[_si]  = 2'd0;
        sr_startAddr[_si] = 22'd0; sr_loopAddr[_si] = 16'd0;
        sr_endAddr[_si]   = 16'd0; sr_stepPtr[_si]  = 16'd0;
        sr_pos[_si]       = 16'd0;
    end
end

// ─── Register decode signals (module-level to avoid automatic) ───────
logic [4:0] wr_snum;   // slot index from register address
logic [3:0] wr_field;  // field index from register address

assign wr_snum  = (reg_addr >= 8'h08) ? 5'((reg_addr - 8'h08) % 8'd24) : 5'd0;
assign wr_field = (reg_addr >= 8'h08) ? 4'((reg_addr - 8'h08) / 8'd24) : 4'd0;

// ─── Header fetch FSM ───────────────────────────────────────────────
// On wave-MSB write (field 1), fetch the 12-byte sample header from wave ROM
// at offset (wave_num * 12) and populate the slot's startAddr/endAddr/etc.
typedef enum logic [2:0] {
    HF_IDLE,
    HF_DRAIN,   // wait for interp's in-flight SDRAM transaction to finish
    HF_REQ,
    HF_WAIT,
    HF_STORE
} hf_state_t;

hf_state_t   hf_state;
logic [23:0] hf_pending;
logic [4:0]  hf_cur_slot;
logic [8:0]  hf_cur_wave;
logic [3:0]  hf_byte_idx;
logic [7:0]  hf_buf [0:11];
logic [21:0] hf_mem_addr_w;
logic        hf_mem_rd_req_w;
logic [4:0]  hf_picked;
logic        hf_found;
logic [4:0]  hf_drain_cnt;
logic [23:0] hf_keyon_restart;  // 1-cycle delayed re-assert after HF_STORE keyon toggle
logic [23:0] hf_pos_reset;      // request pos/stepPtr reset from step-accum block (non-keyon case)

// Wave-table header offset (regs[2] bits 4:2).  Used when wave_num >= 384
// to compute the custom-sample header base address.
logic [2:0]  wavetblhdr;

integer _hi;
always_comb begin
    hf_picked = 5'd0;
    hf_found  = 1'b0;
    for (_hi = 0; _hi < 24; _hi = _hi + 1) begin
        if (hf_pending[_hi] && !hf_found) begin
            hf_picked = 5'(_hi);
            hf_found  = 1'b1;
        end
    end
end

// ─── Mem interface mux: header fetch has priority over interpolator ────
logic [21:0] interp_mem_addr_w;
logic        interp_mem_rd_req_w;
logic        interp_start;    // forward declaration (driven in step-accumulation block)

wire hf_active      = (hf_state != HF_IDLE);
wire any_hf_pending = (hf_pending != 24'd0);
// HF only drives the SDRAM bus while actively reading a header byte.
// During HF_DRAIN/HF_STORE the interpolator keeps the bus so any in-flight
// transaction can complete naturally (avoids deadlock where interp is stuck
// in S_WAIT with mem_rd_req high but the mux has stolen the bus).
wire hf_drives_bus  = (hf_state == HF_REQ) || (hf_state == HF_WAIT);
assign mem_addr   = hf_drives_bus ? hf_mem_addr_w   : interp_mem_addr_w;
assign mem_rd_req = hf_drives_bus ? hf_mem_rd_req_w : interp_mem_rd_req_w;
// Gate valid: interp sees no valid only while HF actually owns the bus
wire interp_mem_rd_valid = hf_drives_bus ? 1'b0 : mem_rd_valid;
// Gate interp_start: prevent new interpolator transactions while HF is pending
// or active.  Existing in-flight transactions can still complete via the
// interp_mem_rd_valid path (above) because hf_drives_bus is false in HF_DRAIN.
wire interp_start_gated = (any_hf_pending || hf_active) ? 1'b0 : interp_start;
wire interp_ready;  // from interpolator: high when S_IDLE (can accept new start)

// ─── CPU register write + TL interpolation + Header fetch FSM ─────────
// Single driver for all sr_* registers (except sr_pos/sr_stepPtr).
// Source order within this always_ff:
//   1. Defaults (clear strobes)
//   2. TL interpolation (writes sr_TL)
//   3. HF FSM (HF_STORE writes sr_bits/startAddr/endAddr/loopAddr/AR/D1R/etc)
//   4. CPU register write (overrides HF writes on the same cycle if conflict)
integer _wi;
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        cpu_mem_wr      <= 1'b0;
        cpu_mem_rd      <= 1'b0;
        reg_dout        <= 8'h00;
        reg_rd_done     <= 1'b0;
        hf_state        <= HF_IDLE;
        hf_pending      <= 24'd0;
        hf_byte_idx     <= 4'd0;
        hf_cur_slot     <= 5'd0;
        hf_cur_wave     <= 9'd0;
        hf_drain_cnt    <= 5'd0;
        hf_mem_rd_req_w <= 1'b0;
        wavetblhdr      <= 3'd0;
        hf_keyon_restart<= 24'd0;
        hf_pos_reset    <= 24'd0;
    end else begin
        cpu_mem_wr      <= 1'b0;
        cpu_mem_rd      <= 1'b0;

        // Delayed keyon re-assert: restore sr_keyon after HF_STORE toggled it off
        for (int _hkr = 0; _hkr < 24; _hkr = _hkr + 1) begin
            if (hf_keyon_restart[_hkr]) begin
                sr_keyon[_hkr]          <= 1'b1;
                hf_keyon_restart[_hkr]  <= 1'b0;
            end
        end
        // NOTE: reg_dout is NOT defaulted to 0 every cycle.  It must hold
        // its value between register reads so the I/O layer can latch the
        // CPU memory read result returned via cpu_mem_ack (below).
        hf_mem_rd_req_w <= 1'b0;

        // TL interpolation — runs every sample period; CPU write below takes priority
        if (sample_start && tl_int_cnt == 4'd0) begin
            for (_wi = 0; _wi < 24; _wi = _wi + 1) begin
                if (tl_int_step == 2'd0) begin
                    if (sr_TL[_wi] < sr_TLdest[_wi]) sr_TL[_wi] <= sr_TL[_wi] + 8'd1;
                end else begin
                    if (sr_TL[_wi] > sr_TLdest[_wi]) sr_TL[_wi] <= sr_TL[_wi] - 8'd1;
                end
            end
        end

        // ─── Header fetch FSM ───────────────────────────────────────
        case (hf_state)
            HF_IDLE: if (hf_found) begin
                hf_cur_slot          <= hf_picked;
                hf_cur_wave          <= sr_wave[hf_picked];
                hf_pending[hf_picked] <= 1'b0;
                hf_byte_idx          <= 4'd0;
                hf_drain_cnt         <= 5'd0;
                hf_state             <= HF_DRAIN;
            end
            // Wait for any in-flight interpolator SDRAM transaction to finish
            // before taking the bus — otherwise HF would steal the response.
            // Since interp_start is already gated (hf_active|any_hf_pending),
            // the interp FSM will reach S_IDLE within one transaction's latency.
            HF_DRAIN: begin
                if (interp_mem_rd_req_w || mem_rd_valid) begin
                    hf_drain_cnt <= 5'd0;
                end else if (hf_drain_cnt >= 5'd15) begin
                    hf_state <= HF_REQ;
                end else begin
                    hf_drain_cnt <= hf_drain_cnt + 5'd1;
                end
            end
            HF_REQ: begin
                // Address calculation matches openMSX YMF278.cc:
                //   wave < 384 || wavetblhdr == 0: base = wave * 12
                //   else: base = wavetblhdr * 0x80000 + (wave-384) * 12
                if (hf_cur_wave < 9'd384 || wavetblhdr == 3'd0) begin
                    hf_mem_addr_w <= ({13'd0, hf_cur_wave} * 22'd12) + {18'd0, hf_byte_idx};
                end else begin
                    // wavetblhdr * 0x80000 == wavetblhdr << 19.
                    // {wavetblhdr[2:0], 19'd0} produces a 22-bit value with
                    // wavetblhdr in bits 21:19, matching openMSX YMF278.cc:599.
                    hf_mem_addr_w <= {wavetblhdr, 19'd0} +
                                     ({13'd0, (hf_cur_wave - 9'd384)} * 22'd12) +
                                     {18'd0, hf_byte_idx};
                end
                hf_mem_rd_req_w <= 1'b1;
                hf_state        <= HF_WAIT;
            end
            HF_WAIT: begin
                if (mem_rd_valid) begin
                    hf_buf[hf_byte_idx] <= mem_rd_data;
                    // Drop the request *immediately* after a successful
                    // read so the memory arbiter sees a falling edge
                    // before HF_REQ presents the next byte's address.
                    // Without this, the arbiter re-fires with the stale
                    // (current) address, producing an off-by-one shift
                    // in hf_buf.
                    hf_mem_rd_req_w <= 1'b0;
                    if (hf_byte_idx == 4'd11) begin
                        hf_state <= HF_STORE;
                    end else begin
                        hf_byte_idx <= hf_byte_idx + 4'd1;
                        hf_state    <= HF_REQ;
                    end
                end else begin
                    hf_mem_rd_req_w <= 1'b1;
                end
            end
            HF_STORE: begin
                sr_bits     [hf_cur_slot] <= hf_buf[0][7:6];
                sr_startAddr[hf_cur_slot] <= {hf_buf[0][5:0], hf_buf[1], hf_buf[2]};
                sr_loopAddr [hf_cur_slot] <= {hf_buf[3], hf_buf[4]};
                // ROM bytes are already in 2's complement form (matches
                // openMSX YMF278.cc:609 and reference_model.py:185).
                // Loop check: (pos + endAddr) >= 0x10000 → pos >= |endAddr|
                sr_endAddr  [hf_cur_slot] <= {hf_buf[5], hf_buf[6]};
                sr_lfo_speed[hf_cur_slot] <= hf_buf[7][5:3];
                sr_vib      [hf_cur_slot] <= hf_buf[7][2:0];
                sr_AR       [hf_cur_slot] <= hf_buf[8][7:4];
                sr_D1R      [hf_cur_slot] <= hf_buf[8][3:0];
                sr_DL_idx   [hf_cur_slot] <= hf_buf[9][7:4];
                sr_D2R      [hf_cur_slot] <= hf_buf[9][3:0];
                sr_RC       [hf_cur_slot] <= hf_buf[10][7:4];
                sr_RR       [hf_cur_slot] <= hf_buf[10][3:0];
                sr_AM       [hf_cur_slot] <= hf_buf[11][2:0];
                // openMSX keyOnHelper equivalent:
                // If slot is already key-on when wave is loaded, restart playback.
                // If not key-on, just reset position.
                if (sr_keyon[hf_cur_slot]) begin
                    // Force envelope restart by generating a keyon edge:
                    // keyon toggle off→on produces keyon_pulse_arr which
                    // resets pos/stepPtr in the step-accumulation block.
                    sr_keyon[hf_cur_slot]  <= 1'b0;
                    hf_keyon_restart[hf_cur_slot] <= 1'b1;
                end else begin
                    // Not key-on: request pos/stepPtr reset via flag
                    // (can't write sr_pos/sr_stepPtr here — different always_ff)
                    hf_pos_reset[hf_cur_slot] <= 1'b1;
                end
                hf_state <= HF_IDLE;
            end
            default: hf_state <= HF_IDLE;
        endcase

        if (reg_rd) begin
            if (reg_addr == 8'h02) begin
                reg_dout <= 8'h20; // YMF278B Device ID
            end else if (reg_addr >= 8'h03 && reg_addr <= 8'h06) begin
                cpu_mem_reg <= reg_addr;
                cpu_mem_rd  <= 1'b1;
                // Don't capture reg_dout here — cpu_mem_rd_data is stale
                // until the SDRAM read completes.  Captured below on cpu_mem_ack.
            end
        end

        // Latch fresh CPU memory read data when the memory module
        // acknowledges (cpu_mem_ack pulses after the SDRAM transaction
        // completes).  reg_dout holds this value until the next ack.
        // Also pulse reg_rd_done so ymf278b_regs can release io_ack.
        reg_rd_done <= 1'b0;
        if (cpu_mem_ack) begin
            reg_dout    <= cpu_mem_rd_data;
            reg_rd_done <= 1'b1;
        end

        if (reg_wr) begin
            if (reg_addr >= 8'h08 && reg_addr <= 8'hF7) begin
                case (wr_field)
                    4'd0: begin
                        sr_wave[wr_snum][7:0] <= reg_data[7:0];
                        hf_pending[wr_snum]   <= 1'b1;
                    end
                    4'd1: begin
                        sr_wave[wr_snum][8] <= reg_data[0];
                        sr_FN[wr_snum][6:0] <= reg_data[7:1];
                        hf_pending[wr_snum]   <= 1'b1;
                    end
                    4'd2: begin
                        sr_FN[wr_snum][9:7] <= reg_data[2:0];
                        sr_PRVB[wr_snum]    <= reg_data[3];
                        sr_OCT[wr_snum]     <= $signed(reg_data[7:4]);
                    end
                    4'd3: begin
                        begin
                            logic [6:0] t;
                            t = reg_data[7:1];
                            sr_TLdest[wr_snum] <= (t != 7'h7F) ? {1'b0, t} : 8'hFF;
                        end
                        if (reg_data[0]) sr_TL[wr_snum] <= sr_TLdest[wr_snum];
                    end
                    4'd4: begin
                        sr_pan[wr_snum]       <= reg_data[4] ? 4'd8 : reg_data[3:0];
                        sr_lfo_active[wr_snum]<= ~reg_data[5];
                        sr_lfo_reset[wr_snum] <=  reg_data[5];
                        sr_DAMP[wr_snum]      <=  reg_data[6];
                        if (reg_data[7]) begin
                            if (!sr_keyon[wr_snum])
                                sr_keyon[wr_snum] <= 1'b1;
                        end else begin
                            sr_keyon[wr_snum] <= 1'b0;
                        end
                    end
                    4'd5: begin
                        sr_lfo_speed[wr_snum] <= reg_data[5:3];
                        sr_vib[wr_snum]       <= reg_data[2:0];
                    end
                    4'd6: begin
                        sr_AR[wr_snum]  <= reg_data[7:4];
                        sr_D1R[wr_snum] <= reg_data[3:0];
                    end
                    4'd7: begin
                        sr_DL_idx[wr_snum] <= reg_data[7:4];
                        sr_D2R[wr_snum]    <= reg_data[3:0];
                    end
                    4'd8: begin
                        sr_RC[wr_snum] <= reg_data[7:4];
                        sr_RR[wr_snum] <= reg_data[3:0];
                    end
                    4'd9: sr_AM[wr_snum] <= reg_data[2:0];
                    default: ;
                endcase
            end else begin
                case (reg_addr)
                    8'h02: wavetblhdr <= reg_data[4:2];  // wave-table header offset
                    8'h03, 8'h04, 8'h05, 8'h06: begin
                        cpu_mem_reg  <= reg_addr;
                        cpu_mem_data <= reg_data;
                        cpu_mem_wr   <= 1'b1;
                    end
                    default: ;
                endcase
            end
        end
    end
end

// ─── Key-on edge detection ───────────────────────────────────────────
logic [23:0] keyon_prev;
logic [23:0] keyon_pulse_arr, keyoff_pulse_arr;
integer _ki;
always_ff @(posedge clk) begin
    for (_ki = 0; _ki < 24; _ki = _ki + 1) begin
        keyon_prev[_ki]        <= sr_keyon[_ki];
        keyon_pulse_arr[_ki]   <=  sr_keyon[_ki] & ~keyon_prev[_ki];
        keyoff_pulse_arr[_ki]  <= ~sr_keyon[_ki] &  keyon_prev[_ki];
    end
end

// ─── Envelope Generator ──────────────────────────────────────────────
logic [9:0] env_vol_out;

ymf278_pcm_envelope u_eg (
    .clk           (clk),
    .rst_n         (rst_n),
    .slot_idx      (slot_idx),
    .slot_valid    (slot_start),
    .AR            (sr_AR[slot_idx]),
    .D1R           (sr_D1R[slot_idx]),
    .D2R           (sr_D2R[slot_idx]),
    .RR            (sr_RR[slot_idx]),
    .RC            (sr_RC[slot_idx]),
    .FN            (sr_FN[slot_idx]),
    .OCT           (sr_OCT[slot_idx]),
    .DL            ({6'd0, dl_tab_rom[sr_DL_idx[slot_idx]]}),
    .PRVB          (sr_PRVB[slot_idx]),
    .DAMP          (sr_DAMP[slot_idx]),
    .key_on        (sr_keyon[slot_idx]),
    .eg_cnt        (eg_cnt),
    .env_vol       (env_vol_out)
);

// ─── LFO ─────────────────────────────────────────────────────────────
logic signed [15:0] vib_offset;
logic [15:0]        am_atten;

ymf278_pcm_lfo u_lfo (
    .clk           (clk),
    .rst_n         (rst_n),
    .slot_idx      (slot_idx),
    .slot_valid    (slot_start),
    .lfo_speed     (sr_lfo_speed[slot_idx]),
    .vib_depth_sel (sr_vib[slot_idx]),
    .am_depth_sel  (sr_AM[slot_idx]),
    .lfo_active    (sr_lfo_active[slot_idx]),
    .lfo_reset     (sr_lfo_reset[slot_idx]),
    .vib_offset    (vib_offset),
    .am_atten      (am_atten)
);

// ─── calcStep ────────────────────────────────────────────────────────
function automatic [31:0] calc_step(
    input signed [3:0] oct,
    input [9:0] fn,
    input signed [15:0] vib
);
    logic signed [3:0] o;
    logic [31:0] t;
    o = oct;
    if (o == -4'sd8) return 32'd0;
    t = ({22'd0, fn} + 32'd1024 + $signed({{16{vib[15]}}, vib})) << (8 + $signed(o));
    return t >> 3;
endfunction

// ─── Interpolator ────────────────────────────────────────────────────
logic [21:0] interp_startAddr;
logic [15:0] interp_pos;
logic [15:0] interp_stepPtr;
logic [15:0] interp_endAddr;
logic [15:0] interp_loopAddr;
logic [1:0]  interp_bits;
logic signed [15:0] interp_out;
logic               interp_valid;

ymf278_pcm_interpolator u_interp (
    .clk         (clk),
    .rst_n       (rst_n),
    .start       (interp_start_gated),
    .startAddr   (interp_startAddr),
    .pos         (interp_pos),
    .stepPtr     (interp_stepPtr),
    .endAddr     (interp_endAddr),
    .loopAddr    (interp_loopAddr),
    .bits        (interp_bits),
    .mem_addr    (interp_mem_addr_w),
    .mem_rd_req  (interp_mem_rd_req_w),
    .mem_rd_data (mem_rd_data),
    .mem_rd_valid(interp_mem_rd_valid),
    .sample_out  (interp_out),
    .sample_valid(interp_valid),
    .ready       (interp_ready)
);

// ─── Volume / Pan ────────────────────────────────────────────────────
logic signed [15:0] vol_left, vol_right;
logic               vol_valid;
logic [9:0]  env_for_vol;
logic [7:0]  tl_for_vol;
logic [3:0]  pan_for_vol;

ymf278_pcm_volume u_vol (
    .clk       (clk),
    .rst_n     (rst_n),
    .start     (interp_valid),
    .sample_in (interp_out),
    .env_vol   (env_for_vol),
    .tl_vol    (tl_for_vol),
    .pan       (pan_for_vol),
    .left_out  (vol_left),
    .right_out (vol_right),
    .out_valid (vol_valid)
);

// ─── Scheduling pipeline ─────────────────────────────────────────────
logic [4:0]  pipe_slot  [0:1];
logic        pipe_valid [0:1];
logic [9:0]  pipe_env   [0:1];

always_ff @(posedge clk) begin
    pipe_slot[0]  <= slot_idx;
    pipe_valid[0] <= slot_start;
    pipe_slot[1]  <= pipe_slot[0];
    pipe_valid[1] <= pipe_valid[0];
    pipe_env[1]   <= env_vol_out;
end

// ─── Step accumulation + interpolator launch ─────────────────────────
logic [31:0] cur_step_v;
logic [15:0] new_stepPtr_v;
logic [15:0] new_pos_v;
logic [15:0] pos_inc_v;
logic [15:0] p2_v;
logic [9:0]  ev_with_am;
logic [4:0]  ps1;       // shorthand for pipe_slot[1]

assign ps1 = pipe_slot[1];

integer _ko;
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        interp_start <= 1'b0;
    end else begin
        interp_start <= 1'b0;

        if (pipe_valid[1] && sr_keyon[ps1]) begin
            begin
                logic signed [15:0] vib_val;
                vib_val = (sr_lfo_active[ps1] && (sr_vib[ps1] != 3'd0))
                          ? vib_offset : 16'sh0;

                cur_step_v    = calc_step(sr_OCT[ps1], sr_FN[ps1], vib_val);
                new_stepPtr_v = sr_stepPtr[ps1] + cur_step_v[15:0];
                new_pos_v     = sr_pos[ps1];

                if (cur_step_v[31:16] != 16'd0 || new_stepPtr_v < sr_stepPtr[ps1]) begin
                    pos_inc_v = cur_step_v[31:16] + (new_stepPtr_v < sr_stepPtr[ps1] ? 16'd1 : 16'd0);
                    p2_v      = sr_pos[ps1] + pos_inc_v;
                    if (({1'b0, p2_v} + {1'b0, sr_endAddr[ps1]}) >= 17'h10000)
                        p2_v = p2_v + sr_endAddr[ps1] + sr_loopAddr[ps1];
                    new_pos_v = p2_v;
                end

                sr_stepPtr[ps1] <= new_stepPtr_v;
                sr_pos[ps1]     <= new_pos_v;

                // Tremolo
                ev_with_am = pipe_env[1];
                if (sr_lfo_active[ps1] && (sr_AM[ps1] != 3'd0)) begin
                    begin
                        logic [10:0] ev_sum;
                        ev_sum = {1'b0, ev_with_am} + am_atten[9:0];
                        ev_with_am = ev_sum[10] ? 10'h3FF : ev_sum[9:0];
                    end
                end

                // Only latch volume params and start interpolator when
                // the interpolator is idle.  This prevents a later slot's
                // envelope from overwriting this slot's value before the
                // interpolator finishes (parameter crosstalk → silence).
                if (interp_ready) begin
                    env_for_vol <= ev_with_am;
                    tl_for_vol  <= sr_TL[ps1];
                    pan_for_vol <= sr_pan[ps1];

                    interp_startAddr <= sr_startAddr[ps1];
                    interp_pos       <= new_pos_v;
                    interp_stepPtr   <= new_stepPtr_v;
                    interp_endAddr   <= sr_endAddr[ps1];
                    interp_loopAddr  <= sr_loopAddr[ps1];
                    interp_bits      <= sr_bits[ps1];
                    interp_start     <= 1'b1;
                end  // if (interp_ready)
            end  // begin (calc block)
        end  // if (pipe_valid[1] && sr_keyon)

        // KEY_ON edge: reset sample playback position (real YMF278B behavior).
        // Placed after step accumulation so this override wins on the same cycle.
        for (_ko = 0; _ko < 24; _ko = _ko + 1) begin
            if (keyon_pulse_arr[_ko] || hf_pos_reset[_ko]) begin
                sr_pos[_ko]     <= 16'd0;
                sr_stepPtr[_ko] <= 16'd0;
            end
        end
    end
end

// ─── L/R accumulation ────────────────────────────────────────────────
// Output at each sample_start boundary instead of requiring exactly 24
// vol_valid pulses.  With key_on gating, only active channels produce
// vol_valid, so the count varies.
logic signed [23:0] accum_left, accum_right;
logic [4:0]  accum_cnt;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        accum_left  <= '0;
        accum_right <= '0;
        accum_cnt   <= 5'd0;
        pcm_left    <= '0;
        pcm_right   <= '0;
        pcm_valid   <= 1'b0;
    end else begin
        pcm_valid <= 1'b0;

        if (vol_valid) begin
            accum_left  <= accum_left  + $signed({{8{vol_left[15]}},  vol_left});
            accum_right <= accum_right + $signed({{8{vol_right[15]}}, vol_right});
            accum_cnt   <= accum_cnt + 5'd1;
        end

        // sample_start: clamp-output whatever was accumulated, then reset.
        // Placed after vol_valid so the reset assignment wins if both fire.
        if (sample_start) begin
            begin
                logic signed [23:0] shifted_l, shifted_r;
                shifted_l = accum_left >>> 4;
                shifted_r = accum_right >>> 4;

                if (shifted_l > 24'sd32767)       pcm_left <= 16'sd32767;
                else if (shifted_l < -24'sd32768) pcm_left <= -16'sd32768;
                else                              pcm_left <= 16'(shifted_l);

                if (shifted_r > 24'sd32767)       pcm_right <= 16'sd32767;
                else if (shifted_r < -24'sd32768) pcm_right <= -16'sd32768;
                else                              pcm_right <= 16'(shifted_r);
            end
            pcm_valid   <= 1'b1;
            dbg_accum_cnt <= accum_cnt;   // latch for debug before reset
            accum_left  <= '0;
            accum_right <= '0;
            accum_cnt   <= 5'd0;
        end
    end
end

// ─── Debug: active key-on count ──────────────────────────────────────
integer _pc;
always_comb begin
    keyon_count = 5'd0;
    for (_pc = 0; _pc < 24; _pc = _pc + 1)
        keyon_count = keyon_count + {4'd0, sr_keyon[_pc]};
end
// ─── Debug: minimum envelope volume (lower = louder) ─────────────────
// DEBUG MODE: sticky — latches the lowest env_for_vol ever observed since
// reset.  Even a brief envelope opening will permanently lower dbg_env_min.
// Useful to diagnose whether envelope EVER opens for any slot.
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        dbg_env_min <= 10'h280;
    end else begin
        if (interp_start && (ev_with_am < dbg_env_min))
            dbg_env_min <= ev_with_am;
        // (sample_start reset removed for sticky behavior — debug only)
    end
end

// ─── Debug: non-zero data detection ──────────────────────────────────
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        dbg_mem_nonzero    <= 1'b0;
        dbg_interp_nonzero <= 1'b0;
    end else begin
        // Row 1: did mem_rd_valid ever fire? (handshake check)
        if (mem_rd_valid)
            dbg_mem_nonzero <= 1'b1;
        // Row 2: did mem_rd_valid ever return non-zero data? (address check)
        if (mem_rd_valid && (mem_rd_data != 8'd0))
            dbg_interp_nonzero <= 1'b1;
    end
end

endmodule
`default_nettype wire
