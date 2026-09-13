// A-Z80 bring-up through az80_wrapper: does it execute, and is the
// unidirectional data-bus termination right in both directions?
// Same program shape as the NextZ80 bring-up: a computed value is stored and
// then read back, because a wrong read path leaves the store looking correct.
`timescale 1ns/1ps
module tb_az80_bringup;
   logic clk = 0;  always #139.7 clk = ~clk;      // 3.579545 MHz
   logic reset = 1;
   wire  m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n, halt_n, busak_n;
   wire [15:0] a;
   wire  [7:0] do_;
   logic [7:0] di;

   az80_wrapper dut (.clk(clk), .reset(reset), .wait_n(1'b1), .int_n(1'b1),
                     .nmi_n(1'b1), .busrq_n(1'b1),
                     .m1_n(m1_n), .mreq_n(mreq_n), .iorq_n(iorq_n), .rd_n(rd_n),
                     .wr_n(wr_n), .rfsh_n(rfsh_n), .halt_n(halt_n), .busak_n(busak_n),
                     .a(a), .di(di), .do_(do_));

   logic [7:0] mem [0:255];
   //  LD HL,0080h / LD B,10 / XOR A / loop: ADD A,B / DJNZ loop
   //  LD (HL),A / LD A,0 / LD A,(HL) / LD (0081h),A / HALT   -> sum 55 = 0x37
   initial begin
      for (int i = 0; i < 256; i++) mem[i] = 8'h00;
      mem['h00]=8'h21; mem['h01]=8'h80; mem['h02]=8'h00;
      mem['h03]=8'h06; mem['h04]=8'h0A;
      mem['h05]=8'hAF;
      mem['h06]=8'h80;
      mem['h07]=8'h10; mem['h08]=8'hFD;
      mem['h09]=8'h77;
      mem['h0A]=8'h3E; mem['h0B]=8'h00;
      mem['h0C]=8'h7E;
      mem['h0D]=8'h32; mem['h0E]=8'h81; mem['h0F]=8'h00;
      mem['h10]=8'h76;
   end

   //  Asynchronous memory: this bench is about the wrapper, not about latency.
   always_comb di = mem[a[7:0]];
   always @(posedge clk) if (!mreq_n && !wr_n) mem[a[7:0]] <= do_;

   int n = 0;
   initial begin
      repeat (10) @(posedge clk); reset = 0;
      while (halt_n && n < 20000) begin @(posedge clk); n++; end
      $display("=== tb_az80_bringup ===");
      $display("  halted   : %s after %0d clocks", halt_n ? "NO" : "yes", n);
      $display("  mem[80h] : %02h  expect 37", mem['h80]);
      $display("  mem[81h] : %02h  expect 37", mem['h81]);
      if (halt_n)                  $display("tb_az80_bringup: FAIL -- never halted");
      else if (mem['h80] !== 8'h37) $display("tb_az80_bringup: FAIL -- store path wrong");
      else if (mem['h81] !== 8'h37) $display("tb_az80_bringup: FAIL -- store fine, READ-BACK wrong");
      else                          $display("tb_az80_bringup: PASS");
      $finish;
   end
endmodule
