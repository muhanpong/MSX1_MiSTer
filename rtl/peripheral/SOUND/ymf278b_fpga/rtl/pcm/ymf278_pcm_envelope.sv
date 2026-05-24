// YMF278 PCM Envelope Generator
// 24-slot time-multiplexed. One slot updated per clock cycle.
// Exactly matches openMSX YMF278.cc advance() EG logic.
`default_nettype none

module ymf278_pcm_envelope (
    input  wire        clk,
    input  wire        rst_n,

    // Scheduler interface
    input  wire [4:0]  slot_idx,       // 0..23 current slot
    input  wire        slot_valid,     // process this slot

    // Per-slot parameters (from register file, latched externally)
    input  wire [3:0]  AR,
    input  wire [3:0]  D1R,
    input  wire [3:0]  D2R,
    input  wire [3:0]  RR,
    input  wire [3:0]  RC,
    input  wire [9:0]  FN,
    input  wire signed [3:0] OCT,     // sign-extended -8..+7
    input  wire [15:0] DL,            // dl_tab value (10-bit value zero-padded to 16)
    input  wire        PRVB,
    input  wire        DAMP,
    input  wire        key_on,

    // eg_cnt: global, incremented once per full 24-slot round
    input  wire [23:0] eg_cnt,

    // Output
    output logic [9:0] env_vol        // 0=max, 0x280=silence
);

// ── Constants ──────────────────────────────────────────────────────
localparam int MAX_ATT_INDEX = 11'h280;
localparam int MIN_ATT_INDEX = 11'h000;

// EG states
localparam [2:0] EG_OFF = 3'd0;
localparam [2:0] EG_REL = 3'd1;
localparam [2:0] EG_SUS = 3'd2;
localparam [2:0] EG_DEC = 3'd3;
localparam [2:0] EG_ATT = 3'd4;

// ── ROM tables ─────────────────────────────────────────────────────
// eg_inc[120]: 15 rows × 8 columns
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

// eg_rate_select[64]: O(a) = a*8
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

// eg_rate_shift[64]
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

// ── Per-slot BRAM: {state[2:0], env_vol[10:0]} ────────────────────
// env_vol 11 bits to hold 0..0x280 without overflow
logic [13:0] slot_mem [0:23];  // {state[2:0], env_vol[10:0]}
integer _si;
initial begin
    for (_si = 0; _si < 24; _si = _si + 1)
        slot_mem[_si] = {EG_OFF, 11'(MAX_ATT_INDEX)};
end

// ── Per-slot key_on previous state (for internal edge detection) ──
logic key_on_prev_mem [0:23];
integer _kpi;
initial begin
    for (_kpi = 0; _kpi < 24; _kpi = _kpi + 1)
        key_on_prev_mem[_kpi] = 1'b0;
end

// ── Helper functions ──────────────────────────────────────────────

// compute_rate: matches YMF278.cc
function automatic [5:0] compute_rate(
    input [3:0] val, rc,
    input signed [3:0] oct,
    input [9:0] fn
);
    logic signed [7:0] res;
    if (val == 4'd0) return 6'd0;
    if (val == 15)   return 6'd63;
    res = $signed({4'd0, val}) * 8'sd4;
    if (rc != 4'd15) begin
        // oct_rc = clamp(OCT + RC, 0, 15)
        begin
            logic signed [5:0] oct_rc;
            logic [3:0] clamped;
            oct_rc = $signed({2'b0,rc}) + oct;
            if (oct_rc < 6'sd0)        clamped = 4'd0;
            else if (oct_rc > 6'sd15)  clamped = 4'd15;
            else                       clamped = oct_rc[3:0];
            res += $signed({3'd0, clamped, 1'b0});   // += 2*clamped
            if (fn[9]) res += 8'sd1;
        end
    end
    if (res < 8'sd0)  return 6'd0;
    if (res > 8'sd63) return 6'd63;
    return res[5:0];
endfunction

// compute_decay_rate
function automatic [5:0] compute_decay_rate(
    input [3:0]  val, rc,
    input        damp, prvb,
    input [10:0] ev,
    input signed [3:0] oct,
    input [9:0]  fn
);
    // dl_tab[4] = 0x080, dl_tab[6] = 0x0C0
    if (damp) return (ev < 11'h080) ? 6'd48 : 6'd63;
    if (prvb && ev >= 11'h0C0) return 6'd20;
    return compute_rate(val, rc, oct, fn);
endfunction

// eg_do_update: check if eg_cnt lower 'shift' bits are zero
function automatic logic eg_do_update(input [23:0] cnt, input [7:0] sh);
    logic [23:0] mask;
    mask = (24'd1 << sh) - 24'd1;  // 0 when sh=0 → always update
    return (cnt & mask) == 24'd0;
endfunction

// eg_phase: 3-bit phase index = (cnt >> shift) & 7
function automatic [2:0] eg_phase(input [23:0] cnt, input [7:0] sh);
    return 3'((cnt >> sh) & 24'd7);
endfunction

// attack_step: env_vol + ((~env_vol * inc) >> 4) — C++ int semantics.
// ~ev treated as signed 11-bit (negative), product >> 4 is arithmetic.
function automatic [10:0] attack_step(input [10:0] ev, input [7:0] i);
    logic signed [10:0] inv;
    logic signed [20:0] product;
    logic signed [11:0] result;
    inv     = ~ev;                              // signed 11-bit NOT → negative value
    product = inv * $signed({1'b0, i});         // signed × positive = negative product
    result  = $signed({1'b0, ev}) + product[15:4];  // arithmetic >> 4
    if (result <= 12'sd0) return 11'd0;
    return result[10:0];
endfunction

// ── Pipeline stage 1: read BRAM ───────────────────────────────────
logic [13:0] slot_rd;
logic [10:0] cur_vol;
logic [2:0]  cur_state;
logic        slot_valid_d1;
logic [4:0]  slot_idx_d1;
logic [3:0]  AR_d1, D1R_d1, D2R_d1, RR_d1, RC_d1;
logic [9:0]  FN_d1;
logic signed [3:0] OCT_d1;
logic [15:0] DL_d1;
logic        PRVB_d1, DAMP_d1;
logic        key_on_d1;
logic        key_on_prev_rd;

always_ff @(posedge clk) begin
    slot_rd          <= slot_mem[slot_idx];
    slot_valid_d1    <= slot_valid;
    slot_idx_d1      <= slot_idx;
    AR_d1            <= AR;
    D1R_d1           <= D1R;
    D2R_d1           <= D2R;
    RR_d1            <= RR;
    RC_d1            <= RC;
    FN_d1            <= FN;
    OCT_d1           <= OCT;
    DL_d1            <= DL;
    PRVB_d1          <= PRVB;
    DAMP_d1          <= DAMP;
    key_on_d1        <= key_on;
    key_on_prev_rd   <= key_on_prev_mem[slot_idx];
end

assign cur_vol   = slot_rd[10:0];
assign cur_state = slot_rd[13:11];

// Internal per-slot edge detection — replaces external pulse inputs.
// key_on_prev_rd holds the key_on state from the PREVIOUS slot_valid
// cycle for this slot, so the edge is detected exactly when the slot
// is being processed.
wire local_key_on_pulse  =  key_on_d1 && !key_on_prev_rd;
wire local_key_off_pulse = !key_on_d1 &&  key_on_prev_rd;

// ── EG combinational update ───────────────────────────────────────
logic [10:0] new_vol;
logic [2:0]  new_state;
logic [5:0]  rate;
logic [7:0]  shift_v, sel_v;
logic [7:0]  inc_v;
logic [2:0]  phase_v;
logic        upd;

always_comb begin
    new_vol   = cur_vol;
    new_state = cur_state;
    rate      = 6'd0;
    shift_v   = 8'd0;
    sel_v     = 8'd0;
    inc_v     = 8'd0;
    phase_v   = 3'd0;
    upd       = 1'b0;

    if (slot_valid_d1) begin
        if (local_key_on_pulse) begin
            // Key-on: reset and enter attack (or skip if AR=15)
            new_vol = 11'(MAX_ATT_INDEX);
            if (compute_rate(AR_d1, RC_d1, OCT_d1, FN_d1) < 6'd63) begin
                new_state = EG_ATT;
            end else begin
                new_vol   = 11'(MIN_ATT_INDEX);
                new_state = (DL_d1 != 16'h0) ? EG_DEC : EG_SUS;
            end
        end else if (local_key_off_pulse) begin
            if (cur_state != EG_OFF) new_state = EG_REL;
        end else begin
            case (cur_state)
                EG_ATT: begin
                    rate    = compute_rate(AR_d1, RC_d1, OCT_d1, FN_d1);
                    shift_v = eg_rate_shift_rom[rate];
                    if (rate < 6'd63 && eg_do_update(eg_cnt, shift_v)) begin
                        sel_v   = eg_rate_select_rom[rate];
                        phase_v = eg_phase(eg_cnt, shift_v);
                        inc_v   = eg_inc_rom[sel_v + {5'd0, phase_v}];
                        new_vol = attack_step(cur_vol, inc_v);
                        if (new_vol <= 11'(MIN_ATT_INDEX)) begin
                            new_vol   = 11'(MIN_ATT_INDEX);
                            new_state = (DL_d1 != 16'h0) ? EG_DEC : EG_SUS;
                        end
                    end
                end

                EG_DEC: begin
                    rate    = compute_decay_rate(D1R_d1, RC_d1, DAMP_d1, PRVB_d1, cur_vol, OCT_d1, FN_d1);
                    shift_v = eg_rate_shift_rom[rate];
                    if (eg_do_update(eg_cnt, shift_v)) begin
                        sel_v   = eg_rate_select_rom[rate];
                        phase_v = eg_phase(eg_cnt, shift_v);
                        inc_v   = eg_inc_rom[sel_v + {5'd0, phase_v}];
                        new_vol = cur_vol + {3'd0, inc_v};
                        if (new_vol >= DL_d1[10:0]) begin
                            new_state = (new_vol < 11'(MAX_ATT_INDEX)) ? EG_SUS : EG_OFF;
                        end
                    end
                end

                EG_SUS: begin
                    rate    = compute_decay_rate(D2R_d1, RC_d1, DAMP_d1, PRVB_d1, cur_vol, OCT_d1, FN_d1);
                    shift_v = eg_rate_shift_rom[rate];
                    if (eg_do_update(eg_cnt, shift_v)) begin
                        sel_v   = eg_rate_select_rom[rate];
                        phase_v = eg_phase(eg_cnt, shift_v);
                        inc_v   = eg_inc_rom[sel_v + {5'd0, phase_v}];
                        new_vol = cur_vol + {3'd0, inc_v};
                        if (new_vol >= 11'(MAX_ATT_INDEX)) begin
                            new_vol   = 11'(MAX_ATT_INDEX);
                            new_state = EG_OFF;
                        end
                    end
                end

                EG_REL: begin
                    rate    = compute_decay_rate(RR_d1, RC_d1, DAMP_d1, PRVB_d1, cur_vol, OCT_d1, FN_d1);
                    shift_v = eg_rate_shift_rom[rate];
                    if (eg_do_update(eg_cnt, shift_v)) begin
                        sel_v   = eg_rate_select_rom[rate];
                        phase_v = eg_phase(eg_cnt, shift_v);
                        inc_v   = eg_inc_rom[sel_v + {5'd0, phase_v}];
                        new_vol = cur_vol + {3'd0, inc_v};
                        if (new_vol >= 11'(MAX_ATT_INDEX)) begin
                            new_vol   = 11'(MAX_ATT_INDEX);
                            new_state = EG_OFF;
                        end
                    end
                end

                default: ; // EG_OFF
            endcase
        end
    end
end

// ── BRAM write ────────────────────────────────────────────────────
always_ff @(posedge clk) begin
    if (!rst_n) begin
        for (int i = 0; i < 24; i++) begin
            slot_mem[i] <= {EG_OFF, 11'(MAX_ATT_INDEX)};
            key_on_prev_mem[i] <= 1'b0;
        end
    end else if (slot_valid_d1) begin
        slot_mem[slot_idx_d1] <= {new_state, new_vol};
        key_on_prev_mem[slot_idx_d1] <= key_on_d1;
    end
end

// ── Output: expose current slot's env_vol ────────────────────────
always_ff @(posedge clk) begin
    if (!rst_n) env_vol <= 10'(MAX_ATT_INDEX);
    else        env_vol <= slot_mem[slot_idx][9:0];
end

endmodule
`default_nettype wire
