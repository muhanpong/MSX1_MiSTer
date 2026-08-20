// Yamanooto mapper testbench — spec conformance (docs/yamanooto_spec.md)
//
// Every stimulus is an ordinary Z80 memory access at a full 16-bit address.
// Reference: "Yamanooto Hardware Reference (public)" rev 15oct2024 + openMSX
// src/memory/Yamanooto.cc (master @2712dbd1c).
//
//   Y0  reset state: only ENAR writable, nothing readable
//   Y1  REGEN unlocks CFGR/OFFR read+write
//   Y2  OFFR arithmetic: segment = (OFFR*4 + SUBOFF) + written value, latched on bank write
//   Y3  OFFR alone must NOT move a bank until the mapper register is written
//   Y4  SCC visibility uses the RAW bank value (openMSX #1992 / the "512KB boundary" myth)
//   Y5  K4 mode: different bank decode, SCC disabled
//   Y6  MDIS blocks bank writes
//   Y7  ROMDIS hides the flash
//   Y8  WREN gates flash writes and freezes banking
//   Y9  SCC+ window, mode register at 0xBFFE/0xBFFF, RAM-mode hiding (deviation from openMSX)
//
// usage: sim/run_yamanooto.sh
`timescale 1ns/1ps

module tb_yamanooto;

reg clk = 0;
always #23.28 clk = ~clk;

reg         reset    = 1;
reg         cs       = 0;
reg         cart_num = 0;
reg         cpu_rd   = 0;
reg         cpu_wr   = 0;
reg         cpu_mreq = 0;
reg  [15:0] cpu_addr = 16'h0000;
reg  [7:0]  din      = 8'h00;

wire        mem_unmaped;
wire [24:0] mem_addr;
wire [7:0]  cart_dout;
wire        cart_dout_en;
wire        scc_req;
wire  [1:0] scc_mode;   // per cart: {B, A}
wire        flash_wr_en;

cart_yamanooto dut (
   .clk(clk), .reset(reset),
   .mem_size(25'h800000),                 // 8MB
   .cpu_addr(cpu_addr), .din(din),
   .cpu_mreq(cpu_mreq), .cpu_wr(cpu_wr), .cpu_rd(cpu_rd),
   .cs(cs), .cart_num(cart_num),
   .mem_unmaped(mem_unmaped), .mem_addr(mem_addr),
   .cart_dout(cart_dout), .cart_dout_en(cart_dout_en),
   .scc_req(scc_req), .scc_mode(scc_mode), .flash_wr_en(flash_wr_en)
);

integer n_pass = 0, n_fail = 0;
task check(input string name, input cond);
   begin
      if (cond) begin n_pass = n_pass + 1; $display("PASS: %0s", name); end
      else      begin n_fail = n_fail + 1; $display("FAIL: %0s", name); end
   end
endtask

// captured live during the access
reg        req_seen, unmap_seen, douten_seen;
reg [24:0] addr_seen;
reg [7:0]  dout_seen;

task wr(input [15:0] a, input [7:0] d);
   begin
      @(negedge clk);
      cpu_addr = a; din = d; cs = 1; cpu_mreq = 1; cpu_wr = 1;
      #1 req_seen = scc_req; unmap_seen = mem_unmaped; addr_seen = mem_addr;
      @(posedge clk);
      @(negedge clk);
      cs = 0; cpu_mreq = 0; cpu_wr = 0;
      @(posedge clk);
   end
endtask

task rd(input [15:0] a);
   begin
      @(negedge clk);
      cpu_addr = a; cs = 1; cpu_mreq = 1; cpu_rd = 1;
      #1 req_seen = scc_req; unmap_seen = mem_unmaped; addr_seen = mem_addr;
         douten_seen = cart_dout_en; dout_seen = cart_dout;
      @(posedge clk);
      @(negedge clk);
      cs = 0; cpu_mreq = 0; cpu_rd = 0;
      @(posedge clk);
   end
endtask

// read the flash segment currently mapped at a page base
task seg_of(input [15:0] page_base, output [9:0] seg);
   begin
      rd(page_base);
      seg = addr_seen[22:13];
   end
endtask

task do_reset;
   begin
      cs = 0; cpu_rd = 0; cpu_wr = 0; cpu_mreq = 0; cart_num = 0;
      reset = 1; repeat (4) @(posedge clk); @(negedge clk); reset = 0; repeat (2) @(posedge clk);
   end
endtask

// unlock: ENAR <- REGEN
task unlock; wr(16'h7FFF, 8'h01); endtask

reg [9:0] seg;
reg       o1, o2;

initial begin
   $display("=== tb_yamanooto ===");
   do_reset;

   // ============================================ Y0 reset state
   rd(16'h7FFD);
   check("Y0.1 CFGR not readable before REGEN", douten_seen == 1'b0 && dout_seen === 8'hFF);
   rd(16'h7FFF);
   check("Y0.2 ENAR not readable before REGEN", douten_seen == 1'b0);
   wr(16'h7FFD, 8'h08);                       // try to set K4 while locked
   rd(16'h7FFD);
   check("Y0.3 CFGR write ignored while locked", douten_seen == 1'b0);
   seg_of(16'h4000, seg);
   check("Y0.4 reset bank0 = segment 0", seg == 10'd0);
   seg_of(16'hA000, seg);
   check("Y0.5 reset bank3 = segment 3", seg == 10'd3);

   // ============================================ Y1 REGEN
   unlock;
   rd(16'h7FFF);
   check("Y1.1 ENAR readable after REGEN", douten_seen == 1'b1 && dout_seen == 8'h01);
   wr(16'h7FFE, 8'h5A);
   rd(16'h7FFE);
   check("Y1.2 OFFR R/W after REGEN", douten_seen == 1'b1 && dout_seen == 8'h5A);
   wr(16'h7FFD, 8'h00);
   rd(16'h7FFD);
   check("Y1.3 CFGR R/W after REGEN", douten_seen == 1'b1 && dout_seen == 8'h00);

   // ============================================ Y2 offset arithmetic
   // segment = (OFFR*4 + SUBOFF) + written value
   do_reset; unlock;
   wr(16'h7FFE, 8'd3);                        // OFFR = 3  -> +12 segments
   wr(16'h9000, 8'd5);                        // bank2 <- 5
   seg_of(16'h8000, seg);
   check("Y2.1 OFFR=3, bank<-5 => segment 17", seg == 10'd17);

   wr(16'h7FFD, 8'h20);                       // SUBOFF = 2 (CFGR bit5:4 = 10)
   wr(16'h9000, 8'd5);
   seg_of(16'h8000, seg);
   check("Y2.2 OFFR=3 SUBOFF=2, bank<-5 => segment 19", seg == 10'd19);

   wr(16'h7FFD, 8'h30);                       // SUBOFF = 3
   wr(16'h7FFE, 8'd255);                      // OFFR = 255 -> 1020
   wr(16'h9000, 8'd5);                        // 1020+3+5 = 1028 -> &0x3FF = 4
   seg_of(16'h8000, seg);
   check("Y2.3 wrap at 1024 segments (8MB)", seg == 10'd4);

   // ============================================ Y3 deferred latch
   do_reset; unlock;
   wr(16'h9000, 8'd7);                        // bank2 <- 7, offset still 0
   seg_of(16'h8000, seg);
   check("Y3.1 offset 0 => segment 7", seg == 10'd7);
   wr(16'h7FFE, 8'd10);                       // change OFFR only
   seg_of(16'h8000, seg);
   check("Y3.2 OFFR change alone does NOT move the bank", seg == 10'd7);
   wr(16'h9000, 8'd7);                        // now rewrite the mapper register
   seg_of(16'h8000, seg);
   check("Y3.3 re-writing the mapper applies the offset (7+40)", seg == 10'd47);

   // ============================================ Y4 SCC visibility uses RAW bank
   // This is the openMSX #1992 bug: with the offset-adjusted value the game's 0x3F
   // would only work when the offset is a multiple of 64 (= 512KB).
   do_reset; unlock;
   wr(16'h9000, 8'h3F);                       // enable SCC the normal way, offset 0
   rd(16'h9800);
   check("Y4.1 SCC window open at 0x9800 (offset 0)", req_seen == 1'b1);

   wr(16'h7FFE, 8'd1);                        // OFFR = 1 -> +4 segments, NOT a 512KB multiple
   wr(16'h9000, 8'h3F);                       // same raw value the game writes
   rd(16'h9800);
   check("Y4.2 SCC still open with a non-512KB-aligned offset", req_seen == 1'b1);
   seg_of(16'h8000, seg);
   check("Y4.2b ...while the bank really is offset (0x3F+4=67)", seg == 10'd67);

   wr(16'h9000, 8'h3E);                       // not 0x3F -> window must close
   rd(16'h9800);
   check("Y4.3 SCC closed when raw bank != 0x3F", req_seen == 1'b0);

   // ============================================ Y5 K4 mode
   do_reset; unlock;
   wr(16'h9000, 8'h3F);                       // SCC on in K5
   rd(16'h9800);
   check("Y5.1 K5: SCC on", req_seen == 1'b1);
   wr(16'h7FFD, 8'h08);                       // K4
   rd(16'h9800);
   check("Y5.2 K4: SCC disabled", req_seen == 1'b0);
   wr(16'h8000, 8'd9);                        // K4 bank decode: 0x8000-0x9FFF
   seg_of(16'h8000, seg);
   check("Y5.3 K4 bank write at 0x8000 works", seg == 10'd9);

   // ============================================ Y6 MDIS
   do_reset; unlock;
   wr(16'h9000, 8'd6);
   seg_of(16'h8000, seg);
   check("Y6.1 bank set to 6", seg == 10'd6);
   wr(16'h7FFD, 8'h01);                       // MDIS
   wr(16'h9000, 8'd9);                        // must be ignored
   seg_of(16'h8000, seg);
   check("Y6.2 MDIS blocks bank writes", seg == 10'd6);
   wr(16'h7FFD, 8'h00);
   wr(16'h9000, 8'd9);
   seg_of(16'h8000, seg);
   check("Y6.3 clearing MDIS restores banking", seg == 10'd9);

   // ============================================ Y7 ROMDIS
   do_reset; unlock;
   rd(16'h4000);
   check("Y7.1 flash visible by default", unmap_seen == 1'b0);
   wr(16'h7FFD, 8'h04);                       // ROMDIS
   rd(16'h4000);
   check("Y7.2 ROMDIS hides the flash", unmap_seen == 1'b1);
   wr(16'h7FFD, 8'h00);
   rd(16'h4000);
   check("Y7.3 clearing ROMDIS restores the flash", unmap_seen == 1'b0);

   // ============================================ Y8 WREN
   do_reset; unlock;
   check("Y8.1 WREN clear by default", flash_wr_en == 1'b0);
   wr(16'h6000, 8'hAA);                       // a plain write must not reach memory
   check("Y8.2 write blocked while WREN=0", unmap_seen == 1'b1);
   wr(16'h7FFF, 8'h11);                       // ENAR: WREN | REGEN
   check("Y8.3 WREN set", flash_wr_en == 1'b1);
   wr(16'h6000, 8'hAA);
   check("Y8.4 write reaches the flash while WREN=1", unmap_seen == 1'b0);
   wr(16'h9000, 8'd12);                       // banking is frozen while WREN=1
   seg_of(16'h8000, seg);
   check("Y8.5 WREN=1 freezes banking", seg == 10'd2);

   // ============================================ Y9 SCC+ / mode register / RAM mode
   do_reset; unlock;
   wr(16'hBFFE, 8'h20);                       // SCC+ mode
   check("Y9.1 mode register selects Plus", scc_mode[0] == 1'b1);
   wr(16'hB000, 8'h80);                       // bank3 bit7
   rd(16'hB800);
   check("Y9.2 SCC+ window open at 0xB800", req_seen == 1'b1);
   rd(16'hBFFE);
   check("Y9.3 0xBFFE excluded from the SCC+ window", req_seen == 1'b0);
   rd(16'h9800);
   check("Y9.4 SCC window closed in Plus mode", req_seen == 1'b0);

   wr(16'hBFFE, 8'h30);                       // Plus + RAM mode (bit4)
   rd(16'hB800);
   check("Y9.5 RAM mode hides the SCC+ window (yimmi9rc2 / bifi, openMSX #1964)",
         req_seen == 1'b0);
   wr(16'hBFFE, 8'h20);
   rd(16'hB800);
   check("Y9.6 clearing RAM mode restores the SCC+ window", req_seen == 1'b1);

   wr(16'hBFFF, 8'h00);                       // alias -> Compatible
   check("Y9.7 0xBFFF works as the mode-register alias", scc_mode[0] == 1'b0);

   // ---------------------------------------------------------------- Y10
   // REGEN=0 must leave the ROM visible at 0x7FFC-0x7FFF.  Only reg_rd (which is
   // REGEN-gated) may shadow the flash; the address-only reg_hit made these four
   // bytes read 0xFF and broke Vampire Killer's item pickup (INC (HL) @0x7FFC).
   $display("--- Y10 register window does not shadow the ROM while REGEN=0");
   wr(16'h7FFF, 8'h01);                 // REGEN on
   wr(16'h7FFE, 8'h00);                 // OFFR = 0
   wr(16'h7FFF, 8'h00);                 // REGEN off  <- the launcher's last act
   for (int a = 16'h7FFC; a <= 16'h7FFF; a++) begin
      rd(a[15:0]);
      check($sformatf("Y10.%0d 0x%04X reads as ROM, not a register", a-16'h7FFB, a),
            unmap_seen == 1'b0 && douten_seen == 1'b0);
   end
   // and with REGEN set they must go back to being registers
   wr(16'h7FFF, 8'h01);
   rd(16'h7FFF);
   check("Y10.5 REGEN=1 restores register readback", douten_seen == 1'b1);
   // ENAR must not advertise SPI/SD (bits 1,2) or the vendor's SD driver hangs
   wr(16'h7FFF, 8'h07);                 // REGEN | SPIEN | MSTEN
   rd(16'h7FFF);
   check("Y10.6 ENAR readback masks SPIEN/MSTEN", (dout_seen & 8'h06) == 8'h00);
   check("Y10.7 ENAR readback keeps the implemented bits", (dout_seen & 8'h01) == 8'h01);
   wr(16'h7FFF, 8'h81);                 // bit7 is used by real launchers
   rd(16'h7FFF);
   check("Y10.8 ENAR readback preserves bit7", dout_seen[7] == 1'b1);
   wr(16'h7FFF, 8'h00);

   $display("RESULT: %0d passed, %0d failed", n_pass, n_fail);
   $finish;
end

endmodule
