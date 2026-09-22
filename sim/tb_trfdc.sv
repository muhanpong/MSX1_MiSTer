// tb_trfdc -- the TURBOR_FDC block: mapper_msxdos2 (7FF0-only) and the fdc block
// (WD2793, Sony register layout 7FF8-7FFF) sharing ONE page-1 window, the way
// msx_slots wires them when a pack block is MEMORY=FDC + MAPPER_TRFDC.
//
// What the turbo R disk ROM (openMSX TurboRFDC.cc) guarantees and this checks:
//   * a write to 7FF0 selects the 16 kB bank and is NOT seen by the FDC,
//   * WD2793 register traffic at 7FF8-7FFF does NOT move the bank,
//   * 7FF0-7FF7 reads are not claimed by the FDC (the kernel never reads them,
//     but the bus must not float a wrong output_en),
//   * a read at 7FFF is the Sony DRQ/IRQ status byte, claimed by the FDC,
//   * reset parks bank 0 (the DOS 2 kernel bank, where INIT lives).
// Reference: tools/turbor_diskrom/README.md, docs/turbor_diskrom_20260923.md.
`timescale 1ns/1ps
module tb_trfdc;
   logic        clk = 0, reset = 1, mreq = 0, wr = 0, rd = 0;
   logic [15:0] a = 0;
   logic  [7:0] d = 0;
   wire  [24:0] mem_addr;
   wire         mem_unmaped, fdc_oe;
   wire   [7:0] fdc_dout;
   int          fails = 0, checks = 0;

   mapper_msxdos2 map (.clk(clk), .reset(reset), .rom_size(25'd65536),
                       .cpu_addr(a), .din(d), .cpu_mreq(mreq), .cpu_wr(wr),
                       .cs(1'b1), .win_7ff0_only(1'b1),
                       .mem_unmaped(mem_unmaped), .mem_addr(mem_addr));

   // fdc.sv: cs is `device == DEVICE_FDC`, address is the page offset.
   wire [31:0] sd_lba; wire sd_rd, sd_wr; wire [7:0] sd_buff_din;
   fdc fdc (.clk(clk), .reset(reset), .clk_en(1'b1), .cs(a[15:14] == 2'b01),
            .addr(a[13:0]), .d_from_cpu(d), .d_to_cpu(fdc_dout), .output_en(fdc_oe),
            .rd(rd & mreq), .wr(wr & mreq),
            .img_mounted(1'b0), .img_size(32'd0), .img_readonly(1'b0),
            .sd_lba(sd_lba), .sd_rd(sd_rd), .sd_wr(sd_wr), .sd_ack(1'b0),
            .sd_buff_addr(9'd0), .sd_buff_dout(8'h00), .sd_buff_din(sd_buff_din), .sd_buff_wr(1'b0));

   always #5 clk = ~clk;

   task check(input bit cond, input string what);
      begin checks++; if (!cond) begin $display("FAIL %s", what); fails++; end end
   endtask
   task write(input [15:0] addr, input [7:0] val);
      begin a = addr; d = val; mreq = 1; wr = 1; @(negedge clk); wr = 0; mreq = 0; @(negedge clk); end
   endtask
   task read(input [15:0] addr);
      begin a = addr; mreq = 1; rd = 1; @(negedge clk); #1; end
   endtask
   task idle; begin rd = 0; mreq = 0; @(negedge clk); end endtask

   initial begin
      repeat (3) @(negedge clk); reset = 0; @(negedge clk);

      read(16'h4000); check(mem_addr == 25'h0000000 && !mem_unmaped, "reset: page 1 = bank 0 (DOS 2 kernel)"); idle;

      // bank register: mapper yes, FDC no
      write(16'h7FF0, 8'd3);
      read(16'h4000); check(mem_addr == 25'h000C000, "7FF0 <- 3 selects bank 3 (DOS 1 kernel + hb driver)");
      check(!fdc_oe, "7FF0 is not an FDC register");
      idle;
      read(16'h7FF0); check(!fdc_oe, "reading 7FF0 is not claimed by the FDC"); idle;
      read(16'h7FF4); check(!fdc_oe, "7FF4 (was TC8566AF MSR) is plain ROM here"); idle;

      // WD2793 traffic: FDC yes, bank no
      write(16'h7FF8, 8'hD0);                          // FORCE INTERRUPT
      write(16'h7FFA, 8'h03);                          // SECTOR
      write(16'h7FFC, 8'h01);                          // side latch
      write(16'h7FFD, 8'h80);                          // motor on, drive 0
      read(16'h4000); check(mem_addr == 25'h000C000, "WD2793 register writes do not move the bank"); idle;
      read(16'h7FFF); check(fdc_oe, "7FFF status is claimed by the FDC");
      check(fdc_dout[5:0] == 6'b111111, "7FFF low bits read as 1 (Sony layout)"); idle;
      read(16'h7FFC); check(fdc_oe && fdc_dout == 8'h01, "7FFC side latch reads back"); idle;
      read(16'h7FFD); check(fdc_oe && fdc_dout == (8'h80 & 8'hFB), "7FFD drive latch reads back (bit2 masked)"); idle;

      // the bank stub in every bank is `LD (7FF0),A / RET` -- back to bank 0
      write(16'h7FF0, 8'd0);
      read(16'h4000); check(mem_addr == 25'h0000000, "7FF0 <- 0 returns to bank 0"); idle;

      // reset while parked in bank 1 (message bank) -> bank 0 again
      write(16'h7FF0, 8'd1);
      reset = 1; @(negedge clk); reset = 0; @(negedge clk);
      read(16'h4000); check(mem_addr == 25'h0000000, "reset returns to bank 0"); idle;

      $display("%0d checks, %0d failed", checks, fails);
      if (fails) begin $display("FAILED"); $fatal(1); end
      $display("PASSED");
      $finish;
   end
endmodule
