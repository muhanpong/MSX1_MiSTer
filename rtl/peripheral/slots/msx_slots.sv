module msx_slots
(
   input                       clk,
   input                       clk_sdram,
   input                       clk_en,       // 3.58MHz - sound chips (pitch), chip-internal timing
   input                       clk_en_cpu,   // CPU rate (== clk_en unless turbo): PSG bus strobe + FDC
   input                       reset,
   //BASE                
   input                [15:0] cpu_addr,
   input                 [7:0] cpu_dout,
   output                [7:0] cpu_din,
   input                       cpu_wr,
   input                       cpu_rd,
   input                       cpu_mreq,
   input                       cpu_iorq,
   input                       cpu_m1,
   input                 [1:0] active_slot,
   output signed        [15:0] sound,
   input                 [3:0] opll_vol,          // 2 dB ladder, see vol_mul()
   input                 [3:0] scc_vol,
   input                 [1:0] scc_en,           // per-cartridge SCC mute (1 = audible)
   input                      opll_mute,
   //RAM
   output               [26:0] ram_addr,
   output                [7:0] ram_din,
   input                 [7:0] ram_dout,
   output                      ram_rnw,
   output                      sdram_ce,
   output                      bram_ce,
   input                 [1:0] sdram_size,
   output               [26:0] flash_addr,
   output                [7:0] flash_din,
   output                      flash_req,
   input                       flash_ready,
   input                       flash_done,
   //Block device
   input                       img_mounted,
   input                [31:0] img_size,
   input                       img_readonly,
   output               [31:0] sd_lba,
   output                      sd_rd,
   output                      sd_wr,
   input                       sd_ack,
   input                [13:0] sd_buff_addr,
   input                 [7:0] sd_buff_dout,
   output                [7:0] sd_buff_din,
   input                       sd_buff_wr,
   //Config
   input  MSX::block_t         slot_layout[64],
   input  MSX::lookup_RAM_t    lookup_RAM[16],
   input  MSX::lookup_SRAM_t   lookup_SRAM[4],
   input  MSX::bios_config_t   bios_config,
   input  mapper_typ_t         selected_mapper[2],
   input  dev_typ_t            cart_device[2],
   input  dev_typ_t            msx_device,
   input                 [3:0] msx_dev_ref_ram[8],
   //SD CARD
   output             [7:0] d_to_sd,
   input              [7:0] d_from_sd,
   output                   sd_tx,
   output                   sd_rx,
   //DEBUG
   output                   debug_FDC_req,
   output                   debug_sd_card,
   output                   debug_erase,
   output                   debug_scc_wr,
   // ASCII16X flash info (for SDRAM-based save/load)
   output logic       [1:0] flash16x_active,
   output logic      [26:0] flash16x_base[2],
   output logic      [15:0] flash16x_size[2],
   // ASCII16X write-time capture (for change-log persistence)
   output                   flash16x_prog_we,
   // Turbo guard scoping: current memory access targets a ce_3m58-latched
   // device (SCC/SCC+ register window, FM-PAC memory-mapped OPLL).  See the
   // assign near the opll instance and the TURBO BUS GUARD block in msx.sv.
   output                   slow_dev,
   // Turbo OPLL write pacer (see the block near the opll instance): msx.sv
   // ANDs opll_pace_n into wait_n exactly like vdp_pace_n.
   input                    cpu_turbo,
   output                   msx_turbo_req,       // Panasonic 40H/41H asked for 5.37MHz
   output                   opll_pace_n,
   output            [22:0] flash16x_prog_addr,
   output             [7:0] flash16x_prog_data
);

assign flash16x_prog_we   = mapper_ascii16x_prog_we | mapper_yamanooto_prog_we;
// Edge-valid form of the same thing, for flash.sv's command-decode inhibit.
wire flash16x_prog_phase  = mapper_ascii16x_prog_phase | mapper_yamanooto_prog_phase;
assign flash16x_prog_addr = mapper_yamanooto_prog_we ? mapper_yamanooto_flash_addr
                                                       : mapper_ascii16x_addr[22:0];
assign flash16x_prog_data = cpu_dout;

// Per-source trim, then a WIDE sum that saturates.  The old one-line 16-bit add
// could already wrap silently when three loud sources coincided; scaling makes that
// more reachable, so the sum is done in 18 bits and clipped instead of wrapping.
// Multipliers are x/128: 128=0dB, 203=+4dB, 81=-4dB, 51=-8dB (same table the OPL4
// trim uses).  Entry 0 is 0dB so an untouched menu is bit-identical to before --
// x128>>>7 is exact, not an approximation.
// signed [9:0], not [8:0].  A signed 9-bit field tops out at 255, so a future
// "+8dB" entry (x322) would read as -190 -- a SIGN INVERSION of the whole channel
// that nothing downstream can detect.  msx.sv's psg_mul is UNSIGNED [8:0] (max
// 511) and would not have that problem, so the two "identical" tables did not
// actually have identical headroom.  Widen here rather than rely on a comment.
function automatic signed [9:0] vol_mul(input [3:0] v);
   // 2 dB ladder; labels are dB VS UNITY and the multipliers deliver them (max
   // error 0.03 dB).  Ring 0,-2,-4,-6,-8,0,+2,+4,+6,+8 (0 twice: down to -8, back through 0, up to +8).
   // Entry 0 = OSD power-on default = 0 dB = unity, unchanged for OPLL/SCC.
   case (v)
       4'd1: vol_mul = 10'sd102;   //  -2dB
       4'd2: vol_mul = 10'sd81;   //  -4dB
       4'd3: vol_mul = 10'sd64;   //  -6dB
       4'd4: vol_mul = 10'sd51;   //  -8dB
       4'd5: vol_mul = 10'sd128;   //   0dB
       4'd6: vol_mul = 10'sd161;   //  +2dB
       4'd7: vol_mul = 10'sd203;   //  +4dB
       4'd8: vol_mul = 10'sd255;   //  +6dB
       4'd9: vol_mul = 10'sd322;   //  +8dB
       default: vol_mul = 10'sd128;   //   0dB  <- entry 0 = OSD default / out of range
   endcase
endfunction

// Mute is a separate control, not a ladder rung -- see the CONF_STR note in MSX1.sv.
wire signed [24:0] opll_scaled = opll_mute ? 25'sd0 : $signed(sound_opll) * vol_mul(opll_vol);
wire signed [24:0] scc_scaled  = $signed(scc_wave)   * vol_mul(scc_vol);
// 19 bits, not 18: worst case is 51966 + 51966 + 32767 = 136699, which overflows
// an 18-bit signed sum and would wrap BEFORE the clamp could see it.
wire signed [18:0] snd_sum     = 19'($signed(opll_scaled) >>> 7)
                               + 19'($signed(scc_scaled)  >>> 7)
                               + 19'(sound_psg);
assign sound = (snd_sum > 19'sd32767)  ? 16'sh7FFF :
               (snd_sum < -19'sd32768) ? 16'sh8000 : 16'(snd_sum);
assign d_to_sd = cpu_dout;
assign debug_FDC_req = FDC_req;

logic [7:0] mapper_slot[4];
wire mapper_en, mapper_rd;
wire [7:0] slot_mapper_dout;
wire [7:0] yamanooto_dout = mapper_yamanooto_dout_en ? mapper_yamanooto_dout : 8'hFF;

assign mapper_en = (cpu_addr == 16'hFFFF & bios_config.slot_expander_en[active_slot] & mapper_mask[active_slot] & cpu_mreq );
assign mapper_rd =  mapper_en & cpu_rd;
assign slot_mapper_dout  =  mapper_rd ? ~mapper_slot[active_slot] : 8'hFF;
always @(posedge clk) begin
   if (reset) begin
      mapper_slot[0] <= 8'h00;
      mapper_slot[1] <= 8'h00;
      mapper_slot[2] <= 8'h00;
      mapper_slot[3] <= 8'h00;
   end else begin
      if (mapper_en & cpu_wr )
         mapper_slot[active_slot] <= cpu_dout;
   end
end


mapper_typ_t        mapper;
device_typ_t        device;

wire          [1:0] block      = cpu_addr[15:14];
wire          [1:0] subslot    = mapper_slot[active_slot][(3'd2 * block) +:2];
wire          [5:0] layout_id  = {active_slot, subslot, block};
wire          [3:0] ref_ram    = slot_layout[layout_id].ref_ram;
wire          [1:0] ref_sram   = slot_layout[layout_id].ref_sram;
wire          [1:0] offset_ram = slot_layout[layout_id].offset_ram;
wire                cart_num   = slot_layout[layout_id].cart_num;
wire                external   = slot_layout[layout_id].external;
assign              device     = slot_layout[layout_id].device;
assign              mapper     = selected_mapper[cart_num] == MAPPER_UNUSED 
                               & device == DEVICE_ROM 
                               & external                                     ? MAPPER_UNUSED : slot_layout[layout_id].mapper;                              
wire         [26:0] base_ram   = lookup_RAM[ref_ram].addr;
wire         [15:0] size       = lookup_RAM[ref_ram].size;  //16kB * size
wire                ram_ro     = lookup_RAM[ref_ram].ro;
wire         [17:0] base_sram  = lookup_SRAM[ref_sram].addr;
wire         [15:0] size_sram  = lookup_SRAM[ref_sram].size;

assign ram_addr   = device_kanji_ram_ce ? device_kanji_addr                                   :
                                          (sram_cs ? 27'(base_sram) : base_ram) + mapper_addr ;

wire cart_ascii8  = mapper == MAPPER_ASCII8  | mapper == MAPPER_KOEI | mapper == MAPPER_WIZARDY;
wire cart_ascii16 = mapper == MAPPER_ASCII16 | mapper == MAPPER_RTYPE;

wire [26:0] mapper_addr = mem_unmaped                 ? 27'hDEAD                    :
                          mapper == MAPPER_NONE       ? 27'(mapper_none_addr)       :
                          mapper == MAPPER_RAM        ? 27'(mapper_ram_addr)        :
                          mapper == MAPPER_LINEAR     ? 27'(mapper_linear_addr)     :
                          mapper == MAPPER_OFFSET     ? 27'(mapper_offset_addr)     :
                          mapper == MAPPER_KONAMI     ? 27'(mapper_konami_addr)     :
                          mapper == MAPPER_KONAMI_SCC ? 27'(mapper_konami_scc_addr) :
                          mapper == MAPPER_FMPAC      ? 27'(fmpac_addr)             :
                          mapper == MAPPER_MFRSD1     ? 27'(mapper_mfrsd1_addr)     :
                          mapper == MAPPER_MFRSD2     ? 27'(mapper_mfrsd2_addr)     :
                          mapper == MAPPER_MFRSD3     ? 27'(mapper_mfrsd3_addr)     :
                          mapper == MAPPER_HALNOTE    ? 27'(mapper_halnote_addr)    :
                          cart_ascii8                 ? 27'(mapper_ascii8_addr)     :
                          cart_ascii16                ? 27'(mapper_ascii16_addr)    :
                          mapper == MAPPER_ASCII16X   ? 27'(mapper_ascii16x_addr)   :
                          mapper == MAPPER_YAMANOOTO  ? 27'(mapper_yamanooto_addr)  :
                          mapper == MAPPER_GM2        ? 27'(mapper_gm2_addr)        :
                                                        27'hDEAD                    ;

assign cpu_din          = mapper_ram_dout                        //IO
                        & mapper_mfrsd2_dout                     //IO
                        & slot_mapper_dout                       //UNMAPPED
                        & mapper_mfrsd3_dout                     //UNMAPPED
                        & fm_pac_dout                            //UNMAPPED
                        & d_to_cpu_FDC                           //UNMAPPED
                        & scc_sound_dout                         //UNMAPPED
                        & yamanooto_dout                         //UNMAPPED
                        & psg_dout                               //IO (cart PSG read, port 12H)
                        & flash_dout
                        & d_to_cpu_reset_status                  //IO
                        & d_to_cpu_matsushita                    //IO 40H/41H
                        & (mem_unmaped  ? 8'hFF : ram_dout);

assign sdram_ce = (sdram_size != 2'd0 & ~sram_cs) & ((cpu_mreq & (cpu_rd | (cpu_wr & ~ram_ro)) & mapper != MAPPER_UNUSED & ~mem_unmaped) | device_kanji_ram_ce | mapper_ascii16x_prog_we | mapper_yamanooto_prog_we);
assign bram_ce  = (sdram_size == 2'd0 | sram_cs)  & ((cpu_mreq & (cpu_rd | (cpu_wr & (~ram_ro | sram_cs))) & mapper != MAPPER_UNUSED & ~mem_unmaped) | device_kanji_ram_ce);
assign ram_rnw  = ~((sram_cs & sram_wr) | (~sram_cs & cpu_wr & cpu_mreq & ~ram_ro) | mapper_ascii16x_prog_we | mapper_yamanooto_prog_we);

assign ram_din  = cpu_dout;

wire mem_unmaped = mapper_konami_unmaped     | 
                   mapper_konami_scc_unmaped |
                   fmpac_mem_unmaped         | 
                   mapper_mfrsd1_unmaped     | 
                   mapper_mfrsd3_unmaped     | 
                   mapper_ascii8_unmaped     | 
                   mapper_ascii16_unmaped    |
                   mapper_ascii16x_unmaped   |
                   mapper_yamanooto_unmaped  |
                   mapper_halnote_unmaped    | 
                   mapper_rd                 | 
                   FDC_req                   |
                   flash_rq                  ;
                   
wire [3:0] mapper_mask = mapper_mfrd_mask;
wire sram_cs     = fmpac_sram_cs | gm2_sram_cs | ascii16_sram_cs | ascii8_sram_cs | halnote_sram_cs;
wire sram_wr     = fmpac_sram_wr | gm2_sram_wr | ascii16_sram_wr | ascii8_sram_wr | halnote_sram_wr;

//MAPPER NONE
wire [26:0] mapper_none_addr = 27'(cpu_addr[13:0]) + (27'(offset_ram) << 14);

//MAPPER LINEAR
wire [26:0] mapper_linear_addr = 27'(cpu_addr[15:0]) & ((27'(size) << 14)-27'd1);

//NONE 
wire [26:0] mapper_offset_addr  = 27'({(cpu_addr[15:14] - offset_ram),cpu_addr[13:0]});
//wire mapper_offset_unmaped      = cpu_addr[15:14] < offset_ram; //TODO podminit mapperem

wire [24:0] mapper_halnote_addr;
wire        mapper_halnote_unmaped;
wire        halnote_sram_cs, halnote_sram_wr;
mapper_halnote halnote
(
   //.rom_size(25'(size) << 14),
   .din(cpu_dout),
   .cs(mapper == MAPPER_HALNOTE),
   .mem_unmaped(mapper_halnote_unmaped),
   .mem_addr(mapper_halnote_addr),
   .sram_cs(halnote_sram_cs),
   .sram_we(halnote_sram_wr),
   .*
);

wire flash_rq;
wire [7:0] flash_dout;
// A cart that owns its own SDRAM region (not the shared MFRSD chip window): its
// erase must be clamped to that region and it reports the AMD manufacturer id.
wire own_flash_rq = (mapper_ascii16x_flash_rq | mapper_yamanooto_flash_rq)
                  & ~mapper_mfrsd0_flash_rq & ~mapper_mfrsd3_flash_rq;
flash flash 
(
   .clk(clk),
   .clk_sdram(clk_sdram),
   .addr(23'(mapper_mfrsd0_flash_rq   ? flash_mfrsd0_addr            :
             mapper_mfrsd3_flash_rq   ? flash_mfrsd3_addr            :
             mapper_ascii16x_flash_rq ? mapper_ascii16x_flash_addr   :
             mapper_yamanooto_flash_rq ? mapper_yamanooto_flash_addr :
                                        flash_mfrsd1_addr             )),
   .din(cpu_dout),
   .dout(flash_dout),
   .data_valid(flash_rq),
   .we(cpu_mreq & cpu_wr),
   // The mappers that run their own program FSM already know which write is
   // data; flash.sv must not decode those as command cycles (flash.sv data_phase).
   .data_phase(flash16x_prog_phase),
   .ce(((mapper_mfrsd3_flash_rq | mapper_mfrsd1_flash_rq | mapper_mfrsd0_flash_rq) & |(cart_device[cart_num] & DEV_FLASH)) |
       mapper_ascii16x_flash_rq | mapper_yamanooto_flash_rq),
   .sdram_addr(flash_addr),
   .sdram_din(flash_din),
   .sdram_req(flash_req),
   .sdram_ready(flash_ready),
   .sdram_done(flash_done),
   .sdram_offset((mapper_ascii16x_flash_rq | mapper_yamanooto_flash_rq) ? 27'(base_ram) : mfrsd_base_ram[0]),
   // AMD/Spansion id + CFI: both the ASCII16X cart and Yamanooto are AMD-family.
   .amd_family(own_flash_rq),
   // Bottom-boot is NOT a per-cart property here: openMSX models all three parts
   // with the same map -- 8 x 8KB then 127 x 64KB.  ASCII16X S29GL064S70TFI040,
   // Yamanooto S29GL064N90TFI04, MFRSD-SD M29W640GB.  Gating this on the ASCII16X
   // path alone is what left MFRSD scaling an 8KB sector index by 16 bits.
   .boot_sector(1'b1),
   // Region byte-size the erase may not exceed: the owning cart's own ROM area,
   // or the full 8MB chip window for the MFRSD paths (their region is 8MB).
   .erase_limit(own_flash_rq ? 27'(size) << 14 : 27'h800000),
   .debug_erase(debug_erase)
);


wire [26:0] mfrsd_base_ram[2];
wire [22:0] flash_mfrsd0_addr;
wire        mapper_mfrsd0_flash_rq;
mapper_mfrsd0 mfrsd0
(
   .cs(device == DEVICE_MFRSD0),
   .mfrsd_base_ram(mfrsd_base_ram),
   .flash_addr(flash_mfrsd0_addr),
   .flash_rq(mapper_mfrsd0_flash_rq),
   .*
);

wire  [3:0] mapper_mfrd_mask;
wire [26:0] mapper_mfrsd1_addr;
wire        mapper_mfrsd1_unmaped;
wire  [7:0] mfrsd_configReg; 
wire [22:0] flash_mfrsd1_addr;
wire        mapper_mfrsd1_flash_rq;
wire        mapper_mfrdsd1_sccMode, mapper_mfrdsd1_sccReq;
mapper_mfrsd1 mfrsd1
(
   .slot(active_slot),
   .cs(mapper == MAPPER_MFRSD1), 
   .din(cpu_dout),
   .configReg(mfrsd_configReg),
   .mfrsd_base_ram(mfrsd_base_ram[0]),
   .mapper_mask(mapper_mfrd_mask),
   .mem_addr(mapper_mfrsd1_addr),
   .mem_unmaped(mapper_mfrsd1_unmaped),
   .flash_addr(flash_mfrsd1_addr),
   .flash_rq(mapper_mfrsd1_flash_rq),
   .scc_mode(mapper_mfrdsd1_sccMode),
   .scc_req(mapper_mfrdsd1_sccReq),
   .*
);

wire [21:0] mapper_mfrsd2_addr;
wire  [7:0] mapper_mfrsd2_dout;
mapper_mfrsd2 mfrsd2
(
   .mapper_dout(mapper_mfrsd2_dout),
   .mem_addr(mapper_mfrsd2_addr),
   .en(|(cart_device[cart_num] & DEV_MFRSD2)),
   .*
);

wire [26:0] mapper_mfrsd3_addr;
wire [22:0] flash_mfrsd3_addr;
wire        mapper_mfrsd3_unmaped, mfrsd3_oe;
wire  [7:0] mapper_mfrsd3_dout;
wire        mapper_mfrsd3_flash_rq;
mapper_mfrsd3 mfrsd3
(
   .cs(mapper == MAPPER_MFRSD3), 
   .din(cpu_dout),
   .mem_addr(mapper_mfrsd3_addr),
   .flash_addr(flash_mfrsd3_addr),
   .mem_unmaped(mapper_mfrsd3_unmaped),
   .sd_tx(sd_tx),
   .sd_rx(sd_rx),
   .d_from_sd(d_from_sd),
   .mfrsd_base_ram(mfrsd_base_ram[0]),
   .configReg(mfrsd_configReg),
   .mapper_dout(mapper_mfrsd3_dout),
   .flash_rq(mapper_mfrsd3_flash_rq),
   .debug_sd_card(debug_sd_card),
   .*
);

//MAPPER MSX RAM
wire [21:0] mapper_ram_addr;
wire  [7:0] mapper_ram_dout;
msx2_ram_mapper msx2_ram_mapper
(
   .en(bios_config.MSX_typ == MSX2),
   .ram_block_count(bios_config.ram_size),
   .mapper_dout(mapper_ram_dout),
   .mapper_addr(mapper_ram_addr),
   .*
);

wire [24:0] mapper_konami_addr;
wire        mapper_konami_unmaped;
cart_konami konami
(
   .rom_size(25'(size) << 14),
   .din(cpu_dout),
   .cs(mapper == MAPPER_KONAMI),
   .mem_unmaped(mapper_konami_unmaped),
   .mem_addr(mapper_konami_addr),
   .*
);

wire [24:0] mapper_ascii8_addr;
wire        mapper_ascii8_unmaped;
wire        ascii8_sram_cs, ascii8_sram_wr;
cart_ascii8 ascii8
(
   .rom_size(25'(size) << 14),
   .cpu_addr(cpu_addr),
   .din(cpu_dout),
   .cs(cart_ascii8),
   .mem_unmaped(mapper_ascii8_unmaped),
   .mem_addr(mapper_ascii8_addr),
   .sram_cs(ascii8_sram_cs),
   .sram_we(ascii8_sram_wr),
   .*
);

wire [24:0] mapper_ascii16_addr;
wire        mapper_ascii16_unmaped;
wire        ascii16_sram_cs, ascii16_sram_wr;
cart_ascii16 ascii16
(
   .rom_size(25'(size) << 14),
   .din(cpu_dout),
   .cs(cart_ascii16),
   .mem_unmaped(mapper_ascii16_unmaped),
   .mem_addr(mapper_ascii16_addr),
   .sram_cs(ascii16_sram_cs),
   .sram_we(ascii16_sram_wr),
   .*
);

wire [24:0] mapper_ascii16x_addr;
wire        mapper_ascii16x_unmaped;
wire [22:0] mapper_ascii16x_flash_addr;
wire        mapper_ascii16x_flash_rq;
wire        mapper_ascii16x_prog_we;   // validated JEDEC byte-program data write -> SDRAM
wire        mapper_ascii16x_prog_phase;
cart_ascii16x ascii16x
(
   .rom_size(25'(size) << 14),
   .din(cpu_dout),
   .cs(mapper == MAPPER_ASCII16X),
   .mem_unmaped(mapper_ascii16x_unmaped),
   .mem_addr(mapper_ascii16x_addr),
   .flash_addr(mapper_ascii16x_flash_addr),
   .flash_rq(mapper_ascii16x_flash_rq),
   .prog_we(mapper_ascii16x_prog_we),
   .prog_phase(mapper_ascii16x_prog_phase),
   .*
);

wire [24:0] mapper_yamanooto_addr;
wire        mapper_yamanooto_unmaped;
wire  [7:0] mapper_yamanooto_dout;
wire        mapper_yamanooto_dout_en;
wire        mapper_yamanooto_sccReq;
wire  [1:0] mapper_yamanooto_sccMode;
wire        mapper_yamanooto_wren;
wire [22:0] mapper_yamanooto_flash_addr;
wire        mapper_yamanooto_flash_rq;
wire        mapper_yamanooto_prog_we;   // validated JEDEC byte-program data write -> SDRAM
wire        mapper_yamanooto_prog_phase;
cart_yamanooto yamanooto
(
   .mem_size(25'(size) << 14),
   .din(cpu_dout),
   .cs(mapper == MAPPER_YAMANOOTO),
   .mem_unmaped(mapper_yamanooto_unmaped),
   .mem_addr(mapper_yamanooto_addr),
   .cart_dout(mapper_yamanooto_dout),
   .cart_dout_en(mapper_yamanooto_dout_en),
   .scc_req(mapper_yamanooto_sccReq),
   .scc_mode(mapper_yamanooto_sccMode),
   .flash_wr_en(mapper_yamanooto_wren),
   .flash_addr(mapper_yamanooto_flash_addr),
   .flash_rq(mapper_yamanooto_flash_rq),
   .prog_we(mapper_yamanooto_prog_we),
   .prog_phase(mapper_yamanooto_prog_phase),
   .*
);

wire [20:0] mapper_konami_scc_addr;
wire        mapper_konami_scc_unmaped;
wire        mapper_konami_scc_sccReq;
wire  [1:0] mapper_konami_scc_sccMode;
cart_konami_scc konami_scc
(
   .mem_size(25'(size) << 14),
   .din(cpu_dout),
   .cs(mapper == MAPPER_KONAMI_SCC),
   .mem_unmaped(mapper_konami_scc_unmaped),
   .mem_addr(mapper_konami_scc_addr), 
   .sccDevice(|(cart_device[cart_num] & DEV_SCC2)) ,
   .scc_req(mapper_konami_scc_sccReq),
   .scc_mode(mapper_konami_scc_sccMode),
   .*
);

wire        [7:0] scc_sound_dout;
wire signed [15:0] scc_wave;
scc_sound scc_sound
(
   .cs(mapper_konami_scc_sccReq | mapper_mfrdsd1_sccReq | mapper_yamanooto_sccReq),  
   .cpu_rd(cpu_rd),
   .cpu_wr(cpu_wr),
   .cpu_mreq(cpu_mreq),
   .cpu_addr(cpu_addr),
   .din(cpu_dout),
   .scc_dout(scc_sound_dout),
   // scc_en only reaches scc_sound's oe, and oe feeds nothing but the wave mix
   // (scc_sound.sv:23) -- muting here leaves register access and chip state alone.
   .oe({|(cart_device[1] & (DEV_SCC | DEV_SCC2)) & scc_en[1],
        |(cart_device[0] & (DEV_SCC | DEV_SCC2)) & scc_en[0]}),
   .wave(scc_wave),
   .sccPlusChip({|(cart_device[1] & DEV_SCC2), |(cart_device[0] & DEV_SCC2)}),
   // NOT gated on the *_sccReq strobes.  Those are only true during a bus cycle,
   // but IKASCC consumes i_SCCP_MODE continuously in its audio path, so a gated
   // value reads Compatible between accesses and ch5 then latches ch4's waveform
   // (IKASCC_player_s.v:309) -- the defect be52736 fixed for konami_scc, reached
   // by another route.  Yamanooto and konami_scc both emit a stable per-cart pair,
   // and for a given cart only one mapper is ever active so the others sit at
   // their reset 0; OR-ing them is therefore exact.
   // MFRSD is reached through its own SD-card menu, not the slot-B mapper
   // dropdown, so it only ever occupies cart 0 and {1'b0, ...} is correct for it.
   .sccPlusMode(mapper_yamanooto_sccMode | mapper_konami_scc_sccMode
                | {1'b0, mapper_mfrdsd1_sccMode}),
   .debug_scc_wr(debug_scc_wr),
   .*
);
wire [24:0] mapper_gm2_addr;
wire        gm2_sram_cs, gm2_sram_wr;
cart_gamemaster2 cart_gamemaster2
(
   .din(cpu_dout),
   .cs(mapper == MAPPER_GM2),
   .sram_we(gm2_sram_wr),
   .sram_cs(gm2_sram_cs),
   .mem_addr(mapper_gm2_addr),
   .*
);

wire  [7:0] fm_pac_dout;
wire [24:0] fmpac_addr;
wire        fmpac_req, fmpac_mem_unmaped, fmpac_sram_cs, fmpac_sram_wr;
wire  [1:0] fmpac_opll_io_enable, fmpac_opll_wr; 
cart_fm_pac fm_pac
(
   .din(cpu_dout),
   .mapper_dout(fm_pac_dout),  
   .cs(mapper == MAPPER_FMPAC),
   .sram_we(fmpac_sram_wr),
   .sram_cs(fmpac_sram_cs),
   .mem_unmaped(fmpac_mem_unmaped),
   .mem_addr(fmpac_addr),
   .opll_wr(fmpac_opll_wr),
   .opll_io_enable(fmpac_opll_io_enable),
   .*
);

wire opll_io_wr  = cpu_addr[7:1] == 7'b0111110 & cpu_iorq & ~cpu_m1 & cpu_wr; //7C - 7D
// FM-PAC memory-mapped OPLL pair 0x(7/B)FF4-5 as a COMBINATIONAL window —
// fmpac_opll_wr is registered one clk late in fm_pac.sv and misses the T80
// WAIT_n sample edge, so neither the guard scoping nor the pacer may use it
// for classification/arming.  (It stays the actual write strobe to the chip.)
wire fmpac_opll_win = (mapper == MAPPER_FMPAC) & cpu_mreq & cpu_addr[13:1] == 13'h1FFA;

//  -----------------------------------------------------------------------------
//  -- TURBO OPLL PACER
//  -----------------------------------------------------------------------------
// The bus guard fixes the WIDTH of one OPLL write; it cannot fix the GAP to
// the next one.  IKAOPLL (like the real YM2413) takes a CPU write into a
// single temporary latch (IKAOPLL_reg.v dbus_inlatch) and only commits it
// when the internal 18-slot rotation reaches the target register — up to
// 72 XIN cycles later.  The datasheet therefore demands 12 XIN after an
// address write and 84 XIN after a data write, and MSX-MUSIC drivers keep
// that spec with SOFTWARE delay loops — which shrink at turbo, so a second
// write clobbers the uncommitted latch and the music corrupts.
// This pacer enforces the spec in hardware, mirroring the VDP pacer: while
// the gap from the previous OPLL write has not elapsed, the write strobe to
// the chip is masked and msx.sv holds the CPU via opll_pace_n; once granted,
// the hold persists until one clk_en edge has passed with the strobe visible
// (= the capture guarantee the guard gives every slow window).  Gated on
// cpu_turbo, so stock stays bit-identical.  Music-register writes thus run
// at stock speed under turbo — exactly what the drivers' delay loops did.
localparam [9:0] OPLL_GAP_ADDR = 10'd72;    // 12 XIN * 6 clk21m
localparam [9:0] OPLL_GAP_DATA = 10'd504;   // 84 XIN * 6 clk21m

wire opll_win = opll_io_wr | (fmpac_opll_win & cpu_wr);   // any OPLL-bound write window
logic [9:0] opll_gap   = '0;
logic       opll_grant = 1'b0;
logic       opll_done  = 1'b0;   // chip-visible strobe has spanned a clk_en edge
logic       opll_a0    = 1'b0;   // A0 of the granted write, for the reload value
always @(posedge clk) begin
   if (reset) begin
      opll_gap <= '0; opll_grant <= 1'b0; opll_done <= 1'b0;
   end else if (~opll_win) begin
      // window closed: a granted+captured write starts the spec gap
      if (opll_grant & opll_done) opll_gap <= opll_a0 ? OPLL_GAP_DATA : OPLL_GAP_ADDR;
      else if (|opll_gap)         opll_gap <= opll_gap - 1'd1;
      opll_grant <= 1'b0;
      opll_done  <= 1'b0;
   end else begin
      if (~opll_grant) begin
         if (~|opll_gap) begin
            opll_grant <= 1'b1;
            opll_a0    <= cpu_addr[0];
         end else opll_gap <= opll_gap - 1'd1;
      end else if (clk_en & opll_wr_chip) opll_done <= 1'b1;
   end
end
// At stock the gate is forced open and pace_n forced released, so the chip
// sees exactly the ungated strobes.  The counter itself always runs, so a
// mid-tune speed switch keeps the pacing history.
wire opll_wr_gate = ~cpu_turbo | opll_grant;
wire opll_wr_chip = (opll_io_wr | fmpac_opll_wr[0] | fmpac_opll_wr[1]) & opll_wr_gate;
assign opll_pace_n = ~(cpu_turbo & opll_win & ~(opll_grant & opll_done));

wire signed [15:0] sound_OPL_int, sound_OPL_EXT[2];
wire signed [15:0] sound_opll;
opll opll
(
   .rst(reset),
   .clk(clk),
   .cen(clk_en),
   .din(cpu_dout),
   .addr(cpu_addr[0]),
   .wr({3{opll_wr_gate}} & {opll_io_wr, (opll_io_wr & fmpac_opll_io_enable[1]) | fmpac_opll_wr[1] , (opll_io_wr & fmpac_opll_io_enable[0]) | fmpac_opll_wr[0]}),
   .cs({|(msx_device & DEV_OPL3), |(cart_device[1] & DEV_OPL3), |(cart_device[0] & DEV_OPL3)}),
   .sound(sound_opll)
);

//  -----------------------------------------------------------------------------
//  -- TURBO GUARD SCOPING
//  -----------------------------------------------------------------------------
// Memory-mapped destinations whose registers latch on ce_3m58 rather than the
// CPU rate — the only two families left in the design (device audit 20260825):
//   * SCC/SCC+ register windows: IKASCC samples freq/vol/mute/deform at
//     !mclkpcen_n (= ce_3m58_p).  Wave RAM is async and would be safe fast,
//     but the whole window stays slow — narrowing by cpu_addr[7] buys little
//     and interacts with the SCC+ ch5 remap.
//   * FM-PAC memory-mapped OPLL pair 0x(7/B)FF4-5: IKAOPLL phiM cen = clk_en.
//     Decoded here combinationally — fmpac_opll_wr is REGISTERED one clk late
//     in fm_pac.sv and must not be used for guard classification.
// The sccReq terms are strobe-gated; that is safe for the guard because its
// counter only advances while a strobe is low, so the classification is valid
// from the first counted cycle and constant across the window (address and
// mapper state are stable while the strobe is asserted).
// I/O cycles never consult this — msx.sv keeps ALL of them on the slow path.
assign slow_dev = mapper_konami_scc_sccReq | mapper_mfrdsd1_sccReq | mapper_yamanooto_sccReq
                | fmpac_opll_win;

wire        device_kanji_ram_ce;
wire [26:0] device_kanji_addr;
kanji kanji
(
   .addr(cpu_addr[7:0]),
   .din(cpu_dout),
   .cs(|(msx_device & DEV_KANJI)),
   .base_ram(lookup_RAM[msx_dev_ref_ram[0]].addr),
   .rom_size(lookup_RAM[msx_dev_ref_ram[0]].size),
   .mem_addr(device_kanji_addr),
   .ram_ce(device_kanji_ram_ce),
   .*
);

wire [7:0] d_to_cpu_reset_status;
dev_reset_status dev_reset_status
(
   .cpu_addr(cpu_addr[7:0]),
   .cs(|(msx_device & DEV_RESET_STATUS)),
   .dout(d_to_cpu_reset_status),
   .*
);

wire [7:0] d_to_cpu_matsushita;
dev_matsushita dev_matsushita
(
   .cpu_addr(cpu_addr[7:0]),
   .cs(|(msx_device & DEV_MATSUSHITA)),
   .dout(d_to_cpu_matsushita),
   .turbo(msx_turbo_req),
   .*
);

wire signed [15:0] sound_psg;
wire  [7:0] psg_dout;
psg psg
(
   .cpu_addr(cpu_addr[7:0]),
   .cs({|(cart_device[1] & DEV_PSG), |(cart_device[0] & DEV_PSG)}),
   .sound(sound_psg),
   .dout(psg_dout),
   .*
);

always @(posedge clk) begin
    if (reset) begin
        flash16x_active <= 2'b00;
    end else if ((mapper == MAPPER_ASCII16X | mapper == MAPPER_YAMANOOTO) & cpu_mreq) begin
        flash16x_base[cart_num]   <= base_ram;
        flash16x_size[cart_num]   <= size;
        flash16x_active[cart_num] <= 1'b1;
    end
end

wire        FDC_req;
wire  [7:0] d_to_cpu_FDC;
// FDC on clk_en_cpu, NOT clk_en.  wd1793's `ce` port is documented as "ce at
// CPU clock rate" (wd1793.sv:28) and it EDGE-DETECTS the bus on that enable
// (wd1793.sv:271-387: old_wr/old_rd sampled under `if(ce)`, the write is only
// committed on the old_wr && !wre falling edge).  Unlike the SCC's level-based
// register capture, a single clock-enable edge inside the write window is NOT
// enough for it - it needs an edge with the strobe idle before AND after, i.e.
// a guaranteed idle gap, which WAIT_n fundamentally cannot create (WAIT_n can
// only lengthen the current cycle, never delay the next one's strobe).
// Clocking the whole wd1793 from the CPU rate keeps every CPU<->FDC timing
// RATIO identical to stock (bus handshake, watchdog, index counter and the
// main FSM all scale together), and is bit-identical when turbo is off.
// A dropped FDC write corrupts the user's disk image, so this one is not
// negotiable.
fdc fdc
(
   .clk(clk),
   .reset(reset),
   .clk_en(clk_en_cpu),
   .cs(device == DEVICE_FDC),
   .addr(cpu_addr[13:0]),
   .d_from_cpu(cpu_dout),
   .d_to_cpu(d_to_cpu_FDC),
   .output_en(FDC_req),
   .rd(cpu_rd & cpu_mreq),
   .wr(cpu_wr & cpu_mreq),
   .img_mounted(img_mounted),
   .img_size(img_size),
   .img_readonly(img_readonly),
   
   .sd_lba(sd_lba),
   .sd_rd(sd_rd),
   .sd_wr(sd_wr),
   .sd_ack(sd_ack),
   .sd_buff_addr(sd_buff_addr[8:0]),
   .sd_buff_dout(sd_buff_dout),
   .sd_buff_din(sd_buff_din),
   .sd_buff_wr(sd_buff_wr)
);

endmodule
