// Does az80_clkgen produce the Z80 frequencies, is every az80_clk edge on a
// clk21m RISING edge (the phase lock the SDC depends on), and does a speed
// change never emit a short or stretched pulse?
`timescale 1ns/1ps
module tb_az80_clkgen;
   logic clk_sdram = 0;  always #5.8207 clk_sdram = ~clk_sdram;   // 85.909090 MHz
   //  clk21m exactly as the PLL makes it: rising on every 4th clk_sdram rising
   //  edge.  A start offset proves the lock is found, not assumed.
   logic [1:0] div4 = 2'd1;  logic clk21m = 0;
   always @(posedge clk_sdram) begin div4 <= div4 + 1'd1; if (div4[0]) clk21m <= ~clk21m; end
   logic reset = 1;
   logic [2:0] cpu_speed = 3'd0;
   logic       bus_idle  = 1'b1;
   wire        az80_clk;
   wire  [2:0] speed_q;
   az80_clkgen dut (.clk_sdram(clk_sdram), .clk21m(clk21m), .reset(reset), .pause(1'b0), .cpu_speed(cpu_speed),
                    .cpu_bus_idle(bus_idle), .az80_clk(az80_clk), .cpu_speed_q(speed_q));

   //  speed 4 now expects the /8 clamp -- 21.5 MHz is T80s, and az80_clkgen must
   //  never emit /4 (the SDC declares this clock at /8).
   real  expect_mhz [0:4] = '{3.579545, 5.369318, 7.159090, 10.738635, 10.738635};
   //  high-phase share: 3+3, 2+2, 2+1, 1+1, 1+1 clk21m periods
   real  expect_duty[0:4] = '{50.0, 50.0, 66.667, 50.0, 50.0};

   //  Phase lock: every az80_clk edge must coincide with a clk21m rise.  Both
   //  change right after a clk_sdram rising edge, so on the NEXT clk_sdram edge
   //  "az80_clk changed" must imply "clk21m just went 0->1".
   //  At clk_sdram edge k the right-hand sides hold values from BEFORE edge k:
   //  az80_clk/clk21m = after edge k-1, az_q/c21_q = after edge k-2.  So
   //  (az_q != az80_clk) means az80_clk changed at edge k-1, and the matching
   //  clk21m rise at edge k-1 is (c21_q == 0 && clk21m == 1).  Offsets are also
   //  histogrammed so a wrong checker cannot pass or fail silently.
   logic az_q = 0, c21_q = 0;  int lock_bad = 0, lock_edges = 0;
   int since_rise = 0;  int off_hist [0:3] = '{0,0,0,0};
   always @(posedge clk_sdram) begin
      az_q <= az80_clk;  c21_q <= clk21m;
      since_rise <= (!c21_q && clk21m) ? 1 : since_rise + 1;
      if (!reset && (az_q != az80_clk)) begin
         lock_edges++;
         off_hist[((!c21_q && clk21m) ? 0 : since_rise) % 4]++;
         if (!(!c21_q && clk21m)) lock_bad++;
      end
   end
   int   errors = 0;
   task chk(input bit c, input string m); if(!c) begin $display("  FAIL: %s", m); errors++; end endtask

   time  t_rise, t_fall, t_prev_rise;
   int   n_hi, n_lo, n_edge;
   real  meas;

   task automatic measure(input [2:0] spd);
      begin
         cpu_speed = spd;
         repeat (200) @(posedge clk_sdram);      // let the divisor latch
         @(posedge az80_clk); t_prev_rise = $time;
         n_hi = 0; n_lo = 0; n_edge = 0;
         for (int i = 0; i < 40; i++) begin
            @(negedge az80_clk); t_fall = $time;
            @(posedge az80_clk); t_rise = $time;
            n_hi += (t_fall - t_prev_rise);
            n_lo += (t_rise - t_fall);
            n_edge++;
            t_prev_rise = t_rise;
         end
         meas = 1000.0 * n_edge / (n_hi + n_lo);   // ns -> MHz
         $display("  spd=%0d  %8.6f MHz (want %8.6f)  duty %5.1f%%",
                  spd, meas, expect_mhz[spd], 100.0*n_hi/(n_hi+n_lo));
         chk(meas > expect_mhz[spd]*0.999 && meas < expect_mhz[spd]*1.001, "frequency off");
         chk((100.0*n_hi/(n_hi+n_lo)) > expect_duty[spd]-0.5 && (100.0*n_hi/(n_hi+n_lo)) < expect_duty[spd]+0.5, "duty off");
      end
   endtask

   //  A speed change must never produce a half-period shorter than the FASTEST
   //  mode in force -- that is the same invariant tb_turbo_clock asserts for the
   //  enable, and here it is what stops the CPU seeing a runt clock pulse.
   time last_edge = 0; int min_half = 1000000; bit watch = 0;
   always @(az80_clk) begin
      if (watch && last_edge != 0 && ($time - last_edge) < min_half)
         min_half = $time - last_edge;
      last_edge = $time;
   end

   initial begin
      repeat (8) @(posedge clk_sdram); reset = 0;
      $display("=== tb_az80_clkgen ===");
      for (int s = 0; s < 5; s++) measure(s[2:0]);

      $display("  fuzzing speed changes...");
      @(posedge az80_clk);          // start from a known edge
      min_half = 1000000; watch = 1;
      for (int i = 0; i < 4000; i++) begin
         @(posedge clk_sdram);
         if ($urandom_range(0,60) == 0) cpu_speed = $urandom_range(0,4);
      end
      //  /8 is now the fastest mode (speed 4 clamps to it): half period =
      //  4 clk_sdram periods = 46.57 ns.  A 23 ns half would mean the clamp
      //  failed and the divider emitted the retired /4.
      //  $time is in timeunits and this bench is `timescale 1ns/1ps, so the
      //  figure below is nanoseconds.
      $display("  shortest half-period seen: %0d ns (floor 46 ns = /8, /4 retired)", min_half);
      chk(min_half >= 46, "runt pulse, or the retired /4 leaked past the clamp");

      $display("  phase lock: %0d az80_clk edges, %0d NOT on a clk21m rise  (clk_sdram offset from rise: 0:%0d 1:%0d 2:%0d 3:%0d)",
               lock_edges, lock_bad, off_hist[0], off_hist[1], off_hist[2], off_hist[3]);
      chk(lock_edges > 100 && lock_bad == 0, "az80_clk edge off the clk21m rising grid");

      $display("");
      if (errors == 0) $display("tb_az80_clkgen: PASS");
      else             $display("tb_az80_clkgen: FAIL (%0d errors)", errors);
      $finish(errors ? 1 : 0);
   end
endmodule
