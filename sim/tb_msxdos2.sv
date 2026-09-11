// MSX-DOS 2 ROM mapper: one 16 kB block at page 1, one bank register.
//
// The expected behaviour is written from openMSX RomMSXDOS2.cc -- reset parks
// block 0 at page 1, pages 0/2/3 are unmapped, and a write in any of the three
// documented windows sets the block -- not from a reading of msxdos2.sv.
`timescale 1ns/1ps
module tb_msxdos2;

   logic        clk = 0, reset = 1, cpu_mreq = 0, cpu_wr = 0, cs = 1;
   logic [15:0] cpu_addr = 0;
   logic  [7:0] din = 0;
   logic [24:0] rom_size = 25'd65536;        // 4 blocks, the real DOS 2 ROMs
   wire  [24:0] mem_addr;
   wire         mem_unmaped;
   int          fails = 0, checks = 0;

   mapper_msxdos2 dut (.clk(clk), .reset(reset), .rom_size(rom_size),
                       .cpu_addr(cpu_addr), .din(din), .cpu_mreq(cpu_mreq),
                       .cpu_wr(cpu_wr), .cs(cs),
                       .mem_unmaped(mem_unmaped), .mem_addr(mem_addr));

   always #5 clk = ~clk;

   task check(input [24:0] want_addr, input bit want_unmap, input string what);
      begin
         checks++;
         #1;
         if (mem_addr !== want_addr || mem_unmaped !== want_unmap) begin
            $display("FAIL %-40s addr=%07h/%b want=%07h/%b",
                     what, mem_addr, mem_unmaped, want_addr, want_unmap);
            fails++;
         end
      end
   endtask

   task look(input [15:0] a);
      begin cpu_addr = a; cpu_mreq = 1; cpu_wr = 0; @(negedge clk); end
   endtask

   task bankwr(input [15:0] a, input [7:0] d);
      begin
         cpu_addr = a; din = d; cpu_mreq = 1; cpu_wr = 1;
         @(negedge clk); cpu_wr = 0; cpu_mreq = 0; @(negedge clk);
      end
   endtask

   initial begin
      repeat (3) @(negedge clk);
      reset = 0; @(negedge clk);

      // 1..2 -- reset parks block 0 at page 1
      look(16'h4000); check(25'h0000000, 1'b0, "reset: 4000 -> block 0");
      look(16'h7FFF); check(25'h0003FFF, 1'b0, "reset: 7FFF -> block 0 end");

      // 3..5 -- only page 1 is mapped
      look(16'h0000); check(25'h0000000, 1'b1, "page 0 unmapped");
      look(16'h8000); check(25'h0000000, 1'b1, "page 2 unmapped");
      look(16'hC000); check(25'h0000000, 1'b1, "page 3 unmapped");

      // 6..8 -- each of the three documented bank windows
      bankwr(16'h6000, 8'd1); look(16'h4000); check(25'h0004000, 1'b0, "6000 window banks");
      bankwr(16'h7FF0, 8'd2); look(16'h4000); check(25'h0008000, 1'b0, "7FF0 banks");
      bankwr(16'h7FFE, 8'd3); look(16'h4000); check(25'h000C000, 1'b0, "7FFE banks");

      // 9 -- anywhere inside 6000-6FFF, not just the first byte
      bankwr(16'h6ABC, 8'd1); look(16'h4000); check(25'h0004000, 1'b0, "6ABC banks too");

      // 10..11 -- addresses that must NOT bank
      bankwr(16'h7000, 8'd2); look(16'h4000); check(25'h0004000, 1'b0, "7000 does not bank");
      bankwr(16'h5000, 8'd2); look(16'h4000); check(25'h0004000, 1'b0, "5000 does not bank");

      // 12 -- a write with cs low belongs to another slot
      cs = 0; bankwr(16'h6000, 8'd3); cs = 1;
      look(16'h4000); check(25'h0004000, 1'b0, "write ignored when cs low");

      // 13 -- offset inside the block follows the low 14 bits
      bankwr(16'h6000, 8'd2); look(16'h5234); check(25'h0009234, 1'b0, "offset within block");

      // 14..15 -- a block past the end of the ROM wraps, it does not read off it
      bankwr(16'h6000, 8'd4); look(16'h4000); check(25'h0000000, 1'b0, "block 4 of 4 wraps to 0");
      bankwr(16'h6000, 8'd7); look(16'h4000); check(25'h000C000, 1'b0, "block 7 of 4 wraps to 3");

      // 16 -- and the wrap follows the declared size, not a fixed mask
      rom_size = 25'd32768;                    // 2 blocks
      bankwr(16'h6000, 8'd3); look(16'h4000); check(25'h0004000, 1'b0, "2-block ROM wraps to 1");

      // 17 -- reset returns to block 0
      rom_size = 25'd65536;
      bankwr(16'h6000, 8'd3);
      reset = 1; @(negedge clk); reset = 0; @(negedge clk);
      look(16'h4000); check(25'h0000000, 1'b0, "reset returns to block 0");

      $display("%0d checks, %0d failed", checks, fails);
      if (fails) begin $display("FAILED"); $fatal(1); end
      $display("PASSED");
      $finish;
   end
endmodule
