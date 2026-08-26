//============================================================================
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//============================================================================

module emu
(
   //Master input clock
   input         CLK_50M,

   //Async reset from top-level module.
   //Can be used as initial reset.
   input         RESET,

   //Must be passed to hps_io module
   inout  [48:0] HPS_BUS,

   //Base video clock. Usually equals to CLK_SYS.
   output        CLK_VIDEO,

   //Multiple resolutions are supported using different CE_PIXEL rates.
   //Must be based on CLK_VIDEO
   output        CE_PIXEL,

   //Video aspect ratio for HDMI. Most retro systems have ratio 4:3.
   //if VIDEO_ARX[12] or VIDEO_ARY[12] is set then [11:0] contains scaled size instead of aspect ratio.
   output [12:0] VIDEO_ARX,
   output [12:0] VIDEO_ARY,

   output  [7:0] VGA_R,
   output  [7:0] VGA_G,
   output  [7:0] VGA_B,
   output        VGA_HS,
   output        VGA_VS,
   output        VGA_DE,    // = ~(VBlank | HBlank)
   output        VGA_F1,
   output [1:0]  VGA_SL,
   output        VGA_SCALER, // Force VGA scaler
   output        VGA_DISABLE, // analog out is off

   input  [11:0] HDMI_WIDTH,
   input  [11:0] HDMI_HEIGHT,
   output        HDMI_FREEZE,
   output        HDMI_BLACKOUT,

`ifdef MISTER_FB
   // Use framebuffer in DDRAM
   // FB_FORMAT:
   //    [2:0] : 011=8bpp(palette) 100=16bpp 101=24bpp 110=32bpp
   //    [3]   : 0=16bits 565 1=16bits 1555
   //    [4]   : 0=RGB  1=BGR (for 16/24/32 modes)
   //
   // FB_STRIDE either 0 (rounded to 256 bytes) or multiple of pixel size (in bytes)
   output        FB_EN,
   output  [4:0] FB_FORMAT,
   output [11:0] FB_WIDTH,
   output [11:0] FB_HEIGHT,
   output [31:0] FB_BASE,
   output [13:0] FB_STRIDE,
   input         FB_VBL,
   input         FB_LL,
   output        FB_FORCE_BLANK,

`ifdef MISTER_FB_PALETTE
   // Palette control for 8bit modes.
   // Ignored for other video modes.
   output        FB_PAL_CLK,
   output  [7:0] FB_PAL_ADDR,
   output [23:0] FB_PAL_DOUT,
   input  [23:0] FB_PAL_DIN,
   output        FB_PAL_WR,
`endif
`endif

   output        LED_USER,  // 1 - ON, 0 - OFF.

   // b[1]: 0 - LED status is system status OR'd with b[0]
   //       1 - LED status is controled solely by b[0]
   // hint: supply 2'b00 to let the system control the LED.
   output  [1:0] LED_POWER,
   output  [1:0] LED_DISK,

   // I/O board button press simulation (active high)
   // b[1]: user button
   // b[0]: osd button
   output  [1:0] BUTTONS,

   input         CLK_AUDIO, // 24.576 MHz
   output [15:0] AUDIO_L,
   output [15:0] AUDIO_R,
   output        AUDIO_S,   // 1 - signed audio samples, 0 - unsigned
   output  [1:0] AUDIO_MIX, // 0 - no mix, 1 - 25%, 2 - 50%, 3 - 100% (mono)

   //ADC
   inout   [3:0] ADC_BUS,

   //SD-SPI
   output        SD_SCK,
   output        SD_MOSI,
   input         SD_MISO,
   output        SD_CS,
   input         SD_CD,

   //High latency DDR3 RAM interface
   //Use for non-critical time purposes
   output        DDRAM_CLK,
   input         DDRAM_BUSY,
   output  [7:0] DDRAM_BURSTCNT,
   output [28:0] DDRAM_ADDR,
   input  [63:0] DDRAM_DOUT,
   input         DDRAM_DOUT_READY,
   output        DDRAM_RD,
   output [63:0] DDRAM_DIN,
   output  [7:0] DDRAM_BE,
   output        DDRAM_WE,

   //SDRAM interface with lower latency
   output        SDRAM_CLK,
   output        SDRAM_CKE,
   output [12:0] SDRAM_A,
   output  [1:0] SDRAM_BA,
   inout  [15:0] SDRAM_DQ,
   output        SDRAM_DQML,
   output        SDRAM_DQMH,
   output        SDRAM_nCS,
   output        SDRAM_nCAS,
   output        SDRAM_nRAS,
   output        SDRAM_nWE,

`ifdef MISTER_DUAL_SDRAM
   //Secondary SDRAM
   //Set all output SDRAM_* signals to Z ASAP if SDRAM2_EN is 0
   input         SDRAM2_EN,
   output        SDRAM2_CLK,
   output [12:0] SDRAM2_A,
   output  [1:0] SDRAM2_BA,
   inout  [15:0] SDRAM2_DQ,
   output        SDRAM2_nCS,
   output        SDRAM2_nCAS,
   output        SDRAM2_nRAS,
   output        SDRAM2_nWE,
`endif

   input         UART_CTS,
   output        UART_RTS,
   input         UART_RXD,
   output        UART_TXD,
   output        UART_DTR,
   input         UART_DSR,

   // Open-drain User port.
   // 0 - D+/RX
   // 1 - D-/TX
   // 2..6 - USR2..USR6
   // Set USER_OUT to 1 to read from USER_IN.
   input   [6:0] USER_IN,
   output  [6:0] USER_OUT,

   input         OSD_STATUS
);

///////// Default values for ports not used in this core /////////
assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;

assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;

assign AUDIO_S = 1;
// Silence audio while paused (CPU is frozen but MoonSound runs on clk_sdram and would
// otherwise sustain/howl; PSG holds a DC level). Covers OSD pause and DMA save/load.
assign AUDIO_L = msx_pause ? 16'sd0 : audio_l;
assign AUDIO_R = msx_pause ? 16'sd0 : audio_r;
assign AUDIO_MIX = 0;

assign LED_POWER = 0;
assign LED_USER = vsd_sel & sd_act;
assign LED_DISK  = {1'b1, ~vsd_sel & sd_act};
assign BUTTONS = 0;

localparam VDNUM = 6;

MSX::user_config_t msxConfig;
MSX::bios_config_t bios_config;
MSX::config_cart_t cart_conf[2];
MSX::block_t       slot_layout[64];
MSX::lookup_RAM_t  lookup_RAM[16];
MSX::lookup_SRAM_t lookup_SRAM[4];

wire             forced_scandoubler;
wire      [21:0] gamma_bus;
wire       [1:0] buttons;
// hps_io drives [127:0]; we only ever took the low 64 and had run out -- bits
// 49,50,52,53,63 were all that remained.  Widening costs nothing (the upper bits
// are already generated) and gives the audio trims room.
wire     [127:0] status;
wire      [10:0] ps2_key;
wire      [24:0] ps2_mouse;
wire       [5:0] joy0, joy1;
wire             ioctl_download;
wire      [15:0] ioctl_index;
wire             ioctl_wr;
wire      [26:0] ioctl_addr;
wire       [7:0] ioctl_dout;
wire      [31:0] sd_lba[0:VDNUM-1];
wire [VDNUM-1:0] sd_rd;
wire [VDNUM-1:0] sd_wr;
wire [VDNUM-1:0] sd_ack;
wire      [13:0] sd_buff_addr;
wire       [7:0] sd_buff_dout;
wire       [7:0] sd_buff_din[0:VDNUM-1];
wire             sd_buff_wr;
wire [VDNUM-1:0] img_mounted;
wire      [63:0] img_size;   // 64-bit: SD images can exceed 4GiB (sd_card/hps_io are 64-bit)
wire             img_readonly;
wire      [15:0] sdram_sz;
wire      [64:0] rtc;

//[0]     RESET
//[2:1]   Aspect ratio
//[4:3]   Scanlines
//[6:5]   Scale
//[7]     Vertical crop
//[8]     Tape input
//[9]     Tape rewind
//[10]    Reset & Detach
//[11]    MSX type
//[12]    MSX1 VideoMode 
//[14:13] MSX2 VideoMode
//[16:15] MSX2 RAM Size
//[19:17] SLOT A CART TYPE
//[23:20] ROM A TYPE MAPPER
//[25:24] RESERVA
//[28:26] SRAM SIZE 
//[31:29] SLOT B CART TYPE
//[34:32] ROM B TYPE MAPPER
//[35]    RESERVA
//[37:36] CPU SPEED (turbo)
//[38]    BORDER
//[48]    DEBUG OVERLAY
//[50:49] free (was OPL4 PCM VOLUME, 2-bit)
//[51]    CHEATS
//[53:52] free (was OPL4 FM VOLUME, 2-bit)
//[56:54] OPL4 PCM VOLUME (5 steps, first entry = default)
//[59:57] OPL4 FM VOLUME  (5 steps, first entry = default)
//[71]    SLOT A sub-slots On/Off (expanded cart slot)
//[72]    SLOT B sub-slots On/Off
//[84:73] SLOT A sub-slot 0..3 device, 3 bits each (None,ROM,SCC,SCC+,FM-PAC,GameMaster2)
//[96:85] SLOT B sub-slot 0..3 device, 3 bits each (GameMaster2 never on B)
`include "build_id.v" 
localparam CONF_STR = {
   "MSX1;",
   "-;",
   "FC1,MSX,Load ROM PACK,30000000;",
   "FC2,MSX,Load FW  PACK,32000000;",
   CONF_STR_SLOT_A,
   CONF_STR_EXPAND_A,
   CONF_STR_SUBSLOT_A,
   "H7H3FS3,ROM,Load,30C00000;",       // slot-level copy; the sub-slot page has its own (msx_config.sv)
   CONF_STR_MAPPER_A,
   CONF_STR_SRAM_SIZE_A,
   "-;",
   CONF_STR_SLOT_B,
   CONF_STR_EXPAND_B,
   CONF_STR_SUBSLOT_B,
   // Deliberately F, NOT FS.  The S would set `opensave`, and user_io.cpp:2937
   // mounts the companion <rom>.sav with a HARDCODED drive index 0 -- there is only
   // ever ONE save image and it is on VD0.  Adding S to slot B therefore does not
   // give slot B a save, it STEALS VD0 from slot A: loading any slot-B ROM unmounts
   // <romA>.sav, and the end-of-upload load_sram then reads <romB>.sav into slot A's
   // SRAM / flash region, after which the next SRAM Save writes slot A's data into
   // <romB>.sav.  Both files are destroyed.  Verified against the firmware source
   // and reachable in the DEFAULT configuration.  Slot B saving needs a firmware
   // answer, not a CONF_STR flag.
   "H8H4F4,ROM,Load,33000000;",        // slot-level copy; the sub-slot page has its own (msx_config.sv)
   CONF_STR_MAPPER_B,
   "H6-;",
   "H6R[38],SRAM Save;",
   "H6R[39],SRAM Load;",
   "-;",
   "C,Cheats;",
   "FC7,GG,Load Cheat;",
   "O[51],Cheats,On,Off;",
   "h1-;",
   "h1S5,DSK,Mount Drive A:;",
   "SC4,VHD,Load SD card;",
   "-;",
   "O[8],Tape Input,File,ADC;",
   "H0F5,CAS,Cas File,31600000;",
   "H0T9,Tape Rewind;",
   "-;",
   "P1,Video settings;",
   "h2P1O[14:13],Video mode,AUTO,PAL,NTSC;",
   "H2P1O[12],Video mode,PAL,NTSC;",
   "P1O[2:1],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
   "P1O[5:3],Scandoubler Fx,None,HQ2x-320,HQ2x-160,CRT 25%,CRT 50%,CRT 75%;",
   "P1O[7:6],Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer;",
   "P1O[40],Vertical Crop,No,Yes;",
   "P1O[41],Border,No,Yes;",
   "P1O[42],V9958,No,Yes;",
   "-;",
   "O[43],Pause on OSD,No,Yes;",
   "T[44],Pause;",
   "-;",
   "O[37:36],CPU Speed,3.58MHz,5.37MHz (Panasonic),7.16MHz,10.7MHz;",
   "-;",
   "P2,Audio settings;",
   "P2O[45],MoonSound,Off,On;",
   "P2O[46],PCM Mute,Off,On;",
   "P2O[47],FM Mute,Off,On;",
   // Labels are dB VS UNITY, matching the PSG/OPLL/SCC menus below (0dB = no gain).
   // They used to be offsets from the shipping default, so "0dB" was really -3.98 dB
   // and "+8dB" was really +4.01.  Fixed by moving the VALUES to the names, not by
   // renaming the steps: FM "+8dB" is mul 322 = a real +8 dB.  Entry 0 = default.
   "P2O[112:109],OPL4 PCM Volume,-12dB,-14dB,-16dB,-18dB,-20dB;",
   "P2O[116:113],OPL4 FM Volume,+4dB,+6dB,+8dB,0dB,-2dB,-4dB,-6dB,-8dB,0dB,+2dB;",
   "P2-;",
   "P2O[100:97],PSG Volume,0dB,-2dB,-4dB,-6dB,-8dB,0dB,+2dB,+4dB,+6dB,+8dB;",
   "P2O[104:101],OPLL Volume,0dB,-2dB,-4dB,-6dB,-8dB,0dB,+2dB,+4dB,+6dB,+8dB;",
   "P2O[108:105],SCC Volume,0dB,-2dB,-4dB,-6dB,-8dB,0dB,+2dB,+4dB,+6dB,+8dB;",
   "-;",
   "O[64],Reset on ROM change,Yes,No;",
   "O[48],Debug Overlay,Off,On;",
   "-;",
   "T[0],Reset;",
   "R[10],Reset & Detach ROM Cartridge;",					
   "R[0],Reset and close OSD;",
   "V,v",`BUILD_DATE 
};

wire [12:0] status_menumask;  // hps_io takes 16; [12:7] = expanded-slot menu masks (CONF_STR H7..HC)
wire [1:0] sdram_size;
assign status_menumask[0] = msxConfig.cas_audio_src == CAS_AUDIO_ADC;
assign status_menumask[1] = fdc_enabled;
assign status_menumask[2] = bios_config.use_FDC;
assign status_menumask[3] = ROM_A_load_hide;
assign status_menumask[4] = ROM_B_load_hide;
assign status_menumask[5] = sram_A_select_hide;
// H6 hides SRAM Save / SRAM Load.  A flash cartridge has no SRAM region at all --
// its persistence goes through flash_dirtysave -- so the size sum is 0 and the
// buttons would be hidden, leaving the user no way to trigger a save.  ASCII16X
// was already excepted for exactly this reason; Yamanooto needs the same, or its
// newly-wired flash write path is unreachable from the UI.
assign status_menumask[7]  = slotA_classic_hide;   // slot A expanded -> hide its one-device line
assign status_menumask[8]  = slotB_classic_hide;
assign status_menumask[9]  = subA_page_hide;       // slot A not expanded -> hide "SLOT A sub-slots" page
assign status_menumask[10] = subB_page_hide;       // 'A' in CONF_STR
assign status_menumask[11] = mapper_A_hide;        // 'B': no ROM sub-slot -> Mapper/SRAM entries hidden
assign status_menumask[12] = mapper_B_hide;        // 'C'
assign status_menumask[6] = (lookup_SRAM[0].size + lookup_SRAM[1].size + lookup_SRAM[2].size + lookup_SRAM[3].size == 0)
                          & (cart_conf[0].selected_mapper != MAPPER_ASCII16X)
                          & (cart_conf[0].selected_mapper != MAPPER_YAMANOOTO)
                          & (cart_conf[1].selected_mapper != MAPPER_ASCII16X)
                          & (cart_conf[1].selected_mapper != MAPPER_YAMANOOTO);
assign sdram_size         = sdram_sz[15] ? sdram_sz[1:0] : 2'b00;

hps_io #(.CONF_STR(CONF_STR),.VDNUM(VDNUM)) hps_io
(
   .clk_sys(clk21m),
   .HPS_BUS(HPS_BUS),
   .EXT_BUS(),
   .gamma_bus(gamma_bus),
   .forced_scandoubler(forced_scandoubler),
   .buttons(buttons),
   .status(status),
   .status_menumask(status_menumask),
   .ps2_key(ps2_key),
   .ps2_mouse(ps2_mouse),
   .joystick_0(joy0),
   .joystick_1(joy1),
   .ioctl_download(ioctl_download),
   .ioctl_index(ioctl_index),
   .ioctl_wr(ioctl_wr),
   .ioctl_addr(ioctl_addr),
   .ioctl_dout(ioctl_dout),
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
   .sdram_sz(sdram_sz),
   .RTC(rtc)
);

/////////////////   CONFIG   /////////////////
wire [5:0] mapper_A, mapper_B;
wire       reload, sram_A_select_hide, fdc_enabled, ROM_A_load_hide, ROM_B_load_hide;
wire       slotA_classic_hide, slotB_classic_hide, subA_page_hide, subB_page_hide, mapper_A_hide, mapper_B_hide;

msx_config msx_config 
(
   .clk(clk21m),
   .reset(reset),
   .bios_config(bios_config),
   .HPS_status(status),
   .scandoubler(scandoubler),
   .sdram_size(sdram_size),
   .cart_conf(cart_conf),
   .reload(reload),
   .rom_loaded(rom_loaded),
   .rom_big(rom_big),
   .sram_A_select_hide(sram_A_select_hide),
   .slotA_classic_hide(slotA_classic_hide),
   .slotB_classic_hide(slotB_classic_hide),
   .subA_page_hide(subA_page_hide),
   .subB_page_hide(subB_page_hide),
   .mapper_A_hide(mapper_A_hide),
   .mapper_B_hide(mapper_B_hide),
   .ROM_A_load_hide(ROM_A_load_hide),
   .ROM_B_load_hide(ROM_B_load_hide),
   .fdc_enabled(fdc_enabled),
   .msxConfig(msxConfig)
);

/////////////////   CLOCKS   /////////////////
wire clk21m, clk_sdram, locked_sdram;
wire ce_10m7_p, ce_10m7_n, ce_5m39_p, ce_5m39_n, ce_3m58_p, ce_3m58_n, ce_10hz;
// CPU turbo.  status[37:36]: 0 = 3.58MHz (stock), 1 = 7.16MHz, 2 = 10.74MHz.
// Bound by name into `clock clock (.*)` below.
wire  [1:0] cpu_speed = status[37:36];
wire        cpu_turbo;              // driven by clock.sv from the latched speed
wire  [1:0] cpu_speed_q;            // latched speed, back out of clock.sv
wire        cpu_bus_idle;           // from msx.sv, gates the speed latch
wire        ce_cpu_p, ce_cpu_n;
pll pll
(
   .refclk(CLK_50M),
   .rst(0),
   .outclk_0(clk_sdram), //85.909090
   .outclk_1(clk21m),    //21.477270
   .locked(locked_sdram)
);

clock clock
(
	.*
);

/////////////////    RESET   /////////////////
// "Reset on ROM change" (O[64], default Yes) -- when set to No the machine is held
// rather than reset while memory_upload streams, so a mapper or ROM can be swapped
// under a running program.  The hold is essential: reset_rq is what keeps the CPU
// off the bus while SDRAM and the slot layout change underneath it, so dropping it
// outright would be a genuine hazard, not a cosmetic one.  msx_pause already gates
// every CPU clock enable and is used the same way by the nvram DMA.
// Power-on is unaffected either way -- RESET covers it.
// Caveat, and it is why the default is Yes: across a no-reset swap the slot/subslot
// select registers and the mapper's own bank registers keep their old values.
// S3 guard: `flash16x_active`/`base`/`size` (msx_slots.sv) are cleared ONLY by
// reset, and flash_dirtysave reads flash16x_base LIVE.  With the hold path taken
// they would survive a cart swap and point the next .sav DMA at the departed
// cart's SDRAM region.  Rather than thread a clear signal through two modules,
// simply refuse the no-reset path whenever a flash cart is involved -- that is the
// case where getting it wrong destroys a save, and it is not the case the toggle
// exists for (comparing mappers on a running program).
wire upload_hold = reset_rq & status[64] & ~|flash16x_active;
// msx_pause freezes the CPU clock enables, but MoonSound runs on clk_sdram and is
// held only by `reset`.  With the toggle at No it would keep issuing SDRAM ch4
// traffic while memory_upload streams megabytes into ch1 -- and a FW PACK upload
// moves pcm_rom_base under a live PCM fetch.  This core has twice been bitten by
// sustained multi-channel SDRAM pressure, so keep the OPL4 in reset for the whole
// transfer regardless of the toggle.  It loses its state, which is the right
// trade against corrupting the transfer.
wire reset_ms = reset | upload_hold;
wire reset = RESET | status[0] | status[10] | (reset_rq & ~status[64]);

///////////////// Computer /////////////////
wire  [7:0] R, G, B, cpu_din, cpu_dout;
wire  [7:0] R_ovl, G_ovl, B_ovl;           // video after debug overlay
wire        dbg_pcm_valid, dbg_opl3_valid;
wire signed [15:0] dbg_pcm_level;
wire        dbg_new2;
wire [4:0]  dbg_keyon_count;
wire [4:0]  dbg_accum_cnt;
wire [9:0]  dbg_env_min;
wire        dbg_mem_nonzero;
wire        dbg_pcm_base_set;
wire [23:0] dbg_slot_keyon;
wire [23:0] dbg_slot_active;
wire [23:0] dbg_slot_envlive;
wire        dbg_wait_stuck;
wire        dbg_irq_stuck;
wire        dbg_cpu_nom1;
wire        dbg_intack_stop;
wire        dbg_ack_stopped;
wire        dbg_iff_stuck_off;
wire        dbg_int_refused;
wire [15:0] dbg_pc_snap;
wire [15:0] dbg_pc_vec;
wire [15:0] dbg_pc_now;
wire [15:0] dbg_im_i;
wire [15:0] dbg_watch_pc;
wire [15:0] dbg_watch_dc;
wire        dbg_int_ghost;

// Audio trims for the msx instance, which connects by `.*` -- these are wired by
// name, not in its port list.  4 steps each; entry 0 is exactly unity.
wire  [3:0] psg_vol  = status[100:97];
wire  [3:0] opll_vol = status[104:101];
wire  [3:0] scc_vol  = status[108:105];
wire [15:0] cpu_addr;
wire signed [15:0] audio_l, audio_r;
wire        hsync, vsync, blank_n, hblank, vblank, ce_pix;
wire        cpu_wr, cpu_rd, cpu_mreq, cpu_iorq, cpu_m1;
wire [26:0] ram_addr;
wire  [7:0] ram_din, ram_dout;
wire        ram_rnw, sdram_ce, bram_ce;
wire        sd_tx, sd_rx;
wire  [7:0] d_to_sd, d_from_sd;

dev_typ_t    cart_device[2];
dev_typ_t    msx_device;
wire   [3:0] msx_dev_ref_ram[8];
mapper_typ_t selected_mapper[2];
assign selected_mapper[0] = cart_conf[0].selected_mapper;
assign selected_mapper[1] = cart_conf[1].selected_mapper;
// Pause logic: flash DMA, OSD-open (if option enabled), or manual toggle (T[44])
reg pause_toggle = 1'b0;
reg status44_prev = 1'b0;
always @(posedge clk21m) begin
   status44_prev <= status[44];
   if (~status44_prev & status[44]) pause_toggle <= ~pause_toggle;
end
// flash_changelog (A: ASCII16X change-log engine) ch1 master + CPU pause
// reuses the dump_* mux wires (ch1 + VD0)
wire        dump_active;
wire [26:0] dump_sdram_addr;
wire        dump_sdram_req, dump_sdram_rnw;
wire  [7:0] dump_sdram_din;
wire        flash16x_prog_we;
wire [22:0] flash16x_prog_addr;
wire  [7:0] flash16x_prog_data;
wire        log_clear;
wire [23:0] probe_r2, probe_r23, probe_r0;
wire [15:0] probe_frame;
wire msx_pause = nvbak_dma_active | dump_active | (status[43] & OSD_STATUS) | pause_toggle | upload_hold;

msx MSX
(
   // ce_10m7_p / ce_5m39_n are NOT pause-gated: their only consumers inside
   // msx.sv are the vdp18 core and ce_pix (video timing/pixel stream).  The
   // V9938 path was never gated (CLK21M direct), so on MSX2 machines the
   // display already free-runs during pause; ungating these aligns vdp18
   // machines with that, keeps the scaler fed (a paused CPU means VRAM is
   // static, so the picture is the same frozen image), and lets the pause
   // symbol overlay render/decay on MSX1 machines (A4 review HIGH-1).
   .ce_10m7_p(ce_10m7_p),
   .ce_3m58_p(ce_3m58_p & ~msx_pause),
   .ce_3m58_n(ce_3m58_n & ~msx_pause),
   // CPU clock enable.  Pause-gated exactly like ce_3m58_*, so the pause
   // mechanism is unchanged; with cpu_speed==0 these ARE ce_3m58_p/n.
   .ce_cpu_p (ce_cpu_p  & ~msx_pause),
   .ce_cpu_n (ce_cpu_n  & ~msx_pause),
   .cpu_turbo(cpu_turbo),
   .cpu_speed_q(cpu_speed_q),
   .cpu_bus_idle(cpu_bus_idle),
   .ce_5m39_n(ce_5m39_n),
   .ce_10hz  (ce_10hz   & ~msx_pause),
   .probe_freeze(msx_pause),
   .probe_r2(probe_r2), .probe_r23(probe_r23), .probe_r0(probe_r0), .probe_frame(probe_frame),
   .HS(hsync),
   .DE(blank_n),
   .VS(vsync),
   .cas_motor(motor),
   .cas_audio_in(msxConfig.cas_audio_src == CAS_AUDIO_FILE  ? CAS_dout : tape_in),
   .rtc_time(rtc),
   .dma_active(nvbak_dma_active),
   .sram_save(status[38]),
   .sram_load(status[39]),
   .ioctl_addr(ioctl_addr[26:0]),
   .img_mounted(img_mounted[5]),
   .img_size(img_size[31:0]),   // msx (FDC floppy) port is 32-bit; floppies are small
   .img_readonly(img_readonly),
   .sd_rd(sd_rd[5]),
   .sd_wr(sd_wr[5]),
   .sd_ack(sd_ack[5]),
   .sd_lba(sd_lba[5]),
   .sd_buff_addr(sd_buff_addr),
   .sd_buff_dout(sd_buff_dout),
   .sd_buff_din(sd_buff_din[5]),
   .sd_buff_wr(sd_buff_wr),
   .slot_layout(slot_layout),
   .lookup_RAM(lookup_RAM),
   .lookup_SRAM(lookup_SRAM),
   .bios_config(bios_config),
   .cart_device(cart_device),
   .msx_device(msx_device),
   .msx_dev_ref_ram(msx_dev_ref_ram),
   .selected_mapper(selected_mapper),
   .flash_addr(flash_addr),
   .flash_din(flash_din),
   .flash_req(flash_req),
   .flash_ready(flash_ready),
   .flash_done(flash_done),
   .d_to_sd(d_to_sd),
   .d_from_sd(d_from_sd),
   .sd_tx(sd_tx),
   .sd_rx(sd_rx),
   .flash16x_active(flash16x_active),
   .flash16x_base(flash16x_base),
   .flash16x_size(flash16x_size),
   .flash16x_prog_we(flash16x_prog_we),
   .flash16x_prog_addr(flash16x_prog_addr),
   .flash16x_prog_data(flash16x_prog_data),
   // MoonSound PCM SDRAM
   .pcm_sdram_addr(pcm_sdram_addr),
   .pcm_sdram_req(pcm_sdram_req),
   .pcm_sdram_rnw(pcm_sdram_rnw),
   .pcm_sdram_din(pcm_sdram_din),
   .pcm_sdram_dout(pcm_sdram_dout),
   .pcm_sdram_dout16(pcm_sdram_dout16),
   .pcm_sdram_ready(pcm_sdram_ready),
   .pcm_rom_base(pcm_rom_base),
   // MoonSound mute / debug
   .pcm_mute       (status[46]),
   .fm_mute        (status[47]),
   .pcm_vol        (status[112:109]),
   .fm_vol         (status[116:113]),
   .dbg_pcm_valid  (dbg_pcm_valid),
   .dbg_opl3_valid (dbg_opl3_valid),
   .dbg_pcm_level  (dbg_pcm_level),
   .dbg_new2       (dbg_new2),
   .dbg_keyon_count(dbg_keyon_count),
   .dbg_accum_cnt  (dbg_accum_cnt),
   .dbg_env_min    (dbg_env_min),
   .cheat_en_master(~status[51]),   // global "Cheats On/Off" (O[51], default On=0): gates ALL cheats (standard+FC7), non-destructive
   .*
);

//////////////////   SD   ///////////////////
wire sdclk;
wire sdmosi;
wire vsdmiso;
wire sdmiso = vsd_sel ? vsdmiso : SD_MISO;

reg vsd_sel = 0;
always @(posedge clk21m) if(img_mounted[4]) vsd_sel <= |img_size;

assign SD_CS   = vsd_sel;
assign SD_SCK  = sdclk  & ~vsd_sel;
assign SD_MOSI = sdmosi & ~vsd_sel;

reg sd_act;

always @(posedge clk21m) begin
    reg old_mosi, old_miso;
    integer timeout = 0;

    old_mosi <= sdmosi;
    old_miso <= sdmiso;

    sd_act <= 0;
    if(timeout < 1000000) begin
        timeout <= timeout + 1;
        sd_act <= 1;
    end

    if((old_mosi ^ sdmosi) || (old_miso ^ sdmiso)) timeout <= 0;
end

//////////////////   SPI   ///////////////////
spi_divmmc spi
(
   .clk_sys(clk21m),
   .tx(sd_tx),
   .rx(sd_rx),
   .din(d_to_sd),
   .dout(d_from_sd),
   .ready(),

   .spi_ce(1'b1),
   .spi_clk(sdclk),
   .spi_di(sdmiso),
   .spi_do(sdmosi)
);

sd_card sd_card
(
    .*,
    .clk_sys(clk21m),
    .img_mounted(img_mounted[4]),
    .img_size(img_size),
    .sd_lba(sd_lba[4]),
    .sd_rd(sd_rd[4]),
    .sd_wr(sd_wr[4]),
    .sd_ack(sd_ack[4]),
    .sd_buff_addr(sd_buff_addr),
    .sd_buff_dout(sd_buff_dout),
    .sd_buff_din(sd_buff_din[4]),
    .sd_buff_wr(sd_buff_wr),
    
    .clk_spi(clk_sdram),
    .sdhc(1),
    .sck(sdclk),
    .ss(~vsd_sel),
    .mosi(sdmosi),
    .miso(vsdmiso)
);

/////////////////  VIDEO  /////////////////
logic [9:0] vcrop;
logic wide;
wire  vcrop_en, vga_de;
wire  [1:0] ar;

assign CLK_VIDEO   = clk21m;
assign VGA_SL      = status[5:3] > 2 ? status[4:3] - 2'd2 : 2'd0;
assign vcrop_en    = status[40];
assign ar          = status[2:1];
wire scandoubler = status[5:3] || forced_scandoubler;

always @(posedge CLK_VIDEO) begin
	vcrop <= 0;
	wide <= 0;
	if(HDMI_WIDTH >= (HDMI_HEIGHT + HDMI_HEIGHT[11:1]) && !scandoubler) begin
		if(HDMI_HEIGHT == 480)  vcrop <= 240;
		if(HDMI_HEIGHT == 600)  begin vcrop <= 200; wide <= vcrop_en; end
		if(HDMI_HEIGHT == 720)  vcrop <= 240;
		if(HDMI_HEIGHT == 768)  vcrop <= 256; // NTSC mode has 250 visible lines only!
		if(HDMI_HEIGHT == 800)  begin vcrop <= 200; wide <= vcrop_en; end
		if(HDMI_HEIGHT == 1080) vcrop <= 10'd216;
		if(HDMI_HEIGHT == 1200) vcrop <= 240;
	end
	else if(HDMI_WIDTH >= 1440 && !scandoubler) begin
		// 1920x1440 and 2048x1536 are 4:3 resolutions and won't fit in the previous if statement ( width > height * 1.5 )
		if(HDMI_HEIGHT == 1440) vcrop <= 240;
		if(HDMI_HEIGHT == 1536) vcrop <= 256;
	end
end

video_freak video_freak
(
	.*,
	.VGA_DE_IN(vga_de),
   .VGA_VS(vsync),
	.ARX((!ar) ? (wide ? 12'd340 : 12'd400) : (ar - 1'd1)),
	.ARY((!ar) ? 12'd300 : 12'd0),
	.CROP_SIZE(vcrop_en ? vcrop : 10'd0),
	.CROP_OFF(0),
	.SCALE(status[6:5])
);

debug_overlay u_overlay (
   .CLK_VIDEO      (CLK_VIDEO),
   .ce_pix         (ce_pix),
   .hblank         (hblank),
   .vblank         (vblank),
   .R_in           (R),
   .G_in           (G),
   .B_in           (B),
   .R_out          (R_ovl),
   .G_out          (G_ovl),
   .B_out          (B_ovl),
   .en             (status[48]),
   // pause symbol overlay (docs/pause_overlay_design.md §5) — independent of en/status[48]
   .pause_in       (msx_pause),
   .osd_in         (OSD_STATUS),
   .key_tgl_in     (ps2_key[10]),
   .mouse_tgl_in   (ps2_mouse[24]),
   .joy0_in        (joy0[5:0]),
   .joy1_in        (joy1[5:0]),
   .probe_r2       (probe_r2),
   .probe_r23      (probe_r23),
   .probe_r0       (probe_r0),
   .probe_frame    (probe_frame),
   .dbg_pcm_valid  (dbg_pcm_valid),
   .dbg_opl3_valid (dbg_opl3_valid),
   .dbg_mem_nonzero(dbg_mem_nonzero),
   .dbg_interp_nonzero(dbg_pcm_base_set),
   .dbg_pcm_level  (dbg_pcm_level),
   .dbg_new2       (dbg_new2),
   .dbg_keyon_count(dbg_keyon_count),
   .dbg_accum_cnt  (dbg_accum_cnt),
   .dbg_env_min    (dbg_env_min),
   .dbg_slot_keyon (dbg_slot_keyon),
   .dbg_slot_active(dbg_slot_active),
   .dbg_slot_envlive(dbg_slot_envlive),
   .dbg_wait_stuck (dbg_wait_stuck),
   .dbg_irq_stuck  (dbg_irq_stuck),
   .dbg_cpu_nom1   (dbg_cpu_nom1),
   .dbg_intack_stop(dbg_intack_stop),
   .dbg_ack_stopped(dbg_ack_stopped),
   .dbg_iff_stuck_off(dbg_iff_stuck_off),
   .dbg_int_refused(dbg_int_refused),
   .dbg_pc_snap(dbg_pc_snap),
   .dbg_pc_vec(dbg_pc_vec),
   .dbg_pc_now(dbg_pc_now),
   .dbg_im_i(dbg_im_i),
   .dbg_watch_pc(dbg_watch_pc),
   .dbg_watch_dc(dbg_watch_dc),
   .dbg_int_ghost(dbg_int_ghost)
);

video_mixer #(.GAMMA(0)) video_mixer
(
   .CLK_VIDEO(CLK_VIDEO),
   .hq2x(~status[5] & (status[4] ^ status[3])),
   .scandoubler(scandoubler),
   .gamma_bus(gamma_bus),
   .ce_pix(ce_pix),
   .R(R_ovl),
   .G(G_ovl),
   .B(B_ovl),
   .HSync(hsync),
   .VSync(vsync),
   
   .HBlank(hblank),
   .VBlank(vblank),

   .HDMI_FREEZE(),
   .freeze_sync(),

   .CE_PIXEL(CE_PIXEL),
   .VGA_R(VGA_R),
   .VGA_G(VGA_G),
   .VGA_B(VGA_B),
   .VGA_VS(VGA_VS),
   .VGA_HS(VGA_HS),
   .VGA_DE(vga_de)
);

/////////////////  Tape In   /////////////////
wire tape_adc, tape_adc_act, tape_in;

assign tape_in = tape_adc_act & tape_adc;

ltc2308_tape #(.ADC_RATE(120000), .CLK_RATE(21477272)) tape
(
   .clk(clk21m),
   .ADC_BUS(ADC_BUS),
   .dout(tape_adc),
   .active(tape_adc_act)
);

/////////////////  LOAD PACK   /////////////////

wire upload_ram_ce, upload_sdram_rq, upload_bram_rq, upload_ram_ready, reset_rq;
wire nvbak_dma_active;

wire  [7:0] upload_ram_din, config_msx;
wire [26:0] upload_ram_addr;
wire  [7:0] kbd_din;
wire  [8:0] kbd_addr;
wire        kbd_request, kbd_we;
wire        load_sram;
wire  [1:0] rom_loaded;
wire  [1:0] rom_big;
memory_upload memory_upload(
    .clk(clk21m),
    .reset_rq(reset_rq),
    .ioctl_download(ioctl_download),
    .ioctl_index(ioctl_index),
    .ioctl_addr(ioctl_addr),
    .rom_eject(status[10]),
    .reload(reload),
    .ddr3_addr(ddr3_addr_download),
    .ddr3_rd(ddr3_rd_download),
    .ddr3_wr(),
    .ddr3_dout(ddr3_dout),
    .ddr3_ready(ddr3_ready),
    .ddr3_request(ddr3_request_download),
    .ram_addr(upload_ram_addr),
    .ram_din(upload_ram_din),
    .ram_dout(),
    .ram_ce(upload_ram_ce),
    .sdram_ready(upload_ram_ready),
    .sdram_rq(upload_sdram_rq),
    .bram_rq(upload_bram_rq),
    .kbd_request(kbd_request),
    .kbd_addr(kbd_addr),
    .kbd_din(kbd_din),
    .kbd_we(kbd_we),
    .sdram_size(sdram_size),
    .slot_layout(slot_layout),
    .lookup_RAM(lookup_RAM),
    .lookup_SRAM(lookup_SRAM),
    .bios_config(bios_config),
    .cart_conf(cart_conf),
    .rom_loaded(rom_loaded),
    .rom_big(rom_big),
    .cart_device(cart_device),
    .msx_device(msx_device),
    .msx_dev_ref_ram(msx_dev_ref_ram),
    .load_sram(load_sram),
    .pcm_rom_base(pcm_rom_base)
);

wire [27:0] ddr3_addr, ddr3_addr_download, ddr3_addr_cas;
wire  [7:0] ddr3_dout, ddr3_din_download;
wire        ddr3_rd, ddr3_rd_download, ddr3_rd_cas, ddr3_wr_download, ddr3_ready, ddr3_request_download;

assign ddr3_addr = ddr3_request_download ? ddr3_addr_download : ddr3_addr_cas ;
assign ddr3_rd   = ddr3_request_download ? ddr3_rd_download   : ddr3_rd_cas   ;
assign DDRAM_CLK = clk21m;

ddram buffer
(
   .DDRAM_CLK(clk21m),
   .addr(ddr3_addr),
   .dout(ddr3_dout),
   .din(),
   .we(),
   .rd(ddr3_rd),
   .ready(ddr3_ready),
   .reset(reset),
   .*
);

assign ram_dout = sdram_ce ? sdram_dout :
                  bram_ce  ? bram_dout  :
                             8'hFF;

wire         sdram_ready, sdram_rnw, dw_sdram_we, dw_sdram_ready, flash_ready, flash_req, flash_done;
wire  [26:0] sdram_addr;
wire  [24:0] dw_sdram_addr;
wire  [26:0] flash_addr;
wire   [7:0] sdram_dout, bram_dout, dw_sdram_din, flash_din;

// SDRAM ch1: mux between ROM upload and nvram_backup SDRAM DMA
wire  [7:0] nvbak_sdram_dout;
wire [26:0] nvbak_sdram_addr;
wire        nvbak_sdram_req, nvbak_sdram_rnw;
wire  [7:0] nvbak_sdram_din;
wire        upload_active = upload_ram_ce & upload_sdram_rq;
// log_clear: pulse on new ROM staging start -> reset change-log journal per game
reg         upload_active_q;
always @(posedge clk21m) upload_active_q <= upload_active;
assign      log_clear = upload_active & ~upload_active_q;

// MoonSound PCM SDRAM ch4 wires
wire [26:0] pcm_sdram_addr;
wire        pcm_sdram_req;
wire        pcm_sdram_rnw;
wire  [7:0] pcm_sdram_din;
wire  [7:0] pcm_sdram_dout;
wire [15:0] pcm_sdram_dout16;
wire        pcm_sdram_ready;

// PCM ROM base address in SDRAM — driven by memory_upload when loading yrw801.rom
wire [26:0] pcm_rom_base;

sdram sdram
(
   .init(~locked_sdram),
   .clk(clk_sdram),
   .doRefresh(1'd0),

   .ch1_dout(nvbak_sdram_dout),
   .ch1_din (upload_active ? upload_ram_din  : dump_active ? dump_sdram_din  : nvbak_sdram_din),
   .ch1_addr(upload_active ? upload_ram_addr : dump_active ? dump_sdram_addr : nvbak_sdram_addr),
   .ch1_req (upload_active ? upload_active   : dump_active ? dump_sdram_req  : nvbak_sdram_req),
   .ch1_rnw (upload_active ? 1'b0            : dump_active ? dump_sdram_rnw  : nvbak_sdram_rnw),
   .ch1_ready(upload_ram_ready),

   .ch2_dout(sdram_dout),
   .ch2_din(ram_din),
   .ch2_addr(ram_addr),
   .ch2_req(sdram_ce),
   .ch2_rnw(ram_rnw),
   .ch2_ready(sdram_ready),

   .ch3_addr(flash_addr),
   .ch3_dout(),
   .ch3_din(flash_din),
   .ch3_req(flash_req),
   .ch3_rnw(0),
   .ch3_ready(flash_ready),
   .ch3_done(flash_done),

   // ch4: MoonSound PCM reads/writes
   .ch4_addr(pcm_sdram_addr),
   .ch4_dout(pcm_sdram_dout),
   .ch4_dout16(pcm_sdram_dout16),
   .ch4_din(pcm_sdram_din),
   .ch4_req(pcm_sdram_req),
   .ch4_rnw(pcm_sdram_rnw),
   .ch4_ready(pcm_sdram_ready),
   .*
);

// systemRAM addr_width 16: reclaims ~192 M10K. Verified safe (HW autoload OK) —
// machine-ROM PACK and MSX main RAM route to SDRAM (msx_slots sdram_ce when
// sdram_size!=0); BRAM serves only SRAM (sram_cs, <=64KB). The earlier autoload
// regression was the F1/store_name conf bug (fixed: FC1), NOT this width.
dpram #(.addr_width(16)) systemRAM
(
   .clock(clk21m),
   .address_a(18'(upload_bram_rq ? upload_ram_addr : ram_addr)          ),
   .wren_a( upload_bram_rq ? upload_ram_ce         : bram_ce & ~ram_rnw ),
   .data_a( upload_bram_rq ? upload_ram_din        : ram_din            ),
   .q_a(bram_dout),
   .address_b(18'(sram_addr)),
   .wren_b(sram_we),
   .data_b(sd_buff_dout),
   .q_b(sram_dout)
);

///////////////// NVRAM BACKUP ////////////////
wire  [1:0] flash16x_active;
// Which cart the flash persistence engines serve.  The firmware mounts exactly one
// companion <rom>.sav, always on drive 0 (user_io.cpp: `if (opensave)
// user_io_file_mount(buf, 0, 1)`), so only one flash cart can ever be persisted --
// there is no second VD to give slot B.  Pick slot B only when it is the sole flash
// cart; with a flash cart in both slots slot A keeps the engine exactly as before,
// because we cannot tell which of the two the single mounted .sav belongs to.
wire        flash16x_sel = flash16x_active[1] & ~flash16x_active[0];
wire [26:0] flash16x_base[2];
wire [15:0] flash16x_size[2];

wire [26:0] sram_addr;
wire  [7:0] sram_dout;
wire        sram_we;

// EXPERIMENT: VD0 (auto-mounted <rom>.sav) is muxed between nvram_backup and the
// flash_dump_test module. nvram drives nv_sd_*; dump drives dump_sd_*; dump wins
// while dump_active. VD1-3 pass through nvram unchanged.
wire [31:0] nv_sd_lba[0:3];
wire  [3:0] nv_sd_rd, nv_sd_wr;
wire  [7:0] nv_sd_buff_din[0:3];
wire [31:0] dump_sd_lba;
wire        dump_sd_wr, dump_sd_rd;
wire  [7:0] dump_sd_buff_din;

assign sd_lba[0]      = dump_active ? dump_sd_lba      : nv_sd_lba[0];
assign sd_lba[1]      = nv_sd_lba[1];
assign sd_lba[2]      = nv_sd_lba[2];
assign sd_lba[3]      = nv_sd_lba[3];
assign sd_rd[3:1]     = nv_sd_rd[3:1];
assign sd_rd[0]       = dump_active ? dump_sd_rd       : nv_sd_rd[0];
assign sd_wr[3:1]     = nv_sd_wr[3:1];
assign sd_wr[0]       = dump_active ? dump_sd_wr       : nv_sd_wr[0];
assign sd_buff_din[0] = dump_active ? dump_sd_buff_din : nv_sd_buff_din[0];
assign sd_buff_din[1] = nv_sd_buff_din[1];
assign sd_buff_din[2] = nv_sd_buff_din[2];
assign sd_buff_din[3] = nv_sd_buff_din[3];

nvram_backup nvram_backup
(
   .clk(clk21m),
   .reset(reset),
   .lookup_SRAM(lookup_SRAM),
   .load_req(status[39] | load_sram),
   .save_req(status[38]),
   .img_mounted(img_mounted[3:0]),
   .img_readonly(img_readonly),
   .img_size(img_size),
   .sd_lba(nv_sd_lba),
   .sd_rd(nv_sd_rd),
   .sd_wr(nv_sd_wr),
   .sd_ack(sd_ack[3:0]),
   .sd_buff_addr(sd_buff_addr),
   .sd_buff_dout(sd_buff_dout),
   .sd_buff_din(nv_sd_buff_din),
   .ram_addr(sram_addr),
   .ram_dout(sram_dout),
   .ram_we(sram_we),
   .flash16x_active(flash16x_active[flash16x_sel]),
   .flash16x_base(flash16x_base[flash16x_sel]),
   .flash16x_size(flash16x_size[flash16x_sel]),
   .sdram_req (nvbak_sdram_req),
   .sdram_rnw (nvbak_sdram_rnw),
   .sdram_addr(nvbak_sdram_addr),
   .sdram_din (nvbak_sdram_din),
   .sdram_dout(nvbak_sdram_dout),
   .sdram_ready(upload_ram_ready),
   .dma_active(nvbak_dma_active)
);

// ---- ASCII16X DIRTY-BLOCK engine (64KB dirty bitmap -> dump dirty blocks -> VD0 .sav) ----
// SAVE=status[38], LOAD=status[39]|load_sram. Gated on flash16x_active. Reuses the
// dump_* ch1/VD0 mux wires (cl_active==dump_active). Captures prog_we at 64KB
// granularity (0 M10K bitmap); SAVE reads real data from SDRAM -> no overflow.
flash_dirtysave flash_dirtysave
(
   .clk(clk21m),
   .reset(reset),
   .flash16x_active(flash16x_active[flash16x_sel]),
   .flash16x_base(flash16x_base[flash16x_sel]),
   .flash16x_size(flash16x_size[flash16x_sel]),
   .prog_we(flash16x_prog_we),
   .prog_addr(flash16x_prog_addr),
   .save_req(status[38]),
   .load_req(status[39] | load_sram),
   .upload_active(upload_active),
   .log_clear(log_clear),
   .img_mounted(img_mounted[0]),
   .img_readonly(img_readonly),
   .img_size(img_size),
   .sdram_addr(dump_sdram_addr),
   .sdram_req(dump_sdram_req),
   .sdram_rnw(dump_sdram_rnw),
   .sdram_din(dump_sdram_din),
   .sdram_dout(nvbak_sdram_dout),
   .cl_active(dump_active),
   .sd_lba(dump_sd_lba),
   .sd_rd(dump_sd_rd),
   .sd_wr(dump_sd_wr),
   .sd_ack(sd_ack[0]),
   .sd_buff_addr(sd_buff_addr),
   .sd_buff_din(dump_sd_buff_din),
   .sd_buff_dout(sd_buff_dout),
   .sd_buff_wr(sd_buff_wr)
);

///////////////// CAS EMULATE /////////////////
wire ioctl_isCAS, buff_mem_ready, motor, CAS_dout, play, rewind;
logic cas_load = 0;
always @(posedge clk21m) begin
   logic ioctl_download_last; 
   if (~ioctl_isCAS & ioctl_download_last )  begin
      cas_load <= 1'b1;
   end
   ioctl_download_last <= ioctl_isCAS;         
end

assign play         = ~motor & cas_load;
assign ioctl_isCAS  = ioctl_download & (ioctl_index[5:0] == 6'd5);
assign rewind       = status[9] | ioctl_isCAS | reset;

tape cass 
(
   .clk(clk21m),
   .ce_5m3(ce_5m39_p),
   .cas_out(CAS_dout),
   .ram_a(ddr3_addr_cas),
   .ram_di(ddr3_dout),
   .ram_rd(ddr3_rd_cas),
   .buff_mem_ready(ddr3_ready),
   .play(play),
   .rewind(rewind)
);

endmodule
