// ---------------------------------------------------------------------------
// tb_turbo_slowdev - end-to-end proof that NO CPU register write to a
// 3.58MHz-domain device is lost in turbo.
//
// The CPU issues a back-to-back stream of writes with a unique, incrementing
// data byte each time.  Two device models sit on the bus, each reproducing the
// capture style actually found in this core's RTL:
//
//   dev_level : `always @(posedge clk) if (ce) if (wr & cs) reg <= data;`
//               = IKASCC_player_s.v:511 (freq), :614 (vol), :595 (mute),
//                 which are level-decoded from i_WRRQ and sampled at
//                 !mclkpcen_n.  Also the shape of opll's .cen consumers.
//               FAILS if a write window contains no clock-enable edge.
//
//   dev_edge  : old_wr/old_rd sampled under `if(ce)`, write committed on the
//               old_wr && !wre falling edge = wd1793.sv:271-387 (the FDC).
//               FAILS if a window contains no enable edge, AND ALSO if two
//               consecutive windows are not separated by an enable edge with
//               the strobe idle - it then merges them and loses one write.
//
// Each device is instantiated twice: once fed ce_3m58_p (what the stock core
// does) and once fed ce_cpu_p (what the modified core does for the FDC).
//
// Scored per run: writes issued, writes committed, out-of-order/duplicate
// commits, and LOST writes.  A lost write is a corrupted SCC register or a
// corrupted sector on the user's disk image.
//
// Same caveat as tb_turbo_guard: T80pa is VHDL and cannot be elaborated here,
// so `cpu_model` is a hand translation of its CEN_pol / TState / strobe
// process.  The guard is a verbatim copy of the block in rtl/msx.sv.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps

module guard_s (
   input  logic clk21m, reset, ce_3m58_p, cpu_turbo, mreq_n, iorq_n, rd_n, wr_n,
   input  logic slow_dev,
   output logic bus_guard_n
);
   localparam int GUARD_RD      = 8;
   localparam int GUARD_WR      = 2;
   localparam int GUARD_RD_FAST = 5;

   // Must mirror rtl/msx.sv: count on the strobe LEVEL, never on the core's
   // `req` one-shot, and stay transparent on an interrupt-acknowledge cycle.
   // P2 scoping (20260825): the stock threshold + ce_3m58 requirement apply
   // only to I/O and slow_dev accesses; plain memory runs at the fast floor.
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


// --- level capture: IKASCC / opll style ------------------------------------
// The CPU writes a value that increments by exactly 1 per issued write, so a
// correct device observes the sequence ..., v, v+1, v+2, ...  Any jump larger
// than 1 is a LOST write; a repeat of the same value is a harmless duplicate
// (the window spanned two enable edges - same address, same data, idempotent).
// Checking the SEQUENCE rather than a count removes every measurement-window
// artifact and, unlike a count, cannot be satisfied by coincidence.
module dev_level (
   input  logic clk21m, reset, ce, cs, wr,
   input  logic [7:0] din,
   output int   n_commit,
   output int   n_dup,
   output int   n_lost
);
   logic [7:0] prev;
   logic       started;
   always @(posedge clk21m) begin
      if (reset) begin
         n_commit <= 0; n_dup <= 0; n_lost <= 0; started <= 1'b0;
      end else if (ce && cs && wr) begin
         if (!started) begin
            started <= 1'b1; prev <= din; n_commit <= n_commit + 1;
         end else if (din == prev) begin
            n_dup <= n_dup + 1;
         end else begin
            n_commit <= n_commit + 1;
            n_lost   <= n_lost + ((din - prev - 8'd1) & 8'hFF);
            prev     <= din;
         end
      end
   end
endmodule


// --- edge capture: wd1793 style --------------------------------------------
// latch on the rising edge of (cs & wr), commit on the falling edge - both
// observed only at `ce` (wd1793.sv:271-387).
module dev_edge (
   input  logic clk21m, reset, ce, cs, wr,
   input  logic [7:0] din,
   output int   n_commit,
   output int   n_lost
);
   logic       old_wre;
   logic [7:0] latched, prev;
   logic       started;
   wire        wre = cs & wr;
   always @(posedge clk21m) begin
      if (reset) begin
         n_commit <= 0; n_lost <= 0; old_wre <= 1'b0; started <= 1'b0;
      end else if (ce) begin
         old_wre <= wre;
         if (!old_wre &&  wre) latched <= din;
         if ( old_wre && !wre) begin
            n_commit <= n_commit + 1;
            if (!started) begin started <= 1'b1; prev <= latched; end
            else begin
               n_lost <= n_lost + ((latched - prev - 8'd1) & 8'hFF);
               prev   <= latched;
            end
         end
      end
   end
endmodule


// --- OPLL: single temp latch + slot-rotation commit --------------------------
// IKAOPLL_reg.v (and the real YM2413) take a CPU write into ONE temporary
// latch; the commit happens when the internal 18-slot rotation (72 XIN cycles)
// reaches the target register.  A second write before the commit clobbers the
// latch = a lost register write.  Address-register commits are fast (a few
// XIN); data commits take up to a full rotation.
module dev_opll (
   input  logic clk21m, reset, ce, wr, a0,
   output int   n_commit,
   output int   n_lost
);
   logic wr_d;
   logic addr_pend, data_pend;
   int   rot;
   always @(posedge clk21m) begin
      if (reset) begin
         n_commit <= 0; n_lost <= 0; wr_d <= 1'b0;
         addr_pend <= 1'b0; data_pend <= 1'b0; rot <= 0;
      end else begin
         if (ce) begin
            rot <= (rot == 71) ? 0 : rot + 1;
            if (addr_pend && (rot % 4) == 3) begin addr_pend <= 1'b0; n_commit <= n_commit + 1; end
            else if (data_pend && rot == 71) begin data_pend <= 1'b0; n_commit <= n_commit + 1; end
         end
         wr_d <= wr;
         if (wr & ~wr_d) begin
            if (addr_pend | data_pend) n_lost <= n_lost + 1;   // latch clobbered
            addr_pend <= ~a0;
            data_pend <=  a0;
         end
      end
   end
endmodule


// --- verbatim mirror of the TURBO OPLL PACER in msx_slots.sv -----------------
module opll_pacer_s (
   input  logic clk21m, reset, ce_3m58_p, cpu_turbo,
   input  logic win,       // OPLL-bound write window (level)
   input  logic a0_in,
   output logic wr_gate,   // AND into the chip's write strobe
   output logic pace_n     // AND into wait_n
);
   localparam [9:0] GAP_ADDR = 10'd72;    // 12 XIN * 6 clk21m
   localparam [9:0] GAP_DATA = 10'd504;   // 84 XIN * 6 clk21m
   logic [9:0] gap = '0;
   logic grant = 1'b0, done = 1'b0, a0 = 1'b0;
   wire  wr_chip = win & wr_gate;
   always @(posedge clk21m) begin
      if (reset) begin
         gap <= '0; grant <= 1'b0; done <= 1'b0;
      end else if (~win) begin
         if (grant & done) gap <= a0 ? GAP_DATA : GAP_ADDR;
         else if (|gap)    gap <= gap - 1'd1;
         grant <= 1'b0; done <= 1'b0;
      end else begin
         if (~grant) begin
            if (~|gap) begin grant <= 1'b1; a0 <= a0_in; end
            else gap <= gap - 1'd1;
         end else if (ce_3m58_p & wr_chip) done <= 1'b1;
      end
   end
   assign wr_gate = ~cpu_turbo | grant;
   assign pace_n  = ~(cpu_turbo & win & ~(grant & done));
endmodule


// --- T80pa phase / T-state / strobe model, emitting a write stream ---------
module cpu_model_wr (
   input  logic clk21m, reset, ce_cpu_p, ce_cpu_n, wait_n,
   input  int   pattern,          // 0 = LD (HL),A loop (M1+WR), 1 = pure WR,WR
   input  int   gap_t,            // pattern 2: this many internal T-states between writes
   output logic mreq_n, iorq_n, rd_n, wr_n,
   output logic [7:0] wdata,
   output int   n_issued
);
   localparam int K_M1 = 0, K_WR = 2, K_INT = 4;

   logic cen_pol = 1'b0;
   int   tstate  = 1;
   int   twait   = 0;
   int   kind    = K_M1;
   logic is_write;

   assign is_write = (kind == K_WR);

   function automatic int last_t(input int k);
      if      (k == K_M1)  last_t = 4;
      else if (k == K_INT) last_t = (gap_t < 1) ? 1 : gap_t;
      else                 last_t = 3;
   endfunction
   function automatic int int_waits(input int k);
      int_waits = (k == K_M1) ? 1 : 0;
   endfunction

   always @(posedge clk21m) begin
      if (reset) begin
         cen_pol <= 0; tstate <= 1; twait <= 0;
         kind <= (pattern == 0) ? K_M1 : K_WR;
         {mreq_n, iorq_n, rd_n, wr_n} <= 4'b1111;
         wdata <= 8'd0; n_issued <= 0;
      end else if (ce_cpu_p && !cen_pol) begin
         cen_pol <= 1'b1;
      end else if (ce_cpu_n && cen_pol) begin
         if (tstate == 2 && (!wait_n || twait < int_waits(kind))) begin
            cen_pol <= 1'b1;
            if (wait_n && twait < int_waits(kind)) twait <= twait + 1;
         end else begin
            cen_pol <= 1'b0;
            if (tstate >= last_t(kind)) begin   // >= : gap_t can change mid-M-cycle
               tstate <= 1; twait <= 0;
               if (kind == K_WR) begin
                  n_issued <= n_issued + 1;
                  wdata    <= wdata + 8'd1;   // next write gets a new value
                  kind     <= (pattern == 0) ? K_M1 :
                              (pattern == 1) ? K_WR : K_INT;
               end else begin
                  kind <= K_WR;
               end
            end else tstate <= tstate + 1;
         end
         // strobes, as in T80pa for a non-M1 / M1 memory cycle.  K_INT is a
         // no-bus internal M-cycle and drives no strobe at all.
         if (kind != K_INT) begin
            if (tstate == 1) begin mreq_n <= 1'b0; rd_n <= is_write; end
            if (tstate == 2) wr_n <= ~is_write;
            if (tstate == 3) begin
               wr_n <= 1'b1; rd_n <= 1'b1; mreq_n <= (kind != K_M1);
            end
            if (kind == K_M1 && tstate == 4) mreq_n <= 1'b1;
         end
      end
   end
endmodule


module tb_turbo_slowdev;

   localparam int NCYC = 400008;

   logic clk21m = 0, reset = 1;
   logic [1:0] cpu_speed = 2'd0;
   int         pattern   = 0;
   int         gap_t     = 1;

   wire ce_10m7_p, ce_10m7_n, ce_5m39_p, ce_5m39_n;
   wire ce_3m58_p, ce_3m58_n, ce_10hz, ce_cpu_p, ce_cpu_n;

   clock u_clock (
      .clk21m(clk21m), .reset(reset),
      .ce_10m7_p(ce_10m7_p), .ce_10m7_n(ce_10m7_n),
      .ce_5m39_p(ce_5m39_p), .ce_5m39_n(ce_5m39_n),
      .ce_3m58_p(ce_3m58_p), .ce_3m58_n(ce_3m58_n), .ce_10hz(ce_10hz),
      .cpu_speed(cpu_speed), .cpu_bus_idle(1'b1), .ce_cpu_p(ce_cpu_p), .ce_cpu_n(ce_cpu_n)
   );

   wire mreq_n, iorq_n, rd_n, wr_n, bus_guard_n;
   wire [7:0] wdata;
   int  issued;
   logic guard_on = 1'b1;

   wire cpu_turbo = guard_on & (|cpu_speed);

   // dev_slow models the msx_slots slow_dev decode: 1 = the device windows are
   // classified onto the slow path (the shipped configuration), 0 = they are
   // misclassified fast (negative control: the SCC-style device must then
   // demonstrably lose writes, proving the classification is load-bearing).
   logic dev_slow = 1'b1;
   guard_s u_guard (
      .clk21m(clk21m), .reset(reset), .ce_3m58_p(ce_3m58_p),
      .cpu_turbo(cpu_turbo), .mreq_n(mreq_n), .iorq_n(iorq_n),
      .rd_n(rd_n), .wr_n(wr_n), .slow_dev(dev_slow),
      .bus_guard_n(bus_guard_n)
   );

   cpu_model_wr u_cpu (
      .clk21m(clk21m), .reset(reset),
      .ce_cpu_p(ce_cpu_p), .ce_cpu_n(ce_cpu_n), .wait_n(bus_guard_n & opll_pace_n_tb),
      .pattern(pattern), .gap_t(gap_t),
      .mreq_n(mreq_n), .iorq_n(iorq_n), .rd_n(rd_n), .wr_n(wr_n),
      .wdata(wdata), .n_issued(issued)
   );

   // device chip-select: every memory write in this stream targets the device
   wire dev_cs = ~mreq_n;
   wire dev_wr = ~wr_n;

   int  lvl358_c, lvl358_d, lvl358_x;
   int  edg358_c, edg358_x, edgcpu_c, edgcpu_x;

   // SCC / OPLL style on the 3.58MHz train = what the shipped core does
   dev_level u_lvl_358 (.clk21m(clk21m), .reset(reset | dev_rst), .ce(ce_3m58_p),
                        .cs(dev_cs), .wr(dev_wr), .din(wdata),
                        .n_commit(lvl358_c), .n_dup(lvl358_d), .n_lost(lvl358_x));
   // FDC style on the 3.58MHz train = the BROKEN configuration
   dev_edge  u_edg_358 (.clk21m(clk21m), .reset(reset | dev_rst), .ce(ce_3m58_p),
                        .cs(dev_cs), .wr(dev_wr), .din(wdata),
                        .n_commit(edg358_c), .n_lost(edg358_x));
   // FDC style on the CPU train = the fix shipped in msx_slots.sv
   dev_edge  u_edg_cpu (.clk21m(clk21m), .reset(reset | dev_rst), .ce(ce_cpu_p),
                        .cs(dev_cs), .wr(dev_wr), .din(wdata),
                        .n_commit(edgcpu_c), .n_lost(edgcpu_x));

   // --- OPLL pacer scenario wiring ------------------------------------------
   // In the OPLL runs every memory write in the stream is treated as an OPLL
   // write; A0 alternates with the incrementing data (addr, data, addr, ...).
   logic pace_en = 1'b0;
   wire  opll_win_tb = ~mreq_n & ~wr_n;
   wire  opll_a0_tb  = wdata[0];
   wire  opll_gate, opll_pace_n_tb;
   opll_pacer_s u_pace (
      .clk21m(clk21m), .reset(reset), .ce_3m58_p(ce_3m58_p),
      .cpu_turbo(cpu_turbo & pace_en),
      .win(opll_win_tb), .a0_in(opll_a0_tb),
      .wr_gate(opll_gate), .pace_n(opll_pace_n_tb)
   );
   int opll_c, opll_x;
   dev_opll u_opll (
      .clk21m(clk21m), .reset(reset | dev_rst), .ce(ce_3m58_p),
      .wr(opll_win_tb & opll_gate), .a0(opll_a0_tb),
      .n_commit(opll_c), .n_lost(opll_x)
   );

   always #23.28 clk21m = ~clk21m;

   int errors = 0;
   int i0, l3a, l3d, e3a, eca, x3a, xea, xca;

   // R10: the checkers carry `prev`/`started` across runs, so without this the
   // first write after a configuration change registers a spurious "lost" and
   // the pass/fail depends on the ORDER the runs are listed in.  Reset them at
   // the top of every run.
   logic dev_rst = 1'b0;

   int last_scclost, last_fdccpu, last_issued;

   // OPLL pacer scenario: separate scoring (temp-latch clobber model).
   task automatic run_opll(input [1:0] spd, input bit p_en, input string label,
                           input bit expect_loss);
      int c0, x0, i0l, c1, x1, i1l;
      begin
         cpu_speed = spd; guard_on = 1'b1; pattern = 1; gap_t = 1; pace_en = p_en;
         dev_rst = 1'b1; repeat (4) @(posedge clk21m); dev_rst = 1'b0;
         repeat (12) @(posedge clk21m);
         while (u_clock.clkdiv6 !== 3'd5) @(posedge clk21m);
         c0 = opll_c; x0 = opll_x; i0l = issued;
         repeat (NCYC * 2) @(posedge clk21m);   // paced writes are ~500 clk21m apart
         #1;
         c1 = opll_c - c0; x1 = opll_x - x0; i1l = issued - i0l;
         $display("  %-24s %7d %8d %7d", label, i1l, c1, x1);
         if (expect_loss) begin
            if (x1 == 0) begin
               errors++;
               $display("    *** control FAILED: unpaced over-spec stream lost nothing (model not stressed)");
            end
         end else begin
            if (x1 != 0) begin
               errors++;
               $display("    *** OPLL lost %0d register writes despite the pacer", x1);
            end
            if (c1 == 0 && i1l > 0) begin
               errors++;
               $display("    *** OPLL committed NOTHING under the pacer");
            end
         end
      end
   endtask

   task automatic run(input [1:0] spd, input bit g_on, input int pat,
                      input string label, input int gt = 1,
                      input bit sdev = 1'b1);
      int i1, l3, d3, e3, ec, x3, xe, xc;
      begin
         cpu_speed = spd; guard_on = g_on; pattern = pat; gap_t = gt;
         dev_slow = sdev;
         dev_rst = 1'b1; repeat (4) @(posedge clk21m); dev_rst = 1'b0;
         repeat (12) @(posedge clk21m);
         while (u_clock.clkdiv6 !== 3'd5) @(posedge clk21m);
         i0  = issued;   l3a = lvl358_c; l3d = lvl358_d;
         e3a = edg358_c; eca = edgcpu_c;
         x3a = lvl358_x; xea = edg358_x; xca = edgcpu_x;
         repeat (NCYC) @(posedge clk21m);
         #1;
         i1 = issued - i0;
         l3 = lvl358_c - l3a; d3 = lvl358_d - l3d;
         e3 = edg358_c - e3a; ec = edgcpu_c - eca;
         x3 = lvl358_x - x3a; xe = edg358_x - xea; xc = edgcpu_x - xca;
         last_scclost = x3; last_fdccpu = xc; last_issued = i1;
         $display("  %-24s %7d %8d %6d %7d %9d %8d %9d",
                  label, i1, l3, d3, x3, xe, ec, xc);
         // SCC checks only apply when the device is classified slow (shipped
         // config).  The FDC-on-ce_cpu_p device scales with the CPU by
         // construction and must never lose, even misclassified fast.
         if (g_on && sdev) begin
            if (l3 == 0 && i1 > 0) begin
               errors++;
               $display("    *** SCC/OPLL-style device captured NOTHING (total loss)");
            end
            if (x3 != 0) begin
               errors++;
               $display("    *** SCC/OPLL-style device LOST %0d writes", x3);
            end
         end
         if (g_on) begin
            if (xc != 0) begin
               errors++;
               $display("    *** FDC-style device on ce_cpu_p LOST %0d writes", xc);
            end
         end
      end
   endtask

   initial begin
      repeat (4) @(posedge clk21m);
      reset = 0;
      repeat (8) @(posedge clk21m);

      $display("=== tb_turbo_slowdev === (%0d clk21m per run)", NCYC);
      $display("");
      $display("  Writes carry a value that increments by 1 each time, so every");
      $display("  device self-checks the SEQUENCE it receives.  'lost' counts");
      $display("  values that never arrived.  Zero is the only acceptable number.");
      $display("");
      $display("  pattern A = M1 fetch + memory write (LD (HL),A loop)");
      $display("  pattern B = back-to-back write M-cycles with no gap at all,");
      $display("              tighter than any real Z80 instruction (worst case)");
      $display("");
      $display("  run                      issued   SCCok    dup  SCClost  FDC@3m58l  FDCok  FDC@cpul");
      $display("  ------------------------------------------------------------------------------------");
      run(2'd0, 1'b1, 0, "A 3.58MHz stock");
      run(2'd1, 1'b1, 0, "A 5.37MHz guard ON");
      run(2'd2, 1'b1, 0, "A 7.16MHz guard ON");
      run(2'd3, 1'b1, 0, "A 10.7MHz guard ON");
      run(2'd2, 1'b0, 0, "A 7.16MHz guard OFF");
      run(2'd3, 1'b0, 0, "A 10.7MHz guard OFF");
      $display("");
      run(2'd0, 1'b1, 1, "B 3.58MHz stock");
      run(2'd1, 1'b1, 1, "B 5.37MHz guard ON");
      run(2'd2, 1'b1, 1, "B 7.16MHz guard ON");
      run(2'd3, 1'b1, 1, "B 10.7MHz guard ON");
      run(2'd2, 1'b0, 1, "B 7.16MHz guard OFF");
      run(2'd3, 1'b0, 1, "B 10.7MHz guard OFF");
      $display("");
      $display("  P2 scoping, misclassification probe: the same worst-case write stream");
      $display("  with the device MISCLASSIFIED onto the fast path.  Measured result: the");
      $display("  SCC-style device STILL loses nothing -- an EMERGENT invariant, not the");
      $display("  design guarantee.  The CEN p/n granularity plus the guard_cnt register");
      $display("  delay round every guarded write strobe up to >= 6 clk21m = one full");
      $display("  ce_3m58 period, so a window cannot miss the enable edge at any speed or");
      $display("  phase.  The slow classification in msx_slots is therefore defense in");
      $display("  depth: it is what keeps SCC/OPLL safe BY CONSTRUCTION if GUARD_WR /");
      $display("  GUARD_RD_FAST are ever reduced.  These rows pin the invariant; if one");
      $display("  ever reports a loss, the fast floor has been cut below the ce period");
      $display("  and the scoped classification just became the only protection left.");
      run(2'd3, 1'b1, 1, "B 10.7MHz fast-misclass", 1, 1'b0);
      if (last_scclost != 0) begin
         errors++;
         $display("    *** fast write windows can now miss ce_3m58 (%0d lost) -- the fast floor dropped below one ce period", last_scclost);
      end
      run(2'd2, 1'b1, 1, "B 7.16MHz fast-misclass", 1, 1'b0);
      if (last_scclost != 0) begin
         errors++;
         $display("    *** fast write windows can now miss ce_3m58 (%0d lost) -- the fast floor dropped below one ce period", last_scclost);
      end
      run(2'd1, 1'b1, 1, "B 5.37MHz fast-misclass", 1, 1'b0);
      if (last_scclost != 0) begin
         errors++;
         $display("    *** fast write windows can now miss ce_3m58 (%0d lost) -- the fast floor dropped below one ce period", last_scclost);
      end
      $display("");
      $display("  OPLL pacer (temp-latch + 18-slot rotation commit model, worst-case");
      $display("  back-to-back addr/data stream).  Paced turbo must lose ZERO; the");
      $display("  unpaced turbo control must lose (that is the defect being fixed).");
      $display("  The stock row documents that an over-spec stream loses on the real");
      $display("  chip too -- at stock the drivers' software delays are the protection,");
      $display("  and the pacer is deliberately transparent there (bit-identical).");
      $display("");
      $display("  run                       issued  commits    lost");
      $display("  --------------------------------------------------");
      run_opll(2'd3, 1'b1, "OPLL 10.7MHz pacer ON",  1'b0);
      run_opll(2'd2, 1'b1, "OPLL 7.16MHz pacer ON",  1'b0);
      run_opll(2'd1, 1'b1, "OPLL 5.37MHz pacer ON",  1'b0);
      run_opll(2'd3, 1'b0, "OPLL 10.7MHz pacer OFF", 1'b1);
      run_opll(2'd0, 1'b1, "OPLL 3.58MHz (stock)",   1'b1);
      pace_en = 1'b0;
      $display("");
      $display("");
      $display("  Inter-write cadence sweep at 10.7MHz (x3), guard ON: gap_t internal");
      $display("  T-states between consecutive write M-cycles.  This is the test that");
      $display("  distinguishes a GUARANTEE from phase luck for the edge-capture FDC.");
      $display("");
      $display("  run                      issued   SCCok    dup  SCClost  FDC@3m58l  FDCok  FDC@cpul");
      $display("  ------------------------------------------------------------------------------------");
      for (int g = 1; g <= 8; g++)
         run(2'd3, 1'b1, 2, $sformatf("x3 gap=%0d T-states", g), g);
      $display("");
      $display("  Same sweep at 7.16MHz (x2), guard ON:");
      for (int g = 1; g <= 8; g++)
         run(2'd2, 1'b1, 2, $sformatf("x2 gap=%0d T-states", g), g);
      $display("");
      $display("  SCClost   = SCC/OPLL-style level capture on ce_3m58_p (shipped)");
      $display("  FDC@3m58l = wd1793-style edge capture left on clk_en (rejected)");
      $display("  FDC@cpul  = wd1793-style edge capture on ce_cpu_p   (shipped)");
      $display("");
      if (errors == 0)
         $display("tb_turbo_slowdev: PASS - 0 writes lost in every shipped configuration");
      else
         $display("tb_turbo_slowdev: FAIL (%0d failures)", errors);
      // $finish's argument is display VERBOSITY per IEEE 1800, NOT an exit code --
      // the simulator exits 0 from any $finish, so the old `$finish(errors?1:0)`
      // could never fail the run_turbo.sh gate.  $fatal is the call that
      // produces a nonzero process exit status.
      if (errors) $fatal(1, "TB failed with %0d errors", errors);
      $finish;
   end

endmodule
