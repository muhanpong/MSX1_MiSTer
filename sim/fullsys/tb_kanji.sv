//  tb_kanji -- tb_msx with the BIOS reset vector replaced by a kanji-ROM probe.
//
//      sim/fullsys/prep.sh && sim/fullsys/run_kanji.sh <pack.MSX> z80|r800
//
//  The probe is the board's 2026-09-23 BASIC experiment (handoff §3) as 100
//  bytes of machine code at 0000h: select the CPU through S1990 register 6
//  (E4h/E5h), set JIS 07FBh on D9h/D8h, 32x IN A,(C) from D9h, then re-set the
//  address and INIR 32 bytes into C000h.  Every D8h-DBh I/O cycle is printed
//  with the byte the CPU actually latched (d_to_cpu on the last clk21m of the
//  strobe) and the guard/SDRAM state at that edge.  Run it once per CPU and
//  diff: the Z80 column is known good on the board, the R800 column is stale.
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
   localparam int PACKSZ = 1 << 21;
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
      $fclose(fd);
      pack_bytes = i;
      $display("pack: %0d bytes from %s", pack_bytes, pack_file);
      patch_probe();
   end

   //  ── the probe, written over the BIOS at its offset in the pack file ──────
   //  +bios=<byte offset of the BIOS block in the .MSX> (default 16: header),
   //  +cpu=z80|r800 -> S1990 reg 6 = 60h / 40h (bit 5: 1 = Z80, 0 = R800).
   //  The machine boots from 0000h in slot 0 page 0 with everything else at
   //  reset defaults, so the probe needs no stack until the INIR part, which
   //  first puts slot 3-0 (main RAM on every Panasonic 2+/turbo R) into page 3.
   int    bios_off = 16;
   string cpu_sel  = "z80";
   task automatic patch_probe();
      logic [7:0] code [0:255];
      int n = 0, r6;
      void'($value$plusargs("bios=%d", bios_off));
      void'($value$plusargs("cpu=%s", cpu_sel));
      r6 = (cpu_sel == "r800") ? 8'h40 : 8'h60;
      `define B(x) code[n] = 8'(x); n = n + 1;
      //  turbor.sv overlays 002Dh (MSXVER = 3) and 0180h-018Bh (CHGCPU/GETCPU)
      //  on top of page 0 -- a probe byte at 002Dh comes back as 03h (first run:
      //  the 14th IN pair became ED 03 and the loop went to port DAh).  Jump
      //  over the ID bytes; the code then ends well below 0180h.
      `B('h18) `B('h3E)                          // JR 0040h
      while (n < 'h40) begin `B('h00) end
      `B('hF3)                                   // DI
      `B('h3E) `B('h06) `B('hD3) `B('hE4)        // LD A,6 / OUT (E4h),A
      `B('h3E) `B(r6)   `B('hD3) `B('hE5)        // LD A,r6 / OUT (E5h),A
      `B('h3E) `B('h07) `B('hD3) `B('hD9)        // LD A,07h / OUT (D9h),A   JIS high
      `B('h3E) `B('hFB) `B('hD3) `B('hD8)        // LD A,FBh / OUT (D8h),A   JIS low
      `B('h0E) `B('hD9)                          // LD C,D9h
      for (int k = 0; k < 32; k++) begin `B('hED) `B('h78) end   // IN A,(C) x32
      `B('h3E) `B('hC0) `B('hD3) `B('hA8)        // LD A,C0h / OUT (A8h),A   page 3 = slot 3
      `B('hAF) `B('h32) `B('hFF) `B('hFF)        // XOR A / LD (FFFFh),A      slot 3 subslots = 0
      //  A DIFFERENT glyph for the INIR pass (JIS 07FCh): after the IN pass the
      //  07FBh words all sit in sdram.sv's read cache (the Z80 run showed hit=1
      //  on every INIR read), and the board's failure is in the misses.
      `B('h3E) `B('h07) `B('hD3) `B('hD9)        // JIS 07FCh
      `B('h3E) `B('hFC) `B('hD3) `B('hD8)
      `B('h21) `B('h00) `B('hC0)                 // LD HL,C000h
      `B('h06) `B('h20)                          // LD B,32
      `B('h0E) `B('hD9)                          // LD C,D9h
      `B('hED) `B('hB2)                          // INIR
      `B('h18) `B('hFE)                          // JR $  (park)
      `undef B
      for (int k = 0; k < n; k++) packmem[bios_off + k] = code[k];
      $display("probe: %0d bytes at pack+%0d, cpu=%s (S1990 r6=%02x)", n, bios_off, cpu_sel, r6);
   endtask

   //  ── DDR3 model: memory_upload reads the staged file back byte at a time ──
   //  The HPS puts the file in DDR3 on real hardware; nothing arrives through
   //  ioctl_dout.  `ready` is the arbiter's periodic grant, as in
   //  sim/tb_device_reload.sv.
   logic [27:0] ddr3_addr;
   logic        ddr3_rd, ddr3_wr, ddr3_request;
   logic  [7:0] ddr3_dout;
   logic        ddr3_ready = 1'b0;
   int          rdiv = 0;
   always @(posedge clk21m) begin
      rdiv <= (rdiv == 3) ? 0 : rdiv + 1;
      ddr3_ready <= (rdiv == 3);
   end
   //  memory_upload's protocol (memory_upload.sv:170,182): it raises ddr3_rd, the
   //  ready pulse that sees rd high ACCEPTS the request (rd drops, ddr3_addr
   //  advances), and the NEXT ready pulse, with rd low, consumes ddr3_dout.  So
   //  dout has to be the byte at the address the request was accepted with, held
   //  until the next accept -- a plain one-clock delay on the address (what
   //  tb_msx.sv does) has already moved on to addr+1 by the consuming pulse, and
   //  the header reads "SX@": the magic check fails silently and the pack is
   //  skipped with no message at all.  Latch on the accept, like ddram.sv.
   logic [7:0] ddr3_lat = 8'hFF;
   always @(posedge clk21m)
      if (ddr3_ready & ddr3_rd) ddr3_lat <= (ddr3_addr < 28'(pack_bytes)) ? packmem[ddr3_addr] : 8'hFF;
   always_comb ddr3_dout = ddr3_lat;

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
      .address_b(16'd0), .data_b(8'd0), .enable_b(1'b1), .wren_b(1'b0),
      .q_b(), .cs_b(1'b1)
   );

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

   //  Branch targets, first 40 only (enough to see the probe start and park).
   always @(posedge clk21m) begin
      m1_q <= m1_fetch;
      if (m1_fetch & ~m1_q) begin
         if (trace_on && (fetch_a == last_fetch || (fetch_a - last_fetch) > 16'd4)) begin
            nev = nev + 1;
            if (nev < 40) $display("%12.3f  BR  %04x  use_nz=%b", $realtime/1000000.0, fetch_a, use_nz);
         end
         last_fetch <= fetch_a;
      end
   end

   //  ── I/O trace: every D8h-DBh cycle, with what the CPU latched ────────────
   //  The byte the CPU takes is d_to_cpu on the LAST clk21m edge the strobe is
   //  low (NextZ80: the nz_bus `adv` edge; T80s: end of T3).  Register the bus
   //  every edge and print the registered copy when RD/WR rises.
   wire        io_cyc  = ~MSX.iorq_n & (MSX.a[7:2] == 6'b110110) & (~MSX.rd_n | ~MSX.wr_n);
   logic       io_q = 1'b0, io_rd_q = 1'b0;
   logic [7:0] io_a_q, io_d_q, io_do_q;
   logic       q_sdram_ce, q_hit, q_hs_done, q_gopen, q_gslow, q_wait_n, q_adv, q_rdy;
   logic [4:0] q_gcnt;
   int         n_rd = 0, n_wr = 0, cyc_len = 0;
   logic [7:0] got_in [0:31], got_inir [0:31];
   always @(posedge clk21m) begin
      io_q <= io_cyc;
      if (io_cyc) begin
         cyc_len   <= cyc_len + 1;
         io_rd_q   <= ~MSX.rd_n;
         io_a_q    <= MSX.a[7:0];
         io_d_q    <= MSX.d_to_cpu;
         io_do_q   <= MSX.d_from_cpu;
         q_sdram_ce<= sdram_ce;     q_hit   <= sdram_hit;      q_hs_done <= MSX.hs_done;
         q_gopen   <= MSX.guard_open; q_gslow <= MSX.guard_slow; q_wait_n <= MSX.wait_n;
         q_adv     <= MSX.NZB.adv;  q_gcnt  <= MSX.guard_cnt;  q_rdy     <= ch2_ready;
      end else if (io_q) begin
         if (io_rd_q) begin
            $display("%12.3f  IN  %02x -> %02x   len=%0d clk21m  sdram_ce=%b hit=%b hs_done=%b gopen=%b gslow=%b gcnt=%0d wait_n=%b adv=%b use_nz=%b",
                     $realtime/1000000.0, io_a_q, io_d_q, cyc_len, q_sdram_ce, q_hit, q_hs_done,
                     q_gopen, q_gslow, q_gcnt, q_wait_n, q_adv, use_nz);
            if (n_rd < 32)      got_in[n_rd]        = io_d_q;
            else if (n_rd < 64) got_inir[n_rd - 32] = io_d_q;
            n_rd = n_rd + 1;
         end else begin
            $display("%12.3f  OUT %02x <- %02x   len=%0d clk21m  use_nz=%b", $realtime/1000000.0, io_a_q, io_do_q, cyc_len, use_nz);
            n_wr = n_wr + 1;
         end
         cyc_len <= 0;
      end
   end

   //  ── clock-level window: every clk_sdram from the first D9h read, +wave=N ──
   int wave_n = 0, wave_left = 0, wave_started = 0;
   initial void'($value$plusargs("wave=%d", wave_n));
   always @(posedge clk_sdram) begin
      if (!wave_started && n_rd == 0 && io_cyc && ~MSX.rd_n) begin wave_started = 1; wave_left = wave_n; end
      if (wave_left > 0) begin
         wave_left = wave_left - 1;
         $display("W %10.4f c21=%b iorq_n=%b rd_n=%b a=%02x ph=%b adv=%b wait_n=%b | kce=%b kaddr=%02x | sce=%b hit=%b rdy=%b hs=%b gopen=%b gcnt=%0d | cpend=%b pend2=%b caddr=%02x sa0=%b sdata=%04x | dcpu=%02x",
                  $realtime/1000000.0, clk21m, MSX.iorq_n, MSX.rd_n, MSX.a[7:0], MSX.NZB.ph, MSX.NZB.adv, MSX.wait_n,
                  MSX.msx_slots.device_kanji_ram_ce, MSX.msx_slots.kanji.addr1[7:0],
                  sdram_ce, sdram_hit, ch2_ready, MSX.hs_done, MSX.guard_open, MSX.guard_cnt,
                  u_sdram.ch2_cpend, u_sdram.c_pend2, u_sdram.ch2_caddr[7:0],
                  u_sdram.ch2_saved_a0, u_sdram.ch2_saved_data, MSX.d_to_cpu);
      end
   end

   task automatic report();
      $write("  IN  x32 : "); for (int i = 0; i < 32; i++) $write("%02h ", got_in[i]);   $write("\n");
      $write("  INIR x32: "); for (int i = 0; i < 32; i++) $write("%02h ", got_inir[i]); $write("\n");
      $display("RESULT: cpu=%s reads=%0d writes=%0d", cpu_sel, n_rd, n_wr);
   endtask

   initial begin
      #1;
      wait (pack_bytes > 0);
      repeat (64) @(posedge clk21m);
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
      repeat (64) @(posedge clk21m);
      reset = 1'b0; reset_ms = 1'b0;
      trace_on = 1;
      $display("reset released at %0t", $time);
      //  64 reads (32 IN + 32 INIR) end the run; limit_ms is the safety net.
      fork
         begin #(limit_ms * 1_000_000); $display("--- %0d ms elapsed, timeout ---", limit_ms); end
         begin wait (n_rd >= 64); repeat (200) @(posedge clk21m); end
      join_any
      report();
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
