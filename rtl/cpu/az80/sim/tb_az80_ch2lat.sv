// A-Z80 against an SDRAM-ch2-like memory: the request is taken on the RISING
// edge of mreq&(rd|wr) (sdram.sv: ch2_req & ~ch2_req_1), the address is latched
// there, and read data appears LAT clk_sdram cycles later -- until then dout
// still holds the PREVIOUS read's byte (ch2_saved_data).  Every earlier A-Z80
// bench used a 1-clk21m BRAM, which is why none of them could see this.
// Includes the MSX2 M1 wait pair (3.58: guard shorted, pair is the only wait).
`timescale 1ns/1ps
module tb_az80_ch2lat;
   logic clk_sdram = 0;  always #5.8207 clk_sdram = ~clk_sdram;
   logic [1:0] div4 = 0;  logic clk21m = 0;
   always @(posedge clk_sdram) begin div4 <= div4 + 1'd1; if (div4[0]) clk21m <= ~clk21m; end
   logic reset = 1;  logic [2:0] cpu_speed = 3'd0;  wire az80_clk;  wire [2:0] speed_q;
   az80_clkgen clkgen (.clk_sdram(clk_sdram), .clk21m(clk21m), .reset(reset), .pause(1'b0), .cpu_speed(cpu_speed),
                       .cpu_bus_idle(1'b1), .az80_clk(az80_clk), .cpu_speed_q(speed_q));
   wire halt_n, busak_n, m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n;
   wire [15:0] a;  wire [7:0] do_;  wire [7:0] di;  wire wait_n;
   az80_wrapper cpu (.clk(az80_clk), .reset(reset), .wait_n(wait_n), .int_n(1'b1),
                     .nmi_n(1'b1), .busrq_n(1'b1), .m1_n(m1_n), .mreq_n(mreq_n),
                     .iorq_n(iorq_n), .rd_n(rd_n), .wr_n(wr_n), .rfsh_n(rfsh_n),
                     .halt_n(halt_n), .busak_n(busak_n), .a(a), .di(di), .do_(do_));

   // ---- ch2 behavioural model on clk_sdram ----
   int LAT = 24;
   logic [7:0] mem [0:255];
   //  The address the SDRAM actually captures has been through slot/layout/base
   //  decode: model it as the CPU address SETTLE clk_sdram cycles late.  The
   //  hardware trace showed A-Z80 changing its address on the same edge as
   //  MREQ/RD, so a request edge taken immediately reads a stale address.
   //  SETTLE = clk_sdram periods from the az80_clk edge that changes the address
   //  to the first capture edge that may use it -- the same meaning as an STA
   //  "-end SETTLE" multicycle.  A change launched by the CPU edge at clk_sdram
   //  edge 0 is first sampled on edge 1 (a_hist[0] after edge 1); at capture
   //  edge C the right-hand side a_hist[k] holds the sample taken at edge C-1-k,
   //  so "launched at C-SETTLE" is a_hist[SETTLE-2].  (An earlier SETTLE-1 index
   //  silently demanded one period more than it said, and failed a design that
   //  captures on exactly the 3rd edge.)
   int SETTLE = 3;
   logic [15:0] a_hist [0:7];
   always @(posedge clk_sdram) begin a_hist[0] <= a; for (int k = 1; k < 8; k++) a_hist[k] <= a_hist[k-1]; end
   wire [15:0] a_dec = (SETTLE <= 1) ? a : a_hist[SETTLE-2];
   bit   req_delay = 1;     // 1 = MSX1.sv ch2_req_cpu (two clk_sdram stages); 0 = raw strobe (20260914e hardware)
   logic [1:0] ce_sr = 2'b00;
   wire  req_raw = ~mreq_n & (~rd_n | ~wr_n);
   always @(posedge clk_sdram) ce_sr <= {ce_sr[0], req_raw};
   wire  req = req_delay ? (req_raw & (&ce_sr)) : req_raw;
   logic req_1 = 0;  logic [7:0] saved = 8'h00;  logic [7:0] pend_a;  logic pend_rnw;
   logic rdtog = 0;
   int   cnt = -1;
   always @(posedge clk_sdram) begin
      req_1 <= req;
      if (req & ~req_1) begin pend_a <= a_dec[7:0]; pend_rnw <= rd_n ? 1'b0 : 1'b1; cnt <= LAT; end
      else if (cnt > 0) cnt <= cnt - 1;
      else if (cnt == 0) begin
         if (pend_rnw) begin saved <= mem[pend_a]; rdtog <= ~rdtog; end
         cnt <= -1;
      end
      if (~mreq_n & ~wr_n) mem[a[7:0]] <= do_;      // writes: take the data while strobed
   end
   assign di = saved;

   // ---- ce_cpu + M1 wait pair (verbatim logic) ----
   int div_of [0:3] = '{6, 4, 3, 2};  int cecnt = 0;  logic ce_cpu = 0;
   always @(posedge clk21m) begin
      if (reset) begin cecnt <= 0; ce_cpu <= 0; end
      else begin ce_cpu <= (cecnt == 0); cecnt <= (cecnt == div_of[cpu_speed] - 1) ? 0 : cecnt + 1; end
   end
   logic wait_m1_n = 1'b0, u1_2_q = 1'b0;  wire exwait_n = 1'b1;
   always @(posedge clk21m, negedge exwait_n, negedge u1_2_q) begin
      if (~exwait_n) wait_m1_n <= 1'b0; else if (~u1_2_q) wait_m1_n <= 1'b1; else if (ce_cpu) wait_m1_n <= m1_n;
   end
   always @(posedge clk21m, negedge exwait_n) begin
      if (~exwait_n) u1_2_q <= 1'b1; else if (ce_cpu) u1_2_q <= wait_m1_n;
   end
   // ---- A-Z80 SDRAM read pacer, same logic as rtl/msx.sv az_rd_pace_n ----
   bit   pacer_on = 1;
   wire  bus_xfer = ~((iorq_n & mreq_n) | (wr_n & rd_n));
   wire  az_rd_win = pacer_on & bus_xfer & ~mreq_n & ~rd_n;       // sdram_ce & ram_rnw
   logic az_armed = 0, az_done = 0, az_tog0 = 0;  logic [7:0] az_wd = 0;
   always @(posedge clk_sdram) begin
      if (reset | ~az_rd_win) begin az_armed <= 0; az_done <= 0; az_wd <= 0; end
      else begin
         if (~az_armed) begin az_armed <= 1; az_tog0 <= rdtog; end
         else if (rdtog != az_tog0) az_done <= 1;
         if (az_wd != 8'd255) az_wd <= az_wd + 1;
      end
   end
   wire az_rd_pace_n = ~(az_rd_win & ~(az_done | (az_wd == 8'd255)));
   assign wait_n = wait_m1_n & az_rd_pace_n;

   int errors = 0, n, neg_failures = 0, neg2_failures = 0;
   task automatic run(input [2:0] spd, input int lat);
      begin
         reset = 1; cpu_speed = spd; LAT = lat;
         for (int i = 0; i < 256; i++) mem[i] = 8'h00;
         mem['h00]=8'h21; mem['h01]=8'h80; mem['h02]=8'h00; mem['h03]=8'h06; mem['h04]=8'h0A;
         mem['h05]=8'hAF; mem['h06]=8'h80; mem['h07]=8'h10; mem['h08]=8'hFD; mem['h09]=8'h77;
         mem['h0A]=8'h3E; mem['h0B]=8'h00; mem['h0C]=8'h7E; mem['h0D]=8'h32; mem['h0E]=8'h81;
         mem['h0F]=8'h00; mem['h10]=8'h76;
         repeat (400) @(posedge clk_sdram);
         reset = 0;
         n = 0; while (!halt_n && n < 100000) begin @(posedge clk_sdram); n++; end
         n = 0; while (halt_n && n < 300000) begin @(posedge clk_sdram); n++; end
         $display("  spd=%0d LAT=%2d clk_sdram (%4.1f clk21m)  halt=%s mem80=%02h mem81=%02h %s",
                  spd, lat, lat/4.0, halt_n ? "NO " : "yes", mem['h80], mem['h81],
                  (!halt_n && mem['h80]==8'h37 && mem['h81]==8'h37) ? "ok" : "FAIL");
         if (halt_n || mem['h80]!==8'h37 || mem['h81]!==8'h37) errors++;
      end
   endtask
   initial begin
      $display("=== tb_az80_ch2lat: A-Z80 vs SDRAM-ch2 edge-triggered read latency ===");
      $display("  --- pacer OFF (the 20260914a hardware): NEGATIVE CONTROL, must fail ---");
      pacer_on = 0; errors = 0;
      foreach (div_of[s]) run(s[2:0], 24);
      neg_failures = errors;
      $display("  --- pacer ON, request NOT delayed, address settles 3 clk_sdram late (20260914e hardware): NEGATIVE CONTROL 2 ---");
      pacer_on = 1; req_delay = 0; errors = 0;
      foreach (div_of[s]) run(s[2:0], 24);
      neg2_failures = errors;
      req_delay = 1;
      $display("  --- pacer ON (fix), latency sweep ---");
      pacer_on = 1; errors = 0;
      foreach (div_of[s]) for (int l = 4; l <= 60; l += 4) run(s[2:0], l);
      if (neg2_failures != 4) $display("tb_az80_ch2lat: FAIL -- negative control 2 (undelayed request) did not fail (%0d of 4)", neg2_failures);
      else if (neg_failures != 4)  $display("tb_az80_ch2lat: FAIL -- negative control did not fail (%0d of 4): the bench no longer models the hazard", neg_failures);
      else if (errors == 0)   $display("tb_az80_ch2lat: PASS -- negative control failed 4/4, pacer passes every speed and latency");
      else                    $display("tb_az80_ch2lat: FAIL (%0d with the pacer on)", errors);
      $finish;
   end
endmodule
