// tb_subslot_dev -- the OSD "SLOT A/B sub-slots" menu (expanded cart slots).
//
// A cart slot becomes an expanded slot simply by emitting a config line whose
// subslot != 0: memory_upload sets cart_slot_expander_en itself (:306) and
// OR-accumulates cart_device[] across subslots (:537).  MFRSD has always used
// that path for all four of its subslots.  The menu reuses it: with "SLOT x
// sub-slots: On" every subslot 0..3 carries the device the user chose.
//
// Two DUTs:
//   * cart_confDecoder  -- turns (expanded, sub_dev) into a config row; the
//     classic typ-driven rows must be untouched when not expanded.
//   * msx_config        -- the menu-side rules: per-slot On/Off, hide masks,
//     "one file consumer / one SRAM device per slot", GameMaster2 slot A only.
//
// NEGCTL=1 forces the decoder's `expanded` to 0 (pre-feature): every check that
// expects a sub-slot device MUST then fail, the classic checks must still pass.

`timescale 1ns/1ps

module tb_subslot_dev;

   import MSX::*;

   // ------------------------------------------------------------ DUT 1: decoder
   cart_typ_t    typ;
   mapper_typ_t  selected_mapper, detected_mapper;
   logic  [7:0]  selected_sram_size;
   logic  [1:0]  subslot;
   logic         expanded, dut_expanded;
   subslot_dev_t sub_dev;

   mapper_typ_t  mapper;
   device_typ_t  mem_device;
   data_ID_t     rom_id;
   logic  [7:0]  sram_size, ram_size, mode, param;
   dev_typ_t     device;

`ifdef NEGCTL
   assign dut_expanded = 1'b0;
`else
   assign dut_expanded = expanded;
`endif

   cart_confDecoder dut (
      .typ(typ), .selected_mapper(selected_mapper), .detected_mapper(detected_mapper),
      .selected_sram_size(selected_sram_size), .subslot(subslot),
      .expanded(dut_expanded), .sub_dev(sub_dev),
      .mapper(mapper), .mem_device(mem_device), .rom_id(rom_id),
      .sram_size(sram_size), .ram_size(ram_size), .mode(mode), .param(param), .device(device)
   );

   // ------------------------------------------------------------ DUT 2: msx_config
   logic                 cfg_clk = 0;
   logic         [127:0] hps_status = '0;
   MSX::bios_config_t    bios_config;
   MSX::config_cart_t    cart_conf[2];
   MSX::user_config_t    msxConfig_o;
   wire sram_A_hide_o, romA_hide_o, romB_hide_o, fdc_en_o, reload_o;
   wire clsA_hide_o, clsB_hide_o, pageA_hide_o, pageB_hide_o;

   always #5 cfg_clk = ~cfg_clk;

   msx_config cfg (
      .clk(cfg_clk), .reset(1'b0), .bios_config(bios_config),
      .HPS_status(hps_status), .scandoubler(1'b0), .sdram_size(2'd2),
      .rom_loaded(2'b11), .rom_big(2'b00),
      .cart_conf(cart_conf), .sram_A_select_hide(sram_A_hide_o),
      .slotA_classic_hide(clsA_hide_o), .slotB_classic_hide(clsB_hide_o),
      .subA_page_hide(pageA_hide_o), .subB_page_hide(pageB_hide_o),
      .ROM_A_load_hide(romA_hide_o), .ROM_B_load_hide(romB_hide_o),
      .fdc_enabled(fdc_en_o), .msxConfig(msxConfig_o), .reload(reload_o)
   );

   int errors = 0;

   // status bit helpers (must match rtl/msx_config.sv)
   task automatic set_subA(input int i, input logic [2:0] v);  hps_status[73 + 3*i +: 3] = v;  endtask
   task automatic set_subB(input int i, input logic [2:0] v);  hps_status[85 + 3*i +: 3] = v;  endtask

   task automatic drive(input cart_typ_t t, input logic ex, input logic [1:0] ss, input subslot_dev_t d);
      begin
         typ = t; expanded = ex; subslot = ss; sub_dev = d;
         #1;
      end
   endtask

   task automatic expect_row(input string name, input mapper_typ_t m, input data_ID_t r);
      begin
         if (mapper !== m || rom_id !== r) begin
            $display("FAIL %-40s mapper=%0d rom_id=%0d, expected %0d/%0d", name, mapper, rom_id, m, r);
            errors++;
         end
      end
   endtask

   task automatic expect_empty(input string name);
      begin
         if (mapper !== MAPPER_UNUSED || mem_device !== DEVICE_NONE) begin
            $display("FAIL %-40s expected empty, got mapper %0d / mem_device %0d", name, mapper, mem_device);
            errors++;
         end
      end
   endtask

   task automatic expect_devs(input string name, input logic slot_b,
                              input subslot_dev_t d0, d1, d2, d3);
      begin
         if (cart_conf[slot_b].subslot_dev[0] !== d0 || cart_conf[slot_b].subslot_dev[1] !== d1 ||
             cart_conf[slot_b].subslot_dev[2] !== d2 || cart_conf[slot_b].subslot_dev[3] !== d3) begin
            $display("FAIL %-40s got %0d,%0d,%0d,%0d expected %0d,%0d,%0d,%0d", name,
                     cart_conf[slot_b].subslot_dev[0], cart_conf[slot_b].subslot_dev[1],
                     cart_conf[slot_b].subslot_dev[2], cart_conf[slot_b].subslot_dev[3], d0, d1, d2, d3);
            errors++;
         end
      end
   endtask

   task automatic expect_bit(input string name, input logic got, input logic want);
      begin
         if (got !== want) begin $display("FAIL %-40s = %b, expected %b", name, got, want); errors++; end
      end
   endtask

   initial begin
      bios_config        = '{default:'0};
      selected_mapper    = MAPPER_ASCII8;
      detected_mapper    = MAPPER_KONAMI;
      selected_sram_size = 8'd4;

      // =================== decoder: classic (not expanded) is untouched ==========
      drive(CART_TYP_ROM,   1'b0, 2'd0, SUB_FMPAC);  expect_row("classic ROM ss0 (sub_dev ignored)", MAPPER_ASCII8, ROM_ROM);
      drive(CART_TYP_ROM,   1'b0, 2'd1, SUB_FMPAC);  expect_empty("classic ROM ss1 (sub_dev ignored)");
      drive(CART_TYP_SCC2,  1'b0, 2'd0, SUB_NONE);   expect_row("classic SCC+ ss0", MAPPER_KONAMI_SCC, ROM_RAM);
      drive(CART_TYP_MFRSD, 1'b0, 2'd1, SUB_NONE);   expect_row("classic MFRSD ss1", MAPPER_MFRSD1, ROM_NONE);
      drive(CART_TYP_MFRSD, 1'b0, 2'd2, SUB_NONE);   expect_row("classic MFRSD ss2", MAPPER_MFRSD2, ROM_RAM);
      drive(CART_TYP_MFRSD, 1'b0, 2'd3, SUB_NONE);   expect_row("classic MFRSD ss3", MAPPER_MFRSD3, ROM_NONE);

      // =================== decoder: expanded, every device in every subslot ======
      for (int ss = 0; ss < 4; ss++) begin
         drive(CART_TYP_ROM, 1'b1, ss[1:0], SUB_ROM);
         expect_row($sformatf("expanded ss%0d ROM", ss), MAPPER_ASCII8, ROM_ROM);
         if (sram_size !== 8'd4) begin $display("FAIL expanded ss%0d ROM sram_size %0d != 4", ss, sram_size); errors++; end
         drive(CART_TYP_ROM, 1'b1, ss[1:0], SUB_SCC);    expect_row($sformatf("expanded ss%0d SCC", ss),    MAPPER_KONAMI_SCC, ROM_ROM);
         drive(CART_TYP_ROM, 1'b1, ss[1:0], SUB_SCC2);   expect_row($sformatf("expanded ss%0d SCC+", ss),   MAPPER_KONAMI_SCC, ROM_RAM);
         if (ram_size !== 8'd8) begin $display("FAIL expanded ss%0d SCC+ ram_size %0d != 8", ss, ram_size); errors++; end
         drive(CART_TYP_ROM, 1'b1, ss[1:0], SUB_FMPAC);  expect_row($sformatf("expanded ss%0d FM-PAC", ss), MAPPER_FMPAC, ROM_FMPAC);
         if (!(device & DEV_OPL3)) begin $display("FAIL expanded ss%0d FM-PAC no DEV_OPL3", ss); errors++; end
         drive(CART_TYP_ROM, 1'b1, ss[1:0], SUB_GM2);    expect_row($sformatf("expanded ss%0d GM2", ss),    MAPPER_GM2, ROM_GM2);
         drive(CART_TYP_ROM, 1'b1, ss[1:0], SUB_NONE);   expect_empty($sformatf("expanded ss%0d None", ss));
      end

      // expanded IGNORES typ -- a stale MFRSD / FDC / SCC+ type must not leak in
      drive(CART_TYP_MFRSD, 1'b1, 2'd1, SUB_NONE);   expect_empty("expanded ignores stale typ=MFRSD ss1");
      drive(CART_TYP_MFRSD, 1'b1, 2'd0, SUB_FMPAC);  expect_row("expanded ignores stale typ=MFRSD ss0", MAPPER_FMPAC, ROM_FMPAC);
      drive(CART_TYP_SCC2,  1'b1, 2'd0, SUB_NONE);   expect_empty("expanded ignores stale typ=SCC+");
      drive(CART_TYP_FDC,   1'b1, 2'd0, SUB_ROM);    expect_row("expanded ignores stale typ=FDC", MAPPER_ASCII8, ROM_ROM);

      // Yamanooto is a mapper for the ROM, so it rides the ROM row
      selected_mapper = MAPPER_YAMANOOTO;
      drive(CART_TYP_ROM, 1'b1, 2'd2, SUB_ROM);      expect_row("expanded ss2 ROM w/ Yamanooto", MAPPER_YAMANOOTO, ROM_ROM);
      selected_mapper = MAPPER_ASCII8;

      // =================== msx_config: per-slot On/Off and hide masks ============
      hps_status = '0;                       // both slots = ROM type, both Off
      set_subA(0, SUB_ROM); set_subA(1, SUB_FMPAC); set_subA(2, SUB_SCC2); set_subA(3, SUB_NONE);
      set_subB(0, SUB_SCC2); set_subB(1, SUB_ROM);
      #1;
      expect_devs("A Off -> all None",   1'b0, SUB_NONE, SUB_NONE, SUB_NONE, SUB_NONE);
      expect_devs("B Off -> all None",   1'b1, SUB_NONE, SUB_NONE, SUB_NONE, SUB_NONE);
      expect_bit ("A Off: classic shown", clsA_hide_o, 1'b0);
      expect_bit ("A Off: page hidden",   pageA_hide_o, 1'b1);
      expect_bit ("A Off: ROM load shown (typ=ROM)", romA_hide_o, 1'b0);
      expect_bit ("expanded flag A off", cart_conf[0].expanded, 1'b0);

      hps_status[71] = 1'b1;                 // SLOT A sub-slots: On   (B stays Off)
      #1;
      expect_devs("A On -> pass through",  1'b0, SUB_ROM, SUB_FMPAC, SUB_SCC2, SUB_NONE);
      expect_devs("B still Off",           1'b1, SUB_NONE, SUB_NONE, SUB_NONE, SUB_NONE);
      expect_bit ("A On: classic hidden",  clsA_hide_o, 1'b1);
      expect_bit ("A On: page shown",      pageA_hide_o, 1'b0);
      expect_bit ("B: classic still shown", clsB_hide_o, 1'b0);
      expect_bit ("B: page still hidden",  pageB_hide_o, 1'b1);
      expect_bit ("A On: ROM load shown (ROM in ss0)", romA_hide_o, 1'b0);
      expect_bit ("expanded flag A on", cart_conf[0].expanded, 1'b1);

      hps_status[72] = 1'b1;                 // SLOT B sub-slots: On
      #1;
      expect_devs("B On -> pass through",  1'b1, SUB_SCC2, SUB_ROM, SUB_NONE, SUB_NONE);
      expect_bit ("B On: classic hidden",  clsB_hide_o, 1'b1);
      expect_bit ("B On: page shown",      pageB_hide_o, 1'b0);
      expect_bit ("B On: ROM load shown (ROM in ss1)", romB_hide_o, 1'b0);

      // =================== msx_config: conflict rules ===========================
      set_subA(0, SUB_ROM); set_subA(1, SUB_ROM); set_subA(2, SUB_SCC); set_subA(3, SUB_SCC2);
      #1;
      expect_devs("A: one file consumer (ROM,ROM,SCC,SCC+)", 1'b0, SUB_ROM, SUB_NONE, SUB_NONE, SUB_SCC2);

      set_subA(0, SUB_SCC); set_subA(1, SUB_ROM); set_subA(2, SUB_SCC2); set_subA(3, SUB_SCC2);
      #1;
      expect_devs("A: SCC first wins, two SCC+ allowed",     1'b0, SUB_SCC, SUB_NONE, SUB_SCC2, SUB_SCC2);
      expect_bit ("A: SCC counts as ROM file present", romA_hide_o, 1'b0);

      set_subA(0, SUB_FMPAC); set_subA(1, SUB_GM2); set_subA(2, SUB_NONE); set_subA(3, SUB_FMPAC);
      #1;
      expect_devs("A: one SRAM device (FM-PAC,GM2,-,FM-PAC)", 1'b0, SUB_FMPAC, SUB_NONE, SUB_NONE, SUB_NONE);
      expect_bit ("A: no ROM -> load hidden", romA_hide_o, 1'b1);
      expect_bit ("A: no ROM -> SRAM size hidden", sram_A_hide_o, 1'b1);

      set_subA(0, SUB_GM2); set_subA(1, SUB_NONE); set_subA(2, SUB_NONE); set_subA(3, SUB_NONE);
      #1;
      expect_devs("A: GM2 allowed on A", 1'b0, SUB_GM2, SUB_NONE, SUB_NONE, SUB_NONE);

      set_subB(0, SUB_GM2); set_subB(1, SUB_FMPAC); set_subB(2, 3'd6); set_subB(3, 3'd7);
      #1;
      expect_devs("B: GM2 clamped, FM-PAC ok, 6/7 -> None", 1'b1, SUB_NONE, SUB_FMPAC, SUB_NONE, SUB_NONE);
      expect_bit ("B: no ROM -> load hidden", romB_hide_o, 1'b1);

      // =================== msx_config: hidden classic type must not leak ========
      hps_status[19:17] = 3'(CART_TYP_FDC);     // stale classic type while A is expanded
      #1;
      expect_bit ("A expanded: stale FDC type does not enable FDC", fdc_en_o, 1'b0);
      hps_status[71] = 1'b0;
      #1;
      expect_bit ("A Off: classic FDC type enables FDC again", fdc_en_o, 1'b1);

      if (errors == 0) begin
         $display("PASS: expanded cart slots -- decoder rows, per-slot On/Off, menu rules");
         $finish;
      end else begin
         $display("FAILURES: %0d", errors);
         $fatal(1, "sub-slot checks failed");
      end
   end

endmodule
