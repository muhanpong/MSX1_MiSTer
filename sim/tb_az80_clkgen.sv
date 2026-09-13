// Does az80_clkgen produce the five Z80 frequencies at 50% duty, and does a
// speed change never emit a short or stretched pulse?
`timescale 1ns/1ps
module tb_az80_clkgen;
   logic clk_sdram = 0;  always #5.8207 clk_sdram = ~clk_sdram;   // 85.909090 MHz
   logic reset = 1;
   logic [2:0] cpu_speed = 3'd0;
   logic       bus_idle  = 1'b1;
   wire        az80_clk;
   wire  [2:0] speed_q;
   az80_clkgen dut (.clk_sdram(clk_sdram), .reset(reset), .cpu_speed(cpu_speed),
                    .cpu_bus_idle(bus_idle), .az80_clk(az80_clk), .cpu_speed_q(speed_q));

   real  expect_mhz [0:4] = '{3.579545, 5.369318, 7.159090, 10.738635, 21.477270};
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
         //  Tolerance, not equality: the bench's clk_sdram period (5.8207 ns)
         //  is a rounding of 1/85.909090, so hi and lo can differ by a tick of
         //  simulation time without the design being asymmetric.
         chk(n_hi > n_lo - n_edge - 1 && n_hi < n_lo + n_edge + 1, "duty is not 50%");
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
      //  /4 is the fastest mode: half period = 2 clk_sdram periods = 23.28 ns.
      //  $time is in timeunits and this bench is `timescale 1ns/1ps, so the
      //  figure below is nanoseconds -- 23, not 23282.
      $display("  shortest half-period seen: %0d ns (floor 23 ns = /4)", min_half);
      chk(min_half >= 23, "a speed change produced a runt clock pulse");

      $display("");
      if (errors == 0) $display("tb_az80_clkgen: PASS");
      else             $display("tb_az80_clkgen: FAIL (%0d errors)", errors);
      $finish(errors ? 1 : 0);
   end
endmodule
