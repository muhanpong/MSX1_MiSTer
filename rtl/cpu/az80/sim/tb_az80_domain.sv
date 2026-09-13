//
//  A-Z80 across the clock-domain boundary.
//
//  The bring-up bench proved the wrapper with an asynchronous memory, which is
//  not the machine.  In the core the CPU will run on az80_clk (a real clock out
//  of clk_sdram) while the memory, the guard and every peripheral stay on
//  clk21m, and the two only line up at some speeds:
//
//      /24 -> 3 clk21m per half period   aligned
//      /16 -> 2                          aligned
//      /12 -> 1.5                        HALF the edges fall between clk21m edges
//       /8 -> 1                          aligned
//       /4 -> 0.5                        HALF fall between
//
//  Everything comes from one PLL so this is not metastability; it is whether a
//  clk21m memory can answer a CPU whose strobes move off that grid.  This bench
//  is the same program as the bring-up -- compute 55, store it, read it back --
//  against a memory model with clk21m registered-q behaviour, run at all five
//  speeds.  A read-back failure is the signature to watch for: a wrong read path
//  leaves the store looking correct.
//
//  WAIT_n is driven from the clk21m side by a minimal guard that holds until the
//  memory has had a cycle to answer, which is what the real guard does.
//
`timescale 1ns/1ps
module tb_az80_domain;

   //  One PLL: clk_sdram, and clk21m as its /4, phase aligned like the real one.
   logic clk_sdram = 0;  always #5.8207 clk_sdram = ~clk_sdram;
   logic [1:0] div4 = 0;
   logic clk21m = 0;
   always @(posedge clk_sdram) begin
      div4 <= div4 + 1'd1;
      if (div4 == 2'd1) clk21m <= ~clk21m;
   end

   logic reset = 1;
   logic [2:0] cpu_speed = 3'd0;
   wire        az80_clk;
   wire  [2:0] speed_q;

   az80_clkgen clkgen (.clk_sdram(clk_sdram), .reset(reset), .cpu_speed(cpu_speed),
                       .cpu_bus_idle(1'b1), .az80_clk(az80_clk), .cpu_speed_q(speed_q));

   wire halt_n, busak_n;
   wire m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n;
   wire [15:0] a;
   wire  [7:0] do_;
   logic [7:0] di;
   logic       wait_n;

   //  CPU side (az80_clk)
   wire c_m1_n, c_mreq_n, c_iorq_n, c_rd_n, c_wr_n, c_rfsh_n;
   wire [15:0] c_a;  wire [7:0] c_do;  wire [7:0] c_di;  wire c_wait_n;

   az80_wrapper cpu (.clk(az80_clk), .reset(reset), .wait_n(c_wait_n), .int_n(1'b1),
                     .nmi_n(1'b1), .busrq_n(1'b1),
                     .m1_n(c_m1_n), .mreq_n(c_mreq_n), .iorq_n(c_iorq_n), .rd_n(c_rd_n),
                     .wr_n(c_wr_n), .rfsh_n(c_rfsh_n), .halt_n(halt_n), .busak_n(busak_n),
                     .a(c_a), .di(c_di), .do_(c_do));

   //  Bridge: retimes the CPU's real-clock bus onto clk21m
   az80_bridge bridge (
      .clk_sdram(clk_sdram), .clk21m(clk21m), .reset(reset),
      .cpu_mreq_n(c_mreq_n), .cpu_iorq_n(c_iorq_n), .cpu_rd_n(c_rd_n),
      .cpu_wr_n(c_wr_n), .cpu_m1_n(c_m1_n), .cpu_rfsh_n(c_rfsh_n),
      .cpu_a(c_a), .cpu_do(c_do), .cpu_wait_n(c_wait_n), .cpu_di(c_di),
      .mreq_n(mreq_n), .iorq_n(iorq_n), .rd_n(rd_n), .wr_n(wr_n),
      .m1_n(m1_n), .rfsh_n(rfsh_n), .a(a), .d_from_cpu(do_),
      .d_to_cpu(di), .fabric_wait_n(wait_n));

   //  Memory on clk21m with a REGISTERED q, like rtl/peripheral/bram.vhd.
   logic [7:0] mem [0:255];
   logic [7:0] q;
   always @(posedge clk21m) begin
      if (!mreq_n && !wr_n) mem[a[7:0]] <= do_;
      q <= mem[a[7:0]];
   end
   always_comb di = q;

   //  Minimal guard, clk21m: hold WAIT_n until the memory has had two clk21m
   //  cycles with this address, which is what a registered-q read needs.
   logic [2:0] gcnt = 0;
   wire  xfer = (~mreq_n & (~rd_n | ~wr_n)) | (~iorq_n & (~rd_n | ~wr_n));
   always @(posedge clk21m) begin
      if (!xfer) gcnt <= 0;
      else if (gcnt != 3'd7) gcnt <= gcnt + 1'd1;
   end
   always_comb wait_n = ~(xfer & (gcnt < 3'd2));

   initial begin
      for (int i = 0; i < 256; i++) mem[i] = 8'h00;
      mem['h00]=8'h21; mem['h01]=8'h80; mem['h02]=8'h00;   // LD HL,0080h
      mem['h03]=8'h06; mem['h04]=8'h0A;                    // LD B,10
      mem['h05]=8'hAF;                                     // XOR A
      mem['h06]=8'h80;                                     // ADD A,B
      mem['h07]=8'h10; mem['h08]=8'hFD;                    // DJNZ -3
      mem['h09]=8'h77;                                     // LD (HL),A
      mem['h0A]=8'h3E; mem['h0B]=8'h00;                    // LD A,0
      mem['h0C]=8'h7E;                                     // LD A,(HL)
      mem['h0D]=8'h32; mem['h0E]=8'h81; mem['h0F]=8'h00;   // LD (0081h),A
      mem['h10]=8'h76;                                     // HALT
   end

   string names [0:4] = '{"3.58MHz", "5.37MHz", "7.16MHz", "10.7MHz", "21.5MHz"};
   int errors = 0, n;
   //  Instrumentation: how many clk21m edges land inside each write strobe, and
   //  how long the strobe is in clk21m periods.  A write the memory never sees
   //  is the failure mode this bench exists to catch.
   int  wr_windows = 0, wr_seen = 0, wr_min = 9999, wr_cur = 0;
   logic wr_n_q = 1;
   always @(posedge clk21m) begin
      wr_n_q <= wr_n;
      if (!mreq_n && !wr_n) begin wr_seen++; wr_cur++; end
      else if (wr_cur != 0) begin
         if (wr_cur < wr_min) wr_min = wr_cur;
         wr_cur = 0;
      end
      if (wr_n_q && !wr_n) wr_windows++;      // falling edge of wr_n
   end

   task automatic run_at(input [2:0] spd);
      begin
         reset = 1; cpu_speed = spd;
         for (int i = 0; i < 256; i++) mem[i] = 8'h00;
         mem['h00]=8'h21; mem['h01]=8'h80; mem['h02]=8'h00;
         mem['h03]=8'h06; mem['h04]=8'h0A; mem['h05]=8'hAF;
         mem['h06]=8'h80; mem['h07]=8'h10; mem['h08]=8'hFD;
         mem['h09]=8'h77; mem['h0A]=8'h3E; mem['h0B]=8'h00;
         mem['h0C]=8'h7E; mem['h0D]=8'h32; mem['h0E]=8'h81; mem['h0F]=8'h00;
         mem['h10]=8'h76;
         wr_windows = 0; wr_seen = 0; wr_min = 9999; wr_cur = 0;
         repeat (400) @(posedge clk_sdram);
         reset = 0;
         //  Wait for the previous run's HALT to clear before timing this one --
         //  otherwise the loop below sees halt_n already low and exits at once.
         n = 0;
         while (!halt_n && n < 100000) begin @(posedge clk_sdram); n++; end
         n = 0;
         while (halt_n && n < 400000) begin @(posedge clk_sdram); n++; end
         $write("  %-8s halt=%s  mem80=%02h mem81=%02h  wr:edges=%0d seen=%0d min=%0d",
                names[spd], halt_n ? "NO " : "yes", mem['h80], mem['h81],
                wr_windows, wr_seen, (wr_min==9999)?0:wr_min);
         if (halt_n)                    begin $display("   FAIL never halted");        errors++; end
         else if (mem['h80] !== 8'h37)  begin $display("   FAIL store path");           errors++; end
         else if (mem['h81] !== 8'h37)  begin $display("   FAIL READ-BACK (domain)");   errors++; end
         else                                 $display("   ok");
      end
   endtask

   initial begin
      $display("=== tb_az80_domain: A-Z80 on az80_clk, memory and guard on clk21m ===");
      for (int s = 0; s < 5; s++) run_at(s[2:0]);
      $display("");
      if (errors == 0) $display("tb_az80_domain: PASS -- every speed, including the two that are off-grid");
      else             $display("tb_az80_domain: FAIL (%0d)", errors);
      $finish;
   end
endmodule
