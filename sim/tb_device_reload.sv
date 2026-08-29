//  tb_device_reload -- does msx_device survive a SLOT A/B ROM load?
//
//  `load` in memory_upload fires for ioctl_index 1 (machine pack), 2 (FW pack)
//  AND 3/4 (SLOT A/B ROM).  msx_device is OR-accumulated while walking the
//  machine pack's config records.  Two properties must BOTH hold:
//
//     P1  after a machine pack load, msx_device names that pack's devices
//     P2  after a plain ROM load, msx_device STILL names them
//
//  P2 is the one nobody checked.  Clearing msx_device in the `load` block
//  satisfies P1's "no leak" reading but broke P2 on hardware
//  (MSX1_20260830b_devclear vs 30a: Konami-mapper games died on 3.58 machines).
//  See docs/TODO_msx_device_leak.md.
//
//  A third property is what the clear was meant to buy:
//
//     P3  after loading pack B, msx_device does NOT still name pack A's devices
//
//  Build with +define+CLEARFIX to model the reverted one-line "fix" and see
//  which of the three it actually trades away.

`timescale 1ns/1ps

module tb_device_reload;

   // device indices as emitted by createMSXpack: DEVICE_TYPES.index(t) - 1
   localparam int DEV_KANJI_I = 0, DEV_OPL3_I = 1, DEV_RESET_I = 2, DEV_MATSU_I = 4;

   logic clk = 0;
   always #5 clk = ~clk;

   // ---- DDR3 model ---------------------------------------------------------
   localparam int MEMSZ = 4096;
   logic [7:0] mem [MEMSZ];
   logic [27:0] ddr3_addr;
   logic        ddr3_rd, ddr3_wr, ddr3_request;
   logic  [7:0] ddr3_dout = 8'hFF;
   logic        ddr3_ready = 1'b0;

   // ready is a periodic grant, exactly as the DDR3 arbiter gives it
   int rdiv = 0;
   always @(posedge clk) begin
      rdiv <= (rdiv == 3) ? 0 : rdiv + 1;
      ddr3_ready <= (rdiv == 3);
      if (ddr3_ready && ddr3_rd)
         ddr3_dout <= (ddr3_addr < MEMSZ) ? mem[ddr3_addr] : 8'hFF;
   end

   // ---- ioctl -------------------------------------------------------------
   logic        ioctl_download = 0;
   logic [15:0] ioctl_index    = 0;
   logic [26:0] ioctl_addr     = 0;

   // ---- the rest of the interface ----------------------------------------
   logic        rom_eject = 0, reload = 0;
   logic [26:0] ram_addr;
   logic  [7:0] ram_din;
   logic        ram_ce, sdram_rq, bram_rq;
   logic        sdram_ready = 1'b1;      // never stall the fill path
   logic        kbd_request, kbd_we, load_sram, reset_rq;
   logic  [8:0] kbd_addr;
   logic  [7:0] kbd_din;
   logic  [1:0] sdram_size = 2'd2;
   MSX::block_t        slot_layout[64];
   MSX::lookup_RAM_t   lookup_RAM[16];
   MSX::lookup_SRAM_t  lookup_SRAM[4];
   MSX::bios_config_t  bios_config;
   MSX::config_cart_t  cart_conf[2];
   logic  [1:0] rom_loaded, rom_big;
   dev_typ_t    cart_device[2], msx_device;
   logic  [3:0] msx_dev_ref_ram[8];
   logic [26:0] pcm_rom_base;

   memory_upload dut (
      .clk(clk), .reset_rq(reset_rq),
      .ioctl_download(ioctl_download), .ioctl_index(ioctl_index), .ioctl_addr(ioctl_addr),
      .rom_eject(rom_eject), .reload(reload),
      .ddr3_addr(ddr3_addr), .ddr3_rd(ddr3_rd), .ddr3_wr(ddr3_wr),
      .ddr3_dout(ddr3_dout), .ddr3_ready(ddr3_ready), .ddr3_request(ddr3_request),
      .ram_addr(ram_addr), .ram_din(ram_din), .ram_dout(8'h00), .ram_ce(ram_ce),
      .sdram_ready(sdram_ready), .sdram_rq(sdram_rq), .bram_rq(bram_rq),
      .kbd_request(kbd_request), .kbd_addr(kbd_addr), .kbd_din(kbd_din), .kbd_we(kbd_we),
      .sdram_size(sdram_size), .load_sram(load_sram),
      .slot_layout(slot_layout), .lookup_RAM(lookup_RAM), .lookup_SRAM(lookup_SRAM),
      .bios_config(bios_config), .cart_conf(cart_conf),
      .rom_loaded(rom_loaded), .rom_big(rom_big),
      .cart_device(cart_device), .msx_device(msx_device),
      .msx_dev_ref_ram(msx_dev_ref_ram), .pcm_rom_base(pcm_rom_base)
   );

   // ---- pack builders ------------------------------------------------------
   int wp;
   task automatic rec_clear();  wp = 0; for (int i = 0; i < MEMSZ; i++) mem[i] = 8'h00; endtask
   task automatic rec_device(input int dev_idx);
      mem[wp+0]='h4D; mem[wp+1]='h53; mem[wp+2]='h58;     // "MSX"
      mem[wp+3]=8'h70;                                    // CONFIG_TYPES.index("DEVICE")<<4
      mem[wp+4]=0; mem[wp+5]=0; mem[wp+6]=0;              // no inline ROM
      mem[wp+7]=8'(dev_idx);
      for (int i=8;i<16;i++) mem[wp+i]=0;
      wp += 16;
   endtask
   task automatic rec_config();
      mem[wp+0]='h4D; mem[wp+1]='h53; mem[wp+2]='h58;
      mem[wp+3]=8'h60;                                    // CONFIG_TYPES.index("CONFIG")<<4
      mem[wp+4]=8'h10;                                    // MSX2, no expander
      for (int i=5;i<16;i++) mem[wp+i]=0;
      wp += 16;
   endtask

   task automatic do_load(input int idx, input int size);
      ioctl_index = 16'(idx);
      ioctl_download = 1; repeat (20) @(posedge clk);
      ioctl_addr = 27'(size);
      ioctl_download = 0;                                 // falling edge -> load
      repeat (4) @(posedge clk);
      // run until the FSM parks
      for (int t = 0; t < 200000; t++) begin
         @(posedge clk);
         if (!reset_rq) break;
      end
      repeat (20) @(posedge clk);
   endtask

   int errors = 0;
   task automatic ck(input string what, input logic ok);
      if (!ok) begin errors++; $display("FAIL  %s", what); end
      else                     $display("ok    %s", what);
   endtask

   initial begin
      // cart_conf is never read by this synthetic pack (no SLOT_A/B records)
      repeat (10) @(posedge clk);

      // ---- pack A: KANJI + RESET_STATUS ----------------------------------
      rec_clear(); rec_device(DEV_KANJI_I); rec_device(DEV_RESET_I); rec_config();
      do_load(1, wp);
      $display("  after pack A load : msx_device = %04X", msx_device);
      ck("P1  pack A devices present (KANJI)",  msx_device[DEV_KANJI_I]);
      ck("P1  pack A devices present (RESET)",  msx_device[DEV_RESET_I]);

      // ---- now a plain SLOT A ROM load, pack bytes unchanged -------------
      do_load(3, 32768);
      $display("  after ROM load    : msx_device = %04X", msx_device);
      ck("P2  KANJI survives a ROM load",       msx_device[DEV_KANJI_I]);
      ck("P2  RESET survives a ROM load",       msx_device[DEV_RESET_I]);

      // ---- pack B: only MATSUSHITA ---------------------------------------
      rec_clear(); rec_device(DEV_MATSU_I); rec_config();
      do_load(1, wp);
      $display("  after pack B load : msx_device = %04X", msx_device);
      ck("P1  pack B device present (MATSU)",   msx_device[DEV_MATSU_I]);
      ck("P3  pack A's KANJI is gone",         !msx_device[DEV_KANJI_I]);
      ck("P3  pack A's RESET is gone",         !msx_device[DEV_RESET_I]);

      $display("errors=%0d", errors);
      if (errors) $fatal(1, "tb_device_reload FAILED (%0d)", errors);
      $display("tb_device_reload PASSED");
      $finish;
   end

endmodule
