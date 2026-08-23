// tb_audio_trim — per-source audio trim table and its saturation
//
// Guards two things the ear cannot check quickly:
//   1. entry 0 is EXACTLY unity.  x128>>>7 is exact, so an untouched menu must be
//      bit-identical to the pre-trim core -- if this drifts, every existing
//      recording and the sccplus golden comparison silently change meaning.
//   2. the sum saturates instead of wrapping.  The old one-line 16-bit
//      `sound_opll + scc_wave + sound_psg` could wrap when three loud sources
//      coincided; scaling makes that more reachable, so the wide sum must clip.
//
// Negative control (NEGCTL=1) replaces the clamp with a plain truncation, which
// is what the code did before; the saturation checks MUST then fail.
`timescale 1ns/1ps
`default_nettype none

module tb_audio_trim;
   int errors = 0, checks = 0;

   function automatic signed [9:0] vol_mul(input [1:0] v);
      case (v)
         2'd0: vol_mul = 10'sd128;
         2'd1: vol_mul = 10'sd203;
         2'd2: vol_mul = 10'sd81;
         default: vol_mul = 10'sd51;
      endcase
   endfunction

   // mirrors msx_slots.sv
   function automatic signed [15:0] mix(input signed [15:0] opll,
                                        input signed [15:0] scc,
                                        input signed [15:0] psg,
                                        input [1:0] ov, input [1:0] sv);
      logic signed [24:0] a, b;
      logic signed [18:0] sum;
      begin
         a = $signed(opll) * vol_mul(ov);
         b = $signed(scc)  * vol_mul(sv);
         sum = 19'($signed(a) >>> 7) + 19'($signed(b) >>> 7) + 19'(psg);
`ifdef NEGCTL
         mix = 16'(sum);                                   // old wrapping behaviour
`else
         mix = (sum > 19'sd32767)  ? 16'sh7FFF :
               (sum < -19'sd32768) ? 16'sh8000 : 16'(sum);
`endif
      end
   endfunction

   task automatic chk(input string n, input bit c);
      begin checks++; if (!c) begin errors++; $display("FAIL: %s", n); end end
   endtask

   int i; logic signed [15:0] v;
   initial begin
      // ---- unity: entry 0 must be bit-exact over the whole range -------------
      for (i = -32768; i <= 32767; i += 7) begin
         v = 16'(i);
         chk("unity opll", mix(v, 16'sd0, 16'sd0, 2'd0, 2'd0) === v);
         chk("unity scc",  mix(16'sd0, v, 16'sd0, 2'd0, 2'd0) === v);
         chk("unity psg",  mix(16'sd0, 16'sd0, v, 2'd0, 2'd0) === v);
      end

      // ---- silence stays silence at every setting ----------------------------
      for (i = 0; i < 4; i++)
         chk("silence", mix(16'sd0, 16'sd0, 16'sd0, 2'(i), 2'(i)) === 16'sd0);

      // ---- saturation, not wrap ---------------------------------------------
      chk("positive clip", mix(16'sh7FFF, 16'sh7FFF, 16'sh7FFF, 2'd1, 2'd1) === 16'sh7FFF);
      chk("negative clip", mix(16'sh8000, 16'sh8000, 16'sh8000, 2'd1, 2'd1) === 16'sh8000);
      chk("three loud sources at unity still clip",
          mix(16'sh7000, 16'sh7000, 16'sh7000, 2'd0, 2'd0) === 16'sh7FFF);

      // ---- attenuation actually attenuates, boost boosts ---------------------
      chk("-4dB < 0dB", mix(16'sd10000, 16'sd0, 16'sd0, 2'd2, 2'd0)
                      <  mix(16'sd10000, 16'sd0, 16'sd0, 2'd0, 2'd0));
      chk("-8dB < -4dB", mix(16'sd10000, 16'sd0, 16'sd0, 2'd3, 2'd0)
                       <  mix(16'sd10000, 16'sd0, 16'sd0, 2'd2, 2'd0));
      chk("+4dB > 0dB", mix(16'sd10000, 16'sd0, 16'sd0, 2'd1, 2'd0)
                      >  mix(16'sd10000, 16'sd0, 16'sd0, 2'd0, 2'd0));

      $display("");
      $display("tb_audio_trim: %0d checks, %0d errors", checks, errors);
`ifdef NEGCTL
      if (errors == 0) $fatal(1, "NEGCTL BROKEN: clamp removed and nothing failed.");
      $display("negative control OK: %0d failed as required", errors); $finish;
`else
      if (errors) $fatal(1, "tb_audio_trim: %0d of %0d FAILED", errors, checks);
      $finish;
`endif
   end
endmodule
`default_nettype wire
