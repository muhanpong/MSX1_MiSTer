//  memory_upload: what a FAILED firmware search costs the rest of the pack.
//
//  A device record for MoonSound with no inline ROM sends the uploader on an
//  excursion: it saves its place in save_addr, jumps to the firmware store at
//  DDR3 0x2000000 and looks for a pack there.  Three paths come back and only
//  one of them -- the one that found and filled a ROM -- clears save_addr.  The
//  end-of-store path and the "Havarie" path restore the address and leave the
//  flag set.
//
//  STATE_READ_CONF gates the end-of-pack test on save_addr == 0, and the
//  load_sram pulse sits inside that test.  So if the flag is left set, the
//  records after the device are never recognised: no CONFIG, which means
//  bios_config.MSX_typ keeps its zero value of MSX1 and the machine gets the
//  TMS9918; no KBD_LAYOUT; and no .sav auto-load, ever, because nothing asks
//  again.
//
//  Both shipped FS-A1ST and FS-A1GT packs carry the trigger, and 35 machine
//  XMLs declare MoonSound without an inline ROM.  The condition is simply
//  whether a firmware pack has been loaded: with one, the search succeeds and
//  nothing is lost, which is why this has never been seen on hardware.
`timescale 1ns/1ps

module tb_fwsearch;

   //  createMSXpack: DEVICE_TYPES.index("MOONSOUND") - 1
   localparam int DEV_MOONSOUND_I = 3;
   //  createMSXpack: EXTENSIONS.index("MOONSOUND")
   localparam int FW_MOONSOUND    = 8;  // data_ID_t'(ROM_MOONSOUND)
   localparam int FW_FMPAC        = 4;  // data_ID_t'(ROM_FMPAC)
   localparam     FW_BASE         = 28'h2000000;

   logic clk = 0;
   always #5 clk = ~clk;

   // ---- DDR3 model, two regions -------------------------------------------
   localparam int MEMSZ = 4096, FWSZ = 32768;
   logic [7:0] mem   [MEMSZ];
   logic [7:0] fwmem [FWSZ];
   logic [27:0] ddr3_addr;
   logic        ddr3_rd, ddr3_wr, ddr3_request;
   logic  [7:0] ddr3_dout = 8'hFF;
   logic        ddr3_ready = 1'b0;
   int rdiv = 0;
   always @(posedge clk) begin
      rdiv <= (rdiv == 3) ? 0 : rdiv + 1;
      ddr3_ready <= (rdiv == 3);
      if (ddr3_ready && ddr3_rd)
         ddr3_dout <= (ddr3_addr >= FW_BASE)
                    ? (((ddr3_addr - FW_BASE) < FWSZ) ? fwmem[ddr3_addr - FW_BASE] : 8'hFF)
                    : ((ddr3_addr < MEMSZ) ? mem[ddr3_addr] : 8'hFF);
   end

   // ---- interface ----------------------------------------------------------
   logic        ioctl_download = 0;
   logic [15:0] ioctl_index    = 0;
   logic [26:0] ioctl_addr     = 0;
   logic        rom_eject = 0, reload = 0;
   logic [26:0] ram_addr;
   logic  [7:0] ram_din;
   logic        ram_ce, sdram_rq, bram_rq;
   logic        sdram_ready = 1'b1;
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
      //  hold_load comes from save_guard on the real machine and defers the start of a
      //  load while a save is in flight (load_go = (load | load_defer) & ~hold_load).
      //  These cases are all "no save in progress", so it is tied low -- deliberately,
      //  and stated, because an unconnected input reads 0 and looks the same.  A
      //  deferred load is not covered here; the search paths run identically once the
      //  load starts, so it does not affect what this bench shows.
      .hold_load(1'b0),
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

   //  state trace, on demand
   logic trace = 1'b0;
   logic [3:0] st_p = 4'd0;
   always @(posedge clk) begin
      if (trace && dut.state != st_p)
         $display("      T state %0d -> %0d  ddr3_addr=%07x save_addr=%07x conf0..3=%02x %02x %02x %02x",
                  st_p, dut.state, ddr3_addr, dut.save_addr,
                  dut.conf[0], dut.conf[1], dut.conf[2], dut.conf[3]);
      st_p <= dut.state;
   end

   //  load_sram is one clock wide; latch it for the whole run.
   logic saw_load_sram = 1'b0;
   always @(posedge clk) if (load_sram) saw_load_sram <= 1'b1;

   // ---- pack builders ------------------------------------------------------
   int wp;
   task automatic pack_clear();
      wp = 0;
      for (int i = 0; i < MEMSZ; i++) mem[i] = 8'h00;
   endtask
   task automatic rec_device_norom(input int dev_idx);
      mem[wp+0]='h4D; mem[wp+1]='h53; mem[wp+2]='h58;
      mem[wp+3]=8'h70;                       // CONFIG_TYPES.index("DEVICE") << 4
      mem[wp+4]=0; mem[wp+5]=0; mem[wp+6]=0; // size 0: no inline ROM
      mem[wp+7]=8'(dev_idx);
      for (int i=8;i<16;i++) mem[wp+i]=0;
      wp += 16;
   endtask
   task automatic rec_config(input logic [7:0] cfg);
      mem[wp+0]='h4D; mem[wp+1]='h53; mem[wp+2]='h58;
      mem[wp+3]=8'h60;                       // CONFIG_TYPES.index("CONFIG") << 4
      mem[wp+4]=cfg;                         // MSX_typ in bits 5:4
      for (int i=5;i<16;i++) mem[wp+i]=0;
      wp += 16;
   endtask

   //  empty = whatever a machine holds when no firmware pack was ever loaded
   task automatic fw_empty();
      for (int i = 0; i < FWSZ; i++) fwmem[i] = 8'h00;
   endtask
   //  one firmware record of a single 16 kB block, the way createFWpack writes it
   task automatic fw_one(input int dat_id);
      fw_empty();
      fwmem[0]='h4D; fwmem[1]='h53; fwmem[2]='h58;
      fwmem[3]=8'h00;
      fwmem[4]=8'(dat_id);
      fwmem[5]=8'h00; fwmem[6]=8'h01;        // size >> 14 == 1 block
      for (int i=7;i<16;i++) fwmem[i]=0;
      for (int i=16;i<16+16384;i++) fwmem[i] = 8'(i & 8'hFF);
   endtask
   task automatic fw_valid();   fw_one(FW_MOONSOUND); endtask
   task automatic fw_other();   fw_one(FW_FMPAC);     endtask

   task automatic do_load(input int idx, input int size);
      ioctl_index = 16'(idx);
      ioctl_download = 1; repeat (20) @(posedge clk);
      ioctl_addr = 27'(size);
      ioctl_download = 0;
      //  Wait for the FSM to start and then to finish.  The bound has to clear
      //  the MoonSound success path, which ends in a 2 MB zero-fill of the
      //  custom-wave RAM -- a couple of million byte writes.
      begin
         int t;
         for (t = 0; t < 200_000; t++) begin @(posedge clk); if (reset_rq) break; end
         for (t = 0; t < 60_000_000; t++) begin @(posedge clk); if (!reset_rq) break; end
         if (reset_rq) $display("  !! still busy after %0d clocks, state=%0d", t, dut.state);
      end
      repeat (50) @(posedge clk);
   endtask

   int errors = 0;
   task automatic ck(input string what, input logic ok);
      if (!ok) begin errors++; $display("FAIL  %s", what); end
      else                     $display("ok    %s", what);
   endtask

   initial begin
      repeat (10) @(posedge clk);
      fw_empty();

      //  ---- control: a pack with no device at all must be green -----------
      pack_clear(); rec_config(8'h00);           // MSX1
      saw_load_sram = 1'b0;
      do_load(1, wp);
      $display("  0: MSX_typ=%0d  load_sram seen=%0d", bios_config.MSX_typ, saw_load_sram);
      ck("0  CONFIG is parsed with no device present", bios_config.MSX_typ == MSX1);
      ck("0  the .sav auto-load is requested",         saw_load_sram);

      //  ---- case A: no firmware pack was ever loaded ----------------------
      pack_clear(); rec_device_norom(DEV_MOONSOUND_I); rec_config(8'h10);
      fw_empty();                             // and no index-2 download: size 0
      trace = 1'b1;
      saw_load_sram = 1'b0;
      do_load(1, wp);
      $display("  A: MSX_typ=%0d  load_sram seen=%0d", bios_config.MSX_typ, saw_load_sram);
      ck("A  CONFIG is parsed (MSX_typ becomes MSX2)", bios_config.MSX_typ == MSX2);
      ck("A  the .sav auto-load is requested",         saw_load_sram);
      trace = 1'b0;

      //  ---- case B: a firmware pack is in the store ------------------------
      pack_clear(); rec_device_norom(DEV_MOONSOUND_I); rec_config(8'h10);
      fw_valid();
      do_load(2, 16 + 16384);                  // tells the search where the store ends
      saw_load_sram = 1'b0;
      do_load(1, wp);
      $display("  B: MSX_typ=%0d  load_sram seen=%0d", bios_config.MSX_typ, saw_load_sram);
      ck("B  CONFIG is parsed (MSX_typ becomes MSX2)", bios_config.MSX_typ == MSX2);
      ck("B  the .sav auto-load is requested",         saw_load_sram);

      //  ---- case C: a store that parses but holds a different ROM ----------
      //  This walks to the end of the store and takes the other return site.
      pack_clear(); rec_device_norom(DEV_MOONSOUND_I); rec_config(8'h00);
      fw_other();
      do_load(2, 16 + 16384);
      saw_load_sram = 1'b0;
      do_load(1, wp);
      $display("  C: MSX_typ=%0d  load_sram seen=%0d", bios_config.MSX_typ, saw_load_sram);
      ck("C  CONFIG is parsed (MSX_typ goes back to MSX1)", bios_config.MSX_typ == MSX1);
      ck("C  the .sav auto-load is requested",              saw_load_sram);

      $display("RESULT: %0d error(s)", errors);
      $finish;
   end

endmodule
