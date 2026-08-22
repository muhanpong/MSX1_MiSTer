// tb_ms_trim — MoonSound +3 dB output trim (ymf278b_top stage 2)
//
// Replicates the exact stage-2 expressions from
// rtl/peripheral/SOUND/ymf278b_fpga/rtl/ymf278b_top.sv and checks:
//   T1  gain on the linear region is +3 dB within 0.05 dB
//   T2  no wrap: the result never changes sign vs the input
//   T3  saturation is monotone and clamps to exactly +32767 / -32768
//   T4  the pre-existing full-scale points still map to full scale
//
// Negative control (+define+NEGCTL): the trim multiplier is forced to unity
// (128/128).  T1 MUST then fail — a TB that passes either way proves nothing.
`timescale 1ns/1ps
`default_nettype none

module tb_ms_trim;

`ifdef NEGCTL
   localparam signed [8:0] MS_TRIM_MUL = 9'sd128;   // negative control: x1.0
`else
   localparam signed [8:0] MS_TRIM_MUL = 9'sd181;   // shipped: x1.41406 = +3.009 dB
`endif
   localparam int          MS_TRIM_SH  = 7;

   int errors = 0;
   int checks = 0;

   task automatic chk(input string what, input bit ok);
      checks++;
      if (!ok) begin errors++; $display("FAIL: %s", what); end
   endtask

   // --- the DUT expressions, copied verbatim from ymf278b_top.sv stage 2 ---
   function automatic signed [15:0] trim(input signed [16:0] q);
      logic signed [25:0] mul;
      logic signed [17:0] sh;
      begin
         mul  = $signed(q) * MS_TRIM_MUL;
         sh   = 18'(mul >>> MS_TRIM_SH);
         trim = (sh >  18'sd32767) ? 16'sh7FFF :
                (sh < -18'sd32768) ? 16'sh8000 : sh[15:0];
      end
   endfunction

   real  gmin, gmax, g, db;
   int   lin_lo, lin_hi;
   logic signed [16:0] x;
   logic signed [15:0] y, yprev;

   initial begin
      // ---- T1: gain over the region that cannot clip -------------------
      // |x| * MUL/128 <= 32767  ->  |x| <= 23172 for MUL=181.
      // Measure the ratio only where truncation is negligible (|v| >= 1000,
      // so one LSB is < 0.1%); the exactness of small values is covered by
      // the per-sample floor() check below, which holds for every v.
      lin_lo = -23172; lin_hi = 23172;
      gmin = 1.0e9; gmax = -1.0e9;
      for (int v = lin_lo; v <= lin_hi; v += 7) begin
         if (v == 0) continue;
         x = 17'(v);
         y = trim(x);
         if (v <= -1000 || v >= 1000) begin
            g = real'(int'(y)) / real'(v);
            if (g < gmin) gmin = g;
            if (g > gmax) gmax = g;
         end
         // >>> truncates toward -inf: the result is exactly floor(v*MUL/128)
         chk($sformatf("T1 exact floor v=%0d y=%0d", v, y),
             int'(y) == ((v * int'(MS_TRIM_MUL)) >>> MS_TRIM_SH));
      end
      db = 20.0 * $log10((gmin + gmax) / 2.0);
      $display("T1  measured gain %0.5f .. %0.5f  -> %0.4f dB", gmin, gmax, db);
      chk($sformatf("T1 gain is +3 dB (got %0.4f dB)", db), (db > 2.95) && (db < 3.05));

      // ---- T2: no sign wrap anywhere across the full 17-bit input ------
      for (int v = -65536; v <= 65535; v += 3) begin
         x = 17'(v);
         y = trim(x);
         chk($sformatf("T2 sign wrap v=%0d y=%0d", v, y),
             (v > 0) ? (y > 0) : (v < 0) ? (y < 0) : (y == 0));
      end

      // ---- T3: monotone, and the clamps hit their exact endpoints ------
      yprev = 16'sh8000;
      for (int v = -65536; v <= 65535; v += 11) begin
         x = 17'(v);
         y = trim(x);
         chk($sformatf("T3 monotone v=%0d", v), y >= yprev);
         yprev = y;
      end
      chk("T3 clamp high", trim(17'sd65535)  == 16'sh7FFF);
      chk("T3 clamp low",  trim(-17'sd65536) == 16'sh8000);
      chk("T3 zero",       trim(17'sd0)      == 16'sd0);

      // ---- T4: previously full-scale input stays full scale ------------
      chk("T4 +FS in -> +FS out", trim(17'sd32767)  == 16'sh7FFF);
      chk("T4 -FS in -> -FS out", trim(-17'sd32768) == 16'sh8000);
      // clip onset: floor(23172*181/128) = 32766 (no clamp),
      //             floor(23173*181/128) = 32768 -> clamped to 32767
      chk($sformatf("T4 clip onset last-linear (got %0d)", trim(17'sd23172)),
          trim(17'sd23172) == 16'sd32766);
      chk($sformatf("T4 clip onset first-clamp (got %0d)", trim(17'sd23173)),
          trim(17'sd23173) == 16'sh7FFF);

`ifdef NEGCTL
      $display("");
      $display("NEGATIVE CONTROL: trim forced to x1.0 — T1 MUST fail above.");
      if (errors == 0) begin
         $display("NEGCTL BROKEN: unity gain passed the +3 dB check. TB is worthless.");
         $finish(1);
      end
      $display("negative control OK: %0d/%0d checks failed as required", errors, checks);
      $finish(0);
`else
      $display("");
      $display("tb_ms_trim: %0d checks, %0d errors", checks, errors);
      if (errors) $finish(1);
      $finish(0);
`endif
   end

endmodule
`default_nettype wire
