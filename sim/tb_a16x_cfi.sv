// tb_a16x_cfi — cart_ascii16x + flash.sv together, wired as msx_slots.sv wires them.
//
// What is FAITHFUL here and must stay.  openMSX RomAscii16X::writeMem passes
// EVERY cart-window write to flash.write() unconditionally -- the bank-register
// latch happens afterwards and does not suppress it, and there is no WREN gate:
//     void RomAscii16X::writeMem(uint16_t addr, byte value, EmuTime time) {
//         flash.write(getFlashAddr(addr), value, time);
//         if ((addr & 0x3FFF) >= 0x2000) { ... bankRegs[index] = ...; }
// So `ascii16x.sv:107  assign flash_rq = cs;` is correct, and an ordinary bank
// write of 0x98 to 0x60AA (segment 0x098 = 152) DOES legitimately open CFI -- on
// the real S29GL064 too, since A11 and up are don't-care in the unlock compare.
// C2/C3 below pin that: they fail if we ever "harden" it and become stricter
// than the part, which would also break the CFI probe GoFigure needs
// (flash.sv:33-40).  Yamanooto is different on purpose: it really does have WREN
// (yamanooto.sv:276-277), and openMSX gates it the same way.
//
// What is a DIVERGENCE and is fixed.  During a program, the data cycles must be
// consumed positionally, not re-decoded -- openMSX keeps its anchored cmd[]
// buffer while cmd.size() < cmdSeq.size()+numBytes, so a data byte that happens
// to be 0x98 on an aliased offset cannot enter CFI.  Ours used to, because
// flash.sv's CFI entry (flash.sv:110-113) is a SEPARATE if block with no
// sequence and no data-phase guard.  Entering CFI there is not a cosmetic bug:
// flash.sv:57 then asserts data_valid for every read in the window,
// msx_slots.sv:210 folds it into mem_unmaped, and the cart reads as 0x00 until
// something writes 0xF0 -- and flash.sv has no reset port, so an MSX reset does
// not clear it.  C4 pins that.
//
//   C1  baseline: a normal read of the cart window sees SDRAM, not flash
//   C2  a legitimate bank write of 0x98 at 0x60AA SHOULD open CFI (faithful)
//   C3  ... and the QRY signature must be readable (the probe GoFigure needs)
//   C4  a program-DATA byte of 0x98 must NOT open CFI (the divergence)
`timescale 1ns/1ps
`default_nettype none
module tb_a16x_cfi;
   logic clk = 0, reset = 1;
   logic [15:0] cpu_addr = 0;
   logic  [7:0] din = 0;
   logic cpu_mreq = 0, cpu_wr = 0, cpu_rd = 0;
   logic [24:0] rom_size = 25'(8*1024*1024);

   wire        a_unmaped, a_flash_rq, a_prog_we, a_prog_phase;
   wire [24:0] a_mem_addr;
   wire [22:0] a_flash_addr;

   cart_ascii16x a16x (
      .clk(clk), .reset(reset), .rom_size(rom_size),
      .cpu_addr(cpu_addr), .din(din), .cpu_mreq(cpu_mreq), .cpu_wr(cpu_wr),
      .cs(1'b1), .cart_num(1'b0),
      .mem_unmaped(a_unmaped), .mem_addr(a_mem_addr),
      .flash_addr(a_flash_addr), .flash_rq(a_flash_rq), .prog_we(a_prog_we), .prog_phase(a_prog_phase)
   );

   wire [7:0] fl_dout;
   wire       fl_dv, fl_req, dbg_erase;
   wire [26:0] fl_addr;
   wire  [7:0] fl_din;
   logic sdram_ready = 1, sdram_done = 0;

   flash fl (
      .clk(clk), .clk_sdram(clk),
      .addr(a_flash_addr), .din(din), .dout(fl_dout), .data_valid(fl_dv),
      .we(cpu_mreq & cpu_wr), .ce(a_flash_rq),
      .data_phase(a_prog_phase),  // msx_slots.sv: flash16x_prog_phase (edge-valid)
      .sdram_ready(sdram_ready), .sdram_done(sdram_done),
      .sdram_addr(fl_addr), .sdram_din(fl_din), .sdram_req(fl_req),
      .sdram_offset(27'h0),
      .amd_family(1'b1),          // msx_slots.sv:277 own_flash_rq -> 1 for ASCII16X
      .boot_sector(1'b1),
      .erase_limit(27'h800000),
      .debug_erase(dbg_erase)
   );

   always @(posedge clk) sdram_done <= fl_req;
   always #5 clk = ~clk;

   task automatic w(input [15:0] a, input [7:0] d);
      begin
         @(negedge clk); cpu_addr = a; din = d; cpu_mreq = 1; cpu_wr = 1; cpu_rd = 0;
         repeat (4) @(posedge clk);
         @(negedge clk); cpu_mreq = 0; cpu_wr = 0;
         repeat (6) @(posedge clk);
      end
   endtask

   // A read of the cart window: flash drives the bus only while data_valid.
   task automatic rd(input [15:0] a, output [7:0] v, output bit dv);
      begin
         @(negedge clk); cpu_addr = a; cpu_mreq = 1; cpu_rd = 1; cpu_wr = 0;
         repeat (3) @(posedge clk);
         v = fl_dout; dv = fl_dv;
         @(negedge clk); cpu_mreq = 0; cpu_rd = 0;
         repeat (3) @(posedge clk);
      end
   endtask

   logic [7:0] v; bit dv; int bad = 0;

   initial begin
      repeat (4) @(posedge clk); reset = 0; repeat (4) @(posedge clk);

      rd(16'h4100, v, dv);
      $display("C1 baseline      read 0x4100 -> dout=%02h data_valid=%0b", v, dv);
      if (dv) begin $display("   ** C1 FAIL: flash drives the bus with no command issued"); bad++; end

      $display("-- attack: LD (0x60AA),A  A=0x98  (ordinary ASCII16 bank write, segment 152) --");
      w(16'h60AA, 8'h98);

      rd(16'h4100, v, dv);
      $display("C2 after bank wr read 0x4100 -> dout=%02h data_valid=%0b   (CFI entry here is CORRECT)", v, dv);
      if (!dv) begin $display("   ** C2 FAIL: CFI did NOT open -- we are now stricter than the part"); bad++; end

      rd(16'h4020, v, dv);
      $display("C3 CFI signature read 0x4020 -> %02h (0x51='Q' expected)", v);
      if (v != 8'h51) begin $display("   ** C3 FAIL: CFI 'QRY' missing -- the probe GoFigure needs is broken"); bad++; end

      // leave CFI, then do a REAL ASCII16X byte-program whose data byte is 0x98
      // and whose target address aliases the CFI entry offset.  ascii16x.sv:62-63
      // put the unlock cycles at cpu_addr[11:1] == 0x555 / 0x2AA, so 0x4AAA/0x4555;
      // after the A0 the mapper is in S_PROG and asserts prog_we for the data write.
      w(16'h4000, 8'hF0);
      $display("-- attack2: AA/55/A0 then program data 0x98 at 0x40AA (prog_we asserted) --");
      w(16'h4AAA, 8'hAA);
      w(16'h4555, 8'h55);
      w(16'h4AAA, 8'hA0);
      w(16'h40AA, 8'h98);
      rd(16'h4100, v, dv);
      $display("C4 after data wr read 0x4100 -> dout=%02h data_valid=%0b", v, dv);
      if (dv) begin $display("   ** C4 FAIL: CFI entered from a plain data write"); bad++; end

      $display("");
      $display("tb_a16x_cfi: %0d checks failed", bad);
      if (bad != 0)
         $fatal(1, "FAIL: see the checks above");
      $display("PASS");
      $finish;
   end
endmodule
`default_nettype wire
