// CRITIC TB #1 — flash.sv sector-erase span for a UNIFORM-sector part
// (boot_sector = 0, exactly how msx_slots.sv drives it for Yamanooto).
// Models the ch1 SDRAM handshake and records every byte the erase actually writes.
`timescale 1ns/1ps
`default_nettype none
module tb_erase_sector;
   logic clk=0, clk_sdram=0;
   logic [22:0] addr=0;
   logic [7:0]  din=0;
   wire  [7:0]  dout; wire data_valid;
   logic we=0, ce=1;
   logic sdram_ready=1; logic sdram_done=0;
   wire [26:0] sdram_addr; wire [7:0] sdram_din; wire sdram_req;
   logic [26:0] sdram_offset = 27'h0;
   logic amd_family=1, boot_sector=0;         // <- Yamanooto settings
   logic [26:0] erase_limit = 27'h800000;
   wire debug_erase;

   flash dut(.clk(clk), .clk_sdram(clk_sdram), .addr(addr), .din(din), .dout(dout),
             .data_valid(data_valid), .we(we), .ce(ce),
             .sdram_ready(sdram_ready), .sdram_done(sdram_done),
             .sdram_addr(sdram_addr), .sdram_din(sdram_din), .sdram_req(sdram_req),
             .sdram_offset(sdram_offset), .amd_family(amd_family),
             .boot_sector(boot_sector), .erase_limit(erase_limit),
             .debug_erase(debug_erase));
   always #5 clk = ~clk;

   // SDRAM slave: ack every request one cycle later, log the byte
   int    nwr; longint lo, hi;
   always @(posedge clk) begin
      sdram_done <= 1'b0;
      if (sdram_req & ~sdram_done) begin
         sdram_done <= 1'b1;
         nwr++;
         if (sdram_addr < lo) lo = sdram_addr;
         if (sdram_addr > hi) hi = sdram_addr;
      end
   end

   task automatic w(input [22:0] a, input [7:0] d);
      begin
         @(negedge clk); addr=a; din=d; we=1;
         repeat(3) @(posedge clk);
         @(negedge clk); we=0;
         repeat(2) @(posedge clk);
      end
   endtask

   int errors=0;
   task automatic erase_at(input [22:0] a, input [26:0] want_base);
      begin
         nwr=0; lo=64'h7fffffff; hi=-1;
         w(23'h00AAA, 8'hAA); w(23'h00554, 8'h55); w(23'h00AAA, 8'h80);
         w(23'h00AAA, 8'hAA); w(23'h00554, 8'h55);
         w(a,         8'h30);
         // run the fill to completion (64KB * ~3 cycles)
         while (debug_erase) @(posedge clk);
         repeat(4) @(posedge clk);
         $display("  confirm@0x%06h  filled 0x%07h..0x%07h (%0d bytes)  want base 0x%07h  %s",
                  a, lo[26:0], hi[26:0], nwr, want_base,
                  (lo[26:0]===want_base) ? "OK" : "*** WRONG SECTOR ***");
         if (lo[26:0] !== want_base) errors++;
      end
   endtask

   initial begin
      repeat(4) @(posedge clk);
      $display("uniform 64KB device (boot_sector=0, Yamanooto), sdram_offset=0");
      erase_at(23'h000000, 27'h0000000);   // sector 0, 8KB page 0
      erase_at(23'h002000, 27'h0000000);   // sector 0, 8KB page 1
      erase_at(23'h004000, 27'h0000000);   // sector 0, 8KB page 2
      erase_at(23'h00E000, 27'h0000000);   // sector 0, 8KB page 7
      erase_at(23'h010000, 27'h0010000);   // sector 1 base
      erase_at(23'h012000, 27'h0010000);   // sector 1, page 1
      erase_at(23'h1F0000, 27'h01F0000);   // sector 31
      $display("errors=%0d  -> %s", errors, errors ? "CONFIRMED BUG" : "no bug found");
      $finish;
   end
endmodule
`default_nettype wire
