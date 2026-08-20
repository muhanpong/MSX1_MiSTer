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
   output logic bus_guard_n
);
   localparam int GUARD_RD = 8;
   localparam int GUARD_WR = 2;

   // Must mirror rtl/msx.sv: count on the strobe LEVEL, never on the core's
   // `req` one-shot, and stay transparent on an interrupt-acknowledge cycle.
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
   wire [3:0] guard_min = wr_n ? GUARD_RD[3:0] : GUARD_WR[3:0];
   assign bus_guard_n = ~cpu_turbo | ~bus_cycle | (mreq_n & rd_n & wr_n)
                                   | (guard_ce & (guard_cnt >= guard_min));
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

   guard_s u_guard (
      .clk21m(clk21m), .reset(reset), .ce_3m58_p(ce_3m58_p),
      .cpu_turbo(cpu_turbo), .mreq_n(mreq_n), .iorq_n(iorq_n),
      .rd_n(rd_n), .wr_n(wr_n), .bus_guard_n(bus_guard_n)
   );

   cpu_model_wr u_cpu (
      .clk21m(clk21m), .reset(reset),
      .ce_cpu_p(ce_cpu_p), .ce_cpu_n(ce_cpu_n), .wait_n(bus_guard_n),
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

   always #23.28 clk21m = ~clk21m;

   int errors = 0;
   int i0, l3a, l3d, e3a, eca, x3a, xea, xca;

   // R10: the checkers carry `prev`/`started` across runs, so without this the
   // first write after a configuration change registers a spurious "lost" and
   // the pass/fail depends on the ORDER the runs are listed in.  Reset them at
   // the top of every run.
   logic dev_rst = 1'b0;

   task automatic run(input [1:0] spd, input bit g_on, input int pat,
                      input string label, input int gt = 1);
      int i1, l3, d3, e3, ec, x3, xe, xc;
      begin
         cpu_speed = spd; guard_on = g_on; pattern = pat; gap_t = gt;
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
         $display("  %-24s %7d %8d %6d %7d %9d %8d %9d",
                  label, i1, l3, d3, x3, xe, ec, xc);
         if (g_on) begin
            if (l3 == 0 && i1 > 0) begin
               errors++;
               $display("    *** SCC/OPLL-style device captured NOTHING (total loss)");
            end
            if (x3 != 0) begin
               errors++;
               $display("    *** SCC/OPLL-style device LOST %0d writes", x3);
            end
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
      $finish(errors ? 1 : 0);
   end

endmodule
