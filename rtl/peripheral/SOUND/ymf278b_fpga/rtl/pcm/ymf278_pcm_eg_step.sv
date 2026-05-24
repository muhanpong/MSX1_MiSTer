`default_nettype none

// YMF278B PCM Envelope Generator (Combinational Step)
// Contains the EG ROM tables and advances the state by 1 sample tick.
// Instantiated or called combinationally from the main pipeline.

module ymf278_pcm_eg_step;

    // ── Constants ──────────────────────────────────────────────────────
    localparam [9:0] MAX_ATT_INDEX = 10'h280;
    localparam [9:0] MIN_ATT_INDEX = 10'h000;

    localparam [2:0] EG_OFF = 3'd0;
    localparam [2:0] EG_REL = 3'd1;
    localparam [2:0] EG_SUS = 3'd2;
    localparam [2:0] EG_DEC = 3'd3;
    localparam [2:0] EG_ATT = 3'd4;

    // ── ROM tables ─────────────────────────────────────────────────────
    logic [7:0] eg_inc_rom [0:119];
    initial begin
        // row 0
        eg_inc_rom[  0]=8'd0; eg_inc_rom[  1]=8'd1; eg_inc_rom[  2]=8'd0; eg_inc_rom[  3]=8'd1;
        eg_inc_rom[  4]=8'd0; eg_inc_rom[  5]=8'd1; eg_inc_rom[  6]=8'd0; eg_inc_rom[  7]=8'd1;
        // row 1
        eg_inc_rom[  8]=8'd0; eg_inc_rom[  9]=8'd1; eg_inc_rom[ 10]=8'd0; eg_inc_rom[ 11]=8'd1;
        eg_inc_rom[ 12]=8'd1; eg_inc_rom[ 13]=8'd1; eg_inc_rom[ 14]=8'd0; eg_inc_rom[ 15]=8'd1;
        // row 2
        eg_inc_rom[ 16]=8'd0; eg_inc_rom[ 17]=8'd1; eg_inc_rom[ 18]=8'd1; eg_inc_rom[ 19]=8'd1;
        eg_inc_rom[ 20]=8'd0; eg_inc_rom[ 21]=8'd1; eg_inc_rom[ 22]=8'd1; eg_inc_rom[ 23]=8'd1;
        // row 3
        eg_inc_rom[ 24]=8'd0; eg_inc_rom[ 25]=8'd1; eg_inc_rom[ 26]=8'd1; eg_inc_rom[ 27]=8'd1;
        eg_inc_rom[ 28]=8'd1; eg_inc_rom[ 29]=8'd1; eg_inc_rom[ 30]=8'd1; eg_inc_rom[ 31]=8'd1;
        // row 4
        eg_inc_rom[ 32]=8'd1; eg_inc_rom[ 33]=8'd1; eg_inc_rom[ 34]=8'd1; eg_inc_rom[ 35]=8'd1;
        eg_inc_rom[ 36]=8'd1; eg_inc_rom[ 37]=8'd1; eg_inc_rom[ 38]=8'd1; eg_inc_rom[ 39]=8'd1;
        // row 5
        eg_inc_rom[ 40]=8'd1; eg_inc_rom[ 41]=8'd1; eg_inc_rom[ 42]=8'd1; eg_inc_rom[ 43]=8'd2;
        eg_inc_rom[ 44]=8'd1; eg_inc_rom[ 45]=8'd1; eg_inc_rom[ 46]=8'd1; eg_inc_rom[ 47]=8'd2;
        // row 6
        eg_inc_rom[ 48]=8'd1; eg_inc_rom[ 49]=8'd2; eg_inc_rom[ 50]=8'd1; eg_inc_rom[ 51]=8'd2;
        eg_inc_rom[ 52]=8'd1; eg_inc_rom[ 53]=8'd2; eg_inc_rom[ 54]=8'd1; eg_inc_rom[ 55]=8'd2;
        // row 7
        eg_inc_rom[ 56]=8'd1; eg_inc_rom[ 57]=8'd2; eg_inc_rom[ 58]=8'd2; eg_inc_rom[ 59]=8'd2;
        eg_inc_rom[ 60]=8'd1; eg_inc_rom[ 61]=8'd2; eg_inc_rom[ 62]=8'd2; eg_inc_rom[ 63]=8'd2;
        // row 8
        eg_inc_rom[ 64]=8'd2; eg_inc_rom[ 65]=8'd2; eg_inc_rom[ 66]=8'd2; eg_inc_rom[ 67]=8'd2;
        eg_inc_rom[ 68]=8'd2; eg_inc_rom[ 69]=8'd2; eg_inc_rom[ 70]=8'd2; eg_inc_rom[ 71]=8'd2;
        // row 9
        eg_inc_rom[ 72]=8'd2; eg_inc_rom[ 73]=8'd2; eg_inc_rom[ 74]=8'd2; eg_inc_rom[ 75]=8'd4;
        eg_inc_rom[ 76]=8'd2; eg_inc_rom[ 77]=8'd2; eg_inc_rom[ 78]=8'd2; eg_inc_rom[ 79]=8'd4;
        // row 10
        eg_inc_rom[ 80]=8'd2; eg_inc_rom[ 81]=8'd4; eg_inc_rom[ 82]=8'd2; eg_inc_rom[ 83]=8'd4;
        eg_inc_rom[ 84]=8'd2; eg_inc_rom[ 85]=8'd4; eg_inc_rom[ 86]=8'd2; eg_inc_rom[ 87]=8'd4;
        // row 11
        eg_inc_rom[ 88]=8'd2; eg_inc_rom[ 89]=8'd4; eg_inc_rom[ 90]=8'd4; eg_inc_rom[ 91]=8'd4;
        eg_inc_rom[ 92]=8'd2; eg_inc_rom[ 93]=8'd4; eg_inc_rom[ 94]=8'd4; eg_inc_rom[ 95]=8'd4;
        // row 12
        eg_inc_rom[ 96]=8'd4; eg_inc_rom[ 97]=8'd4; eg_inc_rom[ 98]=8'd4; eg_inc_rom[ 99]=8'd4;
        eg_inc_rom[100]=8'd4; eg_inc_rom[101]=8'd4; eg_inc_rom[102]=8'd4; eg_inc_rom[103]=8'd4;
        // row 13 (instant attack)
        eg_inc_rom[104]=8'd8; eg_inc_rom[105]=8'd8; eg_inc_rom[106]=8'd8; eg_inc_rom[107]=8'd8;
        eg_inc_rom[108]=8'd8; eg_inc_rom[109]=8'd8; eg_inc_rom[110]=8'd8; eg_inc_rom[111]=8'd8;
        // row 14 (infinity / zero rate)
        eg_inc_rom[112]=8'd0; eg_inc_rom[113]=8'd0; eg_inc_rom[114]=8'd0; eg_inc_rom[115]=8'd0;
        eg_inc_rom[116]=8'd0; eg_inc_rom[117]=8'd0; eg_inc_rom[118]=8'd0; eg_inc_rom[119]=8'd0;
    end

    logic [7:0] eg_rate_select_rom [0:63];
    initial begin
        eg_rate_select_rom[ 0]=8'd112; eg_rate_select_rom[ 1]=8'd112;
        eg_rate_select_rom[ 2]=8'd112; eg_rate_select_rom[ 3]=8'd112;
        eg_rate_select_rom[ 4]=8'd0;   eg_rate_select_rom[ 5]=8'd8;
        eg_rate_select_rom[ 6]=8'd16;  eg_rate_select_rom[ 7]=8'd24;
        eg_rate_select_rom[ 8]=8'd0;   eg_rate_select_rom[ 9]=8'd8;
        eg_rate_select_rom[10]=8'd16;  eg_rate_select_rom[11]=8'd24;
        eg_rate_select_rom[12]=8'd0;   eg_rate_select_rom[13]=8'd8;
        eg_rate_select_rom[14]=8'd16;  eg_rate_select_rom[15]=8'd24;
        eg_rate_select_rom[16]=8'd0;   eg_rate_select_rom[17]=8'd8;
        eg_rate_select_rom[18]=8'd16;  eg_rate_select_rom[19]=8'd24;
        eg_rate_select_rom[20]=8'd0;   eg_rate_select_rom[21]=8'd8;
        eg_rate_select_rom[22]=8'd16;  eg_rate_select_rom[23]=8'd24;
        eg_rate_select_rom[24]=8'd0;   eg_rate_select_rom[25]=8'd8;
        eg_rate_select_rom[26]=8'd16;  eg_rate_select_rom[27]=8'd24;
        eg_rate_select_rom[28]=8'd0;   eg_rate_select_rom[29]=8'd8;
        eg_rate_select_rom[30]=8'd16;  eg_rate_select_rom[31]=8'd24;
        eg_rate_select_rom[32]=8'd0;   eg_rate_select_rom[33]=8'd8;
        eg_rate_select_rom[34]=8'd16;  eg_rate_select_rom[35]=8'd24;
        eg_rate_select_rom[36]=8'd0;   eg_rate_select_rom[37]=8'd8;
        eg_rate_select_rom[38]=8'd16;  eg_rate_select_rom[39]=8'd24;
        eg_rate_select_rom[40]=8'd0;   eg_rate_select_rom[41]=8'd8;
        eg_rate_select_rom[42]=8'd16;  eg_rate_select_rom[43]=8'd24;
        eg_rate_select_rom[44]=8'd0;   eg_rate_select_rom[45]=8'd8;
        eg_rate_select_rom[46]=8'd16;  eg_rate_select_rom[47]=8'd24;
        eg_rate_select_rom[48]=8'd0;   eg_rate_select_rom[49]=8'd8;
        eg_rate_select_rom[50]=8'd16;  eg_rate_select_rom[51]=8'd24;
        eg_rate_select_rom[52]=8'd32;  eg_rate_select_rom[53]=8'd40;
        eg_rate_select_rom[54]=8'd48;  eg_rate_select_rom[55]=8'd56;
        eg_rate_select_rom[56]=8'd64;  eg_rate_select_rom[57]=8'd72;
        eg_rate_select_rom[58]=8'd80;  eg_rate_select_rom[59]=8'd88;
        eg_rate_select_rom[60]=8'd96;  eg_rate_select_rom[61]=8'd96;
        eg_rate_select_rom[62]=8'd96;  eg_rate_select_rom[63]=8'd96;
    end

    logic [7:0] eg_rate_shift_rom [0:63];
    initial begin
        eg_rate_shift_rom[ 0]=8'd12; eg_rate_shift_rom[ 1]=8'd12;
        eg_rate_shift_rom[ 2]=8'd12; eg_rate_shift_rom[ 3]=8'd12;
        eg_rate_shift_rom[ 4]=8'd11; eg_rate_shift_rom[ 5]=8'd11;
        eg_rate_shift_rom[ 6]=8'd11; eg_rate_shift_rom[ 7]=8'd11;
        eg_rate_shift_rom[ 8]=8'd10; eg_rate_shift_rom[ 9]=8'd10;
        eg_rate_shift_rom[10]=8'd10; eg_rate_shift_rom[11]=8'd10;
        eg_rate_shift_rom[12]=8'd9;  eg_rate_shift_rom[13]=8'd9;
        eg_rate_shift_rom[14]=8'd9;  eg_rate_shift_rom[15]=8'd9;
        eg_rate_shift_rom[16]=8'd8;  eg_rate_shift_rom[17]=8'd8;
        eg_rate_shift_rom[18]=8'd8;  eg_rate_shift_rom[19]=8'd8;
        eg_rate_shift_rom[20]=8'd7;  eg_rate_shift_rom[21]=8'd7;
        eg_rate_shift_rom[22]=8'd7;  eg_rate_shift_rom[23]=8'd7;
        eg_rate_shift_rom[24]=8'd6;  eg_rate_shift_rom[25]=8'd6;
        eg_rate_shift_rom[26]=8'd6;  eg_rate_shift_rom[27]=8'd6;
        eg_rate_shift_rom[28]=8'd5;  eg_rate_shift_rom[29]=8'd5;
        eg_rate_shift_rom[30]=8'd5;  eg_rate_shift_rom[31]=8'd5;
        eg_rate_shift_rom[32]=8'd4;  eg_rate_shift_rom[33]=8'd4;
        eg_rate_shift_rom[34]=8'd4;  eg_rate_shift_rom[35]=8'd4;
        eg_rate_shift_rom[36]=8'd3;  eg_rate_shift_rom[37]=8'd3;
        eg_rate_shift_rom[38]=8'd3;  eg_rate_shift_rom[39]=8'd3;
        eg_rate_shift_rom[40]=8'd2;  eg_rate_shift_rom[41]=8'd2;
        eg_rate_shift_rom[42]=8'd2;  eg_rate_shift_rom[43]=8'd2;
        eg_rate_shift_rom[44]=8'd1;  eg_rate_shift_rom[45]=8'd1;
        eg_rate_shift_rom[46]=8'd1;  eg_rate_shift_rom[47]=8'd1;
        eg_rate_shift_rom[48]=8'd0;  eg_rate_shift_rom[49]=8'd0;
        eg_rate_shift_rom[50]=8'd0;  eg_rate_shift_rom[51]=8'd0;
        eg_rate_shift_rom[52]=8'd0;  eg_rate_shift_rom[53]=8'd0;
        eg_rate_shift_rom[54]=8'd0;  eg_rate_shift_rom[55]=8'd0;
        eg_rate_shift_rom[56]=8'd0;  eg_rate_shift_rom[57]=8'd0;
        eg_rate_shift_rom[58]=8'd0;  eg_rate_shift_rom[59]=8'd0;
        eg_rate_shift_rom[60]=8'd0;  eg_rate_shift_rom[61]=8'd0;
        eg_rate_shift_rom[62]=8'd0;  eg_rate_shift_rom[63]=8'd0;
    end

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

    // ── Helper ─────────────────────────────────────────────────────────
    function automatic logic eg_do_update(input [23:0] cnt, input [7:0] sh);
        logic [23:0] mask;
        mask = (24'd1 << sh) - 24'd1;
        return (cnt & mask) == 24'd0;
    endfunction

    function automatic [2:0] eg_phase(input [23:0] cnt, input [7:0] sh);
        return 3'((cnt >> sh) & 24'd7);
    endfunction

    ymf278_pcm_alu alu();

    // ── Output logic ───────────────────────────────────────────────────
    // Based on openMSX logic
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

        next_state = cur_state;
        next_vol   = cur_vol;

        if (key_on_edge && cur_state == EG_OFF) begin
            next_vol = MAX_ATT_INDEX;
            rate = alu.calc_eg_rate(ar, rc, oct, fn);
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
                    rate = alu.calc_eg_rate(ar, rc, oct, fn);
                    shift_v = eg_rate_shift_rom[rate];
                    if (rate < 6'd63 && eg_do_update(eg_cnt, shift_v)) begin
                        sel_v = eg_rate_select_rom[rate];
                        phase_v = eg_phase(eg_cnt, shift_v);
                        inc_v = eg_inc_rom[sel_v + {5'd0, phase_v}];
                        next_vol = alu.calc_attack_step(cur_vol, inc_v);
                        if (next_vol <= MIN_ATT_INDEX) begin
                            next_vol = MIN_ATT_INDEX;
                            next_state = (dl_idx != 4'h0) ? EG_DEC : EG_SUS;
                        end
                    end
                end
                EG_DEC: begin
                    rate = alu.calc_decay_rate(d1r, rc, damp, prvb, cur_vol, oct, fn);
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
                    rate = alu.calc_decay_rate(d2r, rc, damp, prvb, cur_vol, oct, fn);
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
                    rate = alu.calc_decay_rate(rr, rc, damp, prvb, cur_vol, oct, fn);
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

endmodule