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

    // ── ROM tables (function-based — works in both iverilog and Quartus;
    //    iverilog doesn't support unpacked-array localparam initializers) ───
    function automatic logic [7:0] eg_inc_rom(input logic [6:0] idx);
        logic [3:0] row;
        logic [2:0] ph;
        row = idx[6:3];
        ph  = idx[2:0];
        case (row)
            4'd0:  eg_inc_rom = ph[0] ? 8'd1 : 8'd0;
            4'd1:  case (ph)
                       3'd4, 3'd5: eg_inc_rom = 8'd1;
                       default:    eg_inc_rom = ph[0] ? 8'd1 : 8'd0;
                   endcase
            4'd2:  case (ph)
                       3'd0, 3'd4: eg_inc_rom = 8'd0;
                       default:    eg_inc_rom = 8'd1;
                   endcase
            4'd3:  eg_inc_rom = (ph == 3'd0) ? 8'd0 : 8'd1;
            4'd4:  eg_inc_rom = 8'd1;
            4'd5:  eg_inc_rom = (ph[1:0] == 2'b11) ? 8'd2 : 8'd1;
            4'd6:  eg_inc_rom = ph[0] ? 8'd2 : 8'd1;
            4'd7:  case (ph)
                       3'd0, 3'd4: eg_inc_rom = 8'd1;
                       default:    eg_inc_rom = 8'd2;
                   endcase
            4'd8:  eg_inc_rom = 8'd2;
            4'd9:  eg_inc_rom = (ph[1:0] == 2'b11) ? 8'd4 : 8'd2;
            4'd10: eg_inc_rom = ph[0] ? 8'd4 : 8'd2;
            4'd11: case (ph)
                       3'd0, 3'd4: eg_inc_rom = 8'd2;
                       default:    eg_inc_rom = 8'd4;
                   endcase
            4'd12: eg_inc_rom = 8'd4;
            4'd13: eg_inc_rom = 8'd8;
            default: eg_inc_rom = 8'd0;     // row 14: infinity / zero rate
        endcase
    endfunction

    function automatic logic [7:0] eg_rate_select_rom(input logic [5:0] idx);
        logic [3:0] row;
        logic [1:0] ph;
        row = idx[5:2];
        ph  = idx[1:0];
        case (row)
            4'd0:  eg_rate_select_rom = 8'd112;
            4'd13: case (ph)
                       2'd0: eg_rate_select_rom = 8'd32;
                       2'd1: eg_rate_select_rom = 8'd40;
                       2'd2: eg_rate_select_rom = 8'd48;
                       2'd3: eg_rate_select_rom = 8'd56;
                   endcase
            4'd14: case (ph)
                       2'd0: eg_rate_select_rom = 8'd64;
                       2'd1: eg_rate_select_rom = 8'd72;
                       2'd2: eg_rate_select_rom = 8'd80;
                       2'd3: eg_rate_select_rom = 8'd88;
                   endcase
            4'd15: eg_rate_select_rom = 8'd96;
            default: // rows 1..12 all = {0, 8, 16, 24}
                case (ph)
                    2'd0: eg_rate_select_rom = 8'd0;
                    2'd1: eg_rate_select_rom = 8'd8;
                    2'd2: eg_rate_select_rom = 8'd16;
                    2'd3: eg_rate_select_rom = 8'd24;
                endcase
        endcase
    endfunction

    function automatic logic [7:0] eg_rate_shift_rom(input logic [5:0] idx);
        // Decreases from 12 (idx 0..3) down by 1 per group of 4, floors at 0.
        case (idx[5:2])
            4'd0:  eg_rate_shift_rom = 8'd12;
            4'd1:  eg_rate_shift_rom = 8'd11;
            4'd2:  eg_rate_shift_rom = 8'd10;
            4'd3:  eg_rate_shift_rom = 8'd9;
            4'd4:  eg_rate_shift_rom = 8'd8;
            4'd5:  eg_rate_shift_rom = 8'd7;
            4'd6:  eg_rate_shift_rom = 8'd6;
            4'd7:  eg_rate_shift_rom = 8'd5;
            4'd8:  eg_rate_shift_rom = 8'd4;
            4'd9:  eg_rate_shift_rom = 8'd3;
            4'd10: eg_rate_shift_rom = 8'd2;
            4'd11: eg_rate_shift_rom = 8'd1;
            default: eg_rate_shift_rom = 8'd0;  // rows 12..15
        endcase
    endfunction

    function automatic logic [9:0] dl_tab_rom(input logic [3:0] idx);
        // dl_tab[0..14] = idx * 0x20; dl_tab[15] = 0x3E0
        if (idx == 4'd15) dl_tab_rom = 10'h3E0;
        else              dl_tab_rom = {3'b0, idx, 3'b0};  // idx << 5
    endfunction

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
                    shift_v = eg_rate_shift_rom(rate);
                    if (rate < 6'd63 && eg_do_update(eg_cnt, shift_v)) begin
                        sel_v = eg_rate_select_rom(rate);
                        phase_v = eg_phase(eg_cnt, shift_v);
                        inc_v = eg_inc_rom(7'(sel_v + {5'd0, phase_v}));
                        next_vol = calc_attack_step(cur_vol, inc_v);
                        if (next_vol <= MIN_ATT_INDEX) begin
                            next_vol = MIN_ATT_INDEX;
                            next_state = (dl_idx != 4'h0) ? EG_DEC : EG_SUS;
                        end
                    end
                end
                EG_DEC: begin
                    rate = calc_decay_rate(d1r, rc, damp, prvb, cur_vol, oct, fn);
                    shift_v = eg_rate_shift_rom(rate);
                    if (eg_do_update(eg_cnt, shift_v)) begin
                        sel_v = eg_rate_select_rom(rate);
                        phase_v = eg_phase(eg_cnt, shift_v);
                        inc_v = eg_inc_rom(7'(sel_v + {5'd0, phase_v}));
                        vol_add = {1'b0, cur_vol} + {3'd0, inc_v};
                        next_vol = (vol_add > 11'h3FF) ? 10'h3FF : vol_add[9:0];
                        if (next_vol >= dl_tab_rom(dl_idx)) begin
                            next_state = (next_vol < MAX_ATT_INDEX) ? EG_SUS : EG_OFF;
                        end
                    end
                end
                EG_SUS: begin
                    rate = calc_decay_rate(d2r, rc, damp, prvb, cur_vol, oct, fn);
                    shift_v = eg_rate_shift_rom(rate);
                    if (eg_do_update(eg_cnt, shift_v)) begin
                        sel_v = eg_rate_select_rom(rate);
                        phase_v = eg_phase(eg_cnt, shift_v);
                        inc_v = eg_inc_rom(7'(sel_v + {5'd0, phase_v}));
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
                    shift_v = eg_rate_shift_rom(rate);
                    if (eg_do_update(eg_cnt, shift_v)) begin
                        sel_v = eg_rate_select_rom(rate);
                        phase_v = eg_phase(eg_cnt, shift_v);
                        inc_v = eg_inc_rom(7'(sel_v + {5'd0, phase_v}));
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
