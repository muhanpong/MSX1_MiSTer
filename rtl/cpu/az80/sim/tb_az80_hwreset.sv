// Reproduces the hardware reset path exactly: az80_clkgen (clock STOPPED while
// reset), msx.sv's 2-stage az_rst_sync releasing the core 2 clocks after the
// clock restarts, and -- the part every earlier bench hid -- NON-ZERO power-up
// state (run with --x-initial unique).  A real Z80 needs >= 3 running clocks
// of /RESET; A-Z80's resets.v clears PC only once the sequencer reaches M1.T2.
`timescale 1ns/1ps
module tb_az80_hwreset;
   logic clk_sdram = 0;  always #5.8207 clk_sdram = ~clk_sdram;
   logic [1:0] div4 = 0;  logic clk21m = 0;
   always @(posedge clk_sdram) begin div4 <= div4 + 1'd1; if (div4[0]) clk21m <= ~clk21m; end
   logic reset = 1;  logic [2:0] cpu_speed = 3'd0;  wire az80_clk;  wire [2:0] speed_q;
   az80_clkgen clkgen (.clk_sdram(clk_sdram), .clk21m(clk21m), .reset(reset), .pause(1'b0), .cpu_speed(cpu_speed),
                       .cpu_bus_idle(1'b1), .az80_clk(az80_clk), .cpu_speed_q(speed_q));
   // ---- msx.sv reset synchroniser, selectable stretch ----
   int stretch = 2;
   logic [4:0] rst_cnt = 5'd31;
   always @(posedge az80_clk, posedge reset) begin
      if (reset) rst_cnt <= 5'd31;
      else if (rst_cnt != 0) rst_cnt <= rst_cnt - 1'd1;
   end
   wire az_reset = (rst_cnt > (5'd31 - stretch[4:0]));   // stays high for `stretch` clocks
   wire halt_n, busak_n, m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n;
   wire [15:0] a;  wire [7:0] do_;  logic [7:0] di;
   az80_wrapper cpu (.clk(az80_clk), .reset(az_reset), .wait_n(1'b1), .int_n(1'b1),
                     .nmi_n(1'b1), .busrq_n(1'b1), .m1_n(m1_n), .mreq_n(mreq_n),
                     .iorq_n(iorq_n), .rd_n(rd_n), .wr_n(wr_n), .rfsh_n(rfsh_n),
                     .halt_n(halt_n), .busak_n(busak_n), .a(a), .di(di), .do_(do_));
   logic [7:0] mem [0:255];  logic [7:0] q;
   always @(posedge clk21m) begin if (!mreq_n && !wr_n) mem[a[7:0]] <= do_; q <= mem[a[7:0]]; end
   always_comb di = q;
   int errors = 0, n, clocks;  logic [15:0] first_a;  logic got_first = 0;
   always @(posedge az80_clk) begin clocks++; if (!got_first && !m1_n && !mreq_n) begin first_a <= a; got_first <= 1; end end
   task automatic run_at(input int st);
      begin
         reset = 1; stretch = st;
         for (int i = 0; i < 256; i++) mem[i] = 8'h00;
         mem['h00]=8'h21; mem['h01]=8'h80; mem['h02]=8'h00; mem['h03]=8'h06; mem['h04]=8'h0A;
         mem['h05]=8'hAF; mem['h06]=8'h80; mem['h07]=8'h10; mem['h08]=8'hFD; mem['h09]=8'h77;
         mem['h0A]=8'h3E; mem['h0B]=8'h00; mem['h0C]=8'h7E; mem['h0D]=8'h32; mem['h0E]=8'h81;
         mem['h0F]=8'h00; mem['h10]=8'h76;
         repeat (400) @(posedge clk_sdram);
         clocks = 0; got_first = 0;
         reset = 0;
         n = 0; while (!halt_n && n < 100000) begin @(posedge clk_sdram); n++; end
         n = 0; while (halt_n && n < 400000) begin @(posedge clk_sdram); n++; end
         $write("  stretch=%0d  halt=%s clocks=%0d firstM1=%04h mem80=%02h mem81=%02h",
                st, halt_n ? "NO " : "yes", clocks, first_a, mem['h80], mem['h81]);
         if (halt_n || mem['h80] !== 8'h37 || mem['h81] !== 8'h37) begin $display("   FAIL"); errors++; end
         else $display("");
      end
   endtask
   initial begin
      $display("=== tb_az80_hwreset: clock stopped in reset, N clocks of /RESET after restart ===");
      run_at(2); run_at(3); run_at(4); run_at(8); run_at(16);
      if (errors) $display("tb_az80_hwreset: %0d of 5 FAILED", errors); else $display("tb_az80_hwreset: PASS");
      $finish;
   end
endmodule
