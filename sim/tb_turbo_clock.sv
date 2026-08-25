// ---------------------------------------------------------------------------
// tb_turbo_clock - verifies the modified rtl/peripheral/clock.sv
//
//  A. cpu_speed==0 : ce_cpu_p/n are BIT-IDENTICAL to ce_3m58_p/n, every cycle.
//  B. ce_3m58_p/n are unchanged by cpu_speed (PSG / SCC / OPLL pitch invariant).
//  C. ce_cpu_p rate == 1x / 2x / 3x of ce_3m58_p, exactly.
//  D. ce_3m58_p is a strict subset of ce_cpu_p.  (NOT claimed for _n: with the
//     x2 decode p@{5,2} the 3.58MHz n-phase at clkdiv6==2 is a turbo p-phase.
//     Nothing depends on an _n subset - what matters is that ce_3m58_n itself
//     is untouched, which check B proves.)
//  E. ce_cpu_p and ce_cpu_n strictly alternate at all times, including across
//     randomised mid-stream mode switches (glitch-free switching).
// ---------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_turbo_clock;

   localparam int NCYC = 200004;   // multiple of 6 so whole clkdiv6 periods are counted

   logic clk21m = 0;
   logic reset  = 1;
   logic [1:0] cpu_speed = 2'd0;
   wire  [1:0] speed_q_tb;      // clock.sv's LATCHED speed

   wire ce_10m7_p, ce_10m7_n, ce_5m39_p, ce_5m39_n;
   wire ce_3m58_p, ce_3m58_n, ce_10hz;
   wire ce_cpu_p,  ce_cpu_n;

   clock dut (
      .clk21m(clk21m), .reset(reset),
      .ce_10m7_p(ce_10m7_p), .ce_10m7_n(ce_10m7_n),
      .ce_5m39_p(ce_5m39_p), .ce_5m39_n(ce_5m39_n),
      .ce_3m58_p(ce_3m58_p), .ce_3m58_n(ce_3m58_n),
      .ce_10hz(ce_10hz),
      .cpu_speed(cpu_speed), .cpu_bus_idle(1'b1), .cpu_speed_q(speed_q_tb), .ce_cpu_p(ce_cpu_p), .ce_cpu_n(ce_cpu_n)
   );

   always #23.28 clk21m = ~clk21m;   // 21.47727 MHz

   int errors = 0;
   int n_3p, n_3n, n_cp, n_cn;
   // reference capture of the 3.58MHz train, taken during the cpu_speed==0 run
   bit ref_3p [NCYC];
   bit ref_3n [NCYC];
   int          cyc;
   bit          have_ref = 0;

   // last ce_cpu edge seen: 0 = none yet, 1 = p, 2 = n
   int last_edge = 0;

   task automatic chk(input bit cond, input string msg);
      if (!cond) begin
         errors++;
         if (errors < 30) $display("  FAIL @cyc %0d: %s", cyc, msg);
      end
   endtask

   // Run NCYC clocks at a fixed speed, collecting statistics.
   task automatic run_fixed(input [1:0] spd, input bit record_ref);
      begin
         n_3p = 0; n_3n = 0; n_cp = 0; n_cn = 0; last_edge = 0;
         cpu_speed = spd;
         // let the mode latch take effect, then align every run to the same
         // clkdiv6 phase so the recorded reference trace lines up cycle-exactly
         repeat (12) @(posedge clk21m);
         while (dut.clkdiv6 !== 3'd5) @(posedge clk21m);
         for (cyc = 0; cyc < NCYC; cyc++) begin
            @(posedge clk21m);
            #1;
            if (ce_3m58_p) n_3p++;
            if (ce_3m58_n) n_3n++;
            if (ce_cpu_p)  n_cp++;
            if (ce_cpu_n)  n_cn++;

            // A: identity when turbo off
            if (spd == 2'd0) begin
               chk(ce_cpu_p === ce_3m58_p, "ce_cpu_p != ce_3m58_p at speed 0");
               chk(ce_cpu_n === ce_3m58_n, "ce_cpu_n != ce_3m58_n at speed 0");
            end
            // D: subset -- holds only where the period divides evenly into 6.
            // At /4 (speed 1) a 3.58MHz p-phase can fall on a /4 n-phase, so the
            // relation is FALSE there by construction.  Nothing in the core
            // depends on it: what the bus guard actually needs is a ce_3m58_p
            // somewhere INSIDE each transfer window, which tb_turbo_guard
            // measures directly (no-CE-hit must be 0).  Asserting the subset at
            // /4 would be asserting a property the design never had.
            if (spd != 2'd1)
               chk(!ce_3m58_p || ce_cpu_p, "ce_3m58_p not a subset of ce_cpu_p");
            // never both in the same cycle
            chk(!(ce_cpu_p && ce_cpu_n), "ce_cpu_p and ce_cpu_n asserted together");
            // E: alternation
            if (ce_cpu_p) begin
               chk(last_edge != 1, "two ce_cpu_p pulses without an ce_cpu_n between");
               last_edge = 1;
            end
            if (ce_cpu_n) begin
               chk(last_edge != 2, "two ce_cpu_n pulses without an ce_cpu_p between");
               last_edge = 2;
            end
            // B: reference comparison of the audio train
            if (record_ref) begin
               ref_3p[cyc] = ce_3m58_p;
               ref_3n[cyc] = ce_3m58_n;
            end else if (have_ref) begin
               chk(ref_3p[cyc] === ce_3m58_p, "ce_3m58_p phase moved with cpu_speed");
               chk(ref_3n[cyc] === ce_3m58_n, "ce_3m58_n phase moved with cpu_speed");
            end
         end
         if (record_ref) have_ref = 1;
      end
   endtask

   real f3, fc;
   initial begin
      repeat (4) @(posedge clk21m);
      reset = 0;
      repeat (4) @(posedge clk21m);

      $display("=== tb_turbo_clock ===");
      $display("cycles per run: %0d  (clk21m = 21.47727 MHz)", NCYC);
      $display("");
      $display(" spd   ce_3m58_p   ce_3m58_n    ce_cpu_p    ce_cpu_n   f(3m58)MHz   f(cpu)MHz  ratio");

      for (int spd = 0; spd < 4; spd++) begin
         run_fixed(spd[1:0], spd == 0);
         f3 = 21.47727 * n_3p / NCYC;
         fc = 21.47727 * n_cp / NCYC;
         $display("  %0d   %9d   %9d   %9d   %9d   %10.6f  %10.6f   %4.2f",
                  spd, n_3p, n_3n, n_cp, n_cn, f3, fc, real'(n_cp)/real'(n_3p));
         chk(n_cp == n_cn, "ce_cpu_p count != ce_cpu_n count");
         chk(n_3p == n_3n, "ce_3m58_p count != ce_3m58_n count");
         // encoding: 0 = /6 3.58, 1 = /4 5.37 (Panasonic), 2 = /3 7.16, 3 = /2 10.74
         // /4 is 1.5x, so the count is 3*n_3p/2 -- assert it as 2*n_cp == 3*n_3p
         // to keep it an exact integer relation rather than a rounded ratio.
         if (spd == 0) chk(n_cp == n_3p,         "speed 0 must be 1x (3.58MHz)");
         if (spd == 1) chk(2 * n_cp == 3 * n_3p, "speed 1 must be exactly 1.5x (5.37MHz)");
         if (spd == 2) chk(n_cp == 2 * n_3p,     "speed 2 must be exactly 2x (7.16MHz)");
         if (spd == 3) chk(n_cp == 3 * n_3p,     "speed 3 must be exactly 3x (10.74MHz)");
      end

      // E (fuzz): random mode switches at random cycles, alternation must hold
      $display("");
      $display("fuzzing mode switches (100000 cycles, random speed every 1..40 cycles)...");
      begin
         int next_switch = 0;
         last_edge = 0;
         while (dut.clkdiv6 !== 3'd5) @(posedge clk21m);
         for (cyc = 0; cyc < 100000; cyc++) begin
            if (cyc >= next_switch) begin
               cpu_speed    = $urandom_range(0, 3);
               next_switch  = cyc + 1 + $urandom_range(0, 39);
            end
            @(posedge clk21m);
            #1;
            chk(!(ce_cpu_p && ce_cpu_n), "fuzz: p and n together");
            // subset does not hold at /4 -- see the note at check D above.  The
            // fuzz loop randomises the speed, so the property is only checked
            // when the LATCHED speed is not /4.
            if (speed_q_tb != 2'd1)
               chk(!ce_3m58_p || ce_cpu_p,  "fuzz: 3m58_p not subset");
            if (ce_cpu_p) begin
               chk(last_edge != 1, "fuzz: two p pulses in a row (phase glitch)");
               last_edge = 1;
            end
            if (ce_cpu_n) begin
               chk(last_edge != 2, "fuzz: two n pulses in a row (phase glitch)");
               last_edge = 2;
            end
         end
      end

      $display("");
      if (errors == 0) $display("tb_turbo_clock: PASS (0 errors)");
      else             $display("tb_turbo_clock: FAIL (%0d errors)", errors);
      // $finish's argument is display VERBOSITY per IEEE 1800, NOT an exit code --
      // the simulator exits 0 from any $finish, so the old `$finish(errors?1:0)`
      // could never fail the run_turbo.sh gate.  $fatal is the call that
      // produces a nonzero process exit status.
      if (errors) $fatal(1, "TB failed with %0d errors", errors);
      $finish;
   end

endmodule
