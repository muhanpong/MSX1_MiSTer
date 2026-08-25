parameter CONF_STR_SLOT_A = {
    "H7H2O[19:17],SLOT A,ROM,SCC,SCC+,FM-PAC,MegaFlashROM SCC+ SD,GameMaster2,FDC,Empty;",
    "H7h2O[19:17],SLOT A,ROM,SCC,SCC+,FM-PAC,MegaFlashROM SCC+ SD,GameMaster2,Empty;"
};
parameter CONF_STR_SLOT_B = {
    "H8O[31:29],SLOT B,ROM,SCC,SCC+,FM-PAC,Empty;"
};
// ---- expanded cart slots -----------------------------------------------------
// "SLOT x sub-slots: On" turns that cart slot into an EXPANDED slot.  Its classic
// one-device line above is then hidden (H7 / H8) and a sub-menu page (P3 / P4,
// shown via H9 / HA) lets the user put a device in each of the four subslots.
// The machinery already existed -- MFRSD fills all four subslots of a cart slot
// the same way -- only the menu was missing.  Per-slot, independent.
//
// Slot B has no GameMaster2: cart_gamemaster2 keeps ONE global bank set
// (gamemaster2.sv:15, no cart_num port), so a second GM2 anywhere would alias it.
parameter CONF_STR_EXPAND_A = {
    "O[71],SLOT A sub-slots,Off,On;"
};
parameter CONF_STR_EXPAND_B = {
    "O[72],SLOT B sub-slots,Off,On;"
};
parameter CONF_STR_SUBSLOT_A = {
    "H9P3,SLOT A sub-slots;",
    "P3O[75:73],Sub-slot 0,None,ROM,SCC,SCC+,FM-PAC,GameMaster2;",
    "P3O[78:76],Sub-slot 1,None,ROM,SCC,SCC+,FM-PAC,GameMaster2;",
    "P3O[81:79],Sub-slot 2,None,ROM,SCC,SCC+,FM-PAC,GameMaster2;",
    "P3O[84:82],Sub-slot 3,None,ROM,SCC,SCC+,FM-PAC,GameMaster2;"
};
parameter CONF_STR_SUBSLOT_B = {
    "HAP4,SLOT B sub-slots;",
    "P4O[87:85],Sub-slot 0,None,ROM,SCC,SCC+,FM-PAC;",
    "P4O[90:88],Sub-slot 1,None,ROM,SCC,SCC+,FM-PAC;",
    "P4O[93:91],Sub-slot 2,None,ROM,SCC,SCC+,FM-PAC;",
    "P4O[96:94],Sub-slot 3,None,ROM,SCC,SCC+,FM-PAC;"
};
// Single "ASCII16X" entry covers both: ROM <= 4MB -> classic ASCII16 (SRAM etc.),
// ROM > 4MB -> ASCII16X flash mapper (8-bit-bank ASCII16 cannot exceed 4MB; per the
// ASCII16-X spec the X mapper is "mostly backwards compatible" for plain ROM banking).
parameter CONF_STR_MAPPER_A = {
    "H3O[23:20],Mapper type,auto,none,ASCII8,ASCII16X,Konami,KonamiSCC,KOEI,linear64,R-TYPE,WIZARDRY,Yamanooto;"
};
parameter CONF_STR_MAPPER_B = {
    "H4O[35:32],Mapper type,auto,none,ASCII8,ASCII16X,Konami,KonamiSCC,KOEI,linear64,R-TYPE,WIZARDRY,Yamanooto;"
};
parameter CONF_STR_SRAM_SIZE_A = {
    "H5O[28:26],SRAM size,auto,1kB,2kB,4kB,8kB,16kB,32kB,none;"
};

module msx_config
(
    input                     clk,
    input                     reset,
    input MSX::bios_config_t  bios_config,
    input             [127:0] HPS_status,
    input                     scandoubler,
    input               [1:0] sdram_size,
    input               [1:0] rom_loaded,
    input               [1:0] rom_big,     // ROM > 4MB per slot -> promote ASCII16X entry to the flash mapper
    output MSX::config_cart_t cart_conf[2],
    output                    sram_A_select_hide,   //5
    output                    slotA_classic_hide,   //7  expanded -> hide the one-device line
    output                    slotB_classic_hide,   //8
    output                    subA_page_hide,       //9  not expanded -> hide the sub-slot page
    output                    subB_page_hide,       //10 ('A' in CONF_STR)
    output                    ROM_A_load_hide,      //3
    output                    ROM_B_load_hide,      //4
    output                    fdc_enabled,
    output MSX::user_config_t msxConfig,
    output                    reload
);

wire [2:0] slot_A_select   = HPS_status[19:17];
wire [2:0] slot_B_select   = HPS_status[31:29];
wire [2:0] sram_A_select   = HPS_status[28:26];
wire [3:0] mapper_A_select = HPS_status[23:20];
wire [3:0] mapper_B_select = HPS_status[35:32];
wire       expanded_A      = HPS_status[71];
wire       expanded_B      = HPS_status[72];
logic [2:0] subA_raw[4], subB_raw[4];
assign subA_raw[0] = HPS_status[75:73];
assign subA_raw[1] = HPS_status[78:76];
assign subA_raw[2] = HPS_status[81:79];
assign subA_raw[3] = HPS_status[84:82];
assign subB_raw[0] = HPS_status[87:85];
assign subB_raw[1] = HPS_status[90:88];
assign subB_raw[2] = HPS_status[93:91];
assign subB_raw[3] = HPS_status[96:94];

cart_typ_t typ_A;
assign typ_A = cart_typ_t'(slot_A_select < CART_TYP_FDC  ? slot_A_select   :
                           bios_config.use_FDC           ? CART_TYP_EMPTY  :
                           slot_A_select == CART_TYP_FDC ? CART_TYP_FDC    :
                                                           CART_TYP_EMPTY );

assign cart_conf[0].typ                = typ_A;
assign cart_conf[1].typ                = slot_B_select < CART_TYP_MFRSD ? cart_typ_t'(slot_B_select) : CART_TYP_EMPTY;

// ---- sub-slot device selection, with the rules the RTL needs ---------------------
// Walk subslots 0..3; the FIRST occurrence wins, later conflicting ones become None:
//   * ROM and SCC both consume the slot's single ROM file -> at most one of them;
//   * FM-PAC and GameMaster2 both take lookup_SRAM index 1/2 of the slot
//     (memory_upload.sv:266) and FM-PAC has one instance per slot -> at most one;
//   * GameMaster2 is slot A only (see the CONF_STR note);
//   * codes 6/7 are unused -> None;
//   * the whole slot is None while it is not expanded.
// SCC+ may appear more than once: konami_scc keeps state per (slot, subslot).
subslot_dev_t subA[4], subB[4];
logic         fileA_used, fileB_used;
always_comb begin
   logic          sram_a, sram_b;
   subslot_dev_t  d;
   fileA_used = 1'b0; sram_a = 1'b0;
   fileB_used = 1'b0; sram_b = 1'b0;
   for (int i = 0; i < 4; i++) begin
      d = (subA_raw[i] > 3'd5) ? SUB_NONE : subslot_dev_t'(subA_raw[i]);
      if (!expanded_A) d = SUB_NONE;
      if (d == SUB_ROM   || d == SUB_SCC) begin if (fileA_used) d = SUB_NONE; else fileA_used = 1'b1; end
      if (d == SUB_FMPAC || d == SUB_GM2) begin if (sram_a)     d = SUB_NONE; else sram_a     = 1'b1; end
      subA[i] = d;

      d = (subB_raw[i] > 3'd4) ? SUB_NONE : subslot_dev_t'(subB_raw[i]);   // 5 = GM2: never on slot B
      if (!expanded_B) d = SUB_NONE;
      if (d == SUB_ROM   || d == SUB_SCC) begin if (fileB_used) d = SUB_NONE; else fileB_used = 1'b1; end
      if (d == SUB_FMPAC)                 begin if (sram_b)     d = SUB_NONE; else sram_b     = 1'b1; end
      subB[i] = d;
   end
end

assign cart_conf[0].expanded       = expanded_A;
assign cart_conf[1].expanded       = expanded_B;
assign cart_conf[0].subslot_dev[0] = subA[0];
assign cart_conf[0].subslot_dev[1] = subA[1];
assign cart_conf[0].subslot_dev[2] = subA[2];
assign cart_conf[0].subslot_dev[3] = subA[3];
assign cart_conf[1].subslot_dev[0] = subB[0];
assign cart_conf[1].subslot_dev[1] = subB[1];
assign cart_conf[1].subslot_dev[2] = subB[2];
assign cart_conf[1].subslot_dev[3] = subB[3];

// "this slot loads a ROM file": classic ROM type, or an expanded slot with a
// ROM / SCC subslot.  Drives the Load / Mapper / SRAM entries.
wire fileA_present = expanded_A ? fileA_used : typ_A == CART_TYP_ROM;
wire fileB_present = expanded_B ? fileB_used : cart_conf[1].typ == CART_TYP_ROM;

// 10-entry list maps uniformly +2 onto the enum (auto..WIZARDRY). The "ASCII16X"
// entry (index 3) resolves by ROM size: >4MB -> MAPPER_ASCII16X (flash), else
// classic MAPPER_ASCII16 (SRAM/banking as before).
assign cart_conf[0].selected_mapper    = rom_loaded[0] ? mapper_typ_t'(mapper_A_select == 4'd10                ? 5'(MAPPER_YAMANOOTO) :
                                                                     (mapper_A_select == 4'd3 & rom_big[0]) ? 5'(MAPPER_ASCII16X)  :
                                                                                               (mapper_A_select + 4'd2)) : MAPPER_UNUSED;
assign cart_conf[1].selected_mapper    = rom_loaded[1] ? mapper_typ_t'(mapper_B_select == 4'd10                ? 5'(MAPPER_YAMANOOTO) :
                                                                     (mapper_B_select == 4'd3 & rom_big[1]) ? 5'(MAPPER_ASCII16X)  :
                                                                                               (mapper_B_select + 4'd2)) : MAPPER_UNUSED;
assign cart_conf[0].selected_sram_size = fileA_present & mapper_A_select > 4'd1 & mapper_A_select != 4'd10 & ~(mapper_A_select == 4'd3 & rom_big[0]) & sram_A_select > 3'd0 & sram_A_select < 3'd7 ? (8'd1 << (sram_A_select - 1'd1)) : 8'd0;
// Slot B gets no SRAM.  Not an oversight: the firmware mounts exactly one
// <rom>.sav and always on VD0 (user_io.cpp:2937), so a second saveable cart has
// nowhere to go, and giving slot B a nonzero size makes memory_upload write
// lookup_SRAM[0] a second time -- aliasing slot A's SRAM onto slot B's buffer.
assign cart_conf[1].selected_sram_size = 8'd0;

assign msxConfig.typ = bios_config.MSX_typ;
assign msxConfig.scandoubler = scandoubler;
assign msxConfig.video_mode = video_mode_t'(bios_config.MSX_typ == MSX1 ? (HPS_status[12] ? 2'd2 : 2'd1) : HPS_status[14:13]);
assign msxConfig.cas_audio_src = cas_audio_src_t'(HPS_status[8]);
assign msxConfig.border = HPS_status[41];
assign msxConfig.vdp_id = HPS_status[42];
assign msxConfig.moonsound_en = HPS_status[45];

assign ROM_A_load_hide    = ~fileA_present;
assign ROM_B_load_hide    = ~fileB_present;
assign slotA_classic_hide = expanded_A;
assign slotB_classic_hide = expanded_B;
assign subA_page_hide     = ~expanded_A;
assign subB_page_hide     = ~expanded_B;
assign sram_A_select_hide = ~fileA_present | mapper_A_select == 4'd0 | mapper_A_select == 4'd10 | (mapper_A_select == 4'd3 & rom_big[0]);
// While slot A is expanded its (hidden) classic type must not leak: FDC is not a
// sub-slot device, so it cannot come from an expanded slot.
assign fdc_enabled = bios_config.use_FDC | (~expanded_A & cart_conf[0].typ == CART_TYP_FDC);


logic  [44:0] lastConfig;
wire [44:0] act_config = {cart_conf[1].typ, cart_conf[0].typ, cart_conf[0].selected_mapper, cart_conf[1].selected_mapper, sram_A_select,
                          expanded_A, expanded_B, subA[0], subA[1], subA[2], subA[3], subB[0], subB[1], subB[2], subB[3]};

always @(posedge clk) begin
    if (reload) lastConfig <= act_config;
end

assign reload = ~reset & lastConfig != act_config;

endmodule
