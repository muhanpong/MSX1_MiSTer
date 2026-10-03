//  tb_x16_header -- an ASCII16X ROM is recognised by its HEADER, whatever its size.
//
//  What memory_upload decides for a slot A ROM, and when:
//
//    * the 8MB padding (`x16_pad`) and the recorded size are fixed BEFORE the first
//      byte is written -- from the menu choice and the size only;
//    * mapper_detect sees the header only WHILE the bytes are written, so the final
//      mapper (the re-latch at the end of the fill) is the first moment it can say
//      "ASCII16X" for an image the menu left as plain ASCII16 or AUTO.
//
//  The OSD "ASCII16X" entry resolves to plain ASCII16 for a ROM of 4MB or less
//  (msx_config.sv), so a small ASCII16X cart used to come out as the 8-bit-bank mapper
//  with no flash and no padding, however it was selected.  The late padding in the
//  end-of-fill branch is what makes the header count.
//
//  For each case the bench checks, from the DUT's own outputs:
//     M   the mapper that reaches slot_layout (page 1 of slot 1-0)
//     S   the size recorded for that RAM entry, in 16kB units (512 = the full 8MB chip)
//     W   how many bytes were written in total / how many of them are 0xFF padding
//         (the image bytes are generated < 0xC0, so every 0xFF write is padding)
//
//  Mutants are made by run_x16_header.sh from copies of the RTL (no late padding;
//  no promotion in the decoder; the detector's signature not cleared on reset).

`timescale 1ns/1ps

module tb_x16_header;

   import MSX::*;

   logic clk = 0;
   always #5 clk = ~clk;

   // ---- the machine pack: SLOT A, SLOT B, CONFIG (bytes from createMSXpack) ----
   localparam int PACKSZ = 48;
   logic [7:0] pack [PACKSZ] = '{
      8'h4D,8'h53,8'h58,8'h24,8'h01,8'h00,8'h00,8'hFF,8'h00,8'h00,8'h00,8'h03,8'h00,8'h00,8'h00,8'h00,
      8'h4D,8'h53,8'h58,8'h38,8'h01,8'h00,8'h00,8'hFF,8'h00,8'h00,8'h00,8'h03,8'h00,8'h00,8'h00,8'h00,
      8'h4D,8'h53,8'h58,8'h60,8'h10,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00};

   // ---- the ROM image the HPS would have staged at the slot A store ------------
   bit has_hdr = 0;
   function automatic logic [7:0] rom_byte(input int off);
      if (has_hdr && off >= 16 && off < 24) begin
         case (off - 16)
            0: return "A"; 1: return "S"; 2: return "C"; 3: return "I";
            4: return "I"; 5: return "1"; 6: return "6"; default: return "X";
         endcase
      end
      return 8'h80 | (8'(off * 7) & 8'h3F);                // < 0xC0, never 0x32, never 0xFF
   endfunction

   // ---- DDR3 model ---------------------------------------------------------
   logic [27:0] ddr3_addr;
   logic        ddr3_rd, ddr3_wr, ddr3_request;
   logic  [7:0] ddr3_dout = 8'hFF;
   logic        ddr3_ready = 1'b0;
   int rdiv = 0;
   always @(posedge clk) begin
      rdiv <= (rdiv == 3) ? 0 : rdiv + 1;
      ddr3_ready <= (rdiv == 3);
      if (ddr3_ready && ddr3_rd)
         ddr3_dout <= (ddr3_addr >= 28'hC00000) ? rom_byte(int'(ddr3_addr - 28'hC00000)) :
                      (ddr3_addr < PACKSZ)      ? pack[ddr3_addr] : 8'h00;
   end

   // ---- ioctl / the rest of the interface ----------------------------------
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

   // ---- what was written ---------------------------------------------------
   longint wr_total, wr_ff;
   longint wr_ff_img, img_len = 0;        // 0xFF among the first img_len writes = the image itself
   int     dbg_left = 3;
   always @(posedge clk) if (ram_ce) begin
      wr_total <= wr_total + 1;
      if (ram_din == 8'hFF) begin
         wr_ff <= wr_ff + 1;
         if (wr_total < img_len) begin
            wr_ff_img <= wr_ff_img + 1;
            if (dbg_left > 0) begin dbg_left <= dbg_left - 1; $display("  FF inside the image: write #%0d addr=%h", wr_total, ram_addr); end
         end
      end
   end

   task automatic do_load(input int idx, input int size);
      ioctl_index = 16'(idx);
      ioctl_download = 1; repeat (20) @(posedge clk);
      ioctl_addr = 27'(size);
      ioctl_download = 0;
      repeat (4) @(posedge clk);
      for (int t = 0; t < 400_000_000; t++) begin
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

   // one case: a slot A ROM of `size` bytes with the given menu choice
   task automatic run_case(input string name, input int size, input bit hdr,
                           input mapper_typ_t sel, input mapper_typ_t want_mapper,
                           input int want_size16k, input bit want_pad);
      mapper_typ_t got_m; logic [3:0] rr; int got_s;
      has_hdr = hdr;
      cart_conf[0].typ             = CART_TYP_ROM;
      cart_conf[0].selected_mapper = sel;
      cart_conf[0].selected_sram_size = 8'd0;
      cart_conf[0].expanded        = 1'b0;
      wr_total = 0; wr_ff = 0; wr_ff_img = 0; img_len = size; dbg_left = 3;
      do_load(3, size);
      got_m = slot_layout[{4'd4, 2'd1}].mapper;
      rr    = slot_layout[{4'd4, 2'd1}].ref_ram;
      got_s = int'(lookup_RAM[rr].size);
      $display("  [%s] mapper=%0d size=%0d(x16k) written=%0d ff=%0d", name, got_m, got_s, wr_total, wr_ff);
      ck({name, ": mapper"},       got_m == want_mapper);
      ck({name, ": size"},         got_s == want_size16k);
      ck({name, ": total bytes"},  wr_total == (want_pad ? 64'd8388608 : 64'(size)));
      ck({name, ": 0xFF padding"}, wr_ff == (want_pad ? 64'(8388608 - size) : 64'd0));
      ck({name, ": image intact (no 0xFF inside it)"}, wr_ff_img == 0);
   endtask

   initial begin
      cart_conf[0] = '{default:'0};
      cart_conf[1] = '{default:'0};
      repeat (10) @(posedge clk);

      do_load(1, PACKSZ);                                 // the machine pack

      // 1. the case that was impossible: a small ASCII16X cart, OSD "ASCII16X" entry
      run_case("hdr 64K, OSD ASCII16X entry",    65536, 1, MAPPER_ASCII16,   MAPPER_ASCII16X, 512, 1);
      // 2. the same cart on AUTO
      run_case("hdr 64K, AUTO",                  65536, 1, MAPPER_AUTO,      MAPPER_ASCII16X, 512, 1);
      // 3. no header: plain ASCII16 stays plain, nothing is padded
      run_case("no hdr 64K, OSD ASCII16X entry", 65536, 0, MAPPER_ASCII16,   MAPPER_ASCII16,    4, 0);
      // 4. a header does not override someone else's explicit choice
      run_case("hdr 64K, ASCII8 chosen",         65536, 1, MAPPER_ASCII8,    MAPPER_ASCII8,     4, 0);
      // 5. the previous ROM's header must not leak into the next ROM's up-front decisions
      run_case("stale: hdr 64K, AUTO (primes)",  65536, 1, MAPPER_AUTO,      MAPPER_ASCII16X, 512, 1);
      run_case("stale: then no hdr 64K, AUTO",   65536, 0, MAPPER_AUTO,      MAPPER_KONAMI,     4, 0);   // no bank writes seen: kon >= ascii
      // 6. regressions: the paths that already worked
      run_case("Yamanooto chosen, 64K",          65536, 0, MAPPER_YAMANOOTO, MAPPER_YAMANOOTO, 512, 1);
      run_case("ASCII16X (>4MB), no hdr",        4*1048576 + 16384, 0, MAPPER_ASCII16X, MAPPER_ASCII16X, 512, 1);

      $display("errors=%0d", errors);
      if (errors) $fatal(1, "tb_x16_header FAILED (%0d)", errors);
      $display("tb_x16_header PASSED");
      $finish;
   end

endmodule
