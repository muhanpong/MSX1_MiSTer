//  memory_upload on a 32 MB board under sdram_tdm: does the biggest machine fit
//  below the VRAM bank?  (sdram128 study, 2026-10-13.)
//
//  sdram_tdm's 32 MB map gives bank 3 -- 24-32 MB -- to the V9968's VRAM
//  (docs/sdram_tdm_design.md section 3).  memory_upload allocates SDRAM linearly
//  from 0 and knows nothing of that.  This bench runs the real uploader over a
//  real machine pack, a real FW pack (yrw801.rom) and two cart ROMs, with an
//  SDRAM that is always ready, and records every byte the uploader writes:
//  the highest address, and how many writes land at or above the VRAM base.
//
//      +pack=<machine .MSX>  +fw=<fw pack>  +roma=<file> +romb=<file>
//      +mapa=<n> +mapb=<n>   (selected mapper, mapper_typ_t value)
//      +limit=<hex byte address, default 1800000 = 24 MB>
//
//  A full-size upload is ~25 MB of byte writes: far too slow for fullsys
//  (443 kB took 91 ms of machine time and 40 minutes of wall clock), and the
//  question is the layout, not the controller.
`timescale 1ns/1ps

module tb_upload32;

   logic clk = 0;
   always #5 clk = ~clk;

   //  DDR3 as the HPS leaves it: machine pack at 0, FW pack at 0x2000000,
   //  slot A ROM at 0xC00000, slot B ROM at 0x3000000 (memory_upload.sv:282, 312).
   localparam int PSZ = 1 << 23, FSZ = 1 << 24, RSZ = 1 << 24;
   logic [7:0] packm [PSZ];
   logic [7:0] fwm   [FSZ];
   logic [7:0] roma  [RSZ];
   logic [7:0] romb  [RSZ];
   int pack_n = 0, fw_n = 0, roma_n = 0, romb_n = 0;

   task automatic rd(input string key, output int n, input int which);
      string f; int fd, c, i;
      n = 0;
      if (!$value$plusargs({key, "=%s"}, f)) return;
      fd = $fopen(f, "rb");
      if (fd == 0) begin $display("FATAL: cannot open %s", f); $finish; end
      i = 0; c = $fgetc(fd);
      while (c >= 0) begin
         case (which)
            0: if (i < PSZ) packm[i] = 8'(c);
            1: if (i < FSZ) fwm[i]   = 8'(c);
            2: if (i < RSZ) roma[i]  = 8'(c);
            3: if (i < RSZ) romb[i]  = 8'(c);
         endcase
         i++; c = $fgetc(fd);
      end
      $fclose(fd);
      n = i;
      $display("%s: %0d bytes from %s", key, n, f);
   endtask

   logic [27:0] ddr3_addr;
   logic        ddr3_rd, ddr3_wr, ddr3_request;
   logic  [7:0] ddr3_dout = 8'hFF;
   logic        ddr3_ready = 1'b1;
   always @(posedge clk)
      if (ddr3_ready & ddr3_rd)
         ddr3_dout <= (ddr3_addr >= 28'h3000000) ? ((ddr3_addr - 28'h3000000 < 28'(romb_n)) ? romb[ddr3_addr - 28'h3000000] : 8'hFF) :
                      (ddr3_addr >= 28'h2000000) ? ((ddr3_addr - 28'h2000000 < 28'(fw_n))   ? fwm[ddr3_addr - 28'h2000000]  : 8'hFF) :
                      (ddr3_addr >= 28'h0C00000) ? ((ddr3_addr - 28'h0C00000 < 28'(roma_n)) ? roma[ddr3_addr - 28'h0C00000] : 8'hFF) :
                      (ddr3_addr < 28'(pack_n)) ? packm[ddr3_addr] : 8'hFF;

   logic        ioctl_download = 0;
   logic [15:0] ioctl_index    = 0;
   logic [26:0] ioctl_addr     = 0;
   logic [26:0] ram_addr;
   logic  [7:0] ram_din;
   logic        ram_ce, sdram_rq, bram_rq;
   logic        kbd_request, kbd_we, load_sram, reset_rq;
   logic  [8:0] kbd_addr;
   logic  [7:0] kbd_din;
   logic  [1:0] sdram_size = 2'd1;            // 32 MB; +sdsz=2 a 64 MB board
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
      .hold_load(1'b0),
      .clk(clk), .reset_rq(reset_rq),
      .ioctl_download(ioctl_download), .ioctl_index(ioctl_index), .ioctl_addr(ioctl_addr),
      .rom_eject(1'b0), .reload(1'b0),
      .ddr3_addr(ddr3_addr), .ddr3_rd(ddr3_rd), .ddr3_wr(ddr3_wr),
      .ddr3_dout(ddr3_dout), .ddr3_ready(ddr3_ready), .ddr3_request(ddr3_request),
      .ram_addr(ram_addr), .ram_din(ram_din), .ram_dout(8'h00), .ram_ce(ram_ce),
      .sdram_ready(1'b1), .sdram_rq(sdram_rq), .bram_rq(bram_rq),
      .kbd_request(kbd_request), .kbd_addr(kbd_addr), .kbd_din(kbd_din), .kbd_we(kbd_we),
      .sdram_size(sdram_size), .load_sram(load_sram),
      .slot_layout(slot_layout), .lookup_RAM(lookup_RAM), .lookup_SRAM(lookup_SRAM),
      .bios_config(bios_config), .cart_conf(cart_conf),
      .rom_loaded(rom_loaded), .rom_big(rom_big),
      .cart_device(cart_device), .msx_device(msx_device),
      .msx_dev_ref_ram(msx_dev_ref_ram), .pcm_rom_base(pcm_rom_base)
   );

   //  every SDRAM byte the uploader writes
   longint nwr = 0, nover = 0;
   logic [26:0] amax = 0, first_over = 0;
   logic [26:0] limit = 27'h1800000;
   always @(posedge clk)
      if (ram_ce & sdram_rq) begin
         nwr++;
         if (ram_addr > amax) amax = ram_addr;
         if (ram_addr >= limit) begin if (nover == 0) first_over = ram_addr; nover++; end
      end

   task automatic do_load(input int idx, input int size);
      ioctl_index = 16'(idx);
      ioctl_download = 1; repeat (20) @(posedge clk);
      ioctl_addr = 27'(size);
      ioctl_download = 0;
      for (int t = 0; t < 200_000; t++) begin @(posedge clk); if (reset_rq) break; end
      for (longint t = 0; t < 64'd2_000_000_000; t++) begin @(posedge clk); if (!reset_rq) break; end
      repeat (50) @(posedge clk);
   endtask

   initial begin
      int ma, mb;
      logic [31:0] lim;
      for (int i = 0; i < 2; i++) cart_conf[i] = '{default:'0};
      if ($value$plusargs("mapa=%d", ma)) cart_conf[0].selected_mapper = mapper_typ_t'(ma);
      if ($value$plusargs("mapb=%d", mb)) cart_conf[1].selected_mapper = mapper_typ_t'(mb);
      if ($value$plusargs("limit=%h", lim)) limit = 27'(lim);
      begin int z; if ($value$plusargs("sdsz=%d", z)) sdram_size = 2'(z); end
      rd("pack", pack_n, 0); rd("fw", fw_n, 1); rd("roma", roma_n, 2); rd("romb", romb_n, 3);
      repeat (10) @(posedge clk);
      //  the order a board sees: FW pack and cart ROMs in DDR3, then the machine
      //  pack's load does the walk that places everything.  The earlier loads
      //  only set their sizes; their walks run first and are redone.
      if (fw_n)   do_load(2, fw_n);
      if (roma_n) do_load(3, roma_n);
      if (romb_n) do_load(4, romb_n);
      nwr = 0; nover = 0; amax = 0;
      do_load(1, pack_n);
      for (int i = 0; i < 16; i++)
         if (lookup_RAM[i].size != 0)
            $display("lookup_RAM[%0d] addr=%07x size=%0d x16kB -> end %07x", i, lookup_RAM[i].addr,
                     lookup_RAM[i].size, lookup_RAM[i].addr + {lookup_RAM[i].size, 14'd0});
      $display("machine RAM mapper: %0d x 16 kB (bios_config.ram_size=%0d), board sdram_size=%0d",
               lookup_RAM[5].size, bios_config.ram_size, sdram_size);
      $display("pcm_rom_base=%07x (wave RAM to %07x)%s", pcm_rom_base, pcm_rom_base + 27'h400000,
               pcm_rom_base == 27'h1800000 ? "  [default: no yrw801 loaded]" : "");
      $display("upload: %0d SDRAM byte writes, highest %07x (%.2f MB); at or above %07x: %0d (first %07x)",
               nwr, amax, (amax + 1) / 1048576.0, limit, nover, first_over);
      //  (a ?: of two string literals is a bit vector padded to the longer one)
      if (nover == 0) $display("UPLOAD32 FITS"); else $display("UPLOAD32 OVERFLOWS");
      $finish;
   end
endmodule
