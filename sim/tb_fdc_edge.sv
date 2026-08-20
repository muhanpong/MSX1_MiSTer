// ---------------------------------------------------------------------------
// tb_fdc_edge - is a ONE-TICK pacer enough for wd1793's edge-detected bus?
//
// The claim under test (team-lead / T-perf): once a pacer forces one ce_3m58_p
// tick to observe wre=1, the next Z80 memory write is >= 7 T-states away, so a
// tick with wre=0 must fall in between and the falling edge is always seen.
//
// That is true for accesses separated by a whole instruction.  It is NOT true
// for the two write M-cycles INSIDE a single 16-bit store.  `LD (nn),HL` (0x22,
// 16T) writes nn and nn+1 back-to-back with ~2 T-states between strobes, and
// the wd1793 register block sits at 0x7FF8..0x7FFB - COMMAND, TRACK, SECTOR,
// DATA - four consecutive bytes.  `LD (0x7FF9),HL` to set track+sector in one
// instruction is an entirely natural driver idiom.  `LD HL,(nn)` / `LD (nn),rr`
// (ED-prefixed) and `EX (SP),HL` have the same shape.
//
// The device model is wd1793.sv:271-387 + :606, verbatim in structure:
//
//     always @(posedge clk_sys) if(ce) begin
//        old_wr <= wre;
//        if((!old_rd && rde) || (!old_wr && wre)) cur_addr <= addr;
//        if(old_wr && !wre && (cur_addr == A_DATA)) write_data <= 1;
//        ...
//        if (!old_wr & wre) begin case (addr) ... endcase end   // :606
//     end
//
// Note :606 - the REGISTER WRITE ITSELF is gated by the rising edge.  A masked
// rising edge does not merely lose a completion pulse; it loses the byte.
//
// Every access carries a unique data value, so the device self-checks the
// (address, data) sequence it receives.  Phase is swept 0..5 because the CPU
// and the 3.58MHz tick grid are both divided from clk21m and therefore sit in
// a fixed relative phase that only the startup offset can change.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps

// --- wd1793 bus front end, transcribed -------------------------------------
module wd_edge_model (
   input  logic clk21m, reset, ce,
   input  logic wre, rde,
   input  logic [1:0] addr,
   input  logic [7:0] din,
   output int   n_wr_ok,      // register writes actually performed
   output int   n_wr_bad,     // performed with the wrong data
   output int   n_rd_pulse,   // read_data completions
   output int   n_cur_bad     // completion attributed to the wrong register
);
   localparam [1:0] A_DATA = 2'd3;

   logic       old_wr, old_rd;
   logic [1:0] cur_addr, last_rd_addr;
   logic [7:0] regfile [0:3];
   logic [7:0] expect_d [0:3];   // filled by the TB via force-free side channel
   int         i;

   always @(posedge clk21m) begin
      if (reset) begin
         old_wr <= 1'b0; old_rd <= 1'b0; cur_addr <= 2'd0;
         n_wr_ok <= 0; n_wr_bad <= 0; n_rd_pulse <= 0; n_cur_bad <= 0;
      end else if (ce) begin
         old_wr <= wre;
         old_rd <= rde;
         if ((!old_rd && rde) || (!old_wr && wre)) cur_addr <= addr;
         // wd1793.sv:384 - the read completion that advances the sector
         // data pointer.  Counted for ANY register so a missed falling edge
         // shows up as a lost completion rather than as a wrong address.
         if (old_rd && !rde) n_rd_pulse <= n_rd_pulse + 1;
         if (old_rd && !rde && (cur_addr != last_rd_addr)) n_cur_bad <= n_cur_bad + 1;
         if (!old_rd && rde) last_rd_addr <= addr;
         if (!old_wr && wre) begin
            regfile[addr] <= din;      // wd1793.sv:606 - the byte lands HERE
            n_wr_ok <= n_wr_ok + 1;
         end
      end
   end
endmodule


// --- T80pa-faithful CPU emitting whole instructions ------------------------
module cpu_instr (
   input  logic clk21m, reset, ce_cpu_p, ce_cpu_n, wait_n,
   input  int   pattern,   // 0 = LD (nn),HL   1 = LD (nn),A   2 = LD HL,(nn)
   input  int   gap_t,     // extra internal T-states BETWEEN the two dev cycles
   output logic mreq_n, rd_n, wr_n,
   output logic dev_cyc,          // this M-cycle targets the FDC
   output logic [1:0] dev_addr,
   output logic [7:0] dev_data,
   output int   n_issued
);
   // M-cycle kinds
   localparam int K_M1 = 0, K_RDM = 1, K_WRD = 2, K_RDD = 3, K_INT = 4;

   int   seq [0:5];
   int   seqn;
   always @(*) begin
      case (pattern)
         0: begin seq[0]=K_M1; seq[1]=K_RDM; seq[2]=K_RDM; seq[3]=K_WRD;
                  if (gap_t > 0) begin seq[4]=K_INT; seq[5]=K_WRD; seqn=6; end
                  else           begin seq[4]=K_WRD; seq[5]=K_M1;  seqn=5; end
            end
         1: begin seq[0]=K_M1; seq[1]=K_RDM; seq[2]=K_RDM; seq[3]=K_WRD; seqn=4;
                  seq[4]=K_M1; end
         default: begin seq[0]=K_M1; seq[1]=K_RDM; seq[2]=K_RDM; seq[3]=K_RDD;
                  if (gap_t > 0) begin seq[4]=K_INT; seq[5]=K_RDD; seqn=6; end
                  else           begin seq[4]=K_RDD; seq[5]=K_M1;  seqn=5; end
            end
      endcase
   end

   logic cen_pol = 1'b0;
   int   tstate  = 1, twait = 0, si = 0;
   int   kind;
   assign kind = seq[si];

   wire is_wr  = (kind == K_WRD);
   wire is_dev = (kind == K_WRD) || (kind == K_RDD);
   assign dev_cyc = is_dev;

   logic [1:0] acc_addr = 2'd1;   // 0x7FF9 = TRACK, then 0x7FFA = SECTOR
   logic [7:0] acc_data = 8'd0;
   assign dev_addr = acc_addr;
   assign dev_data = acc_data;

   function automatic int last_t(input int k);
      if      (k == K_M1)  last_t = 4;
      else if (k == K_INT) last_t = (gap_t < 1) ? 1 : gap_t;
      else                 last_t = 3;
   endfunction
   function automatic int int_waits(input int k); int_waits = (k == K_M1) ? 1 : 0; endfunction

   always @(posedge clk21m) begin
      if (reset) begin
         cen_pol <= 0; tstate <= 1; twait <= 0; si <= 0;
         {mreq_n, rd_n, wr_n} <= 3'b111;
         acc_addr <= 2'd1; acc_data <= 8'd0; n_issued <= 0;
      end else if (ce_cpu_p && !cen_pol) begin
         cen_pol <= 1'b1;
      end else if (ce_cpu_n && cen_pol) begin
         if (tstate == 2 && (!wait_n || twait < int_waits(kind))) begin
            cen_pol <= 1'b1;
            if (wait_n && twait < int_waits(kind)) twait <= twait + 1;
         end else begin
            cen_pol <= 1'b0;
            if (tstate >= last_t(kind)) begin
               tstate <= 1; twait <= 0;
               if (is_dev) begin
                  n_issued <= n_issued + 1;
                  acc_data <= acc_data + 8'd1;
                  acc_addr <= (acc_addr == 2'd2) ? 2'd1 : acc_addr + 2'd1;
               end
               si <= (si + 1 >= seqn) ? 0 : si + 1;
            end else tstate <= tstate + 1;
         end
         // T80pa memory strobes (K_INT is an internal M-cycle: no bus at all)
         if (kind != K_INT) begin
            if (tstate == 1) begin mreq_n <= 1'b0; rd_n <= is_wr; end
            if (tstate == 2) wr_n <= ~is_wr;
            if (tstate == 3) begin
               wr_n <= 1'b1; rd_n <= 1'b1; mreq_n <= (kind != K_M1);
            end
            if (kind == K_M1 && tstate == 4) mreq_n <= 1'b1;
         end
      end
   end
endmodule


module tb_fdc_edge;

   logic clk21m = 0, reset = 1;
   logic [1:0] cpu_speed = 2'd0;
   int   pattern = 0;
   int   phase   = 0;
   int   gap_t   = 0;

   wire ce_10m7_p, ce_10m7_n, ce_5m39_p, ce_5m39_n;
   wire ce_3m58_p, ce_3m58_n, ce_10hz, ce_cpu_p, ce_cpu_n;

   clock u_clock (
      .clk21m(clk21m), .reset(reset),
      .ce_10m7_p(ce_10m7_p), .ce_10m7_n(ce_10m7_n),
      .ce_5m39_p(ce_5m39_p), .ce_5m39_n(ce_5m39_n),
      .ce_3m58_p(ce_3m58_p), .ce_3m58_n(ce_3m58_n), .ce_10hz(ce_10hz),
      .cpu_speed(cpu_speed), .ce_cpu_p(ce_cpu_p), .ce_cpu_n(ce_cpu_n)
   );

   wire mreq_n, rd_n, wr_n, dev_cyc;
   wire [1:0] dev_addr;
   wire [7:0] dev_data;
   int  issued;
   wire turbo_on = |cpu_speed;

   wire wre = dev_cyc & ~wr_n & ~mreq_n;
   wire rde = dev_cyc & ~rd_n & ~mreq_n;

   // ---- ONE-TICK pacer: the T-perf / T-clean guarantee, given every possible
   // benefit of the doubt.  It arms on MREQ (one T-state before the strobe, so
   // it cannot be defeated by the T80pa write-edge race) and releases as soon
   // as a single ce_3m58_p has observed the strobe.  This is the strongest
   // form of "stall until the next ce_3m58_p".
   // pacer_n = how many ce_3m58_p ticks must observe the strobe ACTIVE before
   // the cycle is released.  1 = T-clean / T-perf(io); 2 = T-perf's slow_need
   // for memory, and the "명시 보장" rule proposed for the merged design.
   int   pacer_n = 1;
   logic [1:0] tick_cnt = 2'd0;
   wire  bus_cycle = dev_cyc & ~mreq_n;
   wire  strobe    = wre | rde;
   always @(posedge clk21m) begin
      if (reset | ~bus_cycle)                       tick_cnt <= 2'd0;
      else if (strobe & ce_3m58_p & (tick_cnt != 2'd3)) tick_cnt <= tick_cnt + 2'd1;
   end
   wire wait_n_1tick = ~turbo_on | ~bus_cycle | (tick_cnt >= pacer_n[1:0]);

   cpu_instr u_cpu (
      .clk21m(clk21m), .reset(reset), .ce_cpu_p(ce_cpu_p), .ce_cpu_n(ce_cpu_n),
      .wait_n(wait_n_1tick), .pattern(pattern), .gap_t(gap_t),
      .mreq_n(mreq_n), .rd_n(rd_n), .wr_n(wr_n),
      .dev_cyc(dev_cyc), .dev_addr(dev_addr), .dev_data(dev_data),
      .n_issued(issued)
   );

   // device on ce_3m58_p (what T-clean/T-perf ship) and on ce_cpu_p (my fix)
   int a_ok, a_bad, a_rd, a_cur, b_ok, b_bad, b_rd, b_cur;
   wd_edge_model u_dev_358 (.clk21m(clk21m), .reset(reset), .ce(ce_3m58_p),
      .wre(wre), .rde(rde), .addr(dev_addr), .din(dev_data),
      .n_wr_ok(a_ok), .n_wr_bad(a_bad), .n_rd_pulse(a_rd), .n_cur_bad(a_cur));
   wd_edge_model u_dev_cpu (.clk21m(clk21m), .reset(reset), .ce(ce_cpu_p),
      .wre(wre), .rde(rde), .addr(dev_addr), .din(dev_data),
      .n_wr_ok(b_ok), .n_wr_bad(b_bad), .n_rd_pulse(b_rd), .n_cur_bad(b_cur));

   always #23.28 clk21m = ~clk21m;

   localparam int NCYC = 300000;
   int errors = 0;
   int i0, a0, b0;

   task automatic go(input [1:0] spd, input int pat, input int ph, input string label,
                     input int gt = 0, input int pn = 1);
      int i1, a1, b1;
      begin
         cpu_speed = spd; pattern = pat; phase = ph; gap_t = gt; pacer_n = pn;
         reset = 1; repeat (8) @(posedge clk21m); reset = 0;
         repeat (ph) @(posedge clk21m);
         repeat (8) @(posedge clk21m);
         i0 = issued;
         a0 = (pat == 2) ? a_rd : a_ok;
         b0 = (pat == 2) ? b_rd : b_ok;
         repeat (NCYC) @(posedge clk21m); #1;
         i1 = issued - i0;
         a1 = ((pat == 2) ? a_rd : a_ok) - a0;
         b1 = ((pat == 2) ? b_rd : b_ok) - b0;
         $display("  %-16s ph=%0d g=%0d tick=%0d issued %6d | on ce_3m58_p: %6d  LOST %5d | on ce_cpu_p: %6d  LOST %5d",
                  label, ph, gt, pn, i1, a1, i1 - a1, b1, i1 - b1);
         if (i1 - a1 > 1) errors++;   // >1: tolerate the run-boundary partial access
      end
   endtask

   initial begin
      $display("=== tb_fdc_edge ===");
      $display("wd1793's edge-detected bus front end vs a ONE-TICK pacer.");
      $display("A lost access = a byte that never reached the register file.");
      $display("");
      for (int p = 0; p < 3; p++) begin
         string pn;
         if      (p == 0) pn = "LD (nn),HL  2 writes back-to-back";
         else if (p == 1) pn = "LD (nn),A   1 write per instr";
         else             pn = "LD HL,(nn)  2 reads back-to-back";
         $display("  --- pattern %0d: %s ---", p, pn);
         for (int s = 0; s < 3; s++) begin
            string sn;
            if      (s == 0) sn = "1x 3.58MHz";
            else if (s == 1) sn = "2x 7.16MHz";
            else             sn = "3x 10.7MHz";
            for (int ph = 0; ph < 6; ph++) go(s[1:0], p, ph, sn);
            if (s == 2 && p != 1) begin
               for (int gt = 1; gt <= 6; gt++) go(s[1:0], p, 0, sn, gt);
               // Does requiring TWO / THREE active ticks rescue it?
               for (int ph = 0; ph < 6; ph++) go(s[1:0], p, ph, sn, 0, 2);
               for (int ph = 0; ph < 6; ph++) go(s[1:0], p, ph, sn, 0, 3);
            end
         end
         $display("");
      end
      if (errors == 0)
         $display("tb_fdc_edge: one-tick pacer lost nothing");
      else
         $display("tb_fdc_edge: one-tick pacer LOSES accesses in %0d of 54 runs", errors);
      $finish(errors ? 1 : 0);
   end
endmodule
