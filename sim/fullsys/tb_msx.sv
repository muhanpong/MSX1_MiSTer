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
   always #5.820 clk_sdram = ~clk_sdram;       // 85.909 MHz: 11.64 ns period
                                              // (1ps resolution -- at 1ns the
                                              //  half period rounds to 500x slow)
   logic [1:0] cdiv = 2'd0;
   always @(posedge clk_sdram) cdiv <= cdiv + 2'd1;
   assign clk21m = cdiv[1];

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
         ddr3_dout <= (ddr3_addr < 28'(pack_bytes)) ? packmem[ddr3_addr] : 8'hFF;

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

   sdram u_sdram
   (
      .init(rst_n_cnt != 0), .clk(clk_sdram), .doRefresh(1'b1),
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

   sdram_big u_chip
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

   wire  [31:0] nv_sd_lba[4];
   wire   [3:0] nv_sd_rd, nv_sd_wr;
   logic  [3:0] nv_sd_ack    = 4'b0;
   logic [13:0] nv_buff_addr = 14'd0;
   logic  [7:0] nv_buff_dout = 8'd0;
   wire   [7:0] nv_buff_din[4];
   wire  [17:0] nv_ram_addr;
   wire         nv_ram_we;
   wire   [7:0] nv_ram_dout;
   logic  [3:0] nv_img_mounted = 4'b0;
   logic [63:0] nv_img_size    = 64'd0;
   logic        nv_img_ro      = 1'b0;

   nvram_backup u_nvram
   (
      .clk(clk21m), .reset(reset),
      .lookup_SRAM(lookup_SRAM),
      .load_req(upl_load_sram), .save_req(1'b0),
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
            for (int k = 0; k < 4; k++) if (nv_sd_rd[k] | nv_sd_wr[k]) n = k;
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
   always @(posedge clk21m) begin
      load_flight_q <= load_flight;
      if (load_flight_q && !load_flight && t_load_end < 0) t_load_end = $realtime;
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
               $display("sav: FIRST CPU write into the SRAM window at %0.3f ms after release, addr %0d data %02x, last fetch %04x",
                        (t_first_sram - t_release) / 1e6, ram_addr, ram_din, last_fetch);
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
         $display("hb: %0.0f ms after release, %0d branch events, BRAM writes %0d, SRAM window %0d, load in flight=%0d",
                  ($realtime - t_release) / 1e6, nev, all_bram_writes, all_sram_writes,
                  load_flight);
         $fflush;
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
      .cpu_speed(3'd0), .cpu_bus_idle(cpu_bus_idle),
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
   //  Mount all four images.  Which one the pack's SRAM lands on is only known
   //  after the upload has run, and the firmware mounts <rom>.sav around the ROM
   //  load without knowing either; the engine walks the banks and uses the one
   //  that has an allocation.  Picking an index up front needed the allocation to
   //  exist already, which before the upload it never does -- that is what made
   //  the first run report SKIP on a pack that allocates 16 kB perfectly well.
   int sav_idx = -1;                       // filled in by the SD model, on first use
   task mount_sav;
      begin
         nv_img_size    = 64'(sav_bytes);
         nv_img_mounted = 4'b1111;
         @(posedge clk21m);
         nv_img_mounted = 4'b0000;
         $display("sav: mounted on all four images, %0d bytes", sav_bytes);
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
            if (nz <= 6) $display("upload: slot_layout[%0d] (slot %0d-%0d page %0d) mapper=%0d ref_sram=%0d",
                                  i, i>>4, (i>>2)&3, i&3, slot_layout[i].mapper, slot_layout[i].ref_sram);
         end
         $display("upload: %0d of 64 layout entries populated", nz);
      end
      //  An upload can also end early and quietly: a MOONSOUND device record with
      //  no inline ROM looks for yrw801 in the FW pack, and with none staged the
      //  walk stops before the CONFIG record and before load_sram.  MSX_typ then
      //  stays MSX1, the TMS9918 model answers a turbo R BIOS, and the machine
      //  sits in an interrupt it never clears.  Say so here, not an hour later.
      //  (Plain numbers: a ternary between two string literals prints nothing.)
      $display("upload: MSX_typ=%0d (0=MSX1 1=MSX2)  msx_device=%b  load_sram issued=%0d",
               int'(bios_config.MSX_typ), msx_device, load_sram_seen);
      if (sav_bytes > 0 && !load_sram_seen)
         $display("WARNING: a .sav is mounted but the upload never asked for it");
      if (sav_bytes > 0 && sav_late) begin
         repeat (200) @(posedge clk21m);      // the request is already out by now
         mount_sav();
      end
      repeat (64) @(posedge clk21m);
      reset = 1'b0; reset_ms = 1'b0;
      trace_on = 1;
      t_release = $realtime;
      $display("reset released at %0t", $time);
      $fflush;
      //  Stop at the limit, or +after=<ms> past the first SRAM write (default
      //  100) -- once T_first exists the rest of the boot is not the question.
      begin
         int after_ms;
         if (!$value$plusargs("after=%d", after_ms)) after_ms = 100;
         fork
            #(limit_ms * 1_000_000);
            begin @(sram_first_ev); #(after_ms * 1_000_000); end
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
         $display("sav: first BRAM write %0s, first SRAM-window write %0s after release",
                  ms_since(t_first_bram), ms_since(t_first_sram));
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
