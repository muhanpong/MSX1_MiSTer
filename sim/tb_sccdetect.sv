// SCC / SCC+ *detection* testbench  (docs/sccplus_spec.md, S3b)
//
// Complements tb_sccplus.sv.  That TB drives sccPlusChip/sccPlusMode directly
// and therefore proves nothing about how a cartridge is *detected*; this one
// puts the real mapper in the loop:
//
//        CPU bus  ->  cart_konami_scc  ->  scc_req / scc_mode  ->  scc_sound
//
// so every stimulus is an ordinary Z80 memory write at a full 16-bit address,
// exactly like a game or a music replayer would issue.
//
// Reference: openMSX src/sound/MSXSCCPlusCart.cc (the <SCCplus> device used by
// share/extensions/{scc+,Konami_SD-Snatcher_Sound_Cartridge}.xml):
//
//   void MSXSCCPlusCart::checkEnable() {
//       if      ( (modeRegister & 0x20) && (mapper[3] & 0x80))        enable = EN_SCCPLUS;
//       else if (!(modeRegister & 0x20) && ((mapper[2] & 0x3F)==0x3F)) enable = EN_SCC;
//       else                                                          enable = EN_NONE;
//   }
//   mode register at 0xBFFE / 0xBFFF;  bank regs at 0x5000/0x7000/0x9000/0xB000
//   SCC window 0x9800-0x9FFF, SCC+ window 0xB800-0xBFFF, offset = addr & 0xFF
//   SCC::Mode::Compatible is the *constructed* (reset) mode of every SCC-I cart.
//
// Scenarios
//   D0  plain SCC cart   (sccDevice=0): window gating, 2 KB mirroring,
//                                       0xBFFE must be inert (no SCC+ on an SCC chip)
//   D1  SCC+ cart, reset state = Compatible: ch5 is a ch4 mirror (read + playback),
//                                       writes to 0xA0-0xBF ignored
//   D2  -> Plus: mode bit5 alone puts the CHIP in Plus (ch5 independent);
//                       bank3 bit7 is what opens the 0xB800 WINDOW.  Two separate
//                       things -- openMSX :621 vs :503.  Was conflated; see D5x.
//   D3  mode-register alias 0xBFFF; EN_NONE when mode=Plus but bank3 bit7 cleared
//                       -- windows shut, but the CHIP stays Plus
//   D4  -> back to Compatible and again to Plus: private ch5 RAM survives the round trip
//
// usage: sim/run_sccdetect.sh    (or: iverilog -g2012 -o x sim/tb_sccdetect.sv \
//          rtl/peripheral/slots/konami_scc.sv rtl/peripheral/slots/scc_sound.sv \
//          rtl/IKASCC/src/IKASCC_modules/IKASCC_player_s.v \
//          rtl/IKASCC/src/IKASCC_modules/IKASCC_primitives.v && vvp -n x)
`timescale 1ns/1ps

module tb_sccdetect;

// ---------------------------------------------------------------- clocks
reg clk = 0;
always #23.28 clk = ~clk;                 // ~21.48 MHz
reg [2:0] ce_cnt = 0;
reg clk_en = 0;
always @(posedge clk) begin
   ce_cnt <= (ce_cnt == 3'd5) ? 3'd0 : ce_cnt + 3'd1;
   clk_en <= (ce_cnt == 3'd5);
end

// ---------------------------------------------------------------- bus
reg         reset     = 1;
reg         mapper_cs = 0;                // msx_slots: cs = (mapper == MAPPER_KONAMI_SCC)
reg         cart_num  = 0;
reg         cpu_rd    = 0;
reg         cpu_wr    = 0;
reg         cpu_mreq  = 0;
reg  [15:0] cpu_addr  = 16'h0000;
reg  [7:0]  din       = 8'h00;
reg         sccDevice = 0;                // 0 = CART_TYP_SCC, 1 = CART_TYP_SCC2 (DEV_SCC2)

// ---------------------------------------------------------------- mapper (detection under test)
wire        scc_req;
wire [1:0]  scc_mode;
wire        mem_unmaped;
wire [20:0] mem_addr;

cart_konami_scc u_map (
   .clk(clk), .reset(reset),
   .mem_size(25'd128 << 14),              // 2 MB, not exercised here
   .cpu_addr(cpu_addr), .din(din),
   .cpu_mreq(cpu_mreq), .cpu_wr(cpu_wr), .cpu_rd(cpu_rd),
   .cs(mapper_cs), .cart_num(cart_num), .subslot(2'd0),
   .sccDevice(sccDevice),
   .mem_unmaped(mem_unmaped), .mem_addr(mem_addr),
   .scc_req(scc_req), .scc_mode(scc_mode)
);

// ---------------------------------------------------------------- sound (wired as in msx_slots.sv)
wire [7:0]  scc_dout;
wire signed [15:0] wave;
wire        debug_scc_wr;
wire [1:0]  sccPlusChip = {1'b0, sccDevice};       // DEV_SCC2 of cart A only
wire [1:0]  oe          = 2'b01;                   // DEV_SCC | DEV_SCC2, cart A

scc_sound u_snd (
   .clk(clk), .clk_en(clk_en), .reset(reset),
   .cart_num(cart_num),
   .cs(scc_req),                                   // <- straight from the mapper
   .oe(oe),
   .cpu_rd(cpu_rd), .cpu_wr(cpu_wr), .cpu_mreq(cpu_mreq),
   .cpu_addr(cpu_addr), .din(din),
   .scc_dout(scc_dout), .wave(wave),
   .sccPlusChip(sccPlusChip), .sccPlusMode(scc_mode),
   .debug_scc_wr(debug_scc_wr)
);

// ---------------------------------------------------------------- bookkeeping
integer n_pass = 0, n_fail = 0;
task check(input string name, input cond);
   begin
      if (cond) begin n_pass = n_pass + 1; $display("PASS: %0s", name); end
      else      begin n_fail = n_fail + 1; $display("FAIL: %0s", name); end
   end
endtask

// ---------------------------------------------------------------- bus tasks (full 16-bit address)
task align;
   begin
      @(posedge clk); while (!clk_en) @(posedge clk);
      @(negedge clk);
   end
endtask

task idle(input integer n);
   repeat (n) @(posedge clk);
endtask

// captured during the access window, so it reflects the mapper's live decode
reg req_seen;
reg unmap_seen;

reg [7:0] tb_bank3 = 8'h00;   // bench shadow of the 0xB000 bank register
task wr(input [15:0] a, input [7:0] d);
   if (a[15:11] == 5'b10110) tb_bank3 = d;   // 0xB000-0xB7FF
   begin
      align;
      cpu_addr = a; din = d;
      mapper_cs = 1; cpu_mreq = 1; cpu_wr = 1;
      #1 req_seen = scc_req; unmap_seen = mem_unmaped;
      repeat (9) @(posedge clk);
      @(negedge clk);
      mapper_cs = 0; cpu_mreq = 0; cpu_wr = 0;
      idle(6);
   end
endtask

task rd(input [15:0] a, output [7:0] d);
   begin
      align;
      cpu_addr = a;
      mapper_cs = 1; cpu_mreq = 1; cpu_rd = 1;
      #1 req_seen = scc_req;
      repeat (8) @(posedge clk);
      #1 d = scc_dout;
      @(posedge clk);
      @(negedge clk);
      mapper_cs = 0; cpu_mreq = 0; cpu_rd = 0;
      idle(6);
   end
endtask

// is the SCC register window open at this address?  (asks the mapper, not the wrapper)
task probe(input [15:0] a, output open);
   reg [7:0] dummy;
   begin
      rd(a, dummy);
      open = req_seen;
   end
endtask

// ---------------------------------------------------------------- wave helpers
localparam P_CONST = 0, P_SAW = 1, P_RAMP = 3;
function [7:0] pat(input integer kind, input [7:0] arg, input integer i);
   case (kind)
      P_CONST: pat = arg;
      P_SAW:   pat = (i * 8) - 128;
      default: pat = arg + i * 4;                  // P_RAMP
   endcase
endfunction

// base = full address of the 32-byte block (e.g. 16'h9800, 16'hB880)
task write_wave(input [15:0] base, input integer kind, input [7:0] arg);
   integer i;
   for (i = 0; i < 32; i = i + 1) wr(base + i[15:0], pat(kind, arg, i));
endtask

task verify_block(input [15:0] base, input integer kind, input [7:0] arg, output integer bad);
   integer i; reg [7:0] d;
   begin
      bad = 0;
      for (i = 0; i < 32; i = i + 1) begin
         rd(base + i[15:0], d);
         if (d !== pat(kind, arg, i)) begin
            bad = bad + 1;
            if (bad <= 3) $display("   readback 0x%04X = 0x%02X, expected 0x%02X",
                                   base + i[15:0], d, pat(kind, arg, i));
         end
      end
   end
endtask

// rb = full address of the FREQ/VOL/EN block (0x9880 in SCC/Compat, 0xB8A0 in Plus)
task set_freq_vol(input [15:0] rb, input [11:0] f);
   integer c;
   begin
      for (c = 0; c < 5; c = c + 1) begin
         wr(rb + 16'h000A + c[15:0], 8'h0F);              // VOL = 15
         wr(rb + (c[15:0] << 1),       f[7:0]);           // FREQ lo
         wr(rb + (c[15:0] << 1) + 16'd1, {4'h0, f[11:8]});
      end
   end
endtask

task set_en(input [15:0] rb, input [7:0] mask);
   wr(rb + 16'h000F, mask);
endtask

// Write the mode register, then check each 8 KB segment's write-enable against `expect_ram`
// (bit0 = 0x4000, bit1 = 0x6000, bit2 = 0x8000, bit3 = 0xA000).
// mem_unmaped == 1 on a write means the write is swallowed (segment is not RAM).
// mem_addr = {bank_base, cpu_addr[12:0]}, so a read at a page base exposes that page's bank
task bank_of(input [15:0] page_base, output [7:0] b);
   begin
      align;
      cpu_addr = page_base;
      mapper_cs = 1; cpu_mreq = 1; cpu_rd = 1;
      #1 b = mem_addr[20:13];
      repeat (4) @(posedge clk);
      @(negedge clk);
      mapper_cs = 0; cpu_mreq = 0; cpu_rd = 0;
      idle(4);
   end
endtask

task ram_check(input [7:0] mode, input [3:0] expect_ram, input string name);
   reg [3:0] got;
   reg [15:0] pg [0:3];
   integer k;
   begin
      pg[0] = 16'h4800; pg[1] = 16'h6800; pg[2] = 16'h8400; pg[3] = 16'hA800;
      wr(16'hBFFE, mode);
      for (k = 0; k < 4; k = k + 1) begin
         wr(pg[k], 8'h5A);
         got[k] = ~unmap_seen;                    // not unmapped -> the write lands = RAM
      end
      check(name, got === expect_ram);
      if (got !== expect_ram)
         $display("   expected RAM mask %04b, got %04b (bit0=0x4000 .. bit3=0xA000)",
                  expect_ram, got);
   end
endtask

// ---------------------------------------------------------------- wave measurement
integer m_min, m_max, m_nz;
task measure(input integer settle, input integer nsamp);
   integer i;
   begin
      repeat (settle) begin @(posedge clk); while (!clk_en) @(posedge clk); end
      m_min = 100000; m_max = -100000; m_nz = 0;
      for (i = 0; i < nsamp; i = i + 1) begin
         @(posedge clk); while (!clk_en) @(posedge clk);
         #1;
         if (wave < m_min) m_min = wave;
         if (wave > m_max) m_max = wave;
         if (wave != 0)    m_nz  = m_nz + 1;
      end
   end
endtask

localparam SETTLE = 3000, NSAMP = 4096;
localparam [11:0] FREQ = 12'h040;

task do_reset;
   begin
      mapper_cs = 0; cpu_rd = 0; cpu_wr = 0; cpu_mreq = 0; cart_num = 0;
      reset = 1; idle(60); @(negedge clk); reset = 0; idle(30);
   end
endtask

// ---------------------------------------------------------------- main
integer bad, bad2;
reg [7:0] d, bk;
reg o_scc, o_sccp;
integer ch4_lvl, ch5_lvl;

initial begin
   $display("=== tb_sccdetect ===");
   idle(10);

   // ==================================================== D0  plain SCC cartridge
   $display("--- D0 plain SCC cart (sccDevice=0, CART_TYP_SCC)");
   sccDevice = 0; do_reset;

   probe(16'h9800, o_scc);
   check("D0.1 reset: SCC window closed (bank2 != 0x3F)", o_scc == 1'b0);

   wr(16'h9000, 8'h3F);                      // SCC enable, openMSX: (mapper[2]&0x3F)==0x3F
   probe(16'h9800, o_scc);
   check("D0.2 bank2 <- 0x3F at 0x9000 opens SCC window", o_scc == 1'b1);
   check("D0.2b mode stays Real (scc_mode == 0)", scc_mode == 2'b00);

   write_wave(16'h9800, P_SAW, 0);
   verify_block(16'h9800, P_SAW, 0, bad);
   check("D0.3 ch1 wave R/W through 0x9800", bad == 0);

   // openMSX: SCC window is 0x9800-0x9FFF with offset = addr & 0xFF -> mirrors every 256 B
   verify_block(16'h9900, P_SAW, 0, bad);
   check("D0.4 0x9900 mirrors 0x9800 (2 KB window)", bad == 0);

   // an SCC chip has no mode register: 0xBFFE must not do anything
   wr(16'hBFFE, 8'h20);
   wr(16'hB000, 8'h80);
   check("D0.5 0xBFFE inert on plain SCC (scc_mode still 0)", scc_mode == 2'b00);
   probe(16'hB800, o_sccp);
   check("D0.5b 0xB800 stays closed on plain SCC", o_sccp == 1'b0);
   probe(16'h9800, o_scc);
   check("D0.5c 0x9800 still open on plain SCC", o_scc == 1'b1);

   wr(16'h9000, 8'h00);
   probe(16'h9800, o_scc);
   check("D0.6 bank2 <- 0x00 closes SCC window", o_scc == 1'b0);
   rd(16'h9800, d);
   check("D0.6b closed window reads 0xFF", d === 8'hFF);

   // ==================================================== D1  SCC+ cart, reset = Compatible
   $display("--- D1 SCC+ cart (sccDevice=1) reset state = Compatible");
   sccDevice = 1; do_reset;

   check("D1.1 reset mode == Compatible (scc_mode == 0)", scc_mode == 2'b00);
   probe(16'h9800, o_scc); probe(16'hB800, o_sccp);
   check("D1.1b both windows closed after reset", o_scc == 1'b0 && o_sccp == 1'b0);

   wr(16'h9000, 8'h3F);
   probe(16'h9800, o_scc);
   check("D1.2 SCC window opens at 0x9800 in Compatible", o_scc == 1'b1);

   write_wave(16'h9800, P_CONST, 8'h10);      // ch1
   write_wave(16'h9820, P_CONST, 8'h20);      // ch2
   write_wave(16'h9840, P_CONST, 8'h30);      // ch3
   write_wave(16'h9860, P_CONST, 8'h80);      // ch4 = -128
   bad = 0;
   verify_block(16'h9800, P_CONST, 8'h10, bad2); bad = bad + bad2;
   verify_block(16'h9860, P_CONST, 8'h80, bad2); bad = bad + bad2;
   check("D1.3 ch1-4 wave R/W at 0x9800-0x987F", bad == 0);

   // openMSX SCC::writeWave copies wave4 -> wave5 whenever mode != Plus,
   // and peekMem(Compatible) maps 0xA0-0xBF to readWave(4,..)
   verify_block(16'h98A0, P_CONST, 8'h80, bad);
   check("D1.4 0x98A0-0x98BF reads ch4 wave (ch5 is a ch4 mirror)", bad == 0);

   // openMSX writeMem(Compatible): "0xA0..0xBF : ignore write wave form 5"
   write_wave(16'h98A0, P_CONST, 8'h7F);
   verify_block(16'h9860, P_CONST, 8'h80, bad);
   check("D1.5 write to 0x98A0-0x98BF leaves ch4 untouched", bad == 0);
   verify_block(16'h98A0, P_CONST, 8'h80, bad);
   check("D1.5b write to 0x98A0-0x98BF ignored (still reads ch4)", bad == 0);

   set_freq_vol(16'h9880, FREQ);
   set_en(16'h9880, 8'h08);  measure(SETTLE, NSAMP);      // ch4 solo
   ch4_lvl = m_max;
   check("D1.6 ch4 solo (-128) plays negative", m_nz == NSAMP && m_max < 0);
   set_en(16'h9880, 8'h10);  measure(SETTLE, NSAMP);      // ch5 solo
   ch5_lvl = m_max;
   check("D1.6b ch5 solo mirrors ch4 -> also negative", m_nz == NSAMP && m_max < 0);
   check("D1.6c ch5 level == ch4 level", ch5_lvl == ch4_lvl);
   set_en(16'h9880, 8'h00);

   // ==================================================== D2  switch to Plus
   $display("--- D2 Compatible -> Plus (0xBFFE bit5 + bank3 bit7)");

   wr(16'hBFFE, 8'h20);                       // mode bit5 only
   // openMSX MegaFlashRomSCCPlusSD.cc:621 -- setMode looks at bit5 and nothing else.
   // This assertion used to demand scc_mode == 0 here, which pinned the D5 defect.
   check("D2.1 mode bit5 alone puts the CHIP in Plus", scc_mode == 2'b01);
   probe(16'h9800, o_scc); probe(16'hB800, o_sccp);
   check("D2.1b EN_NONE: both windows closed", o_scc == 1'b0 && o_sccp == 1'b0);

   wr(16'hB000, 8'h80);                       // bank3 bit7 -> opens the window
   check("D2.2 chip still Plus after bank3 bit7", scc_mode == 2'b01);
   probe(16'hB800, o_sccp);
   check("D2.2b SCC+ window open at 0xB800", o_sccp == 1'b1);
   probe(16'h9800, o_scc);
   check("D2.3 0x9800 window closed in Plus mode", o_scc == 1'b0);
   rd(16'h9800, d);
   check("D2.3b 0x9800 reads 0xFF in Plus mode", d === 8'hFF);

   // Plus: waves 1..5 at 0x00-0x9F, FREQ/VOL/EN at 0xA0-0xBF
   write_wave(16'hB860, P_CONST, 8'h80);      // ch4 = -128
   write_wave(16'hB880, P_CONST, 8'h7F);      // ch5 = +127, private RAM
   bad = 0;
   verify_block(16'hB880, P_CONST, 8'h7F, bad2); bad = bad + bad2;
   verify_block(16'hB860, P_CONST, 8'h80, bad2); bad = bad + bad2;
   check("D2.4 ch4/ch5 independent R/W at 0xB860 / 0xB880", bad == 0);

   set_freq_vol(16'hB8A0, FREQ);
   set_en(16'hB8A0, 8'h08); measure(SETTLE, NSAMP);
   check("D2.5 Plus ch4 solo (-128) negative", m_nz == NSAMP && m_max < 0);
   set_en(16'hB8A0, 8'h10); measure(SETTLE, NSAMP);
   check("D2.6 Plus ch5 solo (+127) positive -> independent of ch4", m_nz == NSAMP && m_min > 0);

   // ---- D5x  paging a non-bit7 bank must NOT change the chip mode -------------
   // The symptom D5 describes: in Plus, with ch5 playing its own waveform, the
   // program pages a bank without bit7 into 0xA000-0xBFFF.  That closes the SCC+
   // WINDOW (correct) but must leave the CHIP in Plus.  With the old formula the
   // chip fell back to Compatible and ch5 latched ch4's waveform
   // (IKASCC_player_s.v:309) -- audible as ch5 suddenly sounding like ch4.
   // Enable ch5 BEFORE closing the window: once it is shut the registers at
   // 0xB8A0 are unreachable, which is exactly the situation being modelled.
   set_en(16'hB8A0, 8'h10);                   // ch5 solo (+127, its private RAM)
   wr(16'hB000, 8'h00);                       // bank3 bit7 cleared -> window closed
   check("D5x.1 chip stays Plus with the window closed", scc_mode == 2'b01);
   // negative control, in the bench: the OLD formula (mode AND bank3 bit7) would
   // read Compatible right here, so this case genuinely discriminates.
   check("D5x.2 the old mode formula would have read Compatible (control)",
         (scc_mode & {2{tb_bank3[7]}}) == 2'b00);
   probe(16'hB800, o_sccp); probe(16'h9800, o_scc);
   check("D5x.3 both windows shut (mapper side unchanged)", o_sccp == 1'b0 && o_scc == 1'b0);
   measure(SETTLE, NSAMP);
   check("D5x.4 ch5 still plays its OWN waveform (+127), not a ch4 mirror",
         m_nz == NSAMP && m_min > 0);
   wr(16'hB000, 8'h80);                       // restore the window for D3
   set_en(16'hB8A0, 8'h00);

   // ==================================================== D3  alias + EN_NONE
   $display("--- D3 mode register alias 0xBFFF, EN_NONE when bank3 bit7 cleared");

   wr(16'hB000, 8'h00);                       // clear bank3 bit7, mode still Plus
   // The mapper closes its window; the SOUND CHIP is untouched (openMSX :503 vs :621).
   check("D3.1 bank3 bit7 cleared -> CHIP stays Plus", scc_mode == 2'b01);
   probe(16'h9800, o_scc); probe(16'hB800, o_sccp);
   check("D3.1b EN_NONE (mode=Plus, bank3 bit7=0): both windows closed",
         o_scc == 1'b0 && o_sccp == 1'b0);

   wr(16'hBFFF, 8'h00);                       // mode register alias -> Compatible
   probe(16'h9800, o_scc);
   check("D3.2 0xBFFF works as mode-register alias (0x9800 open again)", o_scc == 1'b1);
   check("D3.2b scc_mode == 0 (Compatible)", scc_mode == 2'b00);

   wr(16'hBFFD, 8'h20);                       // NOT the mode register
   check("D3.3 0xBFFD is not the mode register (still Compatible)", scc_mode == 2'b00);
   probe(16'h9800, o_scc);
   check("D3.3b 0x9800 still open after 0xBFFD write", o_scc == 1'b1);

   // ==================================================== D4  round trip
   $display("--- D4 Plus -> Compatible -> Plus, private ch5 RAM survives");

   // currently Compatible: ch4 was left at -128 by D2, ch5 must mirror it again
   verify_block(16'h98A0, P_CONST, 8'h80, bad);
   check("D4.1 back in Compatible: 0x98A0 reads ch4 mirror, not the private ch5 RAM", bad == 0);
   set_freq_vol(16'h9880, FREQ);
   set_en(16'h9880, 8'h10); measure(SETTLE, NSAMP);
   check("D4.1b Compatible ch5 solo negative again (mirror restored)", m_nz == NSAMP && m_max < 0);
   set_en(16'h9880, 8'h00);

   wr(16'hBFFE, 8'h20); wr(16'hB000, 8'h80);  // -> Plus again
   check("D4.2 Plus re-entered (scc_mode == 1)", scc_mode == 2'b01);
   verify_block(16'hB880, P_CONST, 8'h7F, bad);
   check("D4.3 private ch5 RAM preserved across the round trip", bad == 0);
   set_freq_vol(16'hB8A0, FREQ);
   set_en(16'hB8A0, 8'h10); measure(SETTLE, NSAMP);
   check("D4.3b Plus ch5 solo positive again", m_nz == NSAMP && m_min > 0);
   set_en(16'hB8A0, 8'h00);

   // ==================================================== D5  mode-register RAM gating
   // Snatcher (1988) detects the Sound Cartridge by toggling the mode register between
   // 0x20 (SCC+ mode, RAM write-protected) and 0x30 (bit4 = every segment is RAM) and
   // checking that writes are respectively swallowed and honoured.  A core that leaves
   // the cartridge RAM permanently writable fails that probe and the game reports no
   // sound cartridge.  Reference: openMSX MSXSCCPlusCart::setModeRegister()
   //   mode & 0x10        -> isRamSegment[0..3] all true
   //   else  seg0 = mode&0x01,  seg1 = mode&0x02,
   //         seg2 = (mode&0x24)==0x24,  seg3 = false
   // A blocked write shows up as mem_unmaped = 1 (msx_slots.sv gates sdram_ce/bram_ce on it).
   $display("--- D5 mode-register RAM write gating (Snatcher 1988 probe)");
   sccDevice = 1; do_reset;

   ram_check(8'h00, 4'b0000, "mode 0x00: no segment is RAM");
   ram_check(8'h01, 4'b0001, "mode 0x01: seg0 (0x4000) RAM only");
   ram_check(8'h02, 4'b0010, "mode 0x02: seg1 (0x6000) RAM only");
   ram_check(8'h03, 4'b0011, "mode 0x03: seg0+seg1 RAM");
   ram_check(8'h20, 4'b0000, "mode 0x20: SCC+ mode, still no RAM (Snatcher write-protect phase)");
   ram_check(8'h24, 4'b0100, "mode 0x24: seg2 (0x8000) RAM needs bit5+bit2 together");
   ram_check(8'h04, 4'b0000, "mode 0x04: bit2 without bit5 does NOT make seg2 RAM");
   ram_check(8'h10, 4'b1111, "mode 0x10: bit4 makes every segment RAM");
   ram_check(8'h30, 4'b1111, "mode 0x30: SCC+ mode + all RAM (Snatcher writable phase)");
   ram_check(8'h3F, 4'b1111, "mode 0x3F: all RAM (SD-Snatcher driver restore value)");

   // ==================================================== D6  RAM mode must suppress bank writes
   // openMSX MSXSCCPlusCart::writeMem() has an explicit priority chain with early return:
   //     if ((address|1)==0xBFFF)  { setModeRegister(value); return; }
   //     if (isRamSegment[region]) { ...bank[region][addr&0x1FFF] = value; return; }   <-- return
   //     if ((address & 0x1800) == 0x1000) { setMapper(region, value); return; }
   // So while a segment is RAM, a store into that segment's 2 KB bank-register window is
   // plain data and must NOT reach the bank register.
   //
   // Snatcher (1988) depends on this.  Its loader (disk file offset 0xB1812):
   //     CALL 0C2EDh          ; mode <- 0x20  (RAM write-protected)
   //     LD A,C / LD (9000h),A;   -> goes to the bank register, as intended
   //     CALL 0C2FBh          ; mode <- 0x30  (every segment is RAM)
   //     LD BC,2000h / LD DE,8000h / CALL 0CC27h
   //                          ;   -> copies 8 KB across 0x8000-0x9FFF, crossing 0x9000-0x97FF
   // Under the correct semantics those crossing bytes are data.  If they also latch the bank
   // register, the 8 KB window slides out from under the CPU mid-copy and the cartridge-RAM
   // load is corrupted.
   $display("--- D6 RAM mode must suppress bank-register writes (Snatcher 1988 loader)");
   sccDevice = 1; do_reset;

   wr(16'hBFFE, 8'h20);                    // RAM write-protected
   wr(16'h9000, 8'h05);                    // bank2 <- 5   (intended bank switch)
   bank_of(16'h8000, bk);
   check("D6.1 mode 0x20: write to 0x9000 sets bank2", bk == 8'h05);

   wr(16'hBFFE, 8'h30);                    // every segment is RAM
   wr(16'h9000, 8'hAA);                    // data byte of the 8 KB copy
   bank_of(16'h8000, bk);
   check("D6.2 mode 0x30: write to 0x9000 is DATA, bank2 must stay 5", bk == 8'h05);
   if (bk !== 8'h05)
      $display("   bank2 was clobbered to 0x%02X - the 8 KB window moves mid-copy", bk);

   wr(16'hB000, 8'h55);                    // same for segment 3
   bank_of(16'hA000, bk);
   check("D6.3 mode 0x30: write to 0xB000 is DATA, bank3 must stay 3 (reset value)", bk == 8'h03);
   if (bk !== 8'h03)
      $display("   bank3 was clobbered to 0x%02X", bk);

   $display("RESULT: %0d passed, %0d failed", n_pass, n_fail);
   if (n_fail != 0) $display("SOME CHECKS FAILED");
   $finish;
end

// safety net
initial begin
   #400_000_000;
   $display("TIMEOUT");
   $display("RESULT: %0d passed, %0d failed", n_pass, n_fail + 1);
   $finish;
end

endmodule
