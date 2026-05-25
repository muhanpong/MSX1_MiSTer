// YMF278B PCM ALU (Arithmetic Logic Unit)
// Package of pure combinational functions extracted from openMSX.
// Used to be a module (callable via instance dot notation), converted to a
// package because Quartus 17.1 doesn't support cross-module function calls.

package ymf278_pcm_alu_pkg;

    // ========================================================================
    // 1. Step Calculation (Pitch / Frequency)
    // Matches openMSX: calcStep(OCT, FN)
    // ========================================================================
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

    // ========================================================================
    // 2. Linear Interpolation
    // Matches openMSX: sample = samp_a + ((samp_b - samp_a) * stepPtr) >> 16
    // ========================================================================
    function automatic signed [15:0] calc_interp(
        input signed [15:0] samp_a,
        input signed [15:0] samp_b,
        input [15:0] step_ptr
    );
        logic signed [16:0] diff;
        logic signed [32:0] prod;
        diff = $signed({samp_b[15], samp_b}) - $signed({samp_a[15], samp_a});
        prod = diff * $signed({1'b0, step_ptr});
        return samp_a + prod[32:16];
    endfunction

    // ========================================================================
    // 3. Volume Attenuation (Envelope + Total Level)
    // Replicates openMSX's env_vol + TL -> log scale -> linear volume conversion.
    // MAX_ATT_INDEX = 0x280 (Silence)
    // ========================================================================
    function automatic signed [31:0] calc_vol(
        input signed [15:0] sample_in,
        input [9:0] env_vol,
        input [7:0] tl
    );
        logic [10:0] total_atten;
        logic [7:0]  vol_mul;
        logic [4:0]  vol_shift;
        logic signed [31:0] tmp;

        total_atten = {1'b0, env_vol} + {1'b0, tl, 2'b00}; // TL << 2
        
        if (total_atten >= 11'h280) return 32'sd0; // Silence

        // 6-bit mantissa, 4-bit exponent mapping (derived from YMF278B tables)
        vol_mul   = 8'h80 - {2'b0, total_atten[5:0]};
        vol_shift = 5'(4'd7 + {1'b0, total_atten[9:6]});
        
        tmp = (32'sh8000 * $signed({1'b0, vol_mul})) >>> vol_shift;
        return ($signed(sample_in) * tmp) >>> 15;
    endfunction

    // ========================================================================
    // 4. Panning Attenuation (per channel)
    // openMSX pan tables (YMF278.cc):
    //   pan_left  = [0, 8,16,24,32,40,48,255,255,0, 0, 0, 0, 0, 0, 0]
    //   pan_right = [0, 0, 0, 0, 0, 0, 0, 0, 255,255,48,40,32,24,16, 8]
    //   pan_att(p) = (p==255) ? 0 : (0x20 - (p & 0xF)) >> (p >> 4)
    // Returns 6-bit gain: 0x20 = full (×1 after >>>5), 0 = silence.
    // ========================================================================
    function automatic [5:0] pan_att_calc(input [7:0] p);
        if (p == 8'd255) return 6'd0;
        return 6'((6'h20 - {2'b0, p[3:0]}) >> p[7:4]);
    endfunction

    function automatic [7:0] pan_left_rom(input [3:0] pan_val);
        case (pan_val)
            4'd0:  return 8'd0;    4'd1:  return 8'd8;
            4'd2:  return 8'd16;   4'd3:  return 8'd24;
            4'd4:  return 8'd32;   4'd5:  return 8'd40;
            4'd6:  return 8'd48;   4'd7:  return 8'd255;
            4'd8:  return 8'd255;  default: return 8'd0;
        endcase
    endfunction

    function automatic [7:0] pan_right_rom(input [3:0] pan_val);
        case (pan_val)
            4'd8:  return 8'd255;  4'd9:  return 8'd255;
            4'd10: return 8'd48;   4'd11: return 8'd40;
            4'd12: return 8'd32;   4'd13: return 8'd24;
            4'd14: return 8'd16;   4'd15: return 8'd8;
            default: return 8'd0;
        endcase
    endfunction

    function automatic [5:0] pan_att_left(input [3:0] pan_val);
        return pan_att_calc(pan_left_rom(pan_val));
    endfunction

    function automatic [5:0] pan_att_right(input [3:0] pan_val);
        return pan_att_calc(pan_right_rom(pan_val));
    endfunction

    // ========================================================================
    // 5. Memory Address Calculation
    // Matches openMSX: calculates absolute byte address based on format
    // ========================================================================
    function automatic [21:0] byte_addr(
        input [21:0] base,
        input [15:0] p,
        input [1:0]  fmt,
        input [1:0]  byte_sel   // byte within the sample
    );
        logic [21:0] a;
        case (fmt)
            2'd0: a = base + {6'd0, p};              // 8-bit: 1 byte/sample
            2'd1: a = base + 22'({7'd0, p[15:1]} * 22'd3) + {20'd0, byte_sel}; // 12-bit
            2'd2: a = base + {5'd0, p, 1'b0} + {20'd0, byte_sel[0:0]}; // 16-bit
            default: a = base;
        endcase
        return a;
    endfunction

    // ========================================================================
    // 6. Sample Decoding
    // Reconstructs signed 16-bit PCM from raw bytes
    // ========================================================================
    function automatic signed [15:0] decode_sample(
        input [7:0] b0, b1, b2,
        input [15:0] p,
        input [1:0] fmt
    );
        case (fmt)
            2'd0: return $signed({b0, 8'h00});
            2'd1: begin
                if (p[0]) // odd pos
                    return $signed({b2, b1 & 8'hF0});
                else       // even pos
                    return $signed({b0, (b1 << 4) & 8'hF0});
            end
            2'd2: return $signed({b0, b1});
            default: return 16'sh0;
        endcase
    endfunction

    // ========================================================================
    // 7. Envelope Rate Calculations (ADSR)
    // ========================================================================
    function automatic [5:0] calc_eg_rate(
        input [3:0] val, rc,
        input signed [3:0] oct,
        input [9:0] fn
    );
        logic signed [7:0] res;
        if (val == 4'd0) return 6'd0;
        if (val == 15)   return 6'd63;
        res = $signed({4'd0, val}) * 8'sd4;
        if (rc != 4'd15) begin
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

    function automatic [5:0] calc_decay_rate(
        input [3:0]  val, rc,
        input        damp, prvb,
        input [9:0]  ev,
        input signed [3:0] oct,
        input [9:0]  fn
    );
        // dl_tab[4] = 0x080, dl_tab[6] = 0x0C0
        if (damp) return (ev < 10'h080) ? 6'd48 : 6'd63;
        if (prvb && ev >= 10'h0C0) return 6'd20;
        return calc_eg_rate(val, rc, oct, fn);
    endfunction

    // ========================================================================
    // 8. Envelope Attack Step
    // ========================================================================
    function automatic [9:0] calc_attack_step(input [9:0] ev, input [7:0] inc_val);
        logic signed [10:0] inv;
        logic signed [20:0] product;
        logic signed [11:0] result;
        inv     = ~{1'b0, ev};                              // signed 11-bit NOT
        product = inv * $signed({1'b0, inc_val});           // signed × positive
        result  = $signed({2'b0, ev}) + (product >>> 4);    // arithmetic >> 4
        if (result <= 12'sd0) return 10'd0;
        return result[9:0];
    endfunction

endpackage
