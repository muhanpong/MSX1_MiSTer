// CRITIC TB #3 — can a CPU write DURING a sector erase hijack the 0xFF fill?
// flash.sv:178  `else if ((quadrupleProgram | write_cnt > 0) & we & ~old_we & ce)`
// write_cnt is non-zero for the WHOLE erase, and erase_block is 0 for all but the
// first cycle, so the else-branch is live during the fill.
`timescale 1ns/1ps
`default_nettype none
module tb_hijack;
   logic clk=0;
   logic [22:0] addr=0; logic [7:0] din=0;
   wire [7:0] dout; wire data_valid;
   logic we=0, ce=1;
   logic sdram_ready=1; logic sdram_done=0;
   wire [26:0] sdram_addr; wire [7:0] sdram_din; wire sdram_req;
   wire debug_erase;
   flash dut(.clk(clk), .clk_sdram(clk), .addr(addr), .din(din), .dout(dout),
             .data_valid(data_valid), .we(we), .ce(ce),
             .sdram_ready(sdram_ready), .sdram_done(sdram_done),
             .sdram_addr(sdram_addr), .sdram_din(sdram_din), .sdram_req(sdram_req),
             .sdram_offset(27'h0C00000), .amd_family(1'b1), .boot_sector(1'b0),
             .erase_limit(27'h800000), .debug_erase(debug_erase));
   always #5 clk = ~clk;

   int nwr; longint lo=64'h7fffffff, hi=0; int nff, nother;
   always @(posedge clk) begin
      sdram_done <= 1'b0;
      if (sdram_req & ~sdram_done) begin
         sdram_done <= 1'b1; nwr++;
         if (sdram_addr < lo) lo = sdram_addr;
         if (sdram_addr > hi) hi = sdram_addr;
         if (sdram_din == 8'hFF) nff++; else nother++;
      end
   end
   task automatic w(input [22:0] a, input [7:0] d);
      begin @(negedge clk); addr=a; din=d; we=1; repeat(3) @(posedge clk);
            @(negedge clk); we=0; repeat(2) @(posedge clk); end
   endtask
   initial begin
      repeat(4) @(posedge clk);
      // erase sector 0x20 (0x200000..0x20FFFF)
      w(23'h00AAA,8'hAA); w(23'h00554,8'h55); w(23'h00AAA,8'h80);
      w(23'h00AAA,8'hAA); w(23'h00554,8'h55); w(23'h200000,8'h30);
      // let the fill run ~200 bytes, then inject ONE ordinary CPU write far away
      repeat(600) @(posedge clk);
      $display("mid-erase: %0d bytes filled so far, cursor at 0x%07h", nwr, sdram_addr);
      w(23'h7F0000, 8'h42);           // any write to the cart window during the erase
      while (debug_erase) @(posedge clk);
      repeat(4) @(posedge clk);
      $display("erase finished: %0d writes, span 0x%07h..0x%07h", nwr, lo[26:0], hi[26:0]);
      $display("  bytes written as 0xFF        : %0d", nff);
      $display("  bytes written as SOMETHING ELSE: %0d", nother);
      if (hi > 27'h0C0FFFF+27'h1400000) ;
      if (nother > 1 || hi[26:0] > 27'h0C10000)
         $display("RESULT: *** ERASE HIJACKED -- fill jumped and/or wrote non-0xFF ***");
      else $display("RESULT: erase not hijacked");
      $finish;
   end
endmodule
`default_nettype wire
