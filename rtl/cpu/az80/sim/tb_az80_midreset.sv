// A-Z80 reset asserted WHILE RUNNING (what memory_upload's reset_rq does after
// the core has already executed from a half-loaded ROM), with the clock either
// STOPPED during reset (az80_clkgen's original behaviour) or running.  A real
// Z80 needs a running clock in /RESET; A-Z80's resets.v clears PC only when its
// sequencer reaches M1.T2 with reset_in asserted.  Power-up state is 0 so the
// first run starts at 0000 either way -- this bench is about the second one.
`timescale 1ns/1ps
module tb_az80_midreset;
   logic clk_sdram = 0;  always #5.8207 clk_sdram = ~clk_sdram;
   logic [1:0] div4 = 0;  logic clk21m = 0;
   always @(posedge clk_sdram) begin div4 <= div4 + 1'd1; if (div4[0]) clk21m <= ~clk21m; end
   logic reset = 1, stop_clk = 1;
   logic [2:0] cpu_speed = 3'd0;  wire az80_clk;  wire [2:0] speed_q;
   az80_clkgen clkgen (.clk_sdram(clk_sdram), .clk21m(clk21m), .reset(reset), .pause(reset & stop_clk), .cpu_speed(cpu_speed),
                       .cpu_bus_idle(1'b1), .az80_clk(az80_clk), .cpu_speed_q(speed_q));
   // msx.sv reset synchroniser
   logic [1:0] az_rst_sync = 2'b11;
   always @(posedge az80_clk, posedge reset) if (reset) az_rst_sync <= 2'b11; else az_rst_sync <= {az_rst_sync[0], 1'b0};
   wire az_reset = az_rst_sync[1];
   wire halt_n, busak_n, m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n;
   wire [15:0] a;  wire [7:0] do_;  logic [7:0] di;
   az80_wrapper cpu (.clk(az80_clk), .reset(az_reset), .wait_n(1'b1), .int_n(1'b1),
                     .nmi_n(1'b1), .busrq_n(1'b1), .m1_n(m1_n), .mreq_n(mreq_n),
                     .iorq_n(iorq_n), .rd_n(rd_n), .wr_n(wr_n), .rfsh_n(rfsh_n),
                     .halt_n(halt_n), .busak_n(busak_n), .a(a), .di(di), .do_(do_));
   logic [7:0] mem [0:255];  logic [7:0] q;
   always @(posedge clk21m) begin if (!mreq_n && !wr_n) mem[a[7:0]] <= do_; q <= mem[a[7:0]]; end
   always_comb di = q;
   // first M1 address after each reset release
   logic [15:0] first_m1;  logic got = 0;  logic m1q = 1;
   always @(posedge az80_clk) begin m1q <= m1_n; if (!az_reset && !got && m1q && !m1_n) begin first_m1 <= a; got <= 1; end end
   int errors = 0;
   task automatic go(input bit stop, input int hold_clks, input string label);
      begin
         // power-up-like start: long reset, then run the program for a while
         stop_clk = stop; reset = 1;
         for (int i = 0; i < 256; i++) mem[i] = 8'h00;
         mem['h00]=8'h21; mem['h01]=8'h80; mem['h02]=8'h00; mem['h03]=8'h06; mem['h04]=8'h0A;
         mem['h05]=8'hAF; mem['h06]=8'h80; mem['h07]=8'h10; mem['h08]=8'hFD; mem['h09]=8'h77;
         mem['h0A]=8'h3E; mem['h0B]=8'h00; mem['h0C]=8'h7E; mem['h0D]=8'h32; mem['h0E]=8'h81;
         mem['h0F]=8'h00; mem['h10]=8'h18; mem['h11]=8'hFE;      // ...then JR $ (spin, PC != 0)
         repeat (400) @(posedge clk_sdram); reset = 0;
         repeat (3000) @(posedge clk_sdram);                    // well into the spin at 0010
         // the mid-run reset under test
         got = 0; reset = 1;
         repeat (hold_clks*24) @(posedge clk_sdram);            // hold_clks CPU periods at /24
         reset = 0;
         repeat (2000) @(posedge clk_sdram);
         $display("  %-34s first M1 after release = %04h  %s", label, first_m1, (got && first_m1==16'h0000) ? "ok" : "FAIL (PC not cleared)");
         if (!(got && first_m1==16'h0000)) errors++;
      end
   endtask
   initial begin
      $display("=== tb_az80_midreset ===");
      go(1, 200, "clock STOPPED in reset, 200 T hold");
      go(1, 4000, "clock STOPPED in reset, 4000 T hold");
      go(0, 3,   "clock running, 3 T hold");
      go(0, 8,   "clock running, 8 T hold");
      go(0, 200, "clock running, 200 T hold");
      if (errors) $display("tb_az80_midreset: FAIL (%0d)", errors); else $display("tb_az80_midreset: PASS");
      $finish;
   end
endmodule
