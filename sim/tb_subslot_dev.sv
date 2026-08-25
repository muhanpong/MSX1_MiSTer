// tb_subslot_dev -- the OSD "SLOT A/B sub-slot" device (expanded cart slot).
//
// A cart slot is turned into an expanded slot simply by emitting a config line
// whose subslot != 0: memory_upload sets cart_slot_expander_en itself (:306) and
// OR-accumulates cart_device[] across subslots (:537).  MFRSD has always used
// that path for all four of its subslots.  The new menu reuses it for subslot 1
// of a plain ROM cart, and ALL of the new decision logic lives in
// cart_confDecoder -- which is what this bench pins down.
//
// NEGCTL=1 forces subslot_dev to 0 (the pre-feature behaviour), so every check
// that expects a device in subslot 1 MUST fail.

`timescale 1ns/1ps

module tb_subslot_dev;

   import MSX::*;

   cart_typ_t   typ;
   mapper_typ_t selected_mapper, detected_mapper;
   logic  [7:0] selected_sram_size;
   logic  [1:0] subslot, subslot_dev, drive_dev;

   mapper_typ_t  mapper;
   device_typ_t  mem_device;
   data_ID_t     rom_id;
   logic  [7:0]  sram_size, ram_size, mode, param;
   dev_typ_t     device;

`ifdef NEGCTL
   assign subslot_dev = 2'd0;          // pre-feature: the menu does not exist
`else
   assign subslot_dev = drive_dev;
`endif

   cart_confDecoder dut (
      .typ(typ), .selected_mapper(selected_mapper), .detected_mapper(detected_mapper),
      .selected_sram_size(selected_sram_size), .subslot(subslot), .subslot_dev(subslot_dev),
      .mapper(mapper), .mem_device(mem_device), .rom_id(rom_id),
      .sram_size(sram_size), .ram_size(ram_size), .mode(mode), .param(param), .device(device)
   );

   int errors = 0;

   task automatic drive(input cart_typ_t t, input logic [1:0] ss, input logic [1:0] dev);
      begin
         typ = t; subslot = ss; drive_dev = dev;
         #1;
      end
   endtask

   task automatic expect_mapper(input string name, input mapper_typ_t want);
      begin
         if (mapper !== want) begin
            $display("FAIL %-34s mapper = %0d, expected %0d", name, mapper, want);
            errors++;
         end
      end
   endtask

   task automatic expect_rom(input string name, input data_ID_t want);
      begin
         if (rom_id !== want) begin
            $display("FAIL %-34s rom_id = %0d, expected %0d", name, rom_id, want);
            errors++;
         end
      end
   endtask

   task automatic expect_empty(input string name);
      begin
         // "empty" is what makes memory_upload skip the subslot: the FSM tests
         // (cart_mapper != MAPPER_UNUSED | cart_mem_device != DEVICE_NONE).
         if (mapper !== MAPPER_UNUSED || mem_device !== DEVICE_NONE) begin
            $display("FAIL %-34s expected empty, got mapper %0d / mem_device %0d",
                     name, mapper, mem_device);
            errors++;
         end
      end
   endtask

   initial begin
      selected_mapper    = MAPPER_ASCII8;   // a plain ROM cart with a fixed mapper
      detected_mapper    = MAPPER_KONAMI;
      selected_sram_size = 8'd0;

      // ---- subslot 0 is untouched by the feature -------------------------
      drive(CART_TYP_ROM, 2'd0, 2'd0);
      expect_mapper("ROM ss0 dev=None", MAPPER_ASCII8);
      expect_rom   ("ROM ss0 dev=None", ROM_ROM);
      drive(CART_TYP_ROM, 2'd0, 2'd1);
      expect_mapper("ROM ss0 dev=FM-PAC (ROM wins)", MAPPER_ASCII8);
      expect_rom   ("ROM ss0 dev=FM-PAC (ROM wins)", ROM_ROM);

      // ---- default stays NON-expanded ------------------------------------
      drive(CART_TYP_ROM, 2'd1, 2'd0);
      expect_empty("ROM ss1 dev=None");

      // ---- the feature itself --------------------------------------------
      drive(CART_TYP_ROM, 2'd1, 2'd1);
      expect_mapper("ROM ss1 dev=FM-PAC", MAPPER_FMPAC);
      expect_rom   ("ROM ss1 dev=FM-PAC", ROM_FMPAC);
      if (!(device & DEV_OPL3)) begin
         $display("FAIL ROM ss1 dev=FM-PAC did not raise DEV_OPL3"); errors++;
      end

      drive(CART_TYP_ROM, 2'd1, 2'd2);
      expect_mapper("ROM ss1 dev=GameMaster2", MAPPER_GM2);
      expect_rom   ("ROM ss1 dev=GameMaster2", ROM_GM2);
      if (sram_size !== 8'd8) begin
         $display("FAIL GameMaster2 sram_size = %0d, expected 8", sram_size); errors++;
      end

      // ---- the device lands in subslot 1 ONLY ----------------------------
      drive(CART_TYP_ROM, 2'd2, 2'd1);  expect_empty("ROM ss2 dev=FM-PAC");
      drive(CART_TYP_ROM, 2'd3, 2'd1);  expect_empty("ROM ss3 dev=FM-PAC");
      drive(CART_TYP_ROM, 2'd2, 2'd2);  expect_empty("ROM ss2 dev=GameMaster2");

      // ---- MFRSD owns its own subslots: must be untouched -----------------
      // This is the regression that would silently break a working cartridge.
      drive(CART_TYP_MFRSD, 2'd1, 2'd1);
      expect_mapper("MFRSD ss1 (dev must not win)", MAPPER_MFRSD1);
      drive(CART_TYP_MFRSD, 2'd2, 2'd2);
      expect_mapper("MFRSD ss2 (dev must not win)", MAPPER_MFRSD2);
      drive(CART_TYP_MFRSD, 2'd3, 2'd1);
      expect_mapper("MFRSD ss3 (dev must not win)", MAPPER_MFRSD3);

      // ---- other cart types never expand ---------------------------------
      drive(CART_TYP_SCC2,   2'd1, 2'd1);  expect_empty("SCC+ ss1 dev=FM-PAC");
      drive(CART_TYP_FM_PAC, 2'd1, 2'd1);  expect_empty("FM-PAC ss1 dev=FM-PAC");
      drive(CART_TYP_GM2,    2'd1, 2'd2);  expect_empty("GM2 ss1 dev=GameMaster2");
      drive(CART_TYP_EMPTY,  2'd1, 2'd1);  expect_empty("Empty ss1 dev=FM-PAC");

      if (errors == 0) begin
         $display("PASS: sub-slot device lands in subslot 1 of a ROM cart only");
         $finish;
      end else begin
         $display("FAILURES: %0d", errors);
         $fatal(1, "sub-slot device checks failed");
      end
   end

endmodule
