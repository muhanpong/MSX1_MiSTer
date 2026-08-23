// tb_yamanooto_savetest — run tools/yamanooto_savetest.s's exact sequence
// against the real cart_yamanooto + flash, with a memory model behind them.
//
// The point is to know what the cart SHOULD show before it is put on hardware.
// If this fails, the cart's expectations are wrong (or the RTL is) -- either way
// that is much cheaper to find here than by staring at a border colour.
//
// The five checks mirror the cart one for one:
//   T1  erase -> 0xFF
//   T2  byte program -> reads back
//   T3  the same program with WREN CLEAR must do nothing
//   T4  OFFR must still work normally
//   T5  OFFR must be IGNORED while SPIEN is set (the guard)
//   T6  an erase below 0x10000 clears ONE 8KB sector, neighbour survives
//
// Reads are modelled the way msx_slots does it: the flash supplies the byte
// while data_valid is high (status / id / erase-busy), otherwise it comes from
// memory at the mapper's address.
//
// Negative control (NEGCTL=1) strips the OFFR guard, so T5 must fail.
`timescale 1ns/1ps
`default_nettype none

module tb_yamanooto_savetest;

   localparam [7:0]  SCRATCH = 8'd128;        // segment -> flash 0x100000
   localparam [15:0] ENAR    = 16'h7FFF;
   localparam [15:0] OFFR    = 16'h7FFE;
   localparam [15:0] BANK0   = 16'h5000;
   localparam [15:0] UNLK_A  = 16'h4AAA;
   localparam [15:0] UNLK_B  = 16'h4555;
   localparam [15:0] TARGET  = 16'h4000;

   logic clk = 0, reset = 1;
   logic [15:0] cpu_addr = 0;
   logic  [7:0] din = 0;
   logic cpu_mreq = 0, cpu_wr = 0, cpu_rd = 0, cs = 1, cart_num = 0;
   logic [24:0] mem_size = 25'(8*1024*1024);

   wire mem_unmaped, cart_dout_en, scc_req, flash_wr_en, y_rq, prog_we;
   wire [24:0] mem_addr;  wire [7:0] cart_dout;  wire [1:0] scc_mode;
   wire [22:0] y_addr;

   cart_yamanooto dut(
      .clk(clk), .reset(reset), .mem_size(mem_size), .cpu_addr(cpu_addr),
      .din(din), .cpu_mreq(cpu_mreq), .cpu_wr(cpu_wr), .cpu_rd(cpu_rd),
      .cs(cs), .cart_num(cart_num), .mem_unmaped(mem_unmaped),
      .mem_addr(mem_addr), .cart_dout(cart_dout), .cart_dout_en(cart_dout_en),
      .scc_req(scc_req), .scc_mode(scc_mode), .flash_wr_en(flash_wr_en),
      .flash_addr(y_addr), .flash_rq(y_rq), .prog_we(prog_we));

   wire [7:0]  fl_dout;  wire fl_dv;  wire dbg_erase;
   logic sdram_ready = 1, sdram_done = 0;
   wire [26:0] fl_addr;  wire [7:0] fl_din;  wire fl_req;

   flash fl(
      .clk(clk), .clk_sdram(clk), .addr(23'(y_addr)), .din(din), .dout(fl_dout),
      .data_valid(fl_dv), .we(cpu_mreq & cpu_wr), .ce(y_rq),
      .sdram_ready(sdram_ready), .sdram_done(sdram_done),
      .sdram_addr(fl_addr), .sdram_din(fl_din), .sdram_req(fl_req),
      .sdram_offset(27'd0), .amd_family(1'b1), .boot_sector(1'b1),
      .erase_limit(27'h800000), .debug_erase(dbg_erase));

   always #5 clk = ~clk;
   always @(posedge clk) sdram_done <= fl_req;

   // ---- memory behind the cart.  2MB covers the 0x100000 scratch. ----
   logic [7:0] mem [0:2*1024*1024-1];
   initial for (int i = 0; i < 2*1024*1024; i++) mem[i] = 8'h00;   // NOT 0xFF:
   // starting at 0x00 means T1 only passes if the erase really wrote 0xFF.

   // flash.sv's own 0xFF fill during erase
   always @(posedge clk)
      if (fl_req & sdram_done & (fl_addr < 2*1024*1024)) mem[fl_addr] <= fl_din;
   // the mapper's program write (prog_we forces the SDRAM write in msx_slots)
   always @(posedge clk)
      if (prog_we & (mem_addr < 2*1024*1024)) mem[mem_addr] <= din;

   task automatic w(input [15:0] a, input [7:0] d);
      begin @(negedge clk); cpu_addr=a; din=d; cpu_mreq=1; cpu_wr=1; cpu_rd=0;
            repeat(3) @(posedge clk);
            @(negedge clk); cpu_mreq=0; cpu_wr=0; repeat(2) @(posedge clk); end
   endtask

   task automatic r(input [15:0] a, output [7:0] v);
      begin @(negedge clk); cpu_addr=a; cpu_mreq=1; cpu_rd=1; cpu_wr=0;
            repeat(2) @(posedge clk);
            v = fl_dv ? fl_dout : mem[mem_addr];      // exactly msx_slots' choice
            @(negedge clk); cpu_mreq=0; cpu_rd=0; repeat(2) @(posedge clk); end
   endtask

   int errors = 0;
   task automatic chk(input string n, input bit c);
      begin if (c) $display("  ok  : %s", n);
            else begin $display("  FAIL: %s", n); errors++; end end
   endtask

   task automatic erase_here();
      begin
         w(ENAR, 8'h10);
         w(UNLK_A, 8'hAA); w(UNLK_B, 8'h55); w(UNLK_A, 8'h80);
         w(UNLK_A, 8'hAA); w(UNLK_B, 8'h55); w(TARGET, 8'h30);
         w(ENAR, 8'h00);
         begin automatic int g = 0;
            while (dbg_erase && g < 400000) begin @(posedge clk); g++; end
         end
      end
   endtask

   task automatic prog_at(input [7:0] d);
      begin
         w(ENAR, 8'h10);
         w(UNLK_A, 8'hAA); w(UNLK_B, 8'h55); w(UNLK_A, 8'hA0); w(TARGET, d);
         w(ENAR, 8'h00);
      end
   endtask

   logic [7:0] v;  int guard;
   initial begin
      repeat(4) @(posedge clk); reset = 0; repeat(4) @(posedge clk);

      w(ENAR, 8'h00);
      w(BANK0, SCRATCH);

      // ---- T1 erase ----------------------------------------------------
      w(ENAR, 8'h10);
      w(UNLK_A, 8'hAA); w(UNLK_B, 8'h55); w(UNLK_A, 8'h80);
      w(UNLK_A, 8'hAA); w(UNLK_B, 8'h55); w(TARGET, 8'h30);
      w(ENAR, 8'h00);
      guard = 0;
      while (dbg_erase && guard < 400000) begin @(posedge clk); guard++; end
      chk("T1 erase completed", guard < 400000);
      r(TARGET, v);
      chk($sformatf("T1 erased byte is 0xFF (got %02h)", v), v === 8'hFF);

      // ---- T2 byte program ---------------------------------------------
      w(ENAR, 8'h10);
      w(UNLK_A, 8'hAA); w(UNLK_B, 8'h55); w(UNLK_A, 8'hA0); w(TARGET, 8'hA5);
      w(ENAR, 8'h00);
      r(TARGET, v);
      chk($sformatf("T2 programmed byte reads back (got %02h)", v), v === 8'hA5);

      // ---- T3 program with WREN clear must do nothing -------------------
      w(ENAR, 8'h00);
      w(UNLK_A, 8'hAA); w(UNLK_B, 8'h55); w(UNLK_A, 8'hA0); w(TARGET, 8'h5A);
      r(TARGET, v);
      chk($sformatf("T3 WREN clear blocks the program (got %02h)", v), v === 8'hA5);

      // ---- T4 OFFR must work --------------------------------------------
      w(ENAR, 8'h01);            // REGEN
      w(OFFR, 8'h01);
      w(ENAR, 8'h00);
      w(BANK0, SCRATCH);         // bankReg is stored offset-ADJUSTED, so the
                                 // offset only lands on a bank write
      r(TARGET, v);
      chk($sformatf("T4 OFFR moved the window (got %02h)", v), v !== 8'hA5);

      // ---- T5 OFFR must be ignored with SPIEN set ------------------------
      w(ENAR, 8'h03);            // REGEN | SPIEN
      w(OFFR, 8'h00);            // would restore the offset if it got through
      w(ENAR, 8'h00);
      w(BANK0, SCRATCH);
      r(TARGET, v);
      chk($sformatf("T5 SPIEN blocks the OFFR write (got %02h)", v), v !== 8'hA5);

      // ---- T6 low-64KB erase must clear ONE 8KB sector -------------------
      // Segments 4 and 5 (flash 0x8000 / 0xA000) are adjacent 8KB sectors inside
      // the low 64KB and clear of the 32KB ROM at segments 0-3.  This is the
      // path boot_sector(1'b1) actually changed for Yamanooto, and it persists;
      // T1-T5 all work at 0x100000 and cannot see it.
      w(ENAR, 8'h01); w(OFFR, 8'h00); w(ENAR, 8'h00);   // offset back to 0
      w(BANK0, 8'd4);  erase_here();
      w(BANK0, 8'd5);  erase_here();
      w(BANK0, 8'd4);  prog_at(8'h5A);
      w(BANK0, 8'd5);  prog_at(8'h3C);
      w(BANK0, 8'd4);  erase_here();
      r(TARGET, v);
      chk($sformatf("T6 target sector erased (got %02h)", v), v === 8'hFF);
      w(BANK0, 8'd5);
      r(TARGET, v);
      chk($sformatf("T6 neighbour sector survived (got %02h)", v), v === 8'h3C);

      $display("");
      $display("tb_yamanooto_savetest: %0d failures", errors);
`ifdef NEGCTL
      if (errors == 0)
         $fatal(1, "NEGCTL BROKEN: OFFR guard removed and nothing failed.");
      $display("negative control OK: %0d failed as required", errors);
      $finish;
`else
      if (errors)
         $fatal(1, "tb_yamanooto_savetest: %0d FAILED -- the cart would NOT show green", errors);
      $display("the cart should show BORDER = 3 (light green) on hardware");
      $finish;
`endif
   end
endmodule
`default_nettype wire
