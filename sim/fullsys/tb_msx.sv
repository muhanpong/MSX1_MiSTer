//  tb_msx -- the whole machine, in Verilator.
//
//      sim/fullsys/prep.sh && sim/fullsys/run.sh <pack.MSX> [disk.dsk] [ms]
//
//  Stage 1 (this file): clocks, SDRAM, the pack staged out of a DDR3 model that
//  reads a real .MSX file, systemRAM, and rtl/msx.sv released from reset.  It
//  prints the branch-target stream, which is the same thing the JTAG recorder
//  prints on hardware -- so a capture and a simulation can be diffed line for
//  line, and against openMSX.
//
//  What this replaces: a 20-minute Quartus build plus a board round trip per
//  question.  See sim/fullsys/README.md.
`timescale 1ns/1ps

module tb;

   //  ── clocks ───────────────────────────────────────────────────────────────
   //  clk_sdram is 4x clk21m; tb/README.md documents the phase the guard bench
   //  needed.  Here they are edge-aligned, which is what sdram.sv's own bench
   //  uses and is enough for functional work.
   //  clk_sdram and clk21m are msx ports: declared in msx_ports.svh, driven here.
   initial clk_sdram = 1'b0;
   //  -DTDMCLK (run_tdm.sh CLKONLY=1): the TDM clocks with sdram.sv and its CL2 chip
   //  model -- separates the 6:1 clock from the controller.
`ifdef TDM
 `define TDM_CLOCK
`endif
`ifdef TDMCLK
 `define TDM_CLOCK
`endif
`ifndef TDM_CLOCK
   localparam real TCK_NS = 11.64;
   always #5.820 clk_sdram = ~clk_sdram;       // 85.909 MHz: 11.64 ns period
                                              // (1ps resolution -- at 1ns the
                                              //  half period rounds to 500x slow)
   logic [1:0] cdiv = 2'd0;
   always @(posedge clk_sdram) cdiv <= cdiv + 2'd1;
   assign clk21m = cdiv[1];
`else
   //  sdram128 study: clk_sdram 128.86 MHz, clk21m = clk_sdram / 6 (run_tdm.sh)
   localparam real TCK_NS = 7.76;
   always #3.880 clk_sdram = ~clk_sdram;
   logic [1:0] cdiv6 = 2'd0;
   logic       c21 = 1'b0;
   always @(posedge clk_sdram)
      if (cdiv6 == 2'd2) begin cdiv6 <= 2'd0; c21 <= ~c21; end
      else cdiv6 <= cdiv6 + 2'd1;
   assign clk21m = c21;
`endif

`include "msx_ports.svh"

   //  ── the pack, and the disk ───────────────────────────────────────────────
   //  8 MB.  It was 2 MB, and a 3-3 turbo R pack is 2.4 MB (ST) or 4.4 MB (GT):
   //  the tail was dropped in silence, and with it the end of the 3-3 firmware and
   //  every DEVICE record after it -- RESET_STATUS among them, so port F4 read FFh,
   //  the BIOS took its warm CPU-switch path at 126Bh before any RAM was mapped,
   //  and the machine looped RST 38h -> 0C3Ch -> FD9Ah for the whole run.
   localparam int PACKSZ = 1 << 23;
   logic [7:0] packmem [PACKSZ];
   int         pack_bytes = 0;
   string      pack_file;

   initial begin
      int fd, c, i;
      if (!$value$plusargs("pack=%s", pack_file)) begin
         $display("FATAL: +pack=<file.MSX> is required");
         $finish;
      end
      fd = $fopen(pack_file, "rb");
      if (fd == 0) begin $display("FATAL: cannot open %s", pack_file); $finish; end
      i = 0;
      c = $fgetc(fd);
      while (c >= 0 && i < PACKSZ) begin
         packmem[i] = 8'(c);
         i = i + 1;
         c = $fgetc(fd);
      end
      if (c >= 0) begin
         $display("FATAL: %s is larger than the %0d-byte pack buffer", pack_file, PACKSZ);
         $finish;
      end
      $fclose(fd);
      pack_bytes = i;
      $display("pack: %0d bytes from %s", pack_bytes, pack_file);
   end

   //  ── optional FW pack (+fwpack=<file>), staged as ioctl index 2 ─────────────
   //  memory_upload looks firmware up at DDR3 0x2000000 (MSX1.sv "FW PACK,32000000"),
   //  so the model serves it from there.  Without it a pack that wants firmware
   //  (MoonSound yrw801, FM-PAC, MU-PACK ...) finds an empty store.
   localparam int FWSZ = 1 << 24;
   logic [7:0] fwmem [FWSZ];
   int         fw_bytes = 0;
   initial begin
      string fw_file; int fd, c, i;
      if ($value$plusargs("fwpack=%s", fw_file)) begin
         fd = $fopen(fw_file, "rb");
         if (fd == 0) begin $display("FATAL: cannot open %s", fw_file); $finish; end
         i = 0; c = $fgetc(fd);
         while (c >= 0 && i < FWSZ) begin fwmem[i] = 8'(c); i++; c = $fgetc(fd); end
         if (c >= 0) begin $display("FATAL: %s is larger than %0d bytes", fw_file, FWSZ); $finish; end
         $fclose(fd);
         fw_bytes = i;
         $display("fwpack: %0d bytes from %s", fw_bytes, fw_file);
      end
   end

   //  ── DDR3 model: memory_upload reads the staged file back byte at a time ──
   //  The HPS puts the file in DDR3 on real hardware; nothing arrives through
   //  ioctl_dout.  `ready` is the arbiter's periodic grant, as in
   //  sim/tb_device_reload.sv.
   logic [27:0] ddr3_addr;
   logic        ddr3_rd, ddr3_wr, ddr3_request;
   logic  [7:0] ddr3_dout = 8'hFF;
   logic        ddr3_ready = 1'b0;
   //  One grant every fourth cycle costs eight cycles per byte, and the upload
   //  reads the whole pack a byte at a time: a 1.4 MB pack then takes longer to
   //  stage than the run it is staging for.  The arbiter's rate is not what this
   //  bench is testing, so grant every cycle.  DDR3_SLOW=1 restores the slower
   //  rate for anything that does care.
   int          rdiv = 0;
   bit          ddr3_slow = 1'b0;
   initial      ddr3_slow = $test$plusargs("ddr3slow");
   always @(posedge clk21m) begin
      rdiv <= (rdiv == 3) ? 0 : rdiv + 1;
      ddr3_ready <= ddr3_slow ? (rdiv == 3) : 1'b1;
   end
   //  The data must be valid AT the ready pulse, not one cycle after it -- that
   //  is what ddram.sv does, and getting it wrong makes memory_upload parse the
   //  byte before the one it asked for: the pack comes out as a 32 kB stub and
   //  the machine reads FFh everywhere.  (The toy model in sim/tb_device_reload
   //  registers it, which that bench tolerates and this one does not.)
   //  Latch the byte WHEN THE READ COMPLETES, and hold it.  memory_upload
   //  advances ddr3_addr on that same edge (memory_upload.sv:170) and stores the
   //  byte on the NEXT grant, so anything that keeps following the address --
   //  live or registered -- has already moved on by then and hands over the byte
   //  after the one that was asked for.  Every header then came out shifted by
   //  one: "SX@" instead of "MSX", the magic check failed, and the pack was
   //  skipped in silence, leaving all 64 slot-layout entries empty and the
   //  machine reading FFh everywhere.
   always @(posedge clk21m)
      if (ddr3_ready & ddr3_rd)
         ddr3_dout <= (ddr3_addr >= 28'h2000000 && ddr3_addr < 28'h2000000 + 28'(fw_bytes))
                                                    ? fwmem[ddr3_addr - 28'h2000000]    :
                      (ddr3_addr < 28'(pack_bytes)) ? packmem[ddr3_addr]               : 8'hFF;

   //  ioctl_download/index/addr are msx ports too: declared in msx_ports.svh.

   //  ── memory_upload ────────────────────────────────────────────────────────
   logic        reset_rq;
   logic [26:0] upl_addr;
   logic  [7:0] upl_din;
   logic        upl_ce, upl_sdram_rq, upl_bram_rq, upl_load_sram;
   logic  [1:0] rom_loaded, rom_big;
   MSX::config_cart_t cart_conf [2];

   initial begin
      for (int i = 0; i < 2; i++) cart_conf[i] = '{default:'0};
      //  +slotb=<n>: slot B's cart type as the OSD would set it (cart_typ_t value,
      //  e.g. 8 = CART_TYP_MUPACK).  Default 0 = ROM with no file = empty.
      begin int sb; if ($value$plusargs("slotb=%d", sb)) cart_conf[1].typ = cart_typ_t'(sb); end
   end

   memory_upload u_upload
   (
      .clk(clk21m),
      .reset_rq(reset_rq),
      .ioctl_download(ioctl_download),
      .ioctl_index(ioctl_index),
      .ioctl_addr(ioctl_addr),
      .rom_eject(1'b0),
      .reload(1'b0),
      .hold_load(1'b0),
      .ddr3_addr(ddr3_addr), .ddr3_rd(ddr3_rd), .ddr3_wr(ddr3_wr),
      .ddr3_dout(ddr3_dout), .ddr3_ready(ddr3_ready), .ddr3_request(ddr3_request),
      .ram_addr(upl_addr), .ram_din(upl_din), .ram_dout(ram_dout), .ram_ce(upl_ce),
      .sdram_ready(sdram_ready), .sdram_rq(upl_sdram_rq), .bram_rq(upl_bram_rq),
      .kbd_request(kbd_request), .kbd_addr(kbd_addr), .kbd_din(kbd_din), .kbd_we(kbd_we),
      .sdram_size(sdram_size),
      .load_sram(upl_load_sram),
      .slot_layout(slot_layout), .lookup_RAM(lookup_RAM), .lookup_SRAM(lookup_SRAM),
      .bios_config(bios_config),
      .cart_conf(cart_conf),
      .rom_loaded(rom_loaded), .rom_big(rom_big),
      .cart_device(cart_device), .msx_device(msx_device),
      .msx_dev_ref_ram(msx_dev_ref_ram),
      .pcm_rom_base(pcm_rom_base)
   );

   //  ── SDRAM: the real controller over a behavioural chip ───────────────────
   wire        upload_active = upl_ce & upl_sdram_rq;
   wire [26:0] ch1_addr = upl_addr;
   wire  [7:0] ch1_din  = upl_din;
   wire        ch1_req  = upload_active;
   wire        ch1_rnw  = 1'b0;
   wire  [7:0] ch1_dout;
   wire        sdram_ready;

   wire  [7:0] sdram_dout;
   wire        ch2_ready;

   logic [12:0] SDRAM_A;
   logic  [1:0] SDRAM_BA;
   wire  [15:0] dq_o, dq_i;
   wire         dq_oe, SDRAM_DQML, SDRAM_DQMH, SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS, SDRAM_CKE;

`ifndef TDM
   sdram u_sdram
   (
      .init(rst_n_cnt != 0), .clk(clk_sdram), .doRefresh(1'b1),
`else
   sdram_tdm u_sdram
   (
      .init(rst_n_cnt != 0), .clk(clk_sdram), .mode128(1'b0), .mode64(1'b0),
      .v_en(1'b0), .v_req(1'b0), .v_we(1'b0), .v_addr(16'd0), .v_wdata(32'd0), .v_be(4'd0),
      .v_grant(), .v_rdata(), .v_rvalid(),
      .ch2_busy(sdram_busy),
`endif
      .SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
      .SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE),
      .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_CKE(SDRAM_CKE),
      .SDRAM_DQ_o(dq_o), .SDRAM_DQ_oe(dq_oe), .SDRAM_DQ_i(dq_i),
      .ch1_addr(ch1_addr), .ch1_dout(ch1_dout), .ch1_din(ch1_din),
      .ch1_req(ch1_req), .ch1_rnw(ch1_rnw), .ch1_ready(sdram_ready),
      .ch2_addr(ram_addr), .ch2_dout(sdram_dout), .ch2_din(ram_din),
      .ch2_req(sdram_ce), .ch2_rnw(ram_rnw), .ch2_ready(ch2_ready),
      .ch2_rdtog(sdram_rdtog), .ch2_hit(sdram_hit),
      .ch3_addr(flash_addr), .ch3_din(flash_din), .ch3_req(flash_req),
      .ch3_rnw(1'b0), .ch3_ready(flash_ready),
      .ch4_addr(pcm_sdram_addr), .ch4_din(pcm_sdram_din), .ch4_req(pcm_sdram_req),
      .ch4_rnw(pcm_sdram_rnw), .ch4_dout(pcm_sdram_dout), .ch4_dout16(pcm_sdram_dout16),
      .ch4_ready(pcm_sdram_ready)
   );

`ifndef TDM
   assign sdram_busy = 1'b0;               // sdram.sv has no ch2 queue
   sdram_big u_chip
`else
   sdram_big_tdm u_chip
`endif
   (
      .clk(clk_sdram), .DQ_out(dq_i), .DQ_in(dq_o), .DQ_oe(dq_oe),
      .A(SDRAM_A), .BA(SDRAM_BA), .nCS(SDRAM_nCS), .nWE(SDRAM_nWE),
      .nRAS(SDRAM_nRAS), .nCAS(SDRAM_nCAS), .DQML(SDRAM_DQML), .DQMH(SDRAM_DQMH)
   );

   //  ── systemRAM (SRAM only, since SDRAM is present) ────────────────────────
   wire [7:0] bram_dout;
   dpram #(.addr_width(16)) systemRAM
   (
      .clock(clk21m),
      .address_a(16'(upl_bram_rq ? upl_addr : ram_addr)),
      .data_a(upl_bram_rq ? upl_din : ram_din),
      .enable_a(1'b1),
      .wren_a(upl_bram_rq ? upl_ce : (bram_ce & ~ram_rnw)),
      .q_a(bram_dout), .cs_a(1'b1),
      .address_b(16'(nv_ram_addr)), .data_b(nv_buff_dout), .enable_b(1'b1),
      .wren_b(nv_ram_we), .q_b(nv_ram_dout), .cs_b(1'b1)
   );

   //  ── the save engine, and an SD card behind it ────────────────────────────
   //  nvram_backup lives in MSX1.sv rather than in msx.sv, so the whole-machine
   //  bench did not contain it and a .sav auto-load could not be exercised here
   //  at all.  This is the block device the README's third open item asks for,
   //  in the only shape it needs: ONE image, on VD0, which is where the firmware
   //  always mounts <rom>.sav.
   //
   //      +sav=<file>     the image to serve
   //      +savlate        mount it AFTER the upload finishes, rather than before
   //
   //  +savlate is the ordering that used to lose the auto-load: the end-of-upload
   //  request arrives while the image is not mounted yet.
   localparam int SAVMAX = 1 << 17;
   logic [7:0] savmem [SAVMAX];
   int         sav_bytes = 0;
   string      sav_file;
   bit         sav_late  = 1'b0;

   wire  [31:0] nv_sd_lba[2];
   wire   [1:0] nv_sd_rd, nv_sd_wr;
   logic  [1:0] nv_sd_ack    = 2'b0;
   logic [13:0] nv_buff_addr = 14'd0;
   logic  [7:0] nv_buff_dout = 8'd0;
   wire   [7:0] nv_buff_din[2];
   wire  [17:0] nv_ram_addr;
   wire         nv_ram_we;
   wire   [7:0] nv_ram_dout;
   logic  [1:0] nv_img_mounted = 2'b0;
   logic [63:0] nv_img_size    = 64'd0;
   logic        nv_img_ro      = 1'b0;

   nvram_backup u_nvram
   (
      .clk(clk21m), .reset(reset),
      .lookup_SRAM(lookup_SRAM),
      .load_req(upl_load_sram), .save_req(1'b0), .upload_busy(reset_rq),
      .autosave_en(1'b0), .cpu_wr(1'b0), .cpu_wr_addr(18'd0), .rtc_dirty(1'b0), .flush(1'b0),
      .img_mounted(nv_img_mounted), .img_readonly(nv_img_ro), .img_size(nv_img_size),
      .sd_lba(nv_sd_lba), .sd_rd(nv_sd_rd), .sd_wr(nv_sd_wr), .sd_ack(nv_sd_ack),
      .sd_buff_addr(nv_buff_addr), .sd_buff_dout(nv_buff_dout), .sd_buff_din(nv_buff_din),
      .ram_addr(nv_ram_addr), .ram_we(nv_ram_we), .ram_dout(nv_ram_dout),
      .flash16x_active(1'b0), .flash16x_base(27'd0), .flash16x_size(16'd0),
      .sdram_addr(), .sdram_req(), .sdram_rnw(), .sdram_din(),
      .sdram_dout(8'h00), .sdram_ready(1'b1),
      .dma_active(), .dma_save()
   );

   //  What the uploader actually read for each 16-byte header.  A header whose
   //  magic is not "MSX" sends the FSM back to IDLE with nothing parsed and no
   //  message, so this is the only place the failure is visible.
   int hdr_seen = 0;
   always @(posedge clk21m) begin
      if (u_upload.state == 4'd4 /*STATE_CHECK_CONFIG*/ && hdr_seen < 4) begin
         hdr_seen++;
         $display("hdr %0d: %02x %02x %02x %02x  ddr3_addr=%0d  magic=%0s",
                  hdr_seen, u_upload.conf[0], u_upload.conf[1], u_upload.conf[2],
                  u_upload.conf[3], u_upload.ddr3_addr,
                  ({u_upload.conf[0],u_upload.conf[1],u_upload.conf[2]} == "MSX") ? "OK" : "BAD");
      end
   end

   //  Serve one sector: hold ack, sweep the 512 offsets, drop ack.  nvram_backup
   //  makes its own BRAM write enable from ack and the offset, so the model only
   //  has to present the address and the byte.
   int sectors_served = 0;
   int sd_gap = 0;
   initial if (!$value$plusargs("sdslow=%d", sd_gap)) sd_gap = 0;
   initial begin
      forever begin
         @(posedge clk21m);
         if (|nv_sd_rd | |nv_sd_wr) begin
            automatic int n = 0;
            automatic int base;
            for (int k = 0; k < 2; k++) if (nv_sd_rd[k] | nv_sd_wr[k]) n = k;
            sav_idx = n;
            base = int'(nv_sd_lba[n]) * 512;
            nv_sd_ack[n] <= 1'b1;
            for (int i = 0; i < 512; i++) begin
               nv_buff_addr <= 14'(i);
               nv_buff_dout <= (base + i < SAVMAX) ? savmem[base + i] : 8'hFF;
               @(posedge clk21m);
               if (nv_sd_wr[n] && base + i < SAVMAX) savmem[base + i] = nv_buff_din[n];
            end
            nv_sd_ack[n] <= 1'b0;
            sectors_served++;
            //  A sector here costs about 512 cycles, which is far faster than an
            //  HPS transaction on hardware.  That matters for one measurement
            //  only -- how long the machine runs beside an unfinished load -- so
            //  +sdslow=<cycles> stretches the gap between sectors to something
            //  representative instead of flattering the result.
            repeat (sd_gap) @(posedge clk21m);
            @(posedge clk21m);
         end
      end
   end

   //  docs/sram_load_guard.md step 1: the machine is released 2.9 us after the
   //  .sav is asked for, while the read is tens of SD sectors.  Count the writes
   //  the CPU lands in the SRAM window during that time.  A non-zero count is the
   //  defect in numbers; zero means the guard is a precaution rather than a fix.
   //  Either way the number has to exist before any RTL changes.
   logic load_flight = 1'b0;
   bit   load_sram_seen = 1'b0;
   always @(posedge clk21m) if (upl_load_sram) load_sram_seen <= 1'b1;
   int   cpu_sram_writes = 0, flight_sectors = 0;
   int   flight_cycles = 0, bram_writes_in_flight = 0;
   always @(posedge clk21m) begin
      if (upl_load_sram) load_flight <= 1'b1;
      if (load_flight && sav_idx >= 0 && lookup_SRAM[sav_idx].size > 0
          && sectors_served >= int'(lookup_SRAM[sav_idx].size) * 2) load_flight <= 1'b0;
      if (load_flight) begin
         flight_sectors <= sectors_served;
         flight_cycles  <= flight_cycles + 1;
         //  Any CPU write to BRAM at all.  If this is zero the machine was not
         //  doing anything and a zero in the window below means nothing.
         if (bram_ce && !ram_rnw) bram_writes_in_flight <= bram_writes_in_flight + 1;
         if (bram_ce && !ram_rnw && sav_idx >= 0
             && ram_addr >= 27'(lookup_SRAM[sav_idx].addr)
             && ram_addr <  27'(lookup_SRAM[sav_idx].addr) + 27'(lookup_SRAM[sav_idx].size) * 1024)
            cpu_sram_writes <= cpu_sram_writes + 1;
      end
   end

   //  The counters above only run while the load is in flight, so their result is
   //  a function of +sdslow, which is a guess at the HPS.  What decides the guard
   //  is independent of it: T_first, how long after release the CPU first writes
   //  the SRAM window at all.  If that is shorter than the real load it is a
   //  defect; if longer, a precaution.  So count everything, from release on, and
   //  stamp the first write.  A zero total over a long boot says the firmware
   //  never reached that code on this pack -- the branch trace is the next
   //  instrument, not a bigger window.
   int      all_bram_writes = 0, all_sram_writes = 0;
   realtime t_release = 0, t_first_bram = -1, t_first_sram = -1, t_load_end = -1;
   logic [15:0] first_sram_pc = 16'd0;
   logic [26:0] first_sram_addr = 27'd0;
   logic [7:0]  first_sram_data = 8'd0;
   logic        load_flight_q = 1'b0;
   event        sram_first_ev;
   //  Reads count too: a firmware that READS its settings before the load has
   //  landed acts on stale bytes without ever writing, and the guard under
   //  design (msx_pause) stops reads as well as writes.  Counted per access
   //  (rising edge of bram_ce), not per clock.
   int      all_sram_reads = 0;
   realtime t_first_sram_rd = -1;
   logic [15:0] first_rd_pc = 16'd0;
   logic [26:0] first_rd_addr = 27'd0;
   logic        bram_ce_q = 1'b0;
   always @(posedge clk21m) begin
      load_flight_q <= load_flight;
      if (load_flight_q && !load_flight && t_load_end < 0) t_load_end = $realtime;
      bram_ce_q <= bram_ce;
      if (trace_on && bram_ce && !bram_ce_q && ram_rnw && sav_idx >= 0 && lookup_SRAM[sav_idx].size > 0
          && ram_addr >= 27'(lookup_SRAM[sav_idx].addr)
          && ram_addr <  27'(lookup_SRAM[sav_idx].addr) + 27'(lookup_SRAM[sav_idx].size) * 1024) begin
         all_sram_reads <= all_sram_reads + 1;
         if (t_first_sram_rd < 0) begin
            t_first_sram_rd = $realtime;
            first_rd_pc = last_fetch; first_rd_addr = ram_addr;
            $display("sav: FIRST CPU read of the SRAM window at %0.3f ms after release, addr %0d, last fetch %04x, load in flight=%0d",
                     (t_first_sram_rd - t_release) / 1e6, ram_addr, last_fetch, load_flight);
            $fflush;
            ->sram_first_ev;
         end
      end
      if (trace_on && bram_ce && !ram_rnw) begin
         all_bram_writes <= all_bram_writes + 1;
         if (t_first_bram < 0) t_first_bram = $realtime;
         if (sav_idx >= 0 && lookup_SRAM[sav_idx].size > 0
             && ram_addr >= 27'(lookup_SRAM[sav_idx].addr)
             && ram_addr <  27'(lookup_SRAM[sav_idx].addr) + 27'(lookup_SRAM[sav_idx].size) * 1024) begin
            all_sram_writes <= all_sram_writes + 1;
            if (t_first_sram < 0) begin
               t_first_sram = $realtime;
               first_sram_pc = last_fetch; first_sram_addr = ram_addr; first_sram_data = ram_din;
               $display("sav: FIRST CPU write into the SRAM window at %0.3f ms after release, addr %0d data %02x, last fetch %04x (load in flight=%0d)",
                        (t_first_sram - t_release) / 1e6, ram_addr, ram_din, last_fetch, load_flight);
               $fflush;
               ->sram_first_ev;
            end
         end
      end
   end

   //  Output is block-buffered to a file; a flushed line every 50 ms keeps a
   //  partial log readable and shows the run is moving.
   initial begin
      wait (trace_on);
      forever begin
         #50_000_000;
         $display("hb: %0.0f ms after release, %0d branch events, BRAM writes %0d, SRAM window %0d, SRAM reads %0d, mapper SRAM %0d, load in flight=%0d",
                  ($realtime - t_release) / 1e6, nev, all_bram_writes, all_sram_writes,
                  all_sram_reads, n_slot_sram, load_flight);
         $fflush;
      end
   end

   //  Who holds INT, and what the VDP was told.  A turbo R BIOS that ends in
   //  an interrupt every 0.12 ms -- handler reads 99h, sees no frame flag,
   //  leaves -- has an INT source it cannot clear.  Log which line is low at
   //  each acknowledge, the VDP register writes that decide it (R#0 IE1,
   //  R#1 IE0, R#15 status select, R#19 line), and what 99h reads return.
   //  Bus level only: the DUT stays what the board builds.
   wire       io_rd = ~MSX.iorq_n & ~MSX.rd_n & MSX.m1_n;
   wire       io_wr = ~MSX.iorq_n & ~MSX.wr_n & MSX.m1_n;
   wire       inta  = ~MSX.iorq_n & ~MSX.m1_n;
   logic      io_rd_q = 0, io_wr_q = 0, inta_q = 0;
   logic      vdp_latch = 0;
   logic [7:0] vdp_first = 0, rd99_last = 0;
   int        n_inta = 0, n_inta_vdp = 0, n_inta_ms = 0, n_inta_midi = 0, n_inta_none = 0;
   int        n_rd99 = 0, n_rd99_f = 0, n_regw = 0, n_wr9b = 0;
   always @(posedge clk21m) if (trace_on) begin
      io_rd_q <= io_rd; io_wr_q <= io_wr; inta_q <= inta;
      if (io_rd) rd99_last <= MSX.d_to_cpu;
      //  end of a 99h read: the byte the CPU took
      if (io_rd_q && !io_rd && MSX.a[7:0] == 8'h99) begin
         n_rd99++;
         if (rd99_last[7]) n_rd99_f++;
         vdp_latch = 0;                       // a status read resets the 2-byte latch
      end
      if (io_wr && !io_wr_q && MSX.a[7:0] == 8'h9B) n_wr9b++;
      if (io_wr && !io_wr_q && MSX.a[7:0] == 8'h99) begin
         if (!vdp_latch) begin vdp_first = MSX.d_from_cpu; vdp_latch = 1; end
         else begin
            vdp_latch = 0;
            if (MSX.d_from_cpu[7:6] == 2'b10) begin
               n_regw++;
               if (n_regw <= 300 && (MSX.d_from_cpu[5:0] inside {0, 1, 15, 19}))
                  $display("vdp: %0.3f ms  R#%0d <= %02x", ($realtime - t_release) / 1e6,
                           MSX.d_from_cpu[5:0], vdp_first);
            end
         end
      end
      if (inta && !inta_q) begin
         n_inta++;
         if (!MSX.vdp_int_n)  n_inta_vdp++;
         if (!MSX.ms_int_n)   n_inta_ms++;
         if (!MSX.midi_int_n) n_inta_midi++;
         if (MSX.vdp_int_n & MSX.ms_int_n & MSX.midi_int_n) n_inta_none++;
         if (n_inta <= 3)
            $display("int: dev_midi cs=%0d timer_irq=%0d rxrdy_irq=%0d  midi_io_en=%0d  msx_device=%b",
                     MSX.msx_slots.dev_midi.cs, MSX.msx_slots.dev_midi.timer_irq,
                     MSX.msx_slots.dev_midi.rxrdy_irq, MSX.msx_slots.midi_io_en, msx_device);
         if (n_inta <= 5 || n_inta % 1000 == 0)
            $display("int: %0.3f ms  #%0d  vdp_int_n=%b ms_int_n=%b midi_int_n=%b  last 99h read %02x",
                     ($realtime - t_release) / 1e6, n_inta, MSX.vdp_int_n, MSX.ms_int_n,
                     MSX.midi_int_n, rd99_last);
      end
   end

   //  Upstream of bram_ce: a CPU access the MAPPER claims as SRAM
   //  (msx_slots' sram_cs with a memory read or write), counted per access,
   //  and how many of those the SRAM bound (sram_over) or any other
   //  mem_unmaped term then suppressed.  bram_ce is gated by ~mem_unmaped, so a
   //  bound that misjudges a pack's size would unmap every legitimate access
   //  and the counters above would read 0 for that reason alone.
   wire   slot_sram_acc = MSX.msx_slots.sram_cs & MSX.msx_slots.cpu_mreq
                        & (MSX.msx_slots.cpu_rd | MSX.msx_slots.cpu_wr);
   logic  slot_sram_acc_q = 1'b0;
   int    n_slot_sram = 0, n_slot_sram_over = 0, n_slot_sram_unmapped = 0;
   realtime t_first_slot_sram = -1;
   always @(posedge clk21m) if (trace_on) begin
      slot_sram_acc_q <= slot_sram_acc;
      if (slot_sram_acc && !slot_sram_acc_q) begin
         n_slot_sram++;
         if (MSX.msx_slots.sram_over)   n_slot_sram_over++;
         if (MSX.msx_slots.mem_unmaped) n_slot_sram_unmapped++;
         if (t_first_slot_sram < 0) begin
            t_first_slot_sram = $realtime;
            $display("slot: FIRST CPU access the mapper claims as SRAM at %0.3f ms after release, rd=%0d wr=%0d sram_over=%0d mem_unmaped=%0d, last fetch %04x, load in flight=%0d",
                     (t_first_slot_sram - t_release) / 1e6, MSX.msx_slots.cpu_rd, MSX.msx_slots.cpu_wr,
                     MSX.msx_slots.sram_over, MSX.msx_slots.mem_unmaped, last_fetch, load_flight);
            $fflush;
            ->sram_first_ev;
         end
      end
   end

   //  Every change of the interrupt nets from release on (first 200), so a
   //  source that asserts without being acknowledged -- or never asserts --
   //  shows up with its time, not only at an INTA.
   logic [5:0] irq_mon, irq_mon_q = 6'h3F;
   int         n_irq_mon = 0;
   assign irq_mon = {MSX.vdp_int_n, MSX.ms_int_n, MSX.midi_int_n,
                     MSX.msx_slots.dev_midi.cs, MSX.msx_slots.dev_midi.timer_irq,
                     MSX.msx_slots.dev_midi.rxrdy_irq};
   always @(posedge clk21m) if (trace_on) begin
      irq_mon_q <= irq_mon;
      if (irq_mon != irq_mon_q && n_irq_mon < 200) begin
         n_irq_mon++;
         $display("irq: %0.3f ms  vdp_int_n=%b ms_int_n=%b midi_int_n=%b  midi cs=%b timer=%b rxrdy=%b",
                  ($realtime - t_release) / 1e6, irq_mon[5], irq_mon[4], irq_mon[3],
                  irq_mon[2], irq_mon[1], irq_mon[0]);
      end
   end

   //  The CPU swap (turbo R CHGCPU): which core owns the bus, and whether the
   //  swap state machine ever leaves RUN for good.
   logic [4:0] swp, swp_q = 5'h1F;
   int         n_swp = 0;
   assign swp = {MSX.CPUSWAP.use_nz, MSX.CPUSWAP.want_nz, MSX.CPUSWAP.freeze, 2'(MSX.CPUSWAP.st)};
   always @(posedge clk21m) if (trace_on) begin
      swp_q <= swp;
      if (swp != swp_q && n_swp < 200) begin
         n_swp++;
         $display("swap: %0.3f ms  use_nz=%b want_nz=%b freeze=%b st=%0d  pc~%04x",
                  ($realtime - t_release) / 1e6, swp[4], swp[3], swp[2], swp[1:0], last_fetch);
      end
   end

   //  +forcez80: keep T80s on the bus through CHGCPU.  A discriminator, not a
   //  configuration: if the boot gets further with it, the stall is inside
   //  NextZ80 rather than in the firmware or the VDP.
   initial if ($test$plusargs("forcez80")) begin
      $display("forcez80: tr_r800 held at 0, NextZ80 never takes the bus");
      force MSX.tr_r800 = 1'b0;
   end

   //  What is actually executing in the post-CHGCPU loop: the opcode byte the
   //  CPU fetched (d_to_cpu at the end of each M1 read) for PCs in 7B70-7B8F,
   //  with the slot layout entry and SDRAM/BRAM address it came from.  The
   //  ROM file alone cannot say, since the bank in page 1 is only known live.
   logic m1rd, m1rd_q = 1'b0;
   logic [7:0] m1_byte;
   logic [15:0] m1_addr;
   logic [5:0]  m1_lid;
   logic [26:0] m1_raddr;
   int   n_op = 0;
   assign m1rd = ~MSX.m1_n & ~MSX.mreq_n & ~MSX.rd_n;
   always @(posedge clk21m) if (trace_on) begin
      m1rd_q <= m1rd;
      if (m1rd) begin
         m1_byte <= MSX.d_to_cpu; m1_addr <= fetch_a;
         m1_lid <= MSX.msx_slots.layout_id; m1_raddr <= ram_addr;
      end
      if (m1rd_q && !m1rd && m1_addr >= 16'h7B70 && m1_addr <= 16'h7B8F && n_op < 60) begin
         n_op++;
         $display("op: %0.3f ms  %04x: %02x  layout_id=%0d mapper=%0d ram_addr=%07x  use_nz=%b nz_IFF1=%b",
                  ($realtime - t_release) / 1e6, m1_addr, m1_byte,
                  m1_lid, MSX.msx_slots.mapper, m1_raddr, use_nz, MSX.NZ.CPUStatus[6]);
      end
   end

   //  IFF1 of both cores around the CPU swap: does the owning core have
   //  interrupts enabled while the frame interrupt is pending?  NextZ80's
   //  acceptance is SINT & CPUStatus[6] (nextz80cpu.v:206/225).
   logic [2:0] ie, ie_q = 3'b111;
   int         n_ie = 0;
   assign ie = {MSX.T80.u0.inte_ff1, MSX.NZ.CPUStatus[6], use_nz};
   always @(posedge clk21m) if (trace_on && ($realtime - t_release) > 590e6) begin
      ie_q <= ie;
      if (ie != ie_q && n_ie < 60) begin
         n_ie++;
         $display("iff: %0.3f ms  t80 IFF1=%b  nz IFF1=%b  use_nz=%b  vdp_int_n=%b  pc~%04x",
                  ($realtime - t_release) / 1e6, ie[2], ie[1], ie[0], MSX.vdp_int_n, last_fetch);
      end
   end

   //  S1990 (turbo R): every write to E4h/E5h and every change of its CPU/mode
   //  register.  Reg 6 bits 6:5 = cpust: 11 Z80, 10 R800-ROM, 00 R800-DRAM
   //  (docs/illusion_city_turbor_20260920.md:53).  tr_dram is read by nothing
   //  functional in msx.sv, so a firmware that selects DRAM mode and checks it
   //  would wait forever.
   logic       s19_wr_q = 1'b0;
   logic [1:0] cpust_q = 2'b11;
   int         n_s19 = 0;
   always @(posedge clk21m) if (trace_on) begin
      s19_wr_q <= io_wr && (MSX.a[7:1] == 7'b1110_010);
      if (io_wr && (MSX.a[7:1] == 7'b1110_010) && !s19_wr_q && n_s19 < 80) begin
         n_s19++;
         //  chg_arm decides how the byte reads: armed by the fetch at 0180h
         //  (CHGCPU), turbor.sv:204 decodes din[1:0] (0 Z80, 1 R800-ROM,
         //  2 R800-DRAM); otherwise reg 6 takes din[6:5].
         $display("s1990: %0.3f ms  OUT (%02x),%02x  regsel=%0d  chg_arm=%0d  pc~%04x",
                  ($realtime - t_release) / 1e6, MSX.a[7:0], MSX.d_from_cpu, MSX.turbor.regsel,
                  MSX.turbor.chg_arm, last_fetch);
      end
      cpust_q <= MSX.turbor.cpust;
      if (MSX.turbor.cpust != cpust_q)
         $display("s1990: %0.3f ms  cpust %b -> %b  (r800=%b dram=%b)",
                  ($realtime - t_release) / 1e6, cpust_q, MSX.turbor.cpust,
                  ~MSX.turbor.cpust[0], ~MSX.turbor.cpust[1]);
   end

   //  Positive control for the read detector: +ctlread=<ms> forces one CPU-side
   //  read of the SRAM window's first byte that long after release.  A run
   //  with it must report FIRST CPU read at that time and stop +after later;
   //  without it, "0 reads" and "the detector never fired" look the same.
   //  It drives the bus, so it is a control run only, never a measurement.
   initial begin
      int ctl_ms;
      if ($value$plusargs("ctlread=%d", ctl_ms)) begin
         wait (trace_on);
         #(ctl_ms * 1_000_000);
         @(posedge clk21m);
         while (bram_ce || sdram_ce) @(posedge clk21m);   // between real accesses
         $display("ctl: forcing one read of the SRAM window at %0.3f ms after release",
                  ($realtime - t_release) / 1e6);
         force ram_addr = 27'(lookup_SRAM[sav_idx < 0 ? 3 : sav_idx].addr);
         force ram_rnw  = 1'b1;
         force bram_ce  = 1'b1;
         repeat (2) @(posedge clk21m);
         release bram_ce; release ram_rnw; release ram_addr;
      end
   end

   function automatic string ms_since(realtime t);
      return (t < 0) ? "never" : $sformatf("%0.3f ms", (t - t_release) / 1e6);
   endfunction

   //  Every byte the engine writes into SRAM must be the byte the image held.
   int  sram_bytes = 0, sram_bad = 0;
   always @(posedge clk21m) if (nv_ram_we) begin
      automatic int off = (sav_idx < 0) ? -1 : int'(nv_ram_addr) - int'(lookup_SRAM[sav_idx].addr);
      sram_bytes++;
      if (off >= 0 && off < sav_bytes && nv_buff_dout !== savmem[off]) sram_bad++;
   end

   //  MSX1.sv:1267 -- and the FFh default is load-bearing: an unmapped read is
   //  what a runaway executes as RST 38h.
   assign ram_dout = sdram_ce ? sdram_dout : bram_ce ? bram_dout : 8'hFF;
   assign sdram_size = 2'd2;

   //  ── reset / pacing ───────────────────────────────────────────────────────
   int rst_n_cnt = 256;
   always @(posedge clk21m) if (rst_n_cnt) rst_n_cnt <= rst_n_cnt - 1;

   clock u_clock
   (
      .clk21m(clk21m), .reset(reset),
      .ce_10m7_p(ce_10m7_p), .ce_10m7_n(),
      .ce_5m39_p(), .ce_5m39_n(ce_5m39_n),
      .ce_3m58_p(ce_3m58_p), .ce_3m58_n(ce_3m58_n),
      .ce_10hz(ce_10hz),
      //  As MSX1.sv:637 -- NextZ80 (R800 mode) runs at full rate.  This was
      //  3'd0, so after CHGCPU the bench ran the R800 at the Z80's enable,
      //  about six times too slow, and SDRAM's guard kept the slow limit.
      .cpu_speed(use_nz ? 3'd4 : 3'd0), .cpu_bus_idle(cpu_bus_idle),
      .ce_cpu(ce_cpu), .cpu_turbo(cpu_turbo), .cpu_speed_q(cpu_speed_q)
   );

   //  ── everything the machine needs that nothing else drives ────────────────
   initial begin
      reset = 1'b1; reset_ms = 1'b1; msx_pause = 1'b0;
      r800_fast = 1'b0; r800_vdpw = 3'd0; r800_set_stb = 1'b0; r800_set = 1'b0;
      turbor_en = 1'b1; probe_freeze = 1'b0; dma_active = 1'b0;
      ps2_key = 11'd0; joy0 = 16'd0; joy1 = 16'd0; joymega_en = 2'd0;
      cas_audio_in = 1'b0; rtc_time = 65'd0;
      ioctl_download = 1'b0; ioctl_index = 16'd0; ioctl_addr = 27'd0;
      ioctl_wr = 1'b0; ioctl_dout = 8'd0; cheat_en_master = 1'b0;
      img_mounted = 1'b0; img_size = 32'd0; img_readonly = 1'b0;
      sd_ack = 1'b0; sd_buff_addr = 14'd0; sd_buff_dout = 8'd0; sd_buff_wr = 1'b0;
      d_from_sd = 8'd0; sd_ready = 1'b0;
      psg_vol = 4'd0; opll_vol = 4'd0; scc_vol = 4'd0; scc_en = 2'd0;
      scc_ch_en = 5'h1F; psg_mute = 1'b0; opll_mute = 1'b0;
      pcm_mute = 1'b1; fm_mute = 1'b1; pcm_vol = 4'd0; fm_vol = 4'd0;
      msxConfig = '{default:'0};
      for (int i = 0; i < 2; i++) selected_mapper[i] = MAPPER_UNUSED;
      sram_save = 1'b0; sram_load = 1'b0;
   end

   msx MSX (.*);

   //  ── trace: the branch-target stream, same shape the JTAG ring prints ─────
   logic m1_q = 1'b0;
   logic [15:0] last_fetch = 16'd0;
   int    nev = 0, limit_ms = 60;
   initial if (!$value$plusargs("ms=%d", limit_ms)) limit_ms = 60;
   int    trace_on = 0;
   //  The CPU bus is internal to msx.sv (the two cores are muxed onto it at
   //  rtl/msx.sv:393-400), so the bench reads it hierarchically rather than
   //  asking for new ports -- the DUT stays exactly what the board builds.
   wire   m1_fetch = ~MSX.m1_n & ~MSX.mreq_n & ~MSX.rd_n;
   wire [15:0] fetch_a = MSX.a;

   //  Branch targets only -- an opcode fetch whose address is not 1..4 past the
   //  previous one.  Same rule as rtl/evt_trace.sv, so the two streams diff.
   always @(posedge clk21m) begin
      m1_q <= m1_fetch;
      if (m1_fetch & ~m1_q) begin
         if (trace_on && nev < 12)
            $display("    fetch %04x  sdram_ce=%b bram_ce=%b ram_addr=%07x ram_dout=%02x  layout0={mapper=%0d ref_ram=%0d}",
                     fetch_a, sdram_ce, bram_ce, ram_addr, ram_dout,
                     slot_layout[0].mapper, slot_layout[0].ref_ram);
         if (trace_on && (fetch_a == last_fetch || (fetch_a - last_fetch) > 16'd4)) begin
            nev = nev + 1;
            if (nev < 400000) $display("%12.3f  BR  %04x", $realtime/1000000.0, fetch_a);
         end
         last_fetch <= fetch_a;
      end
   end

   //  Which of the four images this pack's SRAM belongs to is the pack's choice,
   //  not ours: a machine's own battery SRAM is the Computer CMOS image, a cart's
   //  is the ROM one.  Take the first allocation the pack actually made.
   //  Mount the image on VD0, the slot A ROM's raw .sav.  Since 2026-10-04 every
   //  other SRAM (FM-PAC, GM2, machine SRAM, RTC) lives in the SRAM file on VD1,
   //  which has a header per entry (docs/sram_images.md), so a raw image can only
   //  ever stand for bank 0; the entry format has its own bench (run_nvram_layout).
   int sav_idx = -1;                       // filled in by the SD model, on first use
   task mount_sav;
      begin
         nv_img_size    = 64'(sav_bytes);
         nv_img_mounted = 2'b01;
         @(posedge clk21m);
         nv_img_mounted = 2'b00;
         $display("sav: mounted on VD0, %0d bytes", sav_bytes);
      end
   endtask

   initial begin
      #1;
      //  the .sav, if one was given
      begin
         int fd, c;
         if ($value$plusargs("sav=%s", sav_file)) begin
            fd = $fopen(sav_file, "rb");
            if (fd == 0) begin $display("FATAL: cannot open %0s", sav_file); $finish; end
            c = $fgetc(fd);
            while (c >= 0 && sav_bytes < SAVMAX) begin
               savmem[sav_bytes] = 8'(c); sav_bytes++; c = $fgetc(fd);
            end
            $fclose(fd);
            sav_late = $test$plusargs("savlate");
            $display("sav: %0d bytes from %0s (%0s)", sav_bytes, sav_file,
                     sav_late ? "mounted after the upload" : "mounted before the upload");
         end
      end
      wait (pack_bytes > 0);
      repeat (64) @(posedge clk21m);
      //  The firmware mounts <rom>.sav around the ROM load.  Both orders happen
      //  in the field, and the late one is what used to lose the auto-load.
      if (sav_bytes > 0 && !sav_late) mount_sav();
      //  stage the FW pack first (index 2), the way it sits in DDR3 on a board where
      //  one was loaded once and left there.  Its own load pulse runs an empty walk.
      if (fw_bytes > 0) begin
         ioctl_index = 16'd2; ioctl_download = 1'b1;
         repeat (32) @(posedge clk21m);
         ioctl_addr = 27'(fw_bytes);
         ioctl_download = 1'b0;
         for (int t = 0; t < 1_000_000; t++) begin @(posedge clk21m); if (reset_rq) break; end
         for (int t = 0; t < 10_000_000; t++) begin @(posedge clk21m); if (!reset_rq) break; end
         repeat (64) @(posedge clk21m);
         $display("fwpack: staged as index 2");
      end
      //  stage the machine pack (index 1), exactly as hps_io's falling edge does
      ioctl_index = 16'd1; ioctl_download = 1'b1;
      repeat (32) @(posedge clk21m);
      ioctl_addr = 27'(pack_bytes);
      ioctl_download = 1'b0;
      $display("upload: started");
      //  reset_rq is ALREADY low before the load begins (the FSM sits in IDLE),
      //  so waiting for "not busy" straight away returns instantly and the
      //  machine is released onto an empty SDRAM.  Wait for busy first.
      for (int t = 0; t < 1_000_000; t++) begin
         @(posedge clk21m);
         if (reset_rq) break;
      end
      if (!reset_rq) begin $display("FATAL: memory_upload never started"); $finish; end
      for (int t = 0; t < 200_000_000; t++) begin
         @(posedge clk21m);
         if (!reset_rq) break;
      end
      $display("upload: done at %0t", $time);
      for (int i = 0; i < 4; i++)
         $display("upload: lookup_SRAM[%0d] = %0d kB at %0d", i, lookup_SRAM[i].size, lookup_SRAM[i].addr);
      begin
         int nz = 0;
         for (int i = 0; i < 64; i++) if (slot_layout[i].mapper != MAPPER_UNUSED) begin
            nz++;
            $display("upload: slot_layout[%0d] (slot %0d-%0d page %0d) mapper=%0d device=%0d ref_ram=%0d ref_sram=%0d",
                     i, i>>4, (i>>2)&3, i&3, slot_layout[i].mapper, slot_layout[i].device,
                     slot_layout[i].ref_ram, slot_layout[i].ref_sram);
         end
         $display("upload: %0d of 64 layout entries populated", nz);
      end
      if (sav_bytes > 0 && sav_late) begin
         repeat (200) @(posedge clk21m);      // the request is already out by now
         mount_sav();
      end
      repeat (64) @(posedge clk21m);
      //  An upload can also end early and quietly: a MOONSOUND device record with
      //  no inline ROM looks for yrw801 in the FW pack, and with none staged the
      //  walk stops before the CONFIG record and before load_sram.  MSX_typ then
      //  stays MSX1, the TMS9918 model answers a turbo R BIOS, and the machine
      //  sits in an interrupt it never clears.  Say so here, not an hour later.
      //  Sampled here, 64 clocks after reset_rq fell: load_sram pulses on that
      //  same edge, so a check made there reads the flag before it is set.
      //  (Plain numbers: a ternary between two string literals prints nothing.)
      $display("upload: MSX_typ=%0d (0=MSX1 1=MSX2)  msx_device=%b  load_sram issued=%0d",
               int'(bios_config.MSX_typ), msx_device, load_sram_seen);
      $display("upload: bios_ver=%02x (002Dh: 0 MSX1 1 MSX2 2 MSX2+ 3 turbo R, ff = not read)", bios_config.ver);
      //  A hard stop, not a warning: a tree without the firmware-search fix
      //  (bbdf660) printed this WARNING and then ran for hours on a machine with no
      //  CONFIG and no .sav.  $fatal, not $finish: $finish let the process run on
      //  and exited 0.  (A late mount, +sav_late, still sees the request first.)
      if (sav_bytes > 0 && !load_sram_seen)
         $fatal(1, "a .sav is mounted but the upload never asked for it");
      //  Loud but not fatal: run_packver and friends also boot real MSX1 packs.
      if (int'(bios_config.MSX_typ) != 1 && !$test$plusargs("expect_msx1"))
         $display("WARNING: the upload left MSX_typ at MSX1 (CONFIG not reached?); +expect_msx1 if intended");
      mupack_report();
      if (sav_bytes > 0 && sav_late) begin
         repeat (200) @(posedge clk21m);      // the request is already out by now
         mount_sav();
      end
      reset = 1'b0; reset_ms = 1'b0;
      trace_on = 1;
      t_release = $realtime;
      $display("reset released at %0t", $time);
      bios_check();
      $fflush;
      //  Stop at the limit, or +after=<ms> past the first SRAM access, read or
      //  write (default 500) -- once that exists the rest of the boot is not
      //  the question.
      begin
         int after_ms;
         if (!$value$plusargs("after=%d", after_ms)) after_ms = 500;
         fork
            #(longint'(limit_ms) * 64'd1_000_000);   // int overflowed past 2147 ms
            begin @(sram_first_ev); #(longint'(after_ms) * 64'd1_000_000); end
         join_any
         disable fork;
      end
      $display("--- %0.0f ms elapsed, %0d branch events ---", ($realtime - t_release) / 1e6, nev);
      if (sav_bytes > 0) begin
         for (int i = 0; i < 4; i++)
            $display("sav: lookup_SRAM[%0d] = %0d kB at %0d", i, lookup_SRAM[i].size, lookup_SRAM[i].addr);
         $display("sav: image %0d, %0d sectors served, %0d bytes into SRAM, %0d wrong",
                  sav_idx, sectors_served, sram_bytes, sram_bad);
         $display("sav: sector gap %0d cycles, load spanned %0d cycles (%0.2f ms), %0d sectors",
                  sd_gap, flight_cycles, real'(flight_cycles) / 21477.272, flight_sectors);
         $display("sav: CPU writes to BRAM during that span: %0d, of which inside the SRAM window: %0d",
                  bram_writes_in_flight, cpu_sram_writes);
         $display("sav: load ended at %0s after release", ms_since(t_load_end));
         $display("sav: CPU writes to BRAM since release: %0d, of which inside the SRAM window: %0d",
                  all_bram_writes, all_sram_writes);
         $display("int: %0d acknowledged; low at the time: vdp %0d, moonsound %0d, midi %0d, none %0d",
                  n_inta, n_inta_vdp, n_inta_ms, n_inta_midi, n_inta_none);
         $display("int: 99h reads %0d, of which bit 7 set %0d; VDP register writes %0d; 9Bh writes %0d",
                  n_rd99, n_rd99_f, n_regw, n_wr9b);
         $display("sav: first BRAM write %0s, first SRAM-window write %0s after release",
                  ms_since(t_first_bram), ms_since(t_first_sram));
         $display("slot: CPU accesses the mapper claimed as SRAM: %0d, of which sram_over %0d, mem_unmaped %0d; first %0s",
                  n_slot_sram, n_slot_sram_over, n_slot_sram_unmapped, ms_since(t_first_slot_sram));
         $display("sav: CPU reads of the SRAM window since release: %0d; first %0s (addr %0d, last fetch %04x)",
                  all_sram_reads, ms_since(t_first_sram_rd), first_rd_addr, first_rd_pc);
         if (t_first_sram >= 0)
            $display("sav: T_first = %0.3f ms (addr %0d, data %02x, last fetch %04x)",
                     (t_first_sram - t_release) / 1e6, first_sram_addr, first_sram_data, first_sram_pc);
         else
            $display("sav: T_first = none -- no SRAM-window write in this run; read the branch trace");
         if (sav_idx < 0)              $display("RESULT SKIP: this pack allocates no SRAM");
         else if (sectors_served == 0) $display("RESULT FAIL: the .sav was never read");
         else if (sram_bytes == 0)     $display("RESULT FAIL: nothing reached SRAM");
         else if (sram_bad != 0)       $display("RESULT FAIL: %0d bytes differ", sram_bad);
         else                          $display("RESULT PASS");
      end
      $finish;
   end


   //  ── MU-PACK checks ──────────────────────────────────────────────────────
   //  Every SDRAM byte the upload writes at offset 18h-1Fh of a 16 kB block is
   //  kept, so the ROM behind slot 2-2 page 1 can be read back by its base.  If
   //  that base is not 16 kB aligned the lookup says so instead of passing.
   byte unsigned rom_tail [int];
   always @(posedge clk21m)
      if (upl_ce & upl_sdram_rq & ((upl_addr & 27'h3FFF) >= 27'h18) & ((upl_addr & 27'h3FFF) <= 27'h1F))
         rom_tail[int'(upl_addr)] = upl_din;
   //  ── SDRAM demand (sdram128 study, 2026-10-13) ───────────────────────────
   //  How many SDRAM accesses the machine asks for, per channel, and the busiest
   //  1 ms / 100 us windows -- to size a TDM controller (one general slot per 12
   //  clk at 128.86 MHz = 10.74 M accesses/s; two = 21.5 M).  An access is an
   //  ACTIVE command.  "run" counts start when memory_upload releases the machine.
   //  The totals print with the window peaks: a zero total voids the peaks.
   logic upload_seen = 1'b0;
   always @(posedge clk21m) if (reset_rq) upload_seen <= 1'b1;
   longint sd_cyc = 0, sd_act = 0, sd_run_cyc = 0, sd_run_act = 0, sd_rq[4] = '{0,0,0,0};
   longint sd_hit = 0, sd_w1 = 0, sd_w1max = 0, sd_w01 = 0, sd_w01max = 0;
   int     sd_c1 = 0, sd_c01 = 0;
   logic   sd_run = 1'b0, sd_r1 = 1'b0, sd_r2 = 1'b0, sd_r3 = 1'b0, sd_r4 = 1'b0, sd_h = 1'b0;
   always @(posedge clk_sdram) begin
      automatic bit act = (u_sdram.command == 3'b011);
      sd_cyc++;
      if (act) sd_act++;
      if (reset_rq) sd_run = 1'b0; else if (sd_cyc > 1000 && !sd_run && upload_seen) sd_run = 1'b1;
      sd_r1 <= ch1_req; sd_r2 <= sdram_ce; sd_r3 <= flash_req; sd_r4 <= pcm_sdram_req; sd_h <= sdram_hit;
      if (sd_run) begin
         sd_run_cyc++;
         if (act) begin sd_run_act++; sd_w1++; sd_w01++; end
         if (ch1_req & ~sd_r1) sd_rq[0]++;
         if (sdram_ce & ~sd_r2) sd_rq[1]++;
         if (flash_req & ~sd_r3) sd_rq[2]++;
         if (pcm_sdram_req & ~sd_r4) sd_rq[3]++;
         if (sdram_hit & ~sd_h) sd_hit++;
         if (++sd_c1 == int'(1.0e6 / TCK_NS)) begin if (sd_w1 > sd_w1max) sd_w1max = sd_w1; sd_w1 = 0; sd_c1 = 0; end
         if (++sd_c01 == int'(1.0e5 / TCK_NS)) begin if (sd_w01 > sd_w01max) sd_w01max = sd_w01; sd_w01 = 0; sd_c01 = 0; end
      end
   end
   //  CPU read latency: from the request edge (sdram_ce & ram_rnw rising, seen at
   //  clk_sdram) to completion (ch2_rdtog flips, or a cache hit), in ns.  The
   //  same for both controllers, so the TDM figures can be put next to the ones
   //  of sdram.sv, which the board has run on.
   realtime lat_t0 = 0, lat_max = 0, lat_min = 1e9;   // first version divided ns by 1000: max read 0.2
   longint  lat_n = 0, lat_open = 0, lat_hist[8] = '{0,0,0,0,0,0,0,0};   // <100,<150,<200,<250,<300,<350,<400,>=400
   logic    lat_on = 1'b0, lat_ce = 1'b0, lat_tog = 1'b0, lat_hit = 1'b0;
   always @(posedge clk_sdram) begin
      lat_ce <= sdram_ce & ram_rnw;
      if (sd_run && sdram_ce && ram_rnw && !lat_ce) begin lat_on <= 1'b1; lat_t0 = $realtime; lat_tog <= sdram_rdtog; lat_open++; end
      else if (lat_on && (sdram_rdtog != lat_tog || sdram_hit)) begin
         automatic realtime d;
         d = $realtime - lat_t0;              // timescale 1ns: already ns
         if (d < lat_min) lat_min = d;
         lat_on <= 1'b0; lat_n++;
         if (d > lat_max) lat_max = d;
         lat_hist[(d >= 400.0) ? 7 : int'(d / 50.0) - 1 < 0 ? 0 : int'(d / 50.0) - 1]++;
      end
   end
   final begin
      $display("cpu read latency: requests=%0d completed=%0d min=%.1f max=%.1f ns  hist <100:%0d <150:%0d <200:%0d <250:%0d <300:%0d <350:%0d <400:%0d >=400:%0d",
               lat_open, lat_n, lat_min, lat_max, lat_hist[0], lat_hist[1], lat_hist[2], lat_hist[3], lat_hist[4], lat_hist[5], lat_hist[6], lat_hist[7]);
      $display("sdram demand: all cycles=%0d ACT=%0d | run cycles=%0d (%.1f ms) ACT=%0d (%.3f M/s, busy-equivalent %.1f%% of one 12-clk slot stream)",
               sd_cyc, sd_act, sd_run_cyc, sd_run_cyc * TCK_NS * 1e-6, sd_run_act,
               sd_run_cyc ? sd_run_act / (sd_run_cyc * TCK_NS * 1e-9) / 1e6 : 0.0,
               sd_run_cyc ? 100.0 * (sd_run_act / (sd_run_cyc * TCK_NS * 1e-9)) / 10.74e6 : 0.0);
      $display("sdram demand: run requests ch1=%0d ch2=%0d (cache hits %0d) ch3=%0d ch4=%0d",
               sd_rq[0], sd_rq[1], sd_hit, sd_rq[2], sd_rq[3]);
      $display("sdram demand: busiest 1 ms = %0d ACT (%.3f M/s), busiest 100 us = %0d ACT (%.3f M/s)",
               sd_w1max, sd_w1max / 1.0e3, sd_w01max, sd_w01max / 100.0e-6 / 1e6);
   end

   //  What the CPU actually latched, read by read (sdram128 study, 2026-10-13):
   //  T80s takes DI on the CEN edge of TState 2 with WAIT_n high (T80s.vhd:202);
   //  NextZ80 on the clk21m edge nz_bus advances.  For an SDRAM read the line also
   //  says whether ch2 had completed THIS request by then (rdtog moved since the
   //  window opened, or a cache hit) -- "LATE" means the CPU took a stale byte.
   //  The first RDL_MAX reads after release are printed; LATE is counted always.
   localparam int RDL_MAX = 3000;
   int      rdl_n = 0, rdl_late = 0, rdl_sd = 0;
   logic    rdl_win_q = 1'b0, rdl_tog0 = 1'b0, rdl_cdone = 1'b0;
   realtime rdl_t0 = 0, rdl_tc = 0;
   //  slack = latch time - completion time, per T80s SDRAM read (not paced), split
   //  M1 / other; completion seen at clk_sdram (below), so it is exact to 7.8 ns
   realtime rdl_slack_min[2] = '{1e9, 1e9}, rdl_lat_max[2] = '{0, 0};
   always @(posedge clk_sdram)
      if (!rdl_win) rdl_cdone <= 1'b0;
      else if (rdl_win_q && !rdl_cdone && (sdram_rdtog != rdl_tog0 || sdram_hit)) begin
         rdl_cdone <= 1'b1; rdl_tc = $realtime;
      end
   wire     rdl_win   = ~MSX.mreq_n & ~MSX.rd_n & sdram_ce & ram_rnw;
   wire     rdl_t80   = ~MSX.use_nz & ce_cpu & ~MSX.t80_hold & MSX.wait_n & (MSX.T80.tstate == 3'd2);
   wire     rdl_nz    = MSX.use_nz & MSX.NZB.adv;
   //  (Verilator 5.052 does not link MSX.x inside $display: copy them out)
   wire        rdl_usenz = MSX.use_nz, rdl_m1n = MSX.m1_n;
   wire [15:0] rdl_a     = MSX.a;
   wire  [7:0] rdl_d     = MSX.d_to_cpu;
   always @(posedge clk21m) begin
      rdl_win_q <= rdl_win;
      if (rdl_win & ~rdl_win_q) begin rdl_tog0 <= sdram_rdtog; rdl_t0 = $realtime; end
      if (rst_n_cnt == 0 && trace_on && ~MSX.mreq_n & ~MSX.rd_n & (rdl_t80 | rdl_nz)) begin
         automatic bit sd = rdl_win & rdl_win_q;
         automatic bit done = sd && (sdram_rdtog != rdl_tog0 || sdram_hit);
         if (sd) rdl_sd++;
         if (sd && !done) rdl_late++;
         if (sd && done && rdl_t80 && rdl_cdone) begin
            automatic int k = rdl_m1n ? 1 : 0;
            if ($realtime - rdl_tc < rdl_slack_min[k]) rdl_slack_min[k] = $realtime - rdl_tc;
            if (rdl_tc - rdl_t0 > rdl_lat_max[k]) rdl_lat_max[k] = rdl_tc - rdl_t0;
         end
         if (rdl_n < RDL_MAX || (sd && !done))
            $display("%12.3f  RDL %s %04x %02x %s%s %0.1f", $realtime/1000000.0, rdl_usenz ? "nz" : "t8",
                     rdl_a, rdl_d, rdl_m1n ? "rd" : "m1",
                     !sd ? " other" : (done ? (sdram_hit ? " hit" : " sd") : " LATE"),
                     sd ? $realtime - rdl_t0 : 0.0);
         rdl_n++;
      end
   end
   final begin
      $display("cpu latched reads: %0d, from sdram %0d, LATE (ch2 not complete) %0d", rdl_n, rdl_sd, rdl_late);
      $display("T80s sdram reads: M1 latency max %.1f ns, slack min %.1f ns | other latency max %.1f ns, slack min %.1f ns",
               rdl_lat_max[0], rdl_slack_min[0], rdl_lat_max[1], rdl_slack_min[1]);
   end

   //  Did the upload land?  The first record of a machine pack is its BIOS, the
   //  32 kB right after the 16-byte header, filled at lookup_RAM[0] (2026-10-13:
   //  sdram_tdm dropped upload bytes and the machine diverged at the 5th branch).
   //  Both chip models index words by byte address [24:1] for the low 32 MB.
`ifdef TDM
   //  Why a ch2 SDRAM read is slow (sdram_tdm): edge seen -> queued (ch2_rq) ->
   //  picked by a G slot -> captured, in clocks, and what each passed-over G
   //  decision saw: R = refresh frame on the chip, B = the previous G slot's bank,
   //  O = another channel picked (none of these = the CPU was not queued yet).
   //  Printed for reads over TDM_SLOW_CLK clocks.
   localparam int TDM_SLOW_CLK = 24;
   int    ts_cyc = 0, ts_e0 = -1, ts_q = -1, ts_p = -1;
   string ts_why = "";
   logic  ts_rq_q = 1'b0, ts_tog = 1'b0;
   wire   ts_dec = u_sdram.run & (u_sdram.ps[2] | u_sdram.ps[6]);
   wire   ts_rf  = |u_sdram.rf_now | (u_sdram.ps[2] & |u_sdram.rf_next);
   wire   ts_bk  = u_sdram.prev_v & (u_sdram.cand_l[0].b == u_sdram.prev_b);
   wire   ts_ok0 = u_sdram.cand_ok[0];
   wire   ts_oth = |u_sdram.cand_ok[3:1];
   always @(posedge clk_sdram) begin
      ts_cyc++;
      ts_rq_q <= u_sdram.ch2_rq;
      if (sdram_ce & ram_rnw & ~u_sdram.ch2_req_1) begin ts_e0 = ts_cyc; ts_q = -1; ts_p = -1; ts_why = ""; ts_tog <= sdram_rdtog; end
      if (u_sdram.ch2_rq & ~ts_rq_q & ts_q < 0) ts_q = ts_cyc;
      if (ts_dec && ts_q >= 0 && ts_p < 0) begin
         if (ts_ok0) ts_p = ts_cyc;
         else ts_why = {ts_why, ts_rf ? "R" : ts_bk ? "B" : ts_oth ? "O" : "-"};
      end
      if (ts_e0 >= 0 && sdram_rdtog != ts_tog && ts_p >= 0) begin
         if (ts_cyc - ts_e0 > TDM_SLOW_CLK)
            $display("%12.3f  SLOW ch2 read: %0d clk (queued +%0d, picked +%0d, captured +%0d) passed-over [%s] ph@edge=%0d",
                     $realtime/1000000.0, ts_cyc - ts_e0, ts_q - ts_e0, ts_p - ts_e0, ts_cyc - ts_e0, ts_why, int'(u_sdram.ph));
         ts_e0 = -1;
      end
   end
`endif

   //  clk_opl3 measured, not assumed: the OPL3 core wants 14.318 MHz whatever
   //  clk_sdram is (msx.sv divider; it was a fixed /6, 21.48 MHz at 128.86 MHz).
   wire     opl3_ck = MSX.clk_opl3;
   longint  opl3_n = 0;
   realtime opl3_t0 = 0, opl3_t1 = 0;
   always @(posedge opl3_ck) if (trace_on) begin
      if (opl3_n == 0) opl3_t0 = $realtime;
      opl3_t1 = $realtime; opl3_n++;
   end
   final if (opl3_n > 1)
      $display("clk_opl3: %0d edges over %.3f ms = %.4f MHz (OPL3 wants 14.3182)",
               opl3_n, (opl3_t1 - opl3_t0) / 1e6, (opl3_n - 1) / (opl3_t1 - opl3_t0) * 1e3);

   task automatic bios_check();
      int bad = 0, first = -1;
      int base;
      base = int'(lookup_RAM[0].addr);
      for (int i = 0; i < 32768 && 16 + i < pack_bytes; i++) begin
         logic [15:0] w;
         logic  [7:0] b;
         w = u_chip.mem[24'((base + i) >> 1)];
         b = ((base + i) & 1) ? w[15:8] : w[7:0];
         if (b !== packmem[16 + i]) begin bad++; if (first < 0) first = base + i; end
      end
      $display("upload check: BIOS 32 kB at %07x vs pack: %0d bytes differ%s", base, bad,
               first < 0 ? "" : $sformatf(" (first at %07x)", first));
   endtask
   //  A ch1 request edge that finds the previous one still queued overwrites it.
   int ch1_over = 0;
   logic ch1_req_q = 1'b0;
   always @(posedge clk_sdram) begin
      ch1_req_q <= ch1_req;
`ifdef TDM   // sdram.sv declares ch1_rq inside its always block: not reachable
      if (ch1_req & ~ch1_req_q & u_sdram.ch1_rq) ch1_over++;
`endif
   end
   final $display("ch1 request edges onto a queued request: %0d", ch1_over);

   task automatic mupack_report();
      int b, bad = 0;
      string sig = "";
      $display("mupack: slot B typ=%0d expander_en=%b (slot 2 expanded=%0d)",
               int'(cart_conf[1].typ), bios_config.slot_expander_en, bios_config.slot_expander_en[2]);
      for (int p = 0; p < 4; p++)
         $display("mupack: 2-1 page %0d mapper=%0d ref_ram=%0d size=%0d x16kB   2-2 page %0d mapper=%0d ref_ram=%0d",
                  p, slot_layout[36+p].mapper, slot_layout[36+p].ref_ram, lookup_RAM[slot_layout[36+p].ref_ram].size,
                  p, slot_layout[40+p].mapper, slot_layout[40+p].ref_ram);
      b = int'(lookup_RAM[slot_layout[41].ref_ram].addr);
      if (slot_layout[41].mapper == MAPPER_UNUSED) sig = "(slot 2-2 page 1 empty)";
      else if ((b & 32'h3FFF) != 0) sig = $sformatf("(base %07x not 16kB aligned: not checked)", b);
      else for (int k = 8'h18; k <= 8'h1F; k++) sig = {sig, rom_tail.exists(b + k) ? string'(rom_tail[b + k]) : "?"};
      $display("mupack: ROM at slot 2-2 page 1, base %07x, bytes 18h-1Fh = \"%s\"", b, sig);
      $display("mupack: MIDI gt=%0d mu=%0d ext=%0d osd=%0d -> cs=%0d external=%0d ext_ctl=%02x",
               MSX.msx_slots.midi_gt, MSX.msx_slots.midi_mu, MSX.msx_slots.midi_ext, MSX.msx_slots.midi_io_en,
               MSX.msx_slots.dev_midi.cs, MSX.msx_slots.dev_midi.external, MSX.msx_slots.dev_midi.ext_ctl);
   endtask
endmodule

//  32 MB behavioural SDRAM: {BA, row, col} = 24 bits of 16-bit words.  The one
//  in tb/tb_common.sv is 64 K words, which is smaller than a machine pack.
module sdram_big
(
   input               clk,
   output wire [15:0]  DQ_out,
   input       [15:0]  DQ_in,
   input               DQ_oe,
   input        [12:0] A,
   input         [1:0] BA,
   input nCS, input nWE, input nRAS, input nCAS, input DQML, input DQMH
);
   reg [15:0] mem [0:(1<<24)-1];
   reg [12:0] row [0:3];
   reg [15:0] dq_p0, dq_p1;
   reg  [1:0] oe_p = 2'b00;

   assign DQ_out = oe_p[1] ? dq_p1 : 16'h0000;

   wire [2:0] cmd = {nRAS, nCAS, nWE};
   localparam [2:0] C_ACTIVE = 3'b011, C_READ = 3'b101, C_WRITE = 3'b100;
   wire [23:0] idx = {BA, row[BA], A[8:0]};

   always @(posedge clk) begin
      oe_p  <= {oe_p[0], 1'b0};
      dq_p1 <= dq_p0;
      if (!nCS) begin
         case (cmd)
            C_ACTIVE: row[BA] <= A;
            C_READ  : begin dq_p0 <= mem[idx]; oe_p <= {oe_p[0], 1'b1}; end
            C_WRITE : begin
               if (!DQML) mem[idx][7:0]  <= DQ_in[7:0];
               if (!DQMH) mem[idx][15:8] <= DQ_in[15:8];
            end
            default : ;
         endcase
      end
   end
endmodule

//  sdram128 study: CL3 / BL2 / write burst, DQM = A[12:11] (latency 2 read, 0
//  write), on the chip clock = clk_sdram falling (the controller's SDRAM_CLK is
//  the inverted clock).  Functional only -- sim/sdram_tdm/sdram_chk.sv checks the
//  timing.  Chip 1 (nCS high) is not modelled: the bench runs the 32 MB map.
module sdram_big_tdm
(
   input               clk,
   output reg  [15:0]  DQ_out,
   input       [15:0]  DQ_in,
   input               DQ_oe,
   input        [12:0] A,
   input         [1:0] BA,
   input nCS, input nWE, input nRAS, input nCAS, input DQML, input DQMH
);
   reg [15:0] mem [0:(1<<24)-1];
   reg [12:0] row [0:3];
   wire [2:0] cmd = {nRAS, nCAS, nWE};
   //  read pipeline: slot n = the word valid n chip edges from now
   reg [23:0] rq_idx [0:5];
   reg        rq_v   [0:5];
   reg  [1:0] dqm_d1, dqm_d2;
   reg [23:0] w_idx;  reg w_pend = 1'b0;
   initial for (int i = 0; i < 6; i++) rq_v[i] = 1'b0;
   //  the word reaches the FPGA pins after the next FPGA rising edge (STA, as in
   //  sim/sdram_tdm/sdram_chk.sv): it is put on DQ_out there, non-blocking
   reg [15:0] pend = 16'h0000;
   always @(posedge clk) DQ_out <= pend;
   always @(negedge clk) begin
      // the word valid at this chip edge
      for (int i = 0; i < 4; i++) begin rq_v[i] = rq_v[i+1]; rq_idx[i] = rq_idx[i+1]; end
      rq_v[4] = 1'b0;
      pend <= (rq_v[0] && dqm_d2 == 2'b00) ? mem[rq_idx[0]] : 16'h0000;     // DQM latency 2
      dqm_d2 = dqm_d1; dqm_d1 = A[12:11];
      if (w_pend) begin
         if (!A[11]) mem[w_idx][7:0]  <= DQ_in[7:0];
         if (!A[12]) mem[w_idx][15:8] <= DQ_in[15:8];
         w_pend = 1'b0;
      end
      if (!nCS) case (cmd)
         3'b011: row[BA] <= A;
         3'b101: begin
            rq_v[3] = 1'b1; rq_idx[3] = {BA, row[BA], A[8:0]};          // CL3
            rq_v[4] = 1'b1; rq_idx[4] = {BA, row[BA], A[8:1], ~A[0]};
         end
         3'b100: begin
            if (!A[11]) mem[{BA, row[BA], A[8:0]}][7:0]  <= DQ_in[7:0];
            if (!A[12]) mem[{BA, row[BA], A[8:0]}][15:8] <= DQ_in[15:8];
            w_idx = {BA, row[BA], A[8:1], ~A[0]}; w_pend = 1'b1;
         end
         default: ;
      endcase
   end
endmodule
