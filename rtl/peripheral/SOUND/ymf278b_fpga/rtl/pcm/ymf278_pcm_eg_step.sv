// YMF278B PCM Envelope Generator (Combinational Step)
// Package — contains EG ROM tables and the process_eg task.
// Was a module; converted to package for Quartus 17.1 cross-module call
// compatibility.

package ymf278_pcm_eg_pkg;
    import ymf278_pcm_alu_pkg::*;

    // ── Constants ──────────────────────────────────────────────────────
    localparam logic [9:0] MAX_ATT_INDEX = 10'h280;
    localparam logic [9:0] MIN_ATT_INDEX = 10'h000;

    localparam logic [2:0] EG_OFF = 3'd0;
    localparam logic [2:0] EG_REL = 3'd1;
    localparam logic [2:0] EG_SUS = 3'd2;
    localparam logic [2:0] EG_DEC = 3'd3;
    localparam logic [2:0] EG_ATT = 3'd4;

    // ── ROM tables (localparam arrays — Quartus-friendly) ──────────────
    localparam logic [7:0] eg_inc_rom [0:119] = '{
        // row 0
        8'd0, 8'd1, 8'd0, 8'd1, 8'd0, 8'd1, 8'd0, 8'd1,
        // row 1
        8'd0, 8'd1, 8'd0, 8'd1, 8'd1, 8'd1, 8'd0, 8'd1,
        // row 2
        8'd0, 8'd1, 8'd1, 8'd1, 8'd0, 8'd1, 8'd1, 8'd1,
        // row 3
        8'd0, 8'd1, 8'd1, 8'd1, 8'd1, 8'd1, 8'd1, 8'd1,
        // row 4
        8'd1, 8'd1, 8'd1, 8'd1, 8'd1, 8'd1, 8'd1, 8'd1,
        // row 5
        8'd1, 8'd1, 8'd1, 8'd2, 8'd1, 8'd1, 8'd1, 8'd2,
        // row 6
        8'd1, 8'd2, 8'd1, 8'd2, 8'd1, 8'd2, 8'd1, 8'd2,
        // row 7
        8'd1, 8'd2, 8'd2, 8'd2, 8'd1, 8'd2, 8'd2, 8'd2,
        // row 8
        8'd2, 8'd2, 8'd2, 8'd2, 8'd2, 8'd2, 8'd2, 8'd2,
        // row 9
        8'd2, 8'd2, 8'd2, 8'd4, 8'd2, 8'd2, 8'd2, 8'd4,
        // row 10
        8'd2, 8'd4, 8'd2, 8'd4, 8'd2, 8'd4, 8'd2, 8'd4,
        // row 11
        8'd2, 8'd4, 8'd4, 8'd4, 8'd2, 8'd4, 8'd4, 8'd4,
        // row 12
        8'd4, 8'd4, 8'd4, 8'd4, 8'd4, 8'd4, 8'd4, 8'd4,
        // row 13 (instant attack)
        8'd8, 8'd8, 8'd8, 8'd8, 8'd8, 8'd8, 8'd8, 8'd8,
        // row 14 (infinity / zero rate)
        8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0
    };

    localparam logic [7:0] eg_rate_select_rom [0:63] = '{
        8'd112, 8'd112, 8'd112, 8'd112,
        8'd0,   8'd8,   8'd16,  8'd24,
        8'd0,   8'd8,   8'd16,  8'd24,
        8'd0,   8'd8,   8'd16,  8'd24,
        8'd0,   8'd8,   8'd16,  8'd24,
        8'd0,   8'd8,   8'd16,  8'd24,
        8'd0,   8'd8,   8'd16,  8'd24,
        8'd0,   8'd8,   8'd16,  8'd24,
        8'd0,   8'd8,   8'd16,  8'd24,
        8'd0,   8'd8,   8'd16,  8'd24,
        8'd0,   8'd8,   8'd16,  8'd24,
        8'd0,   8'd8,   8'd16,  8'd24,
        8'd0,   8'd8,   8'd16,  8'd24,
        8'd32,  8'd40,  8'd48,  8'd56,
        8'd64,  8'd72,  8'd80,  8'd88,
        8'd96,  8'd96,  8'd96,  8'd96
    };

    localparam logic [7:0] eg_rate_shift_rom [0:63] = '{
        8'd12, 8'd12, 8'd12, 8'd12,
        8'd11, 8'd11, 8'd11, 8'd11,
        8'd10, 8'd10, 8'd10, 8'd10,
        8'd9,  8'd9,  8'd9,  8'd9,
        8'd8,  8'd8,  8'd8,  8'd8,
        8'd7,  8'd7,  8'd7,  8'd7,
        8'd6,  8'd6,  8'd6,  8'd6,
        8'd5,  8'd5,  8'd5,  8'd5,
        8'd4,  8'd4,  8'd4,  8'd4,
        8'd3,  8'd3,  8'd3,  8'd3,
        8'd2,  8'd2,  8'd2,  8'd2,
        8'd1,  8'd1,  8'd1,  8'd1,
        8'd0,  8'd0,  8'd0,  8'd0,
        8'd0,  8'd0,  8'd0,  8'd0,
        8'd0,  8'd0,  8'd0,  8'd0,
        8'd0,  8'd0,  8'd0,  8'd0
    };

    localparam logic [9:0] dl_tab_rom [0:15] = '{
        10'h000, 10'h020, 10'h040, 10'h060,
        10'h080, 10'h0A0, 10'h0C0, 10'h0E0,
        10'h100, 10'h120, 10'h140, 10'h160,
        10'h180, 10'h1A0, 10'h1C0, 10'h3E0
    };

    // ── Helpers ────────────────────────────────────────────────────────
    function automatic logic eg_do_update(input logic [23:0] cnt, input logic [7:0] sh);
        logic [23:0] mask;
        mask = (24'd1 << sh) - 24'd1;
        return (cnt & mask) == 24'd0;
    endfunction

    function automatic logic [2:0] eg_phase(input logic [23:0] cnt, input logic [7:0] sh);
        return 3'((cnt >> sh) & 24'd7);
    endfunction

    // ── EG step task ───────────────────────────────────────────────────
    // Advances envelope state by 1 sample tick (matches openMSX YMF278.cc).
    task automatic process_eg(
        input  logic [2:0]  cur_state,
        input  logic [9:0]  cur_vol,
        input  logic        key_on,
        input  logic        key_on_edge,
        input  logic [3:0]  ar, d1r, d2r, rr, rc,
        input  logic signed [3:0] oct,
        input  logic [9:0]  fn,
        input  logic [3:0]  dl_idx,
        input  logic        damp,
        input  logic        prvb,
        input  logic [23:0] eg_cnt,
        output logic [2:0]  next_state,
        output logic [9:0]  next_vol
    );
        logic [5:0] rate;
        logic [7:0] shift_v;
        logic [7:0] sel_v;
        logic [2:0] phase_v;
        logic [7:0] inc_v;
        logic [10:0] vol_add;

        // CRITICAL: explicit default-init for all locals.  Without these,
        // Quartus infers latches because not every code path through the
        // if/case structure assigns them, contributing to combinational
        // loops + massive timing failure on clk_sdram (85.9MHz).
        rate    = 6'd0;
        shift_v = 8'd0;
        sel_v   = 8'd0;
        phase_v = 3'd0;
        inc_v   = 8'd0;
        vol_add = 11'd0;

        next_state = cur_state;
        next_vol   = cur_vol;

        if (key_on_edge && cur_state == EG_OFF) begin
            next_vol = MAX_ATT_INDEX;
            rate = calc_eg_rate(ar, rc, oct, fn);
            if (rate < 6'd63) next_state = EG_ATT;
            else begin
                next_vol = MIN_ATT_INDEX;
                next_state = (dl_idx != 4'h0) ? EG_DEC : EG_SUS;
            end
        end else if (!key_on && cur_state != EG_OFF) begin
            next_state = EG_REL;
        end else begin
            case (cur_state)
                EG_ATT: begin
                    rate = calc_eg_rate(ar, rc, oct, fn);
                    shift_v = eg_rate_shift_rom[rate];
                    if (rate < 6'd63 && eg_do_update(eg_cnt, shift_v)) begin
                        sel_v = eg_rate_select_rom[rate];
                        phase_v = eg_phase(eg_cnt, shift_v);
                        inc_v = eg_inc_rom[sel_v + {5'd0, phase_v}];
                        next_vol = calc_attack_step(cur_vol, inc_v);
                        if (next_vol <= MIN_ATT_INDEX) begin
                            next_vol = MIN_ATT_INDEX;
                            next_state = (dl_idx != 4'h0) ? EG_DEC : EG_SUS;
                        end
                    end
                end
                EG_DEC: begin
                    rate = calc_decay_rate(d1r, rc, damp, prvb, cur_vol, oct, fn);
                    shift_v = eg_rate_shift_rom[rate];
                    if (eg_do_update(eg_cnt, shift_v)) begin
                        sel_v = eg_rate_select_rom[rate];
                        phase_v = eg_phase(eg_cnt, shift_v);
                        inc_v = eg_inc_rom[sel_v + {5'd0, phase_v}];
                        vol_add = {1'b0, cur_vol} + {3'd0, inc_v};
                        next_vol = (vol_add > 11'h3FF) ? 10'h3FF : vol_add[9:0];
                        if (next_vol >= dl_tab_rom[dl_idx]) begin
                            next_state = (next_vol < MAX_ATT_INDEX) ? EG_SUS : EG_OFF;
                        end
                    end
                end
                EG_SUS: begin
                    rate = calc_decay_rate(d2r, rc, damp, prvb, cur_vol, oct, fn);
                    shift_v = eg_rate_shift_rom[rate];
                    if (eg_do_update(eg_cnt, shift_v)) begin
                        sel_v = eg_rate_select_rom[rate];
                        phase_v = eg_phase(eg_cnt, shift_v);
                        inc_v = eg_inc_rom[sel_v + {5'd0, phase_v}];
                        vol_add = {1'b0, cur_vol} + {3'd0, inc_v};
                        if (vol_add >= {1'b0, MAX_ATT_INDEX}) begin
                            next_vol = MAX_ATT_INDEX;
                            next_state = EG_OFF;
                        end else begin
                            next_vol = vol_add[9:0];
                        end
                    end
                end
                EG_REL: begin
                    rate = calc_decay_rate(rr, rc, damp, prvb, cur_vol, oct, fn);
                    shift_v = eg_rate_shift_rom[rate];
                    if (eg_do_update(eg_cnt, shift_v)) begin
                        sel_v = eg_rate_select_rom[rate];
                        phase_v = eg_phase(eg_cnt, shift_v);
                        inc_v = eg_inc_rom[sel_v + {5'd0, phase_v}];
                        vol_add = {1'b0, cur_vol} + {3'd0, inc_v};
                        if (vol_add >= {1'b0, MAX_ATT_INDEX}) begin
                            next_vol = MAX_ATT_INDEX;
                            next_state = EG_OFF;
                        end else begin
                            next_vol = vol_add[9:0];
                        end
                    end
                end
                default: ;
            endcase
        end
    endtask

endpackage
