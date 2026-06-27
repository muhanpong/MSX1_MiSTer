module msx
(
   input                    reset,
   //Clock
   input                    clk21m,
   input                    ce_10m7_p,
   input                    ce_3m58_p,
   input                    ce_3m58_n,
   input                    ce_5m39_n,
   input                    ce_10hz,
   input                    clk_sdram,
   input                    dma_active,
   //Video
   output             [7:0] R,
   output             [7:0] G,
   output             [7:0] B,
   output                   DE,
   output                   HS,
   output                   VS,
   output                   hblank,
   output                   vblank,
   output                   ce_pix,
   //I/O
   output signed     [15:0] audio_l,
   output signed     [15:0] audio_r,
   input  [           10:0] ps2_key,
   input              [5:0] joy0,
   input              [5:0] joy1,
   //Cassete
   output                   cas_motor,
   input                    cas_audio_in,
   //MSX config
   input             [64:0] rtc_time,
   input MSX::bios_config_t bios_config,
   input MSX::user_config_t msxConfig,
   input  dev_typ_t         cart_device[2],
   input  dev_typ_t         msx_device,
   input              [3:0] msx_dev_ref_ram[8],
   input  mapper_typ_t      selected_mapper[2],
   input                    sram_save,
   input                    sram_load,
   //IOCTL
   input                    ioctl_download,
   input             [15:0] ioctl_index,
   input             [26:0] ioctl_addr,
   input                    ioctl_wr,
   input             [7:0]  ioctl_dout,
   input                    cheat_en_master,   // OSD: cheats Off/On (status[51])
   //SDRAM/BRAM
   output            [26:0] ram_addr,
   output             [7:0] ram_din,
   output                   ram_rnw,
   output                   sdram_ce,
   output                   bram_ce,
   input              [7:0] ram_dout,
   input              [1:0] sdram_size,
   input MSX::block_t       slot_layout[64],
   input MSX::lookup_RAM_t  lookup_RAM[16],
   input MSX::lookup_SRAM_t lookup_SRAM[4],
   //KBD
   input                    kbd_request,
   input              [8:0] kbd_addr,
   input              [7:0] kbd_din,
   input                    kbd_we,
   output            [26:0] flash_addr,
   output             [7:0] flash_din,
   output                   flash_req,
   input                    flash_ready,
   input                    flash_done,
   //SD FDC
   input                    img_mounted,
   input             [31:0] img_size,
   input                    img_readonly,
   output            [31:0] sd_lba,
   output                   sd_rd,
   output                   sd_wr,
   input                    sd_ack,
   input             [13:0] sd_buff_addr,
   input              [7:0] sd_buff_dout,
   output             [7:0] sd_buff_din,
   input                    sd_buff_wr,
   output             [7:0] d_to_sd,
   input              [7:0] d_from_sd,
   output                   sd_tx,
   output                   sd_rx,
   // ASCII16X flash info
   output              [1:0] flash16x_active,
   output             [26:0] flash16x_base[2],
   output             [15:0] flash16x_size[2],
   // MoonSound PCM SDRAM interface (ch4)
   output             [26:0] pcm_sdram_addr,
   output                    pcm_sdram_req,
   output                    pcm_sdram_rnw,
   output              [7:0] pcm_sdram_din,
   input               [7:0] pcm_sdram_dout,
   input              [15:0] pcm_sdram_dout16,
   input                     pcm_sdram_ready,
   // PCM ROM base address in SDRAM (set by memory_upload)
   input              [26:0] pcm_rom_base,

   // MoonSound audio mute (debug)
   input                     pcm_mute,
   input                     fm_mute,
   input               [1:0] pcm_vol,

   // MoonSound debug outputs (clk_sdram domain)
   output wire               dbg_pcm_valid,
   output wire               dbg_opl3_valid,
   output wire signed [15:0] dbg_pcm_level,
   output wire               dbg_new2,
   output wire [4:0]         dbg_keyon_count,
   output wire [4:0]         dbg_accum_cnt,
   output wire [9:0]         dbg_env_min,
   output wire               dbg_mem_nonzero,
   output wire               dbg_pcm_base_set,  // 1 if pcm_rom_base != default
   output wire        [23:0] dbg_slot_keyon,
   output wire        [23:0] dbg_slot_active,
   output wire        [23:0] dbg_slot_envlive,
   // vgmplay OPL-timer freeze detectors (sticky latches, clk21m)
   output logic              dbg_wait_stuck,
   output logic              dbg_irq_stuck,
   output logic              dbg_cpu_nom1,
   output logic              dbg_intack_stop,  // CPU not taking the asserted OPL IRQ
   output wire               dbg_ack_stopped,  // reg4 ack writes stopped (clk_sdram, from ymf278b_top)
   output logic              dbg_iff_stuck_off, // irq asserted while IFF1==0 (EI unreached)
   output logic              dbg_int_refused,   // irq asserted, IFF1==1, yet no INTA (T80 acceptance)
   output logic       [15:0] dbg_pc_snap,       // PC at the last IFF1-fall before green latched
   output logic       [15:0] dbg_pc_vec,        // PC of handler entry after the last INTA
   output logic       [15:0] dbg_pc_now,        // live PC (dark-freeze spin locator)
   output logic       [15:0] dbg_im_i,          // {IM[1:0], 6'b0, I[7:0]} at last INTA
   output logic       [15:0] dbg_watch_pc,      // PC of last write to IM2 table byte 257
   output logic       [15:0] dbg_watch_dc,      // {written data, write count} for that byte
   output logic              dbg_int_ghost      // fatal IFF1-fall had NO INTA (DI-death / ghost)
);

//  -----------------------------------------------------------------------------
//  -- Audio MIX  (stereo; MoonSound is mixed in after instantiation below)
//  -----------------------------------------------------------------------------
wire  [9:0] audioPSG = ay_ch_mix + {keybeep,5'b00000} + {(cas_audio_in & ~cas_motor),4'b0000};
wire [16:0] fm       = {3'b00, audioPSG, 4'b0000};
wire [16:0] mono_mix = {cart_sound[15], cart_sound} + fm;
// Saturating compressor (same as original `compr[7:0]` lookup, inline)
// Index audio_mix[16:14]: 000→linear-pos, 111→linear-neg, others→clamp
wire signed [15:0] mono_audio =
    (mono_mix[16:14] == 3'b000) ? {1'b0, mono_mix[13:0], 1'b0} :
    (mono_mix[16:14] == 3'b111) ? {1'b1, mono_mix[13:0], 1'b0} :
    mono_mix[16] ? 16'sh8000 : 16'sh7FFF;
// MoonSound stereo mix wires — driven by the MoonSound block below
wire signed [15:0] ms_audio_l, ms_audio_r;
wire signed [16:0] mix_l = $signed({mono_audio[15], mono_audio}) + $signed({ms_audio_l[15], ms_audio_l});
wire signed [16:0] mix_r = $signed({mono_audio[15], mono_audio}) + $signed({ms_audio_r[15], ms_audio_r});
// Saturate 17-bit signed → 16-bit signed: clip only on real overflow (sign mismatch)
assign audio_l = (mix_l[16] == mix_l[15]) ? mix_l[15:0] : (mix_l[16] ? 16'sh8000 : 16'sh7FFF);
assign audio_r = (mix_r[16] == mix_r[15]) ? mix_r[15:0] : (mix_r[16] ? 16'sh8000 : 16'sh7FFF);

//  -----------------------------------------------------------------------------
//  -- T80 CPU
//  -----------------------------------------------------------------------------
wire [15:0] a;
wire [7:0] d_to_cpu, d_from_cpu;
wire mreq_n, wr_n, m1_n, iorq_n, rd_n, rfrsh_n;
t80pa #(.Mode(0)) T80
(
   .RESET_n(~reset),
   .CLK(clk21m),
   .CEN_p(ce_3m58_p),
   .CEN_n(ce_3m58_n),
   .WAIT_n(wait_n),
   // Z80 /INT is shared (wired-AND, active-low) between the VDP and the
   // MoonSound (YMF278B/OPL4) Timer-1 IRQ.  MoonSound music players (e.g.
   // MBwave, vgmplay OPLTimer) drive their playback tick from the OPL Timer-1
   // overflow interrupt, so its irq line must reach the CPU.  ms_int_n is the
   // 2-FF-synced irq with I/O-cycle deferral (defined in the MoonSound block).
   .INT_n(vdp_int_n & ms_int_n),
   .NMI_n(1),
   .BUSRQ_n(1),
   .M1_n(m1_n),
   .MREQ_n(mreq_n),
   .IORQ_n(iorq_n),
   .RD_n(rd_n),
   .WR_n(wr_n),
   .RFSH_n(rfrsh_n),
   .HALT_n(1),
   .BUSAK_n(),
   .A(a),
   .DI(d_to_cpu),
   .DO(d_from_cpu),
   .REG(t80_reg)        // [211]=IFF2 [210]=IFF1 ... — freeze diagnosis
);
wire [211:0] t80_reg;

//  -----------------------------------------------------------------------------
//  -- WAIT CPU
//  -----------------------------------------------------------------------------
// Hold the CPU (WAIT_n low) while a MoonSound register access is in flight, so
// the VGM driver's rapid back-to-back writes can't outrun the CDC/chip and drop.
// Only asserts during 0x7E/0x7F/0xC4-0xC7 access when moonsound_en; bounded by a
// safety timeout (ms_wait_cnt) so a lost ack cannot hang the CPU.
wire exwait_n = ~ms_io_pending;

logic wait_n = 1'b0;
always @(posedge clk21m, negedge exwait_n, negedge u1_2_q) begin
   if (~exwait_n)
      wait_n <= 1'b0;
   else if (~u1_2_q)
      wait_n <= 1'b1;
   else if (ce_3m58_p)
      wait_n <= m1_n;
end

logic u1_2_q = 1'b0;
always @(posedge clk21m, negedge exwait_n) begin
   if (~exwait_n)
      u1_2_q <= 1'b1;
   else if (ce_3m58_p)
      u1_2_q <= wait_n;
end

logic map_valid = 0;
wire ppi_en = ~ppi_n;
wire [1:0] slot;

always @(posedge reset, posedge clk21m) begin
    if (reset)
        map_valid = 0;
    else if (ppi_en)
        map_valid = 1;
end

assign slot =    ~map_valid         ? 2'b00         :
                  a[15:14] == 2'b00 ? ppi_out_a[1:0] :
                  a[15:14] == 2'b01 ? ppi_out_a[3:2] :
                  a[15:14] == 2'b10 ? ppi_out_a[5:4] :
                                      ppi_out_a[7:6] ;

//  -----------------------------------------------------------------------------
//  -- IO Decoder
//  -----------------------------------------------------------------------------
wire psg_n  = ~((a[7:3] == 5'b10100)   & ~iorq_n & m1_n);
wire ppi_n  = ~((a[7:3] == 5'b10101)   & ~iorq_n & m1_n);
wire vdp_en =   (a[7:3] == 5'b10011)   & ~iorq_n & m1_n ;
wire rtc_en =   (a[7:1] == 7'b1011010) & ~iorq_n & m1_n & bios_config.MSX_typ == MSX2;

// MoonSound: WAVE 0x7E/7F, FM 0xC4-0xC7
wire ms_wave_cs = msxConfig.moonsound_en & ~iorq_n & m1_n &
                  (a[7:0] == 8'h7E | a[7:0] == 8'h7F);
wire ms_fm_cs   = msxConfig.moonsound_en & ~iorq_n & m1_n &
                  (a[7:2] == 6'b11_0001);     // 0xC4-0xC7

//  -----------------------------------------------------------------------------
//  -- 82C55 PPI
//  -----------------------------------------------------------------------------
wire [7:0] d_from_8255;
wire [7:0] ppi_out_a, ppi_out_c;
wire keybeep = ppi_out_c[7];
assign cas_motor =  ppi_out_c[4];
jt8255 PPI
(
   .rst(reset),
   .clk(clk21m),
   .addr(a[1:0]),
   .din(d_from_cpu),
   .dout(d_from_8255),
   .rdn(rd_n),
   .wrn(wr_n),
   .csn(ppi_n),
   .porta_din(8'h0),
   .portb_din(d_from_kb),
   .portc_din(8'h0),
   .porta_dout(ppi_out_a),
   .portb_dout(),
   .portc_dout(ppi_out_c)
 );

//  -----------------------------------------------------------------------------
//  -- CPU data multiplex
//  -----------------------------------------------------------------------------
wire [7:0] ms_dout;   // driven by MoonSound block below

//  ----- Cheat engine: 4-way set-associative BRAM (capacity 2048), fed by standard .gg -----
//  BRAM-indexed lookup (no comparator cloud) — handles whole-game cheat sets (e.g. castlemore
//  222). HPS sends ONLY enabled cheats on ioctl index 255 as 16-byte records
//  [flags LE32][addr LE32][compare LE32][replace LE32]. We use addr (bytes 4,5) and the
//  replace value (byte 12) => freeze/POKE (flags/compare ignored; our cheats are pokes).
//  512 sets x 4 ways. slot = {gen[2:0], tag[6:0], value[7:0]} (18b). index=a[8:0], tag=a[15:9].
//  gen bump on each new download invalidates the previous set (no sweep/race).
//  Override at the d_to_cpu mux (memory reads). flash.sv / msx_slots / SDRAM untouched.
(* ramstyle = "M10K" *) logic [17:0] cheat_ram0 [512];
(* ramstyle = "M10K" *) logic [17:0] cheat_ram1 [512];
(* ramstyle = "M10K" *) logic [17:0] cheat_ram2 [512];
(* ramstyle = "M10K" *) logic [17:0] cheat_ram3 [512];
logic [17:0] cq0, cq1, cq2, cq3;       // registered reads at set index a[8:0]
logic [15:0] a_q;                      // address aligned with the registered read
logic [3:0]  cwe;                      // per-way write enable (loader)
logic [8:0]  cwaddr;
logic [17:0] cwdata;

always @(posedge clk21m) begin
   cq0 <= cheat_ram0[a[8:0]]; cq1 <= cheat_ram1[a[8:0]];
   cq2 <= cheat_ram2[a[8:0]]; cq3 <= cheat_ram3[a[8:0]];
   a_q <= a;
   if (cwe[0]) cheat_ram0[cwaddr] <= cwdata;
   if (cwe[1]) cheat_ram1[cwaddr] <= cwdata;
   if (cwe[2]) cheat_ram2[cwaddr] <= cwdata;
   if (cwe[3]) cheat_ram3[cwaddr] <= cwdata;
end

logic [2:0] cur_gen;                   // current generation (1..7, never 0)
wire [3:0]  chit;                      // slot: [17:15]=gen, [14:8]=tag, [7:0]=value
assign chit[0] = (cq0[17:15]==cur_gen) & (cq0[14:8]==a_q[15:9]);
assign chit[1] = (cq1[17:15]==cur_gen) & (cq1[14:8]==a_q[15:9]);
assign chit[2] = (cq2[17:15]==cur_gen) & (cq2[14:8]==a_q[15:9]);
assign chit[3] = (cq3[17:15]==cur_gen) & (cq3[14:8]==a_q[15:9]);
wire        cheat_hit   = |chit;
wire [7:0]  cheat_value = chit[0]?cq0[7:0] : chit[1]?cq1[7:0] : chit[2]?cq2[7:0] : cq3[7:0];
wire        cheat_act   = cheat_en_master & cheat_hit & (a==a_q) & ~mreq_n & rfrsh_n;

// loader: standard .gg via ioctl index 255 (16-byte records). addr @bytes 4,5 ; value @byte 12.
// HPS sends only enabled cheats; every record is inserted. gen bump on download start invalidates.
logic       cheat_dl_q;
logic [7:0] ld_lo, ld_hi;
logic [1:0] nextway [512];
integer     ni;
wire        cheat_dl = ioctl_download & (ioctl_index[7:0]==8'd255);
wire [8:0]  ld_set   = {ld_hi[0], ld_lo};   // index = addr[8:0]
wire [6:0]  ld_tag   = ld_hi[7:1];          // tag   = addr[15:9]

initial cur_gen = 3'd1;
always @(posedge clk21m) begin
   cheat_dl_q <= cheat_dl;
   cwe <= 4'b0000;
   if (cheat_dl & ~cheat_dl_q) begin                       // new download: bump gen, reset way ptrs
      cur_gen <= (cur_gen==3'd7) ? 3'd1 : cur_gen + 3'd1;
      for (ni=0; ni<512; ni=ni+1) nextway[ni] <= 2'd0;
   end
   if (cheat_dl & ioctl_wr) begin
      case (ioctl_addr[3:0])                               // byte position within the 16-byte .gg record
         4'd4:  ld_lo <= ioctl_dout;                       // addr[7:0]
         4'd5:  ld_hi <= ioctl_dout;                       // addr[15:8]
         4'd12: begin                                      // replace value -> insert into next way of the set
                  cwe             <= (4'b0001 << nextway[ld_set]);
                  cwaddr          <= ld_set;
                  cwdata          <= {cur_gen, ld_tag, ioctl_dout};
                  nextway[ld_set] <= nextway[ld_set] + 2'd1;
               end
         default: ;
      endcase
   end
end

assign d_to_cpu = rd_n              ? 8'hFF           :
                  vdp_en            ? d_to_cpu_vdp    :
                  rtc_en            ? d_from_rtc      :
                  ~psg_n            ? d_from_psg      :
                  ~ppi_n            ? d_from_8255     :
                  (ms_wave_cs | ms_fm_cs) ? ms_dout   :
                  cheat_act         ? cheat_value     :   // standard .gg cheat override (memory reads)
                                    d_from_slots    ;
//  -----------------------------------------------------------------------------
//  -- Keyboard decoder
//  -----------------------------------------------------------------------------
wire [7:0] d_from_kb;
keyboard msx_key
(
   .reset(reset),
   .clk(clk21m),
   .ps2_key(ps2_key),
   .kb_row(ppi_out_c[3:0]),
   .kb_data(d_from_kb),
   .kbd_addr(kbd_addr),
   .kbd_din(kbd_din),
   .kbd_we(kbd_we),
   .kbd_request(kbd_request)
);

//  -----------------------------------------------------------------------------
//  -- Sound AY-3-8910
//  -----------------------------------------------------------------------------
wire [7:0] d_from_psg, psg_ioa, psg_iob;
wire [5:0] joy_a = psg_iob[4] ? 6'b111111 : {~joy0[5], ~joy0[4], ~joy0[0], ~joy0[1], ~joy0[2], ~joy0[3]};
wire [5:0] joy_b = psg_iob[5] ? 6'b111111 : {~joy1[5], ~joy1[4], ~joy1[0], ~joy1[1], ~joy1[2], ~joy1[3]};
wire [5:0] joyA = joy_a & {psg_iob[0], psg_iob[1], 4'b1111};
wire [5:0] joyB = joy_b & {psg_iob[2], psg_iob[3], 4'b1111};
assign psg_ioa = {cas_audio_in,1'b0, psg_iob[6] ? joyB : joyA};
wire [9:0] ay_ch_mix;

logic u21_1_q = 1'b0;
always @(posedge clk21m,  posedge psg_n) begin
   if (psg_n)
      u21_1_q <= 1'b0;
   else if (ce_3m58_p)
      u21_1_q <= ~psg_n;
end

logic u21_2_q = 1'b0;
always @(posedge clk21m, posedge psg_n) begin
   if (psg_n)
      u21_2_q <= 1'b0;
   else if (ce_3m58_p)
      u21_2_q <= u21_1_q;
end

wire psg_e = !(!u21_2_q | ce_3m58_p) | psg_n;
wire psg_bc   = !(a[0] | psg_e);
wire psg_bdir = !(a[1] | psg_e);
jt49_bus PSG
(
   .rst_n(~reset),
   .clk(clk21m),
   .clk_en(ce_3m58_p),
   .bdir(psg_bdir),
   .bc1(psg_bc),
   .din(d_from_cpu),
   .sel(0),
   .dout(d_from_psg),
   .sound(ay_ch_mix),
   .A(),
   .B(),
   .C(),
   .IOA_in(psg_ioa),
   .IOA_out(),
   .IOB_in(8'hFF),
   .IOB_out(psg_iob)
);

//  -----------------------------------------------------------------------------
//  -- RTC
//  -----------------------------------------------------------------------------
wire [7:0] d_from_rtc;
rtc rtc
(
   .clk21m(clk21m),
   .reset(reset),
   .setup(reset),
   .rt(rtc_time),
   .clkena(ce_10hz),
   .req(req & rtc_en),
   .ack(),
   .wrt(~wr_n),
   .adr(a),
   .dbi(d_from_rtc),
   .dbo(d_from_cpu)
);

//  -----------------------------------------------------------------------------
//  -- Video
//  -----------------------------------------------------------------------------
wire       VRAM_we_lo_vdp, VRAM_we_hi_vdp, vdp18, vdp ;
wire       vdp_int_n;
wire [7:0] d_to_cpu_vdp;

assign vdp18          = bios_config.MSX_typ == MSX1;
assign vdp            = bios_config.MSX_typ == MSX2;

//CPU access
assign d_to_cpu_vdp   = vdp18 ? d_from_vdp18                : d_from_vdp;
assign vdp_int_n      = vdp18 ? int_n_vdp18                 : int_n_vdp;

//Video access
assign R              = vdp18 ? R_vdp18                     : {R_vdp,R_vdp[5:4]};
assign G              = vdp18 ? G_vdp18                     : {G_vdp,G_vdp[5:4]};
assign B              = vdp18 ? B_vdp18                     : {B_vdp,B_vdp[5:4]};
assign HS             = vdp18 ? ~HS_n_vdp18                 : ~HS_n_vdp;
assign VS             = vdp18 ? ~VS_n_vdp18                 : ~VS_n_vdp;
assign DE             = vdp18 ? DE_vdp18                    : DE_vdp;
assign hblank         = vdp18 ? hblank_vdp18                : hblank_vdp_cor;
assign vblank         = vdp18 ? vblank_vdp18                : vblank_vdp;
assign ce_pix         = vdp18 ? ce_5m39_n                   : ~DHClk_vdp;

logic hblank_vdp_cor;
always @(posedge clk21m) begin
   if (hblank_vdp)
      hblank_vdp_cor <= 1'b1;
   else 
      if (DHClk_vdp & DLClk_vdp)
         hblank_vdp_cor <= 1'b0;
end


//VRAM access
assign VRAM_address   = vdp18 ? {2'b00, VRAM_address_vdp18} : VRAM_address_vdp[15:0];
assign VRAM_we_lo     = vdp18 ? VRAM_we_vdp18               : VRAM_we_lo_vdp;
assign VRAM_we_hi     = vdp18 ? 1'b0                        : VRAM_we_hi_vdp;
assign VRAM_do        = vdp18 ? VRAM_do_vdp18               : VRAM_do_vdp;

assign VRAM_we_lo_vdp = ~VRAM_we_n_vdp & DLClk_vdp & ~VRAM_address_vdp[16];
assign VRAM_we_hi_vdp = ~VRAM_we_n_vdp & DLClk_vdp &  VRAM_address_vdp[16];

logic iack;
always @(posedge clk21m) begin
   if (reset) iack <= 0;
   else begin
      if (iorq_n  & mreq_n)
         iack <= 0;
      else
         if (req)
            iack <= 1;
   end
end
wire req = ~((iorq_n & mreq_n) | (wr_n & rd_n) | iack);

wire        int_n_vdp18;
wire  [7:0] d_from_vdp18;
wire  [7:0] R_vdp18, G_vdp18, B_vdp18;
wire        HS_n_vdp18, VS_n_vdp18, DE_vdp18, DLClk_vdp18, hblank_vdp18, vblank_vdp18, Blank_vdp18;
wire [13:0] VRAM_address_vdp18;
wire  [7:0] VRAM_do_vdp18;
wire        VRAM_we_vdp18;
vdp18_core #(.compat_rgb_g(0)) vdp_vdp18
(
   .clk_i(clk21m),
   .clk_en_10m7_i(ce_10m7_p),
   .reset_n_i(~reset),
   .csr_n_i(~(vdp_en & vdp18) | rd_n),
   .csw_n_i(~(vdp_en & vdp18) | wr_n),
   .mode_i(a[0]),
   .cd_i(d_from_cpu),
   .cd_o(d_from_vdp18),
   .int_n_o(int_n_vdp18),
   .vram_we_o(VRAM_we_vdp18),
   .vram_a_o(VRAM_address_vdp18),
   .vram_d_o(VRAM_do_vdp18),
   .vram_d_i(VRAM_di_lo),
   .border_i(msxConfig.border),
   .rgb_r_o(R_vdp18),
   .rgb_g_o(G_vdp18),
   .rgb_b_o(B_vdp18),
   .hsync_n_o(HS_n_vdp18),
   .vsync_n_o(VS_n_vdp18),
   .hblank_o(hblank_vdp18),
   .vblank_o(vblank_vdp18),
   .blank_n_o(DE_vdp18),
   .is_pal_i(msxConfig.video_mode == PAL)
);

wire        int_n_vdp;
wire  [7:0] d_from_vdp;
wire  [5:0] R_vdp, G_vdp, B_vdp;
wire        HS_n_vdp, VS_n_vdp, DE_vdp, DLClk_vdp, DHClk_vdp, Blank_vdp, hblank_vdp, vblank_vdp;
wire [16:0] VRAM_address_vdp;
wire  [7:0] VRAM_do_vdp;
wire        VRAM_we_n_vdp;
vdp vdp_vdp 
(
   .CLK21M(clk21m),
   .RESET(reset),
   .REQ(req & vdp_en & vdp),
   .ACK(),
   .WRT(~wr_n),
   .ADR(a),
   .DBI(d_from_vdp),
   .DBO(d_from_cpu),
   .INT_N(int_n_vdp),
   .PRAMOE_N(),
   .PRAMWE_N(VRAM_we_n_vdp),
   .PRAMADR(VRAM_address_vdp),
   .PRAMDBI({VRAM_di_hi, VRAM_di_lo}),
   .PRAMDBO(VRAM_do_vdp),
   .VDPSPEEDMODE(0),
   .CENTERYJK_R25_N(0),
   .PVIDEOR(R_vdp),
   .PVIDEOG(G_vdp),
   .PVIDEOB(B_vdp),
   .PVIDEODE(DE_vdp),
   .BLANK_O(Blank_vdp),
   .HBLANK(hblank_vdp),
   .VBLANK(vblank_vdp),
   .PVIDEOHS_N(HS_n_vdp),
   .PVIDEOVS_N(VS_n_vdp),
   .PVIDEOCS_N(),
   .PVIDEODHCLK(DHClk_vdp),
   .PVIDEODLCLK(DLClk_vdp),
   .DISPRESO(/*msxConfig.scandoubler*/ 0),
   .LEGACY_VGA(1),
   .RATIOMODE(3'b000),
   .NTSC_PAL_TYPE(msxConfig.video_mode == AUTO),
   .FORCED_V_MODE(msxConfig.video_mode == PAL),
   .BORDER(msxConfig.border),
   .VDP_ID(5'b00000 | msxConfig.vdp_id << 1)
);

wire [15:0] VRAM_address;
wire  [7:0] VRAM_do, VRAM_di_lo, VRAM_di_hi;
wire        VRAM_we_lo, VRAM_we_hi;
spram #(.addr_width(16),.mem_name("VRA2")) vram_lo
(
   .clock(clk21m),
   .address(VRAM_address),
   .wren(VRAM_we_lo),
   .data(VRAM_do),
   .q(VRAM_di_lo)
);
spram #(.addr_width(16),.mem_name("VRA3")) vram_hi
(
   .clock(clk21m),
   .address(VRAM_address),
   .wren(VRAM_we_hi),
   .data(VRAM_do),
   .q(VRAM_di_hi)
);

wire         [7:0] d_from_slots;
wire signed [15:0] cart_sound;
msx_slots msx_slots
(
   .clk(clk21m),
   .clk_en(ce_3m58_p),
   .reset(reset),
   .cpu_addr(a),
   .cpu_din(d_from_slots),  
   .cpu_dout(d_from_cpu),
   .cpu_iorq(~iorq_n),
   .cpu_m1(~m1_n),
   .cpu_mreq(~mreq_n),
   .cpu_rd(~rd_n),
   .cpu_wr(~wr_n),
   .sound(cart_sound),
   .ram_addr(ram_addr),
   .ram_din(ram_din),
   .ram_rnw(ram_rnw),
   .ram_dout(ram_dout),
   .sdram_ce(sdram_ce),
   .bram_ce(bram_ce),
   .sdram_size(sdram_size),
   .flash_addr(flash_addr),
   .flash_din(flash_din),
   .flash_req(flash_req),
   .flash_ready(flash_ready),
   .flash_done(flash_ready),
   .slot_layout(slot_layout),
   .img_mounted(img_mounted),
   .img_size(img_size),
   .img_readonly(img_readonly),
   .sd_lba(sd_lba),
   .sd_rd(sd_rd),
   .sd_wr(sd_wr),
   .sd_ack(sd_ack),
   .sd_buff_addr(sd_buff_addr),
   .sd_buff_dout(sd_buff_dout),
   .sd_buff_din(sd_buff_din),
   .sd_buff_wr(sd_buff_wr),
   .active_slot(slot),
   .lookup_RAM(lookup_RAM),
   .lookup_SRAM(lookup_SRAM),
   .bios_config(bios_config),
   .cart_device(cart_device),
   .msx_device(msx_device),
   .msx_dev_ref_ram(msx_dev_ref_ram),
   .selected_mapper(selected_mapper),
   .sd_tx(sd_tx),
   .sd_rx(sd_rx),
   .d_to_sd(d_to_sd),
   .d_from_sd(d_from_sd),
   .flash16x_active(flash16x_active),
   .flash16x_base(flash16x_base),
   .flash16x_size(flash16x_size)
);


// =============================================================================
// MoonSound (YMF278B OPL4)
// clk_sdram (85.909 MHz) is used as master; CLK_HZ=85909090 → fs≈44192 Hz (0.21% error)
// OPL3 clock: clk_sdram / 6 ≈ 14318182 Hz (target 14318180 Hz — negligible error)
// PCM sample memory: connected to SDRAM ch4 via request/valid bridge
// =============================================================================

// ─── OPL3 clock divider (clk_sdram / 6) ────────────────────────────────────
logic [1:0] opl3_clk_div;
logic       clk_opl3;
always_ff @(posedge clk_sdram) begin
    if (opl3_clk_div == 2'd2) begin
        opl3_clk_div <= 2'd0;
        clk_opl3     <= ~clk_opl3;
    end else
        opl3_clk_div <= opl3_clk_div + 1'd1;
end

// ─── CDC: CPU (clk21m) → ymf278b_top (clk_sdram) ───────────────────────────
// Toggle-synchronizer fires on the FALLING EDGE of wr_n only (once per CPU write).
// wr_n stays low for ~6 clk21m cycles (one T-state at 3.58 MHz on 21.47 MHz clock);
// firing every cycle would toggle ms_req_toggle 6×=even→CDC sees no net change→write dropped.
logic [7:0] ms_io_port_lat, ms_io_data_lat;
logic       ms_req_toggle;
logic       ms_rd_toggle;
logic [2:0] ms_req_sync;
logic [2:0] ms_rd_sync;
logic       ms_wr_n_prev;
logic       ms_rd_n_prev;
logic [7:0] ms_io_dout_lat;
// ── MoonSound I/O flow-control (WAIT_n handshake) ──────────────────────────
// The MSX VGM driver writes the YMF278 with fixed inter-write delays (no BUSY
// poll). When those writes come faster than our CDC+chip can absorb, accesses
// race and a write gets lost → the player hangs (confirmed: adding per-op delay
// on the player side avoids it).  Real MoonSound throttles the CPU via BUSY;
// re-create that: hold WAIT_n during a MoonSound I/O access until the chip acks.
logic       ms_ack_toggle = 1'b0;   // clk_sdram: flips on every ms_io_ack
logic [2:0] ms_ack_sync;            // clk21m: 3-FF sync of ms_ack_toggle
logic       ms_io_pending;          // clk21m: a MoonSound I/O is in flight → assert wait
logic [11:0] ms_wait_cnt;           // safety timeout so a lost ack can't hang the CPU.
                                    // MUST comfortably exceed the worst legitimate ack delay
                                    // (deferred mem-write ack = MEM_WRITE_DELAY(12µs) + engine
                                    // cpu-mem op under playback contention).  A PREMATURE timeout
                                    // releases the CPU while the op is still in flight → the next
                                    // I/O overlaps it → ack-toggle desync / latch corruption.
                                    // 4000 clk21m ≈ 186µs: ~15× the normal worst case.

always_ff @(posedge clk21m) begin
    ms_wr_n_prev <= wr_n;
    ms_rd_n_prev <= rd_n;
    ms_ack_sync  <= {ms_ack_sync[1:0], ms_ack_toggle};
    if (reset) begin
        ms_req_toggle <= 1'b0;
        ms_rd_toggle  <= 1'b0;
        ms_wr_n_prev  <= 1'b1;
        ms_rd_n_prev  <= 1'b1;
        ms_io_pending <= 1'b0;
    end else begin
        if ((ms_wave_cs | ms_fm_cs) & ~wr_n & ms_wr_n_prev) begin
            // Falling edge of wr_n
            ms_io_port_lat <= a[7:0];
            ms_io_data_lat <= d_from_cpu;
            ms_req_toggle  <= ~ms_req_toggle;
            ms_io_pending  <= 1'b1;        // hold CPU until this write is accepted
            ms_wait_cnt    <= 12'd4000;
        end
        if ((ms_wave_cs | ms_fm_cs) & ~rd_n & ms_rd_n_prev) begin
            if (ms_fm_cs & ~a[0]) begin
                // FM STATUS read (0xC4/0xC6): served DIRECTLY from the
                // continuously-synced status byte — no bridge round trip, no
                // WAIT, no request/response pairing to corrupt.  The IRQ
                // handler's status read is the one access that must NEVER
                // return stale data (a single stale bit6=0 sends vgmplay
                // down its no-EI OldHook exit = interrupts silently die).
                ms_strd_toggle <= ~ms_strd_toggle;   // notify: consume NEW2 one-shot
            end else begin
                // Falling edge of rd_n — bridge read (wave ports + FM data port)
                ms_io_port_lat <= a[7:0];
                ms_rd_toggle   <= ~ms_rd_toggle;
                ms_io_pending  <= 1'b1;    // hold CPU until read data is ready
                ms_wait_cnt    <= 12'd4000;
            end
        end
        // Release the wait when the chip acks (one access in flight at a time,
        // since the CPU is held), or after the safety timeout.
        if (ms_io_pending) begin
            if (ms_ack_sync[2] ^ ms_ack_sync[1]) ms_io_pending <= 1'b0;
            else if (ms_wait_cnt == 12'd0)        ms_io_pending <= 1'b0;
            else                                 ms_wait_cnt   <= ms_wait_cnt - 12'd1;
        end
    end
end

always_ff @(posedge clk_sdram) begin
    ms_req_sync <= {ms_req_sync[1:0], ms_req_toggle};
    ms_rd_sync  <= {ms_rd_sync[1:0],  ms_rd_toggle};
    
    // Latch the returned data from the MoonSound core when io_ack pulses
    if (ms_io_ack) begin
        ms_io_dout_lat <= ms_io_dout_raw;
        ms_ack_toggle  <= ~ms_ack_toggle;   // signal completion back to clk21m wait logic
    end
end

wire ms_io_wr_sdram = ms_req_sync[2] ^ ms_req_sync[1];
wire ms_io_rd_sdram = ms_rd_sync[2]  ^ ms_rd_sync[1];

// (slot-0 multi-probe removed — root cause found; see note further down.)
// ms_mem_addr / ms_mem_rd_valid are declared after the bridge below.
// REPURPOSED → ch4 READ-ADDRESS trace" further down.

// Direct FM-status path: continuous CDC of the live status byte into clk21m
// (bits change slowly; the handler cares about bit6 only), plus the
// status-read notification toggle into clk_sdram.
(* preserve *) reg [7:0] ms_status_s1, ms_status_s2;
always @(posedge clk21m) begin
    ms_status_s1 <= ms_status_export;
    ms_status_s2 <= ms_status_s1;
end
logic       ms_strd_toggle = 1'b0;
logic [2:0] ms_strd_sync;
always_ff @(posedge clk_sdram) ms_strd_sync <= {ms_strd_sync[1:0], ms_strd_toggle};
wire ms_status_rd_notify = ms_strd_sync[2] ^ ms_strd_sync[1];
wire [7:0] ms_status_export;

// ─── PCM memory ↔ SDRAM ch4 bridge (read + write) ───────────────────────────
// ymf278b_top outputs mem_addr[21:0] + mem_rd_req/mem_wr_req in clk_sdram domain.
// SDRAM ch4 uses edge-triggered req → ready handshake in clk_sdram domain.
wire [21:0] ms_mem_addr;
wire        ms_mem_rd_req;
wire        ms_mem_wr_req;
wire  [7:0] ms_mem_wr_data;

// ─── SDRAM ch4 read-integrity CANARY (instrumentation) ─────────────────────
// Functional sim has exonerated the engine (5s bit-exact), register path
// (0.995), and the SDRAM controller logic (concurrency TB).  The remaining
// hardware-only suspect is a PHYSICAL ch4 read corruption under playback load
// (the thin 0.303ns slack / SDRAM_DQ path).  This canary re-reads a FIXED
// known SRAM word (header 0 @ 0x200000, stable during playback) through the
// REAL ch4 path whenever the engine's bridge is idle, latches the first value,
// and counts any later mismatch.  can_errs>0 == ch4 SDRAM reads corrupt under
// load == root cause confirmed.  Exposed on the overlay via dbg_env_min.
localparam [21:0] CAN_ADDR = 22'h200000;
logic        can_owns = 1'b0, can_rd_req = 1'b0, can_ref_set = 1'b0;
logic [15:0] can_ref = 16'd0, can_errs = 16'd0, can_bad = 16'd0;
logic [13:0] can_timer = 14'd0;

// muxed bridge inputs: canary takes over only when the engine is fully idle
wire [21:0] br_addr   = can_owns ? CAN_ADDR     : ms_mem_addr;
wire        br_rd_req = can_owns ? can_rd_req   : ms_mem_rd_req;
wire        br_wr_req = can_owns ? 1'b0         : ms_mem_wr_req;

// Address: add PCM ROM base offset (set by memory_upload when loading yrw801.rom)
assign pcm_sdram_addr = pcm_rom_base + {5'd0, br_addr};
assign dbg_pcm_base_set = (pcm_rom_base != 27'h1800000);

// Read/Write bridge → SDRAM ch4
// Read/Write bridge → SDRAM ch4
// SDRAM controller uses edge detection: ch4_req & ~ch4_req_1
// So pcm_sdram_req must stay HIGH long enough for the edge to be captured.
// State machine:
//   0: IDLE — wait for rising edge of ms_mem_rd_req or ms_mem_wr_req
//   1: ACTIVE — hold pcm_sdram_req HIGH, wait for ch4_ready to drop (req accepted)
//   2: WAIT — keep req HIGH (SDRAM is processing), wait for ch4_ready to rise (data ready)
//   3: DONE — deassert req, signal valid for 1 cycle
logic [1:0] pcm_state;
logic pcm_is_write;
logic br_rd_req_prev;
assign pcm_sdram_req = (pcm_state == 2'd1) || (pcm_state == 2'd2);
assign pcm_sdram_rnw = ~pcm_is_write;
assign pcm_sdram_din = ms_mem_wr_data;

always_ff @(posedge clk_sdram) begin
    if (reset) begin
        pcm_state <= 2'd0;
        pcm_is_write <= 1'b0;
        br_rd_req_prev <= 1'b0;
    end else begin
        br_rd_req_prev <= br_rd_req;
        case (pcm_state)
            2'd0: begin // IDLE — detect rising edge of read request (engine OR canary)
                if (br_rd_req && !br_rd_req_prev) begin
                    pcm_is_write <= 1'b0;
                    pcm_state <= 2'd1;
                end else if (br_wr_req) begin
                    pcm_is_write <= 1'b1;
                    pcm_state <= 2'd1;
                end
            end
            2'd1: begin // ACTIVE — req is HIGH, wait for SDRAM to accept (ready drops)
                if (!pcm_sdram_ready) pcm_state <= 2'd2;
            end
            2'd2: begin // WAIT — req still HIGH, wait for SDRAM to complete (ready rises)
                if (pcm_sdram_ready) pcm_state <= 2'd3;
            end
            2'd3: begin // DONE — deassert req, valid for 1 cycle
                pcm_state <= 2'd0;
            end
        endcase
    end
end

// canary control: start a re-read when the bridge AND engine are idle; on the
// DONE cycle, latch the reference (first time) or count a mismatch.
always_ff @(posedge clk_sdram) begin
    if (reset) begin
        can_owns <= 1'b0; can_rd_req <= 1'b0; can_ref_set <= 1'b0;
        can_ref <= 16'd0; can_errs <= 16'd0; can_bad <= 16'd0; can_timer <= 14'd0;
    end else begin
        can_timer <= can_timer + 14'd1;
        // any wave-memory WRITE (sample upload / FixUp) legitimately changes
        // SRAM → re-arm the reference so it latches the FINAL settled content.
        // Playback issues no writes, so the reference is stable while monitoring.
        if (ms_mem_wr_req) begin can_ref_set <= 1'b0; can_errs <= 16'd0; end
        if (!can_owns) begin
            // fire periodically, only when nothing else wants the bridge
            if ((&can_timer) && pcm_state == 2'd0 && !ms_mem_rd_req && !ms_mem_wr_req) begin
                can_owns   <= 1'b1;
                can_rd_req <= 1'b1;
                can_timer  <= 14'd0;
            end
        end else begin
            can_rd_req <= 1'b1;                 // hold req through the transaction
            if (pcm_state == 2'd3) begin        // data ready this cycle
                if (!can_ref_set) begin
                    can_ref     <= pcm_sdram_dout16;
                    can_ref_set <= 1'b1;
                end else if (pcm_sdram_dout16 != can_ref) begin
                    if (can_errs != 16'hFFFF) can_errs <= can_errs + 16'd1;
                    can_bad <= pcm_sdram_dout16;
                end
                can_owns   <= 1'b0;
                can_rd_req <= 1'b0;
            end
        end
    end
end

wire  [7:0] ms_mem_rd_data  = pcm_sdram_dout;
wire [15:0] ms_mem_rd_data16 = pcm_sdram_dout16;
wire        ms_mem_rd_valid = (pcm_state == 2'd3) && !pcm_is_write && !can_owns;
wire        ms_mem_busy     = (pcm_state != 2'd0) || can_owns;

// ─── slot-0 multi-probe REMOVED ────────────────────────────────────────────
// The 96-bit MPRB capture BRAM found the root cause (stale-pos loud read during
// the wave-change release window) and is no longer needed.  Removed so the build
// fits with systemRAM back at addr_width(18) (no M10K headroom).  Engine taps
// dbg_slot0_* remain exposed but unconnected at the ymf278b_top instance.

// ─── ch4 header-read integrity CHECKER (register-only, no BRAM) ─────────────
// The 122->123 onset glitch ("찍") happens ONLY on a NEW wave (= a header
// fetch); replay (no fetch) is clean — and the engine is sim-proven bit-exact.
// Suspect: the REAL SDRAM returns corrupt header bytes during the fetch (which
// coincides with the CPU register-write burst = ch2 contention).  This checker
// compares each ch4 read of wave-123's header words (@0x5C4..0x5CE) to their
// KNOWN yrw801.rom values and counts mismatches.  No BRAM (the CH4LOG BRAM at
// 96% M10K broke SDRAM_DQ IOB packing → flaky RAM → FDD/MFRSD dead).  Result on
// the debug overlay via dbg_env_min: GREEN(0)=header reads clean, RED(>0)=ch4
// read corruption under load = root cause confirmed.  Expected words (little-
// endian {byte[i+1],byte[i]}) from yrw801 wave 123 = 4c bc 46 07 6d f8 8e 00 f0 00 09 00.
logic [15:0] hdr_errs = 16'd0, hdr_bad = 16'd0, hdr_reads = 16'd0;
logic [15:0] hdr_exp;
wire hdr_in_win = ms_mem_rd_valid && (ms_mem_addr[21:4] == 18'h0005C)
                  && (ms_mem_addr[3:1] >= 3'd2) && !ms_mem_addr[0];
always_comb case (ms_mem_addr[3:1])
    3'd2:    hdr_exp = 16'hBC4C;   // @0x5C4: bits/startHi
    3'd3:    hdr_exp = 16'h0746;   // @0x5C6: startLo/loopHi
    3'd4:    hdr_exp = 16'hF86D;   // @0x5C8: loopLo/endHi
    3'd5:    hdr_exp = 16'h008E;   // @0x5CA: endLo/lfovib
    3'd6:    hdr_exp = 16'h00F0;   // @0x5CC: ar.d1r/dl.d2r
    3'd7:    hdr_exp = 16'h0009;   // @0x5CE: rc.rr/am
    default: hdr_exp = 16'h0000;
endcase
always_ff @(posedge clk_sdram) begin
    if (reset) begin hdr_errs <= 16'd0; hdr_bad <= 16'd0; hdr_reads <= 16'd0; end
    else if (hdr_in_win) begin
        if (hdr_reads != 16'hFFFF) hdr_reads <= hdr_reads + 16'd1;
        if (pcm_sdram_dout16 != hdr_exp) begin
            if (hdr_errs != 16'hFFFF) hdr_errs <= hdr_errs + 16'd1;
            hdr_bad <= pcm_sdram_dout16;
        end
    end
end

// ─── ch4 SAMPLE-onset read CHECKER (wave 123 startAddr 0x0CBC46) ────────────
// Header reads proved clean (99/0).  This checks the NEW wave's first SAMPLE
// reads (a HIGH address, different SDRAM row/bank than the header) — read at
// each re-attack (pos=0).  Compares words @0x0CBC46..0x0CBC50 to yrw801 values
// (32FE FE02 FC04 DAFF 0303 FD11).  smp_errs>0 == sample-onset read corruption.
logic [15:0] smp_errs = 16'd0, smp_bad = 16'd0, smp_reads = 16'd0;
logic [15:0] smp_exp;
wire smp_in_win = ms_mem_rd_valid && (ms_mem_addr[21:8] == 14'h0CBC)
                  && (ms_mem_addr[7:1] >= 7'h23) && (ms_mem_addr[7:1] <= 7'h28)
                  && !ms_mem_addr[0];
always_comb case (ms_mem_addr[7:1])
    7'h23:   smp_exp = 16'h32FE;
    7'h24:   smp_exp = 16'hFE02;
    7'h25:   smp_exp = 16'hFC04;
    7'h26:   smp_exp = 16'hDAFF;
    7'h27:   smp_exp = 16'h0303;
    7'h28:   smp_exp = 16'hFD11;
    default: smp_exp = 16'h0000;
endcase
always_ff @(posedge clk_sdram) begin
    if (reset) begin smp_errs <= 16'd0; smp_bad <= 16'd0; smp_reads <= 16'd0; end
    else if (smp_in_win) begin
        if (smp_reads != 16'hFFFF) smp_reads <= smp_reads + 16'd1;
        if (pcm_sdram_dout16 != smp_exp) begin
            if (smp_errs != 16'hFFFF) smp_errs <= smp_errs + 16'd1;
            smp_bad <= pcm_sdram_dout16;
        end
    end
end

// ─── ch4 (PCM) SDRAM round-trip latency probe (measurement build) ───────────
// Counts clk_sdram cycles each ch4 READ transaction is in flight (pcm_state
// non-idle), peak-held since reset.  Routed to the debug overlay via
// dbg_env_min so we can read the worst-case ch4 latency the PCM engine sees on
// real hardware — the number that decides whether slot drops come from SDRAM
// starvation.  Also peak-holds the max concurrent fetch backlog as a sanity bar.
logic [9:0] ms_ch4_rt = '0, ms_ch4_rt_max = '0;
always @(posedge clk_sdram) begin
    if (reset) begin
        ms_ch4_rt <= '0; ms_ch4_rt_max <= '0;
    end else if (pcm_state != 2'd0 && !pcm_is_write) begin
        if (ms_ch4_rt != 10'h3FF) ms_ch4_rt <= ms_ch4_rt + 1'b1;
    end else begin
        if (ms_ch4_rt > ms_ch4_rt_max) ms_ch4_rt_max <= ms_ch4_rt;
        ms_ch4_rt <= '0;
    end
end
// Expose the ACTIVE header-read CHECKER on the overlay (replaces the idle
// canary for the 122->123 onset investigation).  Play 122->123 (fetches the
// wave-123 header @0x5C4): GREEN(0) = header words read clean → corruption is
// NOT the header read; RED(>0) = ch4 returns corrupt header bytes under the
// wave-change contention = root cause.  Saturate to the 10-bit overlay field.
assign dbg_env_min = (hdr_errs[15:10] != 6'd0) ? 10'h3FF : hdr_errs[9:0];

// ─── ymf278b_top instance ────────────────────────────────────────────────────
wire        ms_io_ack;
wire  [7:0] ms_io_dout_raw;
wire signed [15:0] ms_out_l, ms_out_r;
wire        ms_audio_valid;
wire        ms_irq_n;      // MoonSound OPL Timer-1 IRQ (active-low) → Z80 /INT
// 2-FF CDC sync of the OPL irq (clk_opl3 domain) into clk21m (Z80 domain).
(* preserve *) reg ms_irq_n_s1 = 1'b1, ms_irq_n_sync = 1'b1;
always @(posedge clk21m) begin
    ms_irq_n_s1   <= ms_irq_n;
    ms_irq_n_sync <= ms_irq_n_s1;
end

// I/O-cycle deferral, ASSERT-AND-HOLD form (2026-06-11).  History:
//  * plain level wiring (ms_irq_n_sync directly) froze whenever the IRQ
//    asserted while the main loop executed OUT instructions (hardware-isolated
//    2026-06-08: NOP loop + 1130 Hz IRQ ran 2700+ clean interrupts; the same
//    loop doing PSG or FM OUTs froze) — the T80 race needs /INT to be STABLE
//    around I/O cycles.
//  * combinational masking (| (~iorq_n & m1_n), 2026-06-10) fixed OPL3 but
//    re-broke OPL4: it TOGGLES /INT twice around EVERY I/O cycle while the
//    irq is pending.  OPL4's otir wave uploads are back-to-back 12µs WAIT-held
//    OUTs, so the line bounced at exactly the poison moments — hardware showed
//    cyan (CPU stops taking the IRQ) + yellow (so no acks).
//  * now: defer only the INITIAL assertion to a non-I/O moment, then HOLD the
//    level until the software ack deasserts the irq.  No mid-I/O edges at all;
//    int-ack cycles see a rock-stable /INT.
logic ms_int_hold = 1'b0;
always @(posedge clk21m) begin
    if (ms_irq_n_sync | ~msxConfig.moonsound_en)
        ms_int_hold <= 1'b0;                       // irq acked / disabled
    else if (iorq_n | ~m1_n)
        ms_int_hold <= 1'b1;                       // first non-I/O moment: assert, then hold
end
wire ms_int_n = ~ms_int_hold;

// ═══ MoonSound freeze-diagnosis infrastructure ═══════════════════════════════
// Battle-tested during the 2026-06 vgmplay-OPL4 freeze hunt (detectors, T80
// IFF/IM/I/PC forensics, IM2-table write watchpoint).  Compiled out by default;
// re-enable by defining MOONSOUND_DIAG (see MSX1.qsf).
`ifdef MOONSOUND_DIAG
// ── Freeze detectors (clk21m) — latch (sticky) when a signal is stuck
// abnormally long, to diagnose the vgmplay OPL-timer freeze.  Exported to the
// debug overlay (video domain), readable WHILE the CPU is frozen, to tell:
//   dbg_wait_stuck : WAIT_n held low > ~760us  (normal M1/MoonSound wait << this)
//                    => CPU held in a wait state (WAIT deadlock)
//   dbg_irq_stuck  : ms_irq_n held low > ~6ms  (OPL flag never cleared)
//                    => OPL-IRQ storm (interrupt never deasserts)
//   dbg_cpu_nom1   : no M1 (opcode fetch) for > ~760us
//                    => CPU not advancing (halt/stuck), independent of WAIT
//   dbg_intack_stop: while the OPL irq is asserted (ms_irq_n_sync low), the CPU
//                    runs NO interrupt-acknowledge cycle (m1_n & iorq_n both low)
//                    for > ~760us => CPU is NOT taking the asserted interrupt
//                    (IFF disabled / spin), so the handler never acks.
logic [13:0] wait_cnt = 0, nom1_cnt = 0;
logic [16:0] irq_cnt  = 0;
logic [15:0] intack_cnt = 0;   // ~3ms threshold (> the ~880us Timer-1 period, so a
                               // CPU taking the IRQ once per overflow doesn't false-latch)
logic [15:0] iffoff_cnt = 0, refuse_cnt = 0;
logic        iff1_d = 1'b0, ghost_arm = 1'b0, intack_seen = 1'b0;
logic        mreq_n_d = 1'b1, wr_n_d = 1'b1;
logic [15:0] addr_d;
logic [7:0]  data_d;
wire  [7:0]  im2_tbl_hi = t80_reg[39:32] + 8'd1;   // I+1 = page of table byte 257
always_ff @(posedge clk21m) begin
    if (reset) begin
        wait_cnt <= 0; irq_cnt <= 0; nom1_cnt <= 0; intack_cnt <= 0;
        iffoff_cnt <= 0; refuse_cnt <= 0;
        iff1_d <= 0; ghost_arm <= 0; intack_seen <= 0;
        dbg_wait_stuck <= 0; dbg_irq_stuck <= 0; dbg_cpu_nom1 <= 0; dbg_intack_stop <= 0;
        dbg_iff_stuck_off <= 0; dbg_int_refused <= 0; dbg_int_ghost <= 0;
    end else begin
        if (wait_n)            wait_cnt <= 0;
        else if (~&wait_cnt)   wait_cnt <= wait_cnt + 1'b1;
        if (&wait_cnt)         dbg_wait_stuck <= 1'b1;

        if (ms_irq_n_sync)     irq_cnt <= 0;
        else if (~&irq_cnt)    irq_cnt <= irq_cnt + 1'b1;
        if (&irq_cnt)          dbg_irq_stuck <= 1'b1;

        if (~m1_n)             nom1_cnt <= 0;
        else if (~&nom1_cnt)   nom1_cnt <= nom1_cnt + 1'b1;
        if (&nom1_cnt)         dbg_cpu_nom1 <= 1'b1;

        if (~m1_n & ~iorq_n)   intack_cnt <= 0;   // int-ack cycle → CPU taking IRQ
        else if (ms_irq_n_sync) intack_cnt <= 0;  // irq not asserted → not relevant
        else if (~&intack_cnt) intack_cnt <= intack_cnt + 1'b1;
        if (&intack_cnt)       dbg_intack_stop <= 1'b1;

        // IFF1 split detectors: WHICH side refuses the asserted IRQ?
        //   iffoff: irq asserted while IFF1==0 for >3ms — an interrupt was
        //           accepted but software never re-enabled (EI unreached:
        //           vector fetch / handler-path problem).
        //   refuse: irq asserted while IFF1==1 yet NO int-ack for >3ms —
        //           the T80 declines an enabled, stably-asserted /INT
        //           (acceptance-condition bug: Prefix/SetEI/sampling).
        if (ms_irq_n_sync | t80_reg[210])  iffoff_cnt <= 0;
        else if (~&iffoff_cnt)             iffoff_cnt <= iffoff_cnt + 1'b1;
        if (&iffoff_cnt)                   dbg_iff_stuck_off <= 1'b1;

        // Acceptance-moment forensics.  IFF1 falls on BOTH interrupt
        // acceptance and a DI instruction, so classify the FATAL fall (the
        // one in force when the green latch fires):
        //   ghost_arm: set at each IFF1 fall, cleared by an INTA cycle.
        //   PINK = green latched while armed ⇒ the fatal fall had NO INTA
        //          (a DI-path death, or a true T80 ghost-accept).
        //   PINK off (green w/o arm) ⇒ the fatal fall WAS an acceptance ⇒
        //          INTA ran, then execution went somewhere that never EI'd —
        //          check dbg_pc_vec (the vector jump target) for corruption.
        iff1_d <= t80_reg[210];
        if (iff1_d && !t80_reg[210]) begin
            if (!dbg_iff_stuck_off) dbg_pc_snap <= t80_reg[79:64];
            ghost_arm <= 1'b1;
        end else if (~m1_n & ~iorq_n) begin
            ghost_arm <= 1'b0;                      // INTA seen → real acceptance
        end
        if (&iffoff_cnt && ghost_arm) dbg_int_ghost <= 1'b1;

        // Vector-target capture: after each INTA sequence, the first M1 with
        // iorq high is the handler entry fetch — latch the PC there (frozen
        // once green latches).  Direct check for IM2 vector corruption.
        intack_seen <= (~m1_n & ~iorq_n) ? 1'b1
                     : (intack_seen && !(~m1_n & iorq_n)) ? intack_seen : 1'b0;
        if (intack_seen && ~m1_n && iorq_n && !dbg_iff_stuck_off) begin
            dbg_pc_vec <= t80_reg[79:64];
            dbg_im_i   <= {t80_reg[209:208], 6'd0, t80_reg[39:32]};  // IM + I at dispatch
        end
        dbg_pc_now <= t80_reg[79:64];

        // WRITE WATCHPOINT on the IM2 table's 257th byte ({I+1, 0x00}) — the
        // byte found corrupted (0x10-0x13) in the freeze forensics.  Captures
        // WHO writes it: PC + data + count.  The legitimate init value is the
        // entry byte (I+1); only captures of OTHER values are interesting, but
        // count all writes so the init shows up as count=1.
        if (~mreq_n_d & mreq_n & ~wr_n_d) begin   // end of a memory write cycle
            if (addr_d == {im2_tbl_hi, 8'h00}) begin
                dbg_watch_pc <= t80_reg[79:64];
                dbg_watch_dc <= {data_d, dbg_watch_dc[7:0] + 8'd1};
            end
        end
        mreq_n_d <= mreq_n;
        wr_n_d   <= wr_n;
        addr_d   <= a;
        data_d   <= d_from_cpu;

        if (~m1_n & ~iorq_n)               refuse_cnt <= 0;
        else if (ms_irq_n_sync | ~t80_reg[210]) refuse_cnt <= 0;
        else if (~&refuse_cnt)             refuse_cnt <= refuse_cnt + 1'b1;
        if (&refuse_cnt)                   dbg_int_refused <= 1'b1;
    end
end
`else
assign dbg_wait_stuck    = 1'b0;
assign dbg_irq_stuck     = 1'b0;
assign dbg_cpu_nom1      = 1'b0;
assign dbg_intack_stop   = 1'b0;
assign dbg_iff_stuck_off = 1'b0;
assign dbg_int_refused   = 1'b0;
assign dbg_int_ghost     = 1'b0;
assign dbg_pc_snap       = '0;
assign dbg_pc_vec        = '0;
assign dbg_pc_now        = '0;
assign dbg_im_i          = '0;
assign dbg_watch_pc      = '0;
assign dbg_watch_dc      = '0;
`endif

ymf278b_top #(
    .CLK_HZ   (85909090),
    .CLK_OPL3 (14318182)
) u_moonsound (
    .clk          (clk_sdram),
    .clk_opl3     (clk_opl3),
    .rst_n        (~reset),
    .io_port      (ms_io_port_lat),
    .io_data_in   (ms_io_data_lat),
    .io_wr        (ms_io_wr_sdram),
    .io_rd        (ms_io_rd_sdram),
    .io_data_out  (ms_io_dout_raw),
    .io_ack       (ms_io_ack),
    .status_export(ms_status_export),
    .status_rd_notify(ms_status_rd_notify),
    .mem_addr     (ms_mem_addr),
    .mem_rd_req   (ms_mem_rd_req),
    .mem_rd_data  (ms_mem_rd_data),
    .mem_rd_data16(ms_mem_rd_data16),
    .mem_rd_valid (ms_mem_rd_valid),
    .mem_wr_req   (ms_mem_wr_req),
    .mem_wr_data  (ms_mem_wr_data),
    .mem_busy     (ms_mem_busy),
    .audio_left   (ms_out_l),
    .audio_right  (ms_out_r),
    .audio_valid  (ms_audio_valid),
    .irq_n        (ms_irq_n),
    .pcm_mute       (pcm_mute),
    .fm_mute        (fm_mute),
    .pcm_vol        (pcm_vol),
    .dbg_pcm_valid  (dbg_pcm_valid),
    .dbg_opl3_valid (dbg_opl3_valid),
    .dbg_pcm_level  (dbg_pcm_level),
    .dbg_new2       (dbg_new2),
    .dbg_keyon_count(dbg_keyon_count),
    .dbg_accum_cnt  (dbg_accum_cnt),
    .dbg_env_min    (),                 // measurement build: dbg_env_min driven by ch4 latency probe
    .dbg_mem_nonzero(dbg_mem_nonzero),
    .dbg_pcm_base_set(),  // generated locally via assign
    .dbg_slot_keyon (dbg_slot_keyon),
    .dbg_slot_active(dbg_slot_active),
    .dbg_slot_envlive(dbg_slot_envlive),
    .dbg_slot0_hdr_start    (),
    .dbg_slot0_dyn_pos      (),
    .dbg_slot0_dyn_env_vol  (),
    .dbg_slot0_dyn_env_state(),
    .dbg_ack_stopped(dbg_ack_stopped)
);

// Gate audio to zero when MoonSound disabled
assign ms_audio_l = msxConfig.moonsound_en ? ms_out_l : 16'sh0;
assign ms_audio_r = msxConfig.moonsound_en ? ms_out_r : 16'sh0;

// Read data back to the CPU: FM status (0xC4/0xC6) comes straight from the
// live synced byte; everything else from the bridge latch.
assign ms_dout = (ms_fm_cs & ~a[0])       ? ms_status_s2   :
                 (ms_wave_cs | ms_fm_cs)  ? ms_io_dout_lat : 8'h00;

endmodule