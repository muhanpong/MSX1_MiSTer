// ---------------------------------------------------------------------------
// tb_turbo_guard - measures the turbo bus guard.
//
// CAVEAT (read this before trusting the numbers): T80pa is VHDL, so neither
// of the free Verilog simulators here can elaborate it, and ghdl is not
// installed on this machine.  `cpu_model` below is therefore a hand translation of T80pa.vhd's
// CEN_pol / TState / strobe machinery (the process at T80pa.vhd:143-210),
// driven by a synthetic M-cycle mix.  It is NOT the real CPU.  What it does
// faithfully reproduce is the only thing this test is about: WHEN the bus
// strobes rise and fall relative to the CEN_p/CEN_n half-cycles, and how the
// WAIT_n-in-TState-2 stall lengthens the window.
//
// The `guard` module below is a VERBATIM copy of the block added to msx.sv.
//
// Measured per run:
//   * min / max length of every bus-transfer window (`req` high), in clk21m
//   * how many windows contained NO ce_3m58_p edge  (= writes a clk_en-gated
//     peripheral would silently drop)
//   * how many windows were shorter than the SDRAM ch2 open-loop deadline
//   * completed M-cycles per 200004 clk21m  (= throughput)
// ---------------------------------------------------------------------------
`timescale 1ns/1ps

// --- verbatim copy of the guard added to rtl/msx.sv -------------------------
// P2 scoping (20260825): `slow_dev` marks an access to a ce_3m58-latched
// device; I/O cycles are slow wholesale.  Slow keeps the stock threshold AND
// the ce_3m58 requirement; fast (plain memory) uses GUARD_RD_FAST and drops
// the ce requirement.
module guard #(parameter int GUARD_RD = 8, parameter int GUARD_WR = 2,
               parameter int GUARD_RD_FAST = 5) (
   input  logic clk21m,
   input  logic reset,
   input  logic ce_3m58_p,
   input  logic cpu_turbo,
   input  logic mreq_n,
   input  logic iorq_n,
   input  logic rd_n,
   input  logic wr_n,
   input  logic slow_dev,
   output logic bus_guard_n
);
   // MUST mirror rtl/msx.sv exactly.  Counting on the core's `req` is what
   // hung the design: `req` is a one-shot (iack), so guard_cnt caps at 1.
   wire bus_cycle = ~(mreq_n & iorq_n);
   wire bus_xfer  = ~((iorq_n & mreq_n) | (wr_n & rd_n));

   logic [3:0] guard_cnt = 4'd0;
   logic       guard_ce  = 1'b0;
   always @(posedge clk21m) begin
      if (reset | ~bus_cycle) begin
         guard_cnt <= 4'd0;
         guard_ce  <= 1'b0;
      end else if (bus_xfer) begin
         if (guard_cnt != 4'hF) guard_cnt <= guard_cnt + 4'd1;
         if (ce_3m58_p)         guard_ce  <= 1'b1;
      end
   end
   wire guard_slow = ~iorq_n | slow_dev;
   wire [3:0] guard_min = wr_n ? (guard_slow ? GUARD_RD[3:0] : GUARD_RD_FAST[3:0])
                               : GUARD_WR[3:0];
   wire guard_open = guard_slow ? (guard_ce & (guard_cnt >= guard_min))
                                :             (guard_cnt >= guard_min);
   assign bus_guard_n = ~cpu_turbo | ~bus_cycle | (mreq_n & rd_n & wr_n) | guard_open;
endmodule

// --- hand translation of T80pa.vhd's phase/T-state/strobe machinery ---------
module cpu_model (
   input  logic clk21m,
   input  logic reset,
   input  logic ce_cpu_p,
   input  logic ce_cpu_n,
   input  logic wait_n,
   output logic mreq_n,
   output logic iorq_n,
   output logic rd_n,
   output logic wr_n,
   output logic slow_acc,      // this M-cycle targets a ce_3m58-latched device
   output int   mcycles_done
);
   // M-cycle kinds
   localparam int K_M1  = 0;   // opcode fetch, 4T + 1 external MSX M1 wait
   localparam int K_RD  = 1;   // memory read,  3T
   localparam int K_WR  = 2;   // memory write, 3T
   localparam int K_IO  = 3;   // I/O,          4T (T80 IOWait=1)
   localparam int K_INT = 4;   // internal,     2T, no bus
   // Interrupt acknowledge: IORQ_n asserted with RD_n and WR_n BOTH HIGH.
   // T80.vhd:1165-1179 holds TState=1 for three ticks (Auto_Wait) and
   // T80pa.vhd:178-182 drops IORQ_n on the third, so IORQ_n is already low at
   // the TState-2 CEN_n edge where WAIT_n is sampled, and T80pa only raises it
   // again on the CEN_p that leaves T2.  A guard armed on bus_cycle but
   // counting on a strobe therefore sees "armed, nothing to count" -> hang.
   // This is the case the previous version of this TB had no stimulus for.
   localparam int K_INTA = 5;

   // A representative Z80 mix: fetch, operand read, memory write, internal,
   // and an occasional I/O port access.
   localparam int SEQLEN = 16;
   int seq [SEQLEN];
   initial begin
      seq = '{K_M1, K_RD, K_INT, K_M1, K_RD, K_WR,  K_M1, K_INTA,
              K_M1, K_RD, K_RD,  K_WR, K_M1, K_IO,  K_M1, K_INT};
   end

   logic       cen_pol = 1'b0;
   int         tstate  = 1;
   int         twait   = 0;      // extra internal T-states already consumed
   int         kind    = K_M1;
   int         seq_i   = 0;
   logic       is_write;

   assign is_write = (kind == K_WR) || (kind == K_IO && seq_i[0]);

   // Two of the memory cycles are "SCC-window" accesses: seq[5] (a write) and
   // seq[9] (a read).  Like the real slow_dev this is a level decode of the
   // M-cycle identity, stable for the whole window.  I/O cycles are slow via
   // ~iorq_n inside the guard, not via this mark.
   localparam bit [SEQLEN-1:0] SLOW_MARK = 16'h0220;
   assign slow_acc = SLOW_MARK[seq_i];

   function automatic int last_t(input int k);
      case (k)
         K_M1  : last_t = 4;
         K_IO  : last_t = 3;
         K_INT : last_t = 2;
         K_INTA: last_t = 4;
         default: last_t = 3;
      endcase
   endfunction

   // number of internal wait T-states this kind inserts at TState 2
   function automatic int int_waits(input int k);
      case (k)
         K_M1  : int_waits = 1;   // MSX external M1 wait (scales with ce_cpu_p)
         K_IO  : int_waits = 1;   // T80 IOWait=1
         K_INTA: int_waits = 2;   // Z80 INTA inserts two automatic wait states
         default: int_waits = 0;
      endcase
   endfunction

   always @(posedge clk21m) begin
      if (reset) begin
         cen_pol <= 1'b0; tstate <= 1; twait <= 0; seq_i <= 0; kind <= seq[0];
         {mreq_n, iorq_n, rd_n, wr_n} <= 4'b1111;
         mcycles_done <= 0;
      end else if (ce_cpu_p && !cen_pol) begin
         cen_pol <= 1'b1;
         // ---- p-phase (T80pa: "elsif CEN_p = '1' and CEN_pol = '0'") -------
         if (kind == K_IO && tstate == 1) begin
            iorq_n <= 1'b0;
            wr_n   <= ~is_write;
            rd_n   <=  is_write;
         end
      end else if (ce_cpu_n && cen_pol) begin
         // ---- n-phase (T80pa: "elsif CEN_n = '1' and CEN_pol = '1'") -------
         if (tstate == 2 && (!wait_n || twait < int_waits(kind))) begin
            // stall in T2: either the external WAIT_n or the core's own wait
            cen_pol <= 1'b1;
            if (wait_n && twait < int_waits(kind)) twait <= twait + 1;
         end else begin
            cen_pol <= 1'b0;
            if (tstate >= last_t(kind)) begin   // >= : gap_t can change mid-M-cycle
               tstate       <= 1;
               twait        <= 0;
               seq_i        <= (seq_i + 1) % SEQLEN;
               kind         <= seq[(seq_i + 1) % SEQLEN];
               mcycles_done <= mcycles_done + 1;
            end else begin
               tstate <= tstate + 1;
            end
         end
         // strobe assignments (unconditional on the n-edge, as in the VHDL)
         if (kind != K_IO && kind != K_INT && kind != K_INTA) begin
            if (tstate == 1) begin
               mreq_n <= 1'b0;
               rd_n   <= is_write;    // read: 0, write: 1
            end
            if (tstate == 2) wr_n <= ~is_write;
            if (tstate == 3) begin
               wr_n <= 1'b1; rd_n <= 1'b1; mreq_n <= (kind != K_M1);
            end
            if (kind == K_M1 && tstate == 4) mreq_n <= 1'b1;
         end
         if (kind == K_IO && tstate == 3) begin
            wr_n <= 1'b1; rd_n <= 1'b1; iorq_n <= 1'b1;
         end
         // INTA: IORQ_n only, and it is still low when WAIT_n is sampled at T2
         if (kind == K_INTA) begin
            if (tstate == 1) iorq_n <= 1'b0;
            if (tstate >= 3) iorq_n <= 1'b1;
         end
      end
   end
endmodule


module tb_turbo_guard;

   localparam int NCYC = 200004;

   logic clk21m = 0;
   logic reset  = 1;
   logic [1:0] cpu_speed = 2'd0;
   logic       guard_on  = 1'b1;
   logic       force_turbo = 1'b0;

   wire ce_10m7_p, ce_10m7_n, ce_5m39_p, ce_5m39_n;
   wire ce_3m58_p, ce_3m58_n, ce_10hz, ce_cpu_p, ce_cpu_n;

   clock u_clock (
      .clk21m(clk21m), .reset(reset),
      .ce_10m7_p(ce_10m7_p), .ce_10m7_n(ce_10m7_n),
      .ce_5m39_p(ce_5m39_p), .ce_5m39_n(ce_5m39_n),
      .ce_3m58_p(ce_3m58_p), .ce_3m58_n(ce_3m58_n),
      .ce_10hz(ce_10hz),
      .cpu_speed(cpu_speed), .cpu_bus_idle(1'b1), .ce_cpu_p(ce_cpu_p), .ce_cpu_n(ce_cpu_n)
   );

   wire mreq_n, iorq_n, rd_n, wr_n;
   int  mcycles;
   wire bus_guard_n;

   // msx.sv:629-642 VERBATIM, iack included.  The previous version of this TB
   // omitted iack "because it only ever extends req" -- the opposite is true,
   // iack TRUNCATES req to one clk21m cycle, and omitting it simulated a guard
   // the RTL does not have.  Windows are still measured on the strobe level.
   logic iack;
   always @(posedge clk21m) begin
      if (reset) iack <= 0;
      else if (iorq_n & mreq_n) iack <= 0;
      else if (req)             iack <= 1;
   end
   wire req   = ~((iorq_n & mreq_n) | (wr_n & rd_n) | iack);
   wire xfer  = ~((iorq_n & mreq_n) | (wr_n & rd_n));   // level, for measurement

   wire cpu_turbo = guard_on & ((|cpu_speed) | force_turbo);

   int  guard_sel = 8;
   // all_slow forces every access onto the slow path = the pre-scoping guard,
   // used as the legacy baseline the scoped configuration must beat.
   logic all_slow = 1'b0;
   wire  cpu_slow_acc;
   wire  slow_sig = all_slow | cpu_slow_acc;
   wire [8:0] guard_n_bank;
   generate
      genvar gi;
      for (gi = 0; gi < 9; gi++) begin : g_bank
         guard #(.GUARD_RD(gi), .GUARD_WR((gi > 6) ? gi - 6 : 0)) u_guard (
            .clk21m(clk21m), .reset(reset), .ce_3m58_p(ce_3m58_p),
            .cpu_turbo(cpu_turbo), .mreq_n(mreq_n), .iorq_n(iorq_n),
            .rd_n(rd_n), .wr_n(wr_n), .slow_dev(slow_sig),
            .bus_guard_n(guard_n_bank[gi])
         );
      end
   endgenerate
   assign bus_guard_n = guard_n_bank[guard_sel];

   cpu_model u_cpu (
      .clk21m(clk21m), .reset(reset),
      .ce_cpu_p(ce_cpu_p), .ce_cpu_n(ce_cpu_n),
      .wait_n(bus_guard_n),
      .mreq_n(mreq_n), .iorq_n(iorq_n), .rd_n(rd_n), .wr_n(wr_n),
      .slow_acc(cpu_slow_acc),
      .mcycles_done(mcycles)
   );

   always #23.28 clk21m = ~clk21m;

   // --- window measurement ---------------------------------------------------
   // slow/fast are tracked separately: the stock-width + ce_3m58 invariants
   // apply only to the SLOW set (I/O + slow_dev); the FAST set must merely
   // keep every READ window at or above the SDRAM ch2 deadline.
   int  win_len, win_ce, win_min, win_max, n_win, n_win_noce, n_win_short, cyc;
   int  win_min_rd, win_min_wr;          // slow set
   int  fast_min_rd, fast_min_wr;        // fast set
   int  n_noce_slow;
   logic win_is_wr, win_is_slow;
   int  m0;
   logic req_d;

   localparam int SDRAM_DEADLINE = 6;   // ~24 clk_sdram at 85.9MHz = 6 clk21m

   task automatic measure(input [1:0] spd, input bit g_on, input string label,
                          input int thr = 8, input bit ftur = 1'b0,
                          input bit aslow = 1'b0);
      begin
         cpu_speed = spd; guard_on = g_on; guard_sel = thr; force_turbo = ftur;
         all_slow = aslow;
         repeat (12) @(posedge clk21m);
         while (u_clock.clkdiv6 !== 3'd5) @(posedge clk21m);
         while (xfer) @(posedge clk21m);     // never count a partial window
         win_len = 0; win_ce = 0; win_min = 9999; win_max = 0;
         n_win = 0; n_win_noce = 0; n_win_short = 0; req_d = 0;
         win_min_rd = 9999; win_min_wr = 9999;
         fast_min_rd = 9999; fast_min_wr = 9999; n_noce_slow = 0;
         m0 = mcycles;
         for (cyc = 0; cyc < NCYC; cyc++) begin
            @(posedge clk21m); #1;
            if (xfer) begin
               if (win_len == 0) begin
                  win_is_wr   = ~wr_n;
                  win_is_slow = slow_sig | ~iorq_n;   // same classification the guard sees
               end
               win_len++;
               if (ce_3m58_p) win_ce++;
            end else if (req_d) begin       // window just closed
               n_win++;
               if (win_len < win_min) win_min = win_len;
               if (win_len > win_max) win_max = win_len;
               if (win_is_slow) begin
                  if ( win_is_wr && win_len < win_min_wr) win_min_wr = win_len;
                  if (!win_is_wr && win_len < win_min_rd) win_min_rd = win_len;
                  if (win_ce == 0) n_noce_slow++;
               end else begin
                  if ( win_is_wr && win_len < fast_min_wr) fast_min_wr = win_len;
                  if (!win_is_wr && win_len < fast_min_rd) fast_min_rd = win_len;
               end
               if (win_ce == 0)                              n_win_noce++;
               if (!win_is_wr && win_len < SDRAM_DEADLINE)   n_win_short++;
               win_len = 0; win_ce = 0;
            end
            req_d = xfer;
         end
         last_mcyc = mcycles - m0;
         $display("  %-26s %5d %5d %5d %5d %5d %6d  %8d %8d %11d",
                  label, win_min_rd, win_min_wr, fast_min_rd, fast_min_wr,
                  win_max, n_win, n_noce_slow, n_win_short, last_mcyc);
      end
   endtask

   int errors = 0;
   int checks = 0;
   int base_mcyc;
   int legacy_mcyc;
   int last_mcyc;

   task automatic chk(input string what, input bit ok);
      begin checks++; if (!ok) begin errors++; $display("  FAIL: %s", what); end end
   endtask

   // Every turbo configuration must satisfy all of these, or it is unsafe:
   //   the CPU must actually run; SLOW windows (I/O + slow_dev) must be no
   //   shorter than the stock 12 (read) / 6 (write) clk21m and must every one
   //   contain a ce_3m58_p (or a clk_en-captured device drops the write); no
   //   READ window — fast or slow — may close before the open-loop SDRAM ch2
   //   deadline; and fast writes must stay wide enough for the ch2 req edge
   //   detector (>=3 clk21m is comfortable against its 1-clk21m floor).
   task automatic assert_safe(input string label);
      begin
         chk($sformatf("%s: CPU is running (not hung)", label), last_mcyc > 0);
         chk($sformatf("%s: slow read window >= 12 (got %0d)",  label, win_min_rd), win_min_rd >= 12);
         chk($sformatf("%s: slow write window >= 6 (got %0d)",  label, win_min_wr), win_min_wr >= 6);
         chk($sformatf("%s: every slow window has a ce_3m58_p (got %0d without)", label, n_noce_slow),
             n_noce_slow == 0);
         chk($sformatf("%s: no read window under the SDRAM deadline (got %0d)", label, n_win_short),
             n_win_short == 0);
         chk($sformatf("%s: fast write window >= 3 (got %0d)", label, fast_min_wr),
             fast_min_wr >= 3);
      end
   endtask
   initial begin
      repeat (4) @(posedge clk21m);
      reset = 0;
      repeat (8) @(posedge clk21m);

      $display("=== tb_turbo_guard === (%0d clk21m cycles per run)", NCYC);
      $display("");
      $display("  sRD/sWR = slow-set (I/O + slow_dev) window minima, fRD/fWR = fast-set.");
      $display("  configuration               sRDm  sWRm  fRDm  fWRm   max windows  noCEslow  rd<%0d  M-cycles/run",
               SDRAM_DEADLINE);
      $display("  ------------------------------------------------------------------------------------------");
      measure(2'd0, 1'b1, "3.58MHz (stock)");
      // Diagnostic row: the guard is NOT inert at 3.58MHz.  A stock read
      // window is 12 clk21m and the guard needs cnt>=8 by the T2 CEN_n edge,
      // where only 6 have elapsed - so it inserts one extra T-state and costs
      // ~17%.  That is precisely why cpu_turbo hard-bypasses it
      // (bus_guard_n = ~cpu_turbo | ...), making turbo OFF bit-identical by
      // construction rather than by the guard happening to be harmless.
      measure(2'd0, 1'b1, "3.58MHz +guard FORCED ON", 8, 1'b1);
      // NEGATIVE CONTROL: with the guard bypassed, turbo must be demonstrably
      // unsafe.  If these pass, the stimulus is not stressing anything and the
      // "guard ON" results below prove nothing.
      measure(2'd3, 1'b0, "10.7MHz  guard OFF");
      chk("negative control: guard OFF at 10.7MHz drops ce_3m58_p windows",
          n_win_noce > 0);
      chk("negative control: guard OFF at 10.7MHz breaks the SDRAM deadline",
          n_win_short > 0);
      measure(2'd1, 1'b0, "5.37MHz  guard OFF", 5);
      chk("negative control: guard OFF at 5.37MHz drops ce_3m58_p windows",
          n_win_noce > 0);
      measure(2'd2, 1'b0, "7.16MHz  guard OFF");
      measure(2'd0, 1'b1, "3.58MHz (stock)");   // re-measure for the baseline
      base_mcyc = last_mcyc;
      chk("stock: CPU is running", base_mcyc > 0);

      // 5.37MHz uses GUARD_RD=5, not 8: at /4 a T-state is 4 clk21m and 8 is
      // first satisfied a whole T-state late, stretching the read window to 16
      // instead of the stock 12 and cutting the gain from 1.24x to 1.09x.
      measure(2'd1, 1'b1, "5.37MHz  guard ON", 5);
      assert_safe("5.37MHz");
      chk($sformatf("5.37MHz is faster than stock (%0d vs %0d)", last_mcyc, base_mcyc),
          last_mcyc > base_mcyc);
      chk($sformatf("5.37MHz reaches at least 1.2x (got %0d vs %0d)", last_mcyc, base_mcyc),
          last_mcyc * 10 >= base_mcyc * 12);

      measure(2'd2, 1'b1, "7.16MHz  guard ON");
      assert_safe("7.16MHz");
      chk($sformatf("7.16MHz is faster than stock (%0d vs %0d)", last_mcyc, base_mcyc),
          last_mcyc > base_mcyc);

      measure(2'd3, 1'b1, "10.7MHz  guard ON");
      assert_safe("10.7MHz");
      chk($sformatf("10.7MHz is faster than stock"), last_mcyc > base_mcyc);

      // --- P2 scoping: legacy (everything slow) vs scoped, same speed --------
      measure(2'd3, 1'b1, "10.7MHz  legacy all-slow", 8, 1'b0, 1'b1);
      assert_safe("10.7MHz legacy");
      legacy_mcyc = last_mcyc;
      measure(2'd3, 1'b1, "10.7MHz  scoped (P2)");
      assert_safe("10.7MHz scoped");
      chk($sformatf("scoped 10.7MHz beats legacy all-slow (%0d vs %0d)",
                    last_mcyc, legacy_mcyc), last_mcyc > legacy_mcyc);
      chk($sformatf("scoped 10.7MHz reaches at least 1.9x stock (%0d vs %0d)",
                    last_mcyc, base_mcyc), last_mcyc * 10 >= base_mcyc * 19);
      $display("");
      $display("  GUARD_RD sweep at 10.7MHz (x3), GUARD_WR = max(GUARD_RD-6,0):");
      $display("  configuration               sRDm  sWRm  fRDm  fWRm   max windows  noCEslow  rd<%0d  M-cycles/run",
               SDRAM_DEADLINE);
      $display("  ------------------------------------------------------------------------------------------");
      for (int t = 0; t <= 8; t++) begin
         measure(2'd3, 1'b1, $sformatf("10.7MHz  GUARD_RD=%0d", t), t);
      end
      $display("");
      $display("  (GUARD_RD sweep is diagnostic only - not asserted)");
      $display("");
      $display("tb_turbo_guard: %0d checks, %0d errors", checks, errors);
      // $finish's argument is display VERBOSITY per IEEE 1800, NOT an exit code --
      // the simulator exits 0 from any $finish, so the old `$finish(errors?1:0)`
      // could never fail the run_turbo.sh gate.  $fatal is the call that
      // produces a nonzero process exit status.
      if (errors) $fatal(1, "TB failed with %0d errors", errors);
      $finish;
   end

endmodule
