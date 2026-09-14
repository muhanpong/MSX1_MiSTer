// A-Z80 + the MSX2 M1 wait pair (msx.sv wait_m1_n / u1_2_q), which no earlier
// bench included.  At 3.58 MHz cpu_turbo is 0 and the guard is shorted, so on
// hardware the ONLY wait the CPU ever sees during boot is this pair -- clocked
// by ce_cpu on the clk21m grid while the CPU samples WAIT at its own T2 on the
// clk_sdram/24 grid.  The two grids have a fixed but arbitrary phase, so this
// sweeps every ce phase at every speed and asks: does the program still halt,
// and how many clocks did it take (one extra T per M1 is the spec).
`timescale 1ns/1ps
module tb_az80_m1wait;
   logic clk_sdram = 0;  always #5.8207 clk_sdram = ~clk_sdram;
   logic [1:0] div4 = 0;
   logic clk21m = 0;
   always @(posedge clk_sdram) begin div4 <= div4 + 1'd1; if (div4[0]) clk21m <= ~clk21m; end

   logic reset = 1;
   logic [2:0] cpu_speed = 3'd0;
   wire  az80_clk;  wire [2:0] speed_q;
   az80_clkgen clkgen (.clk_sdram(clk_sdram), .clk21m(clk21m), .reset(reset), .pause(1'b0), .cpu_speed(cpu_speed),
                       .cpu_bus_idle(1'b1), .az80_clk(az80_clk), .cpu_speed_q(speed_q));

   wire halt_n, busak_n, m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n;
   wire [15:0] a;  wire [7:0] do_;  logic [7:0] di;  wire wait_n;
   az80_wrapper cpu (.clk(az80_clk), .reset(reset), .wait_n(wait_n), .int_n(1'b1),
                     .nmi_n(1'b1), .busrq_n(1'b1), .m1_n(m1_n), .mreq_n(mreq_n),
                     .iorq_n(iorq_n), .rd_n(rd_n), .wr_n(wr_n), .rfsh_n(rfsh_n),
                     .halt_n(halt_n), .busak_n(busak_n), .a(a), .di(di), .do_(do_));

   logic [7:0] mem [0:255];  logic [7:0] q;
   always @(posedge clk21m) begin if (!mreq_n && !wr_n) mem[a[7:0]] <= do_; q <= mem[a[7:0]]; end
   always_comb di = q;

   // ce_cpu: one pulse every DIV clk21m (clock.sv: 6/4/3/2), phase settable.
   int div_of [0:3] = '{6, 4, 3, 2};
   int ce_phase = 0;
   int cecnt = 0;
   logic ce_cpu = 0;
   always @(posedge clk21m) begin
      if (reset) begin cecnt <= ce_phase; ce_cpu <= 0; end
      else begin
         ce_cpu <= (cecnt == 0);
         cecnt  <= (cecnt == div_of[cpu_speed] - 1) ? 0 : cecnt + 1;
      end
   end

   // ---- the M1 wait pair, verbatim from rtl/msx.sv (exwait_n tied high) ----
   wire exwait_n = 1'b1;
   logic wait_m1_n = 1'b0;
   logic u1_2_q = 1'b0;
   always @(posedge clk21m, negedge exwait_n, negedge u1_2_q) begin
      if (~exwait_n)      wait_m1_n <= 1'b0;
      else if (~u1_2_q)   wait_m1_n <= 1'b1;
      else if (ce_cpu)    wait_m1_n <= m1_n;
   end
   always @(posedge clk21m, negedge exwait_n) begin
      if (~exwait_n)      u1_2_q <= 1'b1;
      else if (ce_cpu)    u1_2_q <= wait_m1_n;
   end
   assign wait_n = wait_m1_n;      // cpu_turbo=0 at boot: guard shorted, pair is everything

   // counters
   int clocks, m1s, waits_seen;
   logic m1_q = 1;
   always @(posedge az80_clk) begin
      clocks++;
      m1_q <= m1_n;
      if (m1_q && !m1_n) m1s++;
      if (!wait_n) waits_seen++;
   end

   int errors = 0, n;
   string names [0:3] = '{"3.58", "5.37", "7.16", "10.7"};
   task automatic run_at(input [2:0] spd, input int ph);
      begin
         reset = 1; cpu_speed = spd; ce_phase = ph;
         for (int i = 0; i < 256; i++) mem[i] = 8'h00;
         mem['h00]=8'h21; mem['h01]=8'h80; mem['h02]=8'h00; mem['h03]=8'h06; mem['h04]=8'h0A;
         mem['h05]=8'hAF; mem['h06]=8'h80; mem['h07]=8'h10; mem['h08]=8'hFD; mem['h09]=8'h77;
         mem['h0A]=8'h3E; mem['h0B]=8'h00; mem['h0C]=8'h7E; mem['h0D]=8'h32; mem['h0E]=8'h81;
         mem['h0F]=8'h00; mem['h10]=8'h76;
         repeat (400) @(posedge clk_sdram);
         clocks = 0; m1s = 0; waits_seen = 0;
         reset = 0;
         n = 0; while (!halt_n && n < 100000) begin @(posedge clk_sdram); n++; end
         n = 0; while (halt_n && n < 600000) begin @(posedge clk_sdram); n++; end
         $write("  %sMHz ph=%0d  halt=%s clocks=%0d m1=%0d waitclks=%0d mem80=%02h mem81=%02h",
                names[spd], ph, halt_n ? "NO " : "yes", clocks, m1s, waits_seen, mem['h80], mem['h81]);
         if (halt_n) begin $display("   FAIL never halted (livelock?)"); errors++; end
         else if (mem['h80] !== 8'h37 || mem['h81] !== 8'h37) begin $display("   FAIL data"); errors++; end
         else $display("");
      end
   endtask

   initial begin
      $display("=== tb_az80_m1wait: A-Z80 with the MSX2 M1 wait pair, ce phase sweep ===");
      $display("  reference without the pair: 225 clocks, ~35 M1 cycles -> expect ~260 with one Tw per M1");
      for (int s = 0; s < 4; s++) for (int p = 0; p < div_of[s]; p++) run_at(s[2:0], p);
      if (errors == 0) $display("tb_az80_m1wait: PASS"); else $display("tb_az80_m1wait: FAIL (%0d)", errors);
      $finish;
   end
endmodule
