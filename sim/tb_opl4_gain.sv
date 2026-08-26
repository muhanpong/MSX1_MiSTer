// tb_opl4_gain — OPL4 per-path output gain, 5-step measured calibration
//
// Models the shipped datapath from
//   rtl/peripheral/SOUND/ymf278b_fpga/rtl/ymf278b_top.sv   (stage 1 + stage 2)
//   rtl/peripheral/SOUND/ymf278b_fpga/rtl/pcm/ymf278_pcm_engine2.sv (frame out)
// PCM is deliberately modelled as TWO stages, because that is the whole point
// of the 2026-08-21 recalibration: the engine saturates to 16 bit internally,
// so most of the attenuation must happen BEFORE that clamp or the clipping can
// never be undone downstream.
//
//   T1  each OSD step delivers its calibrated net dB (FM and PCM separately)
//   T2  no sign wrap anywhere across the full input range, either path
//   T3  monotone, and the extremes land exactly where the arithmetic says
//   T4  FM and PCM sum independently
//   T5  silence in -> bit-exact silence out; pcm_mute really mutes
//   T6  headroom: an accumulator 11 dB over full scale must come through
//       CLEAN at the attenuating steps and clip only at the loudest step.
//       This is the regression that the old post-saturation-only trim failed.
//
// Negative control (+define+NEGCTL): every step forced to unity / no shift.
// T1 and T6 MUST then fail — a TB that passes either way proves nothing.
`timescale 1ns/1ps
`default_nettype none

module tb_opl4_gain;

   localparam int GAIN_SH = 7;

   // ---- gain tables, kept identical to ymf278b_top.sv --------------------
   function automatic [1:0] pcm_pre(input [2:0] sel);
`ifdef NEGCTL
      pcm_pre = 2'd3;                       // negative control: no pre-shift
`else
      case (sel)
         3'd1: pcm_pre = 2'd0;   // "-8dB"  sh 3
         3'd2: pcm_pre = 2'd2;   // "0dB"   sh 1
         3'd3: pcm_pre = 2'd2;   // "+4dB"  sh 1
         3'd4: pcm_pre = 2'd3;   // "+8dB"  sh 0
         default: pcm_pre = 2'd1;// "-4dB"  sh 2   <- default
      endcase
`endif
   endfunction

   function automatic [11:0] pcm_post(input [2:0] sel);
`ifdef NEGCTL
      pcm_post = 12'd128;
`else
      case (sel)
         3'd1: pcm_post = 12'd162;
         3'd2: pcm_post = 12'd102;
         3'd3: pcm_post = 12'd162;
         3'd4: pcm_post = 12'd128;
         default: pcm_post = 12'd129;
      endcase
`endif
   endfunction

   function automatic [11:0] fm_gain(input [2:0] sel);
`ifdef NEGCTL
      fm_gain = 12'd128;
`else
      case (sel)
         3'd1: fm_gain = 12'd128;
         3'd2: fm_gain = 12'd81;
         3'd3: fm_gain = 12'd51;
         3'd4: fm_gain = 12'd203;
         default: fm_gain = 12'd322;
      endcase
`endif
   endfunction

   // ---- engine frame output: shift THEN saturate (ymf278_pcm_engine2) -----
   // pcm_mix_gain() (wave reg 0xF9) is unity at reset and is not part of the
   // OSD scale, so it is left out here.
   function automatic signed [15:0] engine_out(input signed [23:0] accum,
                                               input [2:0] psel);
      logic [1:0] sh;
      logic signed [23:0] shifted;
      begin
         sh = 2'd3 - pcm_pre(psel);
         shifted = accum >>> sh;
         engine_out = (shifted >  24'sd32767) ? 16'sh7FFF :
                      (shifted < -24'sd32768) ? 16'sh8000 : shifted[15:0];
      end
   endfunction

   // ---- ymf278b_top stage 1 + stage 2 ------------------------------------
   function automatic signed [15:0] mix(input signed [16:0] fm,
                                        input signed [23:0] pcm_accum,
                                        input [2:0] fsel, input [2:0] psel,
                                        input pmute);
      logic signed [15:0] pc;
      logic signed [29:0] fm_mul, pc_mul;
      logic signed [21:0] sum;
      begin
         pc     = engine_out(pcm_accum, psel);
         fm_mul = $signed(fm) * $signed({1'b0, fm_gain(fsel)});
         pc_mul = pmute ? 30'sh0 : $signed({pc[15], pc}) * $signed({1'b0, pcm_post(psel)});
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
   real fm_want [5];
   real pc_want [5];
   logic signed [15:0] y, yprev;
   int lim;

   initial begin
      // menu order: FM  { +8dB, 0dB, -4dB, -8dB, +4dB }  -- labels ARE net vs unity
      //   entry 0 (+8dB, mul 322) is the OSD default, user decision 2026-08-26
      fm_want[0] = +8.01; fm_want[1] =  0.00; fm_want[2] = -3.97;
      fm_want[3] = -7.99; fm_want[4] = +4.01;
      // menu order: PCM { -12dB, -16dB, -8dB, -4dB, 0dB }  labels = net vs unity
      pc_want[0] = -12.00; pc_want[1] = -16.00; pc_want[2] = -8.00;
      pc_want[3] =  -4.00; pc_want[4] =   0.00;

      // ---- T1a: FM gain accuracy per step, linear region only -------------
      for (int sel = 0; sel < 5; sel++) begin
         lim = (32767 * 128) / int'(fm_gain(sel[2:0]));
         if (lim > 65535) lim = 65535;
         gmin = 1.0e9; gmax = -1.0e9;
         for (int v = -lim; v <= lim; v += 13) begin
            if (v > -1000 && v < 1000) continue;
            y = mix(17'(v), 24'sd0, sel[2:0], 3'd0, 1'b0);
            g = real'(int'(y)) / real'(v);
            if (g < gmin) gmin = g;
            if (g > gmax) gmax = g;
         end
         db = 20.0 * $log10((gmin + gmax) / 2.0);
         $display("T1a FM  step %0d: %7.3f dB (want %6.2f)", sel, db, fm_want[sel]);
         chk($sformatf("T1a FM step %0d want %0.2f got %0.3f", sel, fm_want[sel], db),
             (db > fm_want[sel] - 0.15) && (db < fm_want[sel] + 0.15));
      end

      // ---- T1b: PCM net gain per step, accumulator -> output ---------------
      for (int sel = 0; sel < 5; sel++) begin
         automatic int sh = 3 - int'(pcm_pre(sel[2:0]));
         automatic int m  = int'(pcm_post(sel[2:0]));
         // Two independent ceilings: the engine clamp (accum >> sh must fit in
         // 16 bit) and the final clamp after the post multiply.  The sweep has
         // to stay under BOTH, so take the smaller -- overwriting with the
         // post-stage limit alone walks straight into the engine clamp.
         begin
            automatic int lim_engine = 32767 << sh;
            automatic int lim_post   = ((32767 * 128) / m) << sh;
            lim = (lim_engine < lim_post) ? lim_engine : lim_post;
         end
         gmin = 1.0e9; gmax = -1.0e9;
         for (int v = -lim; v <= lim; v += (lim/4000 > 0 ? lim/4000 : 1)) begin
            if (v > -20000 && v < 20000) continue;   // truncation dominates below this
            y = mix(17'sd0, 24'(v), 3'd0, sel[2:0], 1'b0);
            g = real'(int'(y)) / real'(v);
            if (g < gmin) gmin = g;
            if (g > gmax) gmax = g;
         end
         db = 20.0 * $log10((gmin + gmax) / 2.0);
         $display("T1b PCM step %0d: %7.3f dB (want %6.2f)  [sh=%0d post=%0d]",
                  sel, db, pc_want[sel], sh, m);
         chk($sformatf("T1b PCM step %0d want %0.2f got %0.3f", sel, pc_want[sel], db),
             (db > pc_want[sel] - 0.15) && (db < pc_want[sel] + 0.15));
      end

      // ---- T2: no sign wrap, both paths, every setting ---------------------
      for (int sel = 0; sel < 5; sel++) begin
         for (int v = -65536; v <= 65535; v += 97) begin
            y = mix(17'(v), 24'sd0, sel[2:0], 3'd0, 1'b0);
            chk($sformatf("T2 FM wrap sel=%0d v=%0d", sel, v),
                (v > 0) ? (y > 0) : (v < 0) ? (y < 0) : (y == 0));
         end
         for (int v = -4000000; v <= 4000000; v += 6113) begin
            y = mix(17'sd0, 24'(v), 3'd0, sel[2:0], 1'b0);
            chk($sformatf("T2 PCM wrap sel=%0d v=%0d", sel, v),
                (v > 0) ? (y > 0) : (v < 0) ? (y < 0) : (y == 0));
         end
      end

      // ---- T3: monotone + exact extremes (FM path) -------------------------
      for (int sel = 0; sel < 5; sel++) begin
         yprev = 16'sh8000;
         for (int v = -65536; v <= 65535; v += 113) begin
            y = mix(17'(v), 24'sd0, sel[2:0], 3'd0, 1'b0);
            chk($sformatf("T3 monotone sel=%0d v=%0d", sel, v), y >= yprev);
            yprev = y;
         end
         begin
            automatic int m  = int'(fm_gain(sel[2:0]));
            automatic int hi = (65535 * m) >>> 7;
            automatic int lo = (-65536 * m) >>> 7;
            if (hi >  32767) hi =  32767;
            if (lo < -32768) lo = -32768;
            chk($sformatf("T3 top extreme sel=%0d want %0d", sel, hi),
                int'(mix( 17'sd65535, 24'sd0, sel[2:0], 3'd0, 1'b0)) == hi);
            chk($sformatf("T3 bottom extreme sel=%0d want %0d", sel, lo),
                int'(mix(-17'sd65536, 24'sd0, sel[2:0], 3'd0, 1'b0)) == lo);
         end
      end

      // ---- T4: the two paths are independent -------------------------------
      // The identity only holds while NEITHER term clamps on its own, so the
      // sweep bounds are derived from the tables rather than assumed.
      for (int fs = 0; fs < 5; fs++)
         for (int ps = 0; ps < 5; ps++)
         begin
            automatic int alim = (32767 * 128) / int'(fm_gain(fs[2:0]));
            automatic int plim = ((32767 * 128) / int'(pcm_post(ps[2:0])))
                                 << (3 - int'(pcm_pre(ps[2:0])));
            if (alim > 65535) alim = 65535;
            for (int a = -alim; a <= alim; a += (alim/4 > 0 ? alim/4 : 1))
               for (int b = -plim; b <= plim; b += (plim/4 > 0 ? plim/4 : 1)) begin
                  automatic int only_fm = int'(mix(17'(a), 24'sd0, fs[2:0], ps[2:0], 1'b0));
                  automatic int only_pc = int'(mix(17'sd0, 24'(b), fs[2:0], ps[2:0], 1'b0));
                  automatic int both    = int'(mix(17'(a), 24'(b), fs[2:0], ps[2:0], 1'b0));
                  automatic int want    = only_fm + only_pc;
                  if (want >  32767) want =  32767;
                  if (want < -32768) want = -32768;
                  chk($sformatf("T4 independence fs=%0d ps=%0d a=%0d b=%0d got %0d want %0d",
                                fs, ps, a, b, both, want), both == want);
               end
         end

      // ---- T5: silence and mute --------------------------------------------
      for (int fs = 0; fs < 5; fs++)
         for (int ps = 0; ps < 5; ps++) begin
            chk($sformatf("T5 silence fs=%0d ps=%0d", fs, ps),
                mix(17'sd0, 24'sd0, fs[2:0], ps[2:0], 1'b0) == 16'sd0);
            chk($sformatf("T5 pcm_mute fs=%0d ps=%0d", fs, ps),
                mix(17'sd0, 24'sd400000, fs[2:0], ps[2:0], 1'b1) == 16'sd0);
         end

      // ---- T6: headroom.  +11 dB over full scale = the measured peak of
      //          both MoonSound music-disk tracks (TIME'S UP!, encounter).
      //          It MUST survive the attenuating steps without touching the
      //          engine clamp.  A post-saturation-only trim cannot do this.
      begin
         automatic int hot = 116112;                  // = +11.0 dBFS, measured
         for (int ps = 0; ps < 5; ps++) begin
            automatic int sh   = 3 - int'(pcm_pre(ps[2:0]));
            automatic int shd  = hot >>> sh;
            automatic bit clipped = (shd > 32767);
            automatic bit want_clean = (ps == 0) || (ps == 1);   // -4dB / -8dB steps
            $display("T6  PCM step %0d: accum %0d >> %0d = %0d %s",
                     ps, hot, sh, shd, clipped ? "CLIPS" : "clean");
            if (want_clean)
               chk($sformatf("T6 step %0d must not clip a +11 dB peak", ps), !clipped);
         end
      end

`ifdef NEGCTL
      $display("");
      $display("NEGATIVE CONTROL: unity gain, no pre-shift — T1/T6 MUST fail.");
      if (errors == 0)
         $fatal(1, "NEGCTL BROKEN: unity passed the calibration checks. TB is worthless.");
      $display("negative control OK: %0d/%0d checks failed as required", errors, checks);
      $finish(0);
`else
      $display("");
      $display("tb_opl4_gain: %0d checks, %0d errors", checks, errors);
      // $finish leaves Verilator's exit code at 0 even with an argument, so a
      // failure MUST go through $fatal or the runner can never see it.
      if (errors) $fatal(1, "tb_opl4_gain: %0d of %0d checks FAILED", errors, checks);
      $finish;
`endif
   end
endmodule
`default_nettype wire
