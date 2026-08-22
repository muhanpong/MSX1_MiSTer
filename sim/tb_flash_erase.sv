// tb_flash_erase — flash.sv erase sector geometry
//
// Every part this flash instance serves is BOTTOM-BOOT with the same map,
// 8 x 8KB then 127 x 64KB, per openMSX's chip table:
//   ASCII16X   S29GL064S70TFI040   RomAscii16X.cc:25            (AMD)
//   Yamanooto  S29GL064N90TFI04    Yamanooto.cc:38              (AMD)
//   MFRSD-SD   M29W640GB           MegaFlashRomSCCPlusSD.cc:274 (STM)
// They differ only in manufacturer id, which is the `amd_family` half of the
// split -- `boot_sector` is NOT a per-cart discriminator here.
//
// The defect this guards: `erase_boot` (the <<13 scaling at flash.sv erase_base)
// used to be gated on the ASCII16X path alone, so MFRSD computed the correct
// 8KB sector index and then scaled it by 16 bits -- a confirm at flash 0x2000
// erased 0x10000-0x1FFFF and left the intended sector un-erased.
//
//   sector base must be  addr & ~0x1FFF  below 64KB,  addr & ~0xFFFF above it.
//
// Negative control (NEGCTL=1) drives boot_sector=0, i.e. the old MFRSD gating;
// the low-64KB cases MUST then land on the wrong sector.
`timescale 1ns/1ps
`default_nettype none

module tb_flash_erase;
   logic clk=0, clk_sdram=0;
   logic [22:0] addr=0; logic [7:0] din=0;
   wire  [7:0] dout; wire data_valid;
   logic we=0, ce=1, sdram_ready=1, sdram_done=0;
   wire [26:0] sdram_addr; wire [7:0] sdram_din; wire sdram_req;
   logic [26:0] sdram_offset = 27'h0100000;
   logic amd_family = 1'b1;
`ifdef NEGCTL
   logic boot_sector = 1'b0;      // the old ASCII16X-only gating
`else
   logic boot_sector = 1'b1;      // every part here is bottom-boot
`endif
   logic [26:0] erase_limit = 27'h800000;
   wire debug_erase;

   flash dut(.clk(clk),.clk_sdram(clk_sdram),.addr(addr),.din(din),.dout(dout),
     .data_valid(data_valid),.we(we),.ce(ce),.sdram_ready(sdram_ready),.sdram_done(sdram_done),
     .sdram_addr(sdram_addr),.sdram_din(sdram_din),.sdram_req(sdram_req),
     .sdram_offset(sdram_offset),.amd_family(amd_family),.boot_sector(boot_sector),
     .erase_limit(erase_limit),.debug_erase(debug_erase));

   always #5 clk=~clk;
   int errors=0, checks=0;

   task automatic w(input [22:0] a, input [7:0] d);
      begin @(negedge clk); addr=a; din=d; we=1; @(posedge clk);
            @(negedge clk); we=0; repeat(2) @(posedge clk); end
   endtask

   task automatic erase_at(input [22:0] target, input string label, input [26:0] want_base);
      begin
         w(23'h000AAA,8'hAA); w(23'h000555,8'h55); w(23'h000AAA,8'h80);
         w(23'h000AAA,8'hAA); w(23'h000555,8'h55); w(target,   8'h30);
         repeat(4) @(posedge clk);
         begin
            automatic bit ok = (sdram_addr === sdram_offset + want_base);
            checks++; if (!ok) errors++;
            $display("  %-24s flash 0x%06h -> sdram 0x%07h (want 0x%07h) %s",
               label, target, sdram_addr, sdram_offset + want_base, ok ? "OK" : "FAIL");
         end
      end
   endtask

   initial begin
      repeat(4) @(posedge clk);
      $display("boot_sector=%0b  (bottom-boot: 8 x 8KB below 64KB, then 64KB sectors)", boot_sector);
      erase_at(23'h000000, "8KB sector 0",      27'h000000);
      erase_at(23'h002000, "8KB sector 1",      27'h002000);
      erase_at(23'h008000, "8KB sector 4",      27'h008000);
      erase_at(23'h00E000, "8KB sector 7",      27'h00E000);
      erase_at(23'h010000, "64KB sector start", 27'h010000);
      erase_at(23'h018000, "64KB sector inner", 27'h010000);
      erase_at(23'h7F0000, "top 64KB sector",   27'h7F0000);

      $display("");
      $display("tb_flash_erase: %0d checks, %0d errors", checks, errors);
`ifdef NEGCTL
      if (errors == 0)
         $fatal(1, "NEGCTL BROKEN: the old ASCII16X-only gating still passed. TB is worthless.");
      $display("negative control OK: %0d/%0d failed as required", errors, checks);
      $finish;
`else
      if (errors) $fatal(1, "tb_flash_erase: %0d of %0d checks FAILED", errors, checks);
      $finish;
`endif
   end
endmodule
`default_nettype wire
