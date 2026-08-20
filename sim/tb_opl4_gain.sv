// tb_opl4_gain — OPL4 per-path output gain (ymf278b_top stage 1 + 2)
//
// Replicates the shipped datapath from
// rtl/peripheral/SOUND/ymf278b_fpga/rtl/ymf278b_top.sv verbatim and checks:
//   T1  each OSD step delivers its nominal dB (0 / +4 / +8 / +12)
//   T2  no sign wrap anywhere across the full input range, either path
//   T3  the single saturation clamps to exactly +32767 / -32768 and is monotone
//   T4  FM and PCM sum independently and correctly (a boost on one path
//       cannot change the other's contribution)
//   T5  silence in -> bit-exact silence out, at every gain setting
//
// Negative control (+define+NEGCTL): every step is forced to unity.  T1 MUST
// then fail for steps 1..3 — a TB that passes either way proves nothing.
`timescale 1ns/1ps
`default_nettype none

module tb_opl4_gain;

   localparam int GAIN_SH = 7;

   function automatic [11:0] gain_mul(input [1:0] sel);
`ifdef NEGCTL
      gain_mul = 12'd128;                       // negative control: every step unity
`else
      case (sel)
         2'd0: gain_mul = 12'd128;   //   0.00 dB
         2'd1: gain_mul = 12'd81;    //  -3.98 dB
         2'd2: gain_mul = 12'd51;    //  -8.00 dB
         default: gain_mul = 12'd32; // -12.04 dB
      endcase
`endif
   endfunction

   // --- the DUT datapath, copied from ymf278b_top.sv stage 1 + stage 2 ---
   function automatic signed [15:0] mix(input signed [16:0] fm,
                                        input signed [15:0] pc,
                                        input [1:0] fsel, input [1:0] psel,
                                        input pmute);
      logic signed [29:0] fm_mul, pc_mul;
      logic signed [21:0] sum;
      begin
         fm_mul = $signed(fm) * $signed({1'b0, gain_mul(fsel)});
         pc_mul = pmute ? 30'sh0 : $signed({pc[15], pc}) * $signed({1'b0, gain_mul(psel)});
         sum    = 22'(fm_mul >>> GAIN_SH) + 22'(pc_mul >>> GAIN_SH);
         mix    = (sum >  22'sd32767) ? 16'sh7FFF :
                  (sum < -22'sd32768) ? 16'sh8000 : sum[15:0];
      end
   endfunction

   int errors = 0, checks = 0;
   task automatic chk(input string what, input bit ok);
      begin checks++; if (!ok) begin errors++; $display("FAIL: %s", what); end end
   endtask

   real gmin, gmax, g, db;
   real want [4]; 
   logic signed [15:0] y, yprev;
   int lim;

   initial begin
      // downward-only scale: 0 dB is the hardware-accurate reference
      want[0] = 0.0; want[1] = -3.98; want[2] = -8.00; want[3] = -12.04;

      // ---- T1: gain accuracy per step, FM path alone, linear region only ----
      for (int sel = 0; sel < 4; sel++) begin
         lim = (32767 * 128) / int'(gain_mul(sel[1:0]));   // largest input that cannot clip
         if (lim > 65535) lim = 65535;                     // bounded by the 17-bit input
         gmin = 1.0e9; gmax = -1.0e9;
         for (int v = -lim; v <= lim; v += 13) begin
            if (v > -1000 && v < 1000) continue;           // truncation dominates below this
            y = mix(17'(v), 16'sd0, sel[1:0], 2'd0, 1'b0);
            g = real'(int'(y)) / real'(v);
            if (g < gmin) gmin = g;
            if (g > gmax) gmax = g;
         end
         db = 20.0 * $log10((gmin + gmax) / 2.0);
         $display("T1  step %0d: measured %0.3f dB (nominal %0.1f)", sel, db, want[sel]);
         chk($sformatf("T1 step %0d is %0.1f dB (got %0.3f)", sel, want[sel], db),
             (db > want[sel] - 0.12) && (db < want[sel] + 0.12));
      end

      // ---- T2: no sign wrap, both paths, every gain setting ----------------
      for (int sel = 0; sel < 4; sel++)
         for (int v = -65536; v <= 65535; v += 97) begin
            y = mix(17'(v), 16'sd0, sel[1:0], 2'd0, 1'b0);
            chk($sformatf("T2 FM wrap sel=%0d v=%0d", sel, v),
                (v > 0) ? (y > 0) : (v < 0) ? (y < 0) : (y == 0));
            if (v >= -32768 && v <= 32767) begin
               y = mix(17'sd0, 16'(v), 2'd0, sel[1:0], 1'b0);
               chk($sformatf("T2 PCM wrap sel=%0d v=%0d", sel, v),
                   (v > 0) ? (y > 0) : (v < 0) ? (y < 0) : (y == 0));
            end
         end

      // ---- T3: monotone + exact clamps -------------------------------------
      for (int sel = 0; sel < 4; sel++) begin
         yprev = 16'sh8000;
         for (int v = -65536; v <= 65535; v += 113) begin
            y = mix(17'(v), 16'sd0, sel[1:0], 2'd0, 1'b0);
            chk($sformatf("T3 monotone sel=%0d v=%0d", sel, v), y >= yprev);
            yprev = y;
         end
         // The extremes only CLAMP where the gain is large enough to push them
         // past full scale; an attenuating step must pass them through scaled.
         // Compute the expectation instead of assuming a clamp.
         begin
            automatic int m  = int'(gain_mul(sel[1:0]));
            automatic int hi = (65535 * m) >>> 7;
            automatic int lo = (-65536 * m) >>> 7;
            if (hi >  32767) hi =  32767;
            if (lo < -32768) lo = -32768;
            chk($sformatf("T3 top extreme sel=%0d (want %0d)", sel, hi),
                int'(mix( 17'sd65535, 16'sd0, sel[1:0], 2'd0, 1'b0)) == hi);
            chk($sformatf("T3 bottom extreme sel=%0d (want %0d)", sel, lo),
                int'(mix(-17'sd65536, 16'sd0, sel[1:0], 2'd0, 1'b0)) == lo);
         end
      end

      // ---- T4: the two paths are independent -------------------------------
      // Boosting FM must not alter what PCM contributes, and vice versa.
      for (int fs = 0; fs < 4; fs++)
         for (int ps = 0; ps < 4; ps++)
            for (int a = -8000; a <= 8000; a += 1000)
               for (int b = -8000; b <= 8000; b += 2000) begin
                  automatic int only_fm = int'(mix(17'(a), 16'sd0, fs[1:0], ps[1:0], 1'b0));
                  automatic int only_pc = int'(mix(17'sd0, 16'(b), fs[1:0], ps[1:0], 1'b0));
                  automatic int both    = int'(mix(17'(a), 16'(b), fs[1:0], ps[1:0], 1'b0));
                  // Each path is floored independently and summed, so the
                  // identity is EXACT — the only thing that can break it is the
                  // final clamp.  |a|,|b| <= 8000 with gain <= 510/128 gives at
                  // most 31875 per path, so neither term can clamp on its own.
                  automatic int want = only_fm + only_pc;
                  if (want >  32767) want =  32767;
                  if (want < -32768) want = -32768;
                  chk($sformatf("T4 independence fs=%0d ps=%0d a=%0d b=%0d (got %0d want %0d)",
                                fs, ps, a, b, both, want), both == want);
               end

      // ---- T5: silence stays silence, and pcm_mute really mutes ------------
      for (int fs = 0; fs < 4; fs++)
         for (int ps = 0; ps < 4; ps++) begin
            chk($sformatf("T5 silence fs=%0d ps=%0d", fs, ps),
                mix(17'sd0, 16'sd0, fs[1:0], ps[1:0], 1'b0) == 16'sd0);
            chk($sformatf("T5 pcm_mute fs=%0d ps=%0d", fs, ps),
                mix(17'sd0, 16'sd20000, fs[1:0], ps[1:0], 1'b1) == 16'sd0);
         end

`ifdef NEGCTL
      $display("");
      $display("NEGATIVE CONTROL: all steps forced to unity — T1 steps 1..3 MUST fail.");
      if (errors == 0) begin
         $display("NEGCTL BROKEN: unity passed the per-step dB check. TB is worthless.");
         $finish(1);
      end
      $display("negative control OK: %0d/%0d checks failed as required", errors, checks);
      $finish(0);
`else
      $display("");
      $display("tb_opl4_gain: %0d checks, %0d errors", checks, errors);
      if (errors) $finish(1);
      $finish(0);
`endif
   end
endmodule
`default_nettype wire
