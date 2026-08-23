// Yamanooto (The SCC Alliance, 2023) — 8MB flash cartridge with SCC-I and PSG.
//
// Flat primary-slot cartridge: the real board has no subslot expander chip, so this is a
// single device.  The user loads a ROM image (typically the full 8MB flash dump) and this
// mapper banks it, exactly like the other ROM mappers.
//
// Spec: "Yamanooto Hardware Reference (public)" rev 15oct2024.  Audit + porting notes in
// docs/yamanooto_spec.md.  Reference implementation: openMSX src/memory/Yamanooto.cc
// (master @2712dbd1c; NOT release 21.0 — see docs/yamanooto_spec.md S5).
//
// Configuration registers live at the top of page 1 and are NOT mirrored:
//   0x7FFF ENAR  bit4 WREN (flash write enable), bit0 REGEN (unlock the other registers)
//   0x7FFE OFFR  8-bit mapper offset
//   0x7FFD CFGR  bit5:4 SUBOFF, bit3 K4, bit2 ROMDIS, bit1 ECHO, bit0 MDIS
//   0x7FFC       undefined in the spec (openMSX puts an FPGA channel here) -> not implemented
// After reset only ENAR is writable and no register is readable, until REGEN is set.
//
// Segment select latches at mapper-write time:   segment = (OFFR*4 + SUBOFF) + written value
// The offset register alone never moves a bank.  Bank registers are 10 bits (1024 x 8KB = 8MB).
//
// SCC visibility uses the RAW written bank value, not the offset-adjusted one.  Getting this
// wrong is what made openMSX <=21.0 require SCC ROMs to sit on 512KB boundaries
// (openMSX issue #1992, fixed in b3ad12816).
//
// Deviation from openMSX (deliberate): the SCC window is also closed while the mode register
// selects RAM mode (bit4).  openMSX has no RAM-mode test at all, which matches old firmware
// yimmi8; artrag reports the real cartridge added the test in yimmi9rc2, and the bifi Sound
// Cartridge documentation requires it.  openMSX issue #1964 is still open on this.
`default_nettype none

module cart_yamanooto
(
   input             clk,
   input             reset,
   input      [24:0] mem_size,
   input      [15:0] cpu_addr,
   input       [7:0] din,
   input             cpu_mreq,
   input             cpu_wr,
   input             cpu_rd,
   input             cs,
   input             cart_num,

   output            mem_unmaped,
   output     [24:0] mem_addr,
   output      [7:0] cart_dout,     // register readback (0xFF when not addressed/readable)
   output            cart_dout_en,
   output            scc_req,       // SCC register window hit  -> scc_sound cs
   output      [1:0] scc_mode,      // per cart: 0 = Compatible, 1 = Plus -> scc_sound
   output            flash_wr_en,   // WREN: writes may reach the flash
   output     [22:0] flash_addr,    // banked flash byte address -> flash.sv
   output            flash_rq,      // this cart is addressing the flash chip
   output            prog_we        // validated JEDEC byte-program data write -> SDRAM
);

// ── register addresses / bits ────────────────────────────────────────────
localparam [15:0] ENAR = 16'h7FFF;
localparam [15:0] OFFR = 16'h7FFE;
localparam [15:0] CFGR = 16'h7FFD;

localparam [7:0] REGEN  = 8'h01;   // ENAR bit0
localparam [7:0] WREN   = 8'h10;   // ENAR bit4
localparam [7:0] SPIEN  = 8'h02;   // ENAR bit1 - SPI/SD enable   (not implemented)
localparam [7:0] MSTEN  = 8'h04;   // ENAR bit2 - master offset   (not implemented)
localparam [7:0] MDIS   = 8'h01;   // CFGR bit0
localparam [7:0] ECHO   = 8'h02;   // CFGR bit1
localparam [7:0] ROMDIS = 8'h04;   // CFGR bit2
localparam [7:0] K4     = 8'h08;   // CFGR bit3
localparam [7:0] SUBOFF = 8'h30;   // CFGR bit5:4

// ── state (per cartridge slot) ───────────────────────────────────────────
logic  [7:0] enableReg [2];
logic  [7:0] offsetReg [2];
logic  [7:0] configReg [2];
logic  [7:0] sccModeReg[2];
logic  [9:0] bankReg   [2][4];    // offset-adjusted  -> flash address
logic  [7:0] rawBank   [2][4];    // as written       -> SCC visibility

wire  [7:0] enar = enableReg [cart_num];
wire  [7:0] cfgr = configReg [cart_num];
wire  [7:0] offr = offsetReg [cart_num];
wire  [7:0] sccm = sccModeReg[cart_num];

wire        regen = |(enar & REGEN);
assign      flash_wr_en = |(enar & WREN);

// effective offset in 8KB units: OFFR*4 + SUBOFF   (spec 2.2 + 2.3)
wire  [9:0] offset = {offr, 2'b00} | {8'd0, cfgr[5:4]};

wire  [1:0] page8kB = 2'(cpu_addr[15:13] - 3'd2);    // 0x4000..0xBFFF -> 0..3
wire        page_ok = (cpu_addr >= 16'h4000) && (cpu_addr < 16'hC000);

// ── register access (0x7FFC-0x7FFF, not mirrored) ────────────────────────
wire        reg_hit = cs & cpu_mreq & (cpu_addr >= 16'h7FFC) & (cpu_addr <= ENAR);
wire        reg_rd  = reg_hit & cpu_rd & regen;       // nothing is readable until REGEN

assign cart_dout_en = reg_rd;
assign cart_dout    = !reg_rd            ? 8'hFF :
                      cpu_addr == CFGR   ? cfgr  :
                      cpu_addr == OFFR   ? offr  :
                      // Bits 1 (SPIEN/SDEN) and 2 (MSTEN) are real hardware features
                      // -- the SPI path to the SD card and the master-offset
                      // register -- that we do not implement.  The vendor's probe
                      // (YAMDET) writes REGEN|SDEN and compares the readback: echo
                      // those bits and it concludes the core supports SD, then
                      // busy-waits on 0x7FFE bit7 in a loop its own source marks
                      // "NO TIMEOUT!!!" -- a dead machine.  Reading them back as 0
                      // makes it take its own "old core, no SD" path instead.
                      // Every other bit, bit7 included, must read back as written:
                      // the Neo-Ultimate launcher writes ENAR=0x81/0x80 and relies
                      // on that.
                      cpu_addr == ENAR   ? (enar & ~(SPIEN | MSTEN)) :
                                           8'hFF;     // 0x7FFC: FPGA channel not implemented

// ── SCC visibility ───────────────────────────────────────────────────────
// K4 (Konami4) has no SCC at all.  RAM mode (mode register bit4) hides the window.
wire        scc_ram_mode = |(sccm & 8'h10);
wire        scc_on       = ~|(cfgr & K4) & ~scc_ram_mode;

// Per-cartridge and REGISTERED, mirroring konami_scc.sv:61.  IKASCC samples
// i_SCCP_MODE continuously in its audio path (IKASCC_player_s.v:309 latches ch5's
// waveform from the shared ch4 RAM unless the mode reads Plus), so a value that is
// only valid during a bus cycle makes ch5 play ch4's waveform even in Plus mode.
// Emitting both carts also stops slot B being hard-wired to bit 0.
assign scc_mode = {|(sccModeReg[1] & 8'h20), |(sccModeReg[0] & 8'h20)};
wire   scc_plus = |(sccm & 8'h20);   // this cart, for the window decode below
assign scc_req  = cs & cpu_mreq & (cpu_rd | cpu_wr) & scc_on &
                  (scc_plus
                     // SCC+  0xB800-0xBFFD  (0xBFFE/0xBFFF are the mode register)
                     ? ( rawBank[cart_num][3][7]            & (cpu_addr >= 16'hB800) & (cpu_addr < 16'hBFFE))
                     // SCC   0x9800-0x9FFF
                     : ((rawBank[cart_num][2][5:0] == 6'h3F) & (cpu_addr[15:11] == 5'b10011)));

// ── bank register writes ─────────────────────────────────────────────────
// K5 (Konami-SCC): 0x5000-0x57FF / 0x7000-0x77FF / 0x9000-0x97FF / 0xB000-0xB7FF
// K4 (Konami)    : 0x6000-0x7FFF / 0x8000-0x9FFF / 0xA000-0xBFFF, bank0 not switchable
wire        mdis     = |(cfgr & MDIS);
wire        bank_k5  = ~|(cfgr & K4) & (cpu_addr[12:11] == 2'b10);
wire        bank_k4  =  |(cfgr & K4) & (cpu_addr >= 16'h6000);
wire        bank_hit = cs & cpu_mreq & cpu_wr & page_ok & ~flash_wr_en & ~mdis
                     & (bank_k5 | bank_k4);

wire        modereg_hit = cs & cpu_mreq & cpu_wr & ~flash_wr_en & ~|(cfgr & K4)
                        & (cpu_addr[15:1] == 15'h5FFF);        // 0xBFFE / 0xBFFF

integer i, j;
always @(posedge clk) begin
   if (reset) begin
      for (i = 0; i < 2; i = i + 1) begin
         enableReg [i] <= 8'h00;
         offsetReg [i] <= 8'h00;
         configReg [i] <= 8'h00;
         sccModeReg[i] <= 8'h00;
         for (j = 0; j < 4; j = j + 1) begin
            bankReg[i][j] <= 10'(j);
            rawBank[i][j] <= 8'(j);
         end
      end
   end else if (cs & cpu_mreq & cpu_wr) begin
      // configuration registers: ENAR always writable, the rest only once REGEN is set
      if (cpu_addr == ENAR)                 enableReg [cart_num] <= din;
      else if (regen & cpu_addr == CFGR)    configReg [cart_num] <= din;
      // 0x7FFE is three registers on real hardware: OFFR, or MOFFR when MSTEN
      // (ENAR bit2), or SPICON when SPIEN (ENAR bit1).  We only implement OFFR, so
      // qualify the write -- otherwise the genuine firmware's MOFFR write silently
      // destroys OFFR.  YAMABOOT.Z8A:175 sets ENAR=%101, writes MOFFR, clears MSTEN,
      // then writes OFFR=0; without this guard the second write clobbers the first.
      // openMSX has the identical defect (Yamanooto.cc:223-225).
      else if (regen & cpu_addr == OFFR & ~|(enar & (MSTEN | SPIEN)))
                                            offsetReg [cart_num] <= din;

      if (modereg_hit)                      sccModeReg[cart_num] <= din;

      if (bank_hit) begin
         bankReg[cart_num][page8kB] <= 10'(({2'd0, din} + offset) & 10'h3FF);
         rawBank[cart_num][page8kB] <= din;
      end
   end
end

// ── memory mapping ───────────────────────────────────────────────────────
wire romdis = |(cfgr & ROMDIS);

// The register window and the SCC window are not flash; ROMDIS hides the flash entirely.
// reg_rd, NOT reg_hit: the register window only SHADOWS the flash while REGEN is
// set.  With REGEN clear the spec says no register is *readable* -- the ROM must
// still show through, and openMSX's readMem (Yamanooto.cc:170) tests
// (enableReg & REGEN) before intercepting, falling through to flash.read().
// Using the address-only reg_hit made 0x7FFC-0x7FFF read 0xFF instead of ROM,
// which corrupts 588 of the 770 used 8KB segments in an 8MB multi-ROM: Vampire
// Killer's ground-item pickup is INC (HL) at 0x7FFC, so items could be walked
// over but never collected.  Writes stay covered by the cpu_wr term below.
assign mem_unmaped = cs & (~page_ok | romdis | scc_req | reg_rd
                           | (cpu_wr & cpu_mreq & ~flash_wr_en));

// 10-bit bank x 8KB already bounds this to the 8MB chip, exactly like openMSX's
// `bankRegs[page8kB] & 0x3ff`.  mem_size is not necessarily a power of two, so it is
// deliberately not used as a mask here.
assign mem_addr = {2'd0, bankReg[cart_num][page8kB], cpu_addr[12:0]};

// ── JEDEC flash programming ──────────────────────────────────────────────
// Modelled on ascii16x.sv, which is the proven path in this core: flash.sv's own
// byte-program (0xA0) branch is structurally dead -- its guard is
// `(quadrupleProgram | write_cnt > 0)` and `bytePrgram` can only set write_cnt
// from INSIDE that block -- so the mapper detects the sequence itself and the
// data byte rides the ordinary SDRAM write path (`prog_we` in msx_slots.sv
// forces sdram_ce / ram_rnw past the region's read-only flag).  Erase is left to
// flash.sv, which does the 0xFF fill with its bounds clamp.
//
// openMSX gates the same way (Yamanooto.cc writeMem): registers 0x7FFC-0x7FFF are
// handled FIRST (ENAR unconditionally, CFGR/OFFR behind REGEN) and the write then
// falls through to flash.write() only while WREN is set and ROMDIS is clear.
// The Selica Korean translations (Final Fantasy, Golvellius 2, Jikuu no Hanayome)
// write #12 to #7FFF -- that is WREN|SPIEN, REGEN stays CLEAR -- and then unlock
// through #4AAA / #4555, which is exactly the 0x555 / 0x2AA word-offset pair
// below.  WREN alone opens the flash; REGEN is not required for programming.
wire        cart_wr  = cs & cpu_mreq & cpu_wr & page_ok & flash_wr_en & ~romdis;
wire        unlock_a = (cpu_addr[11:1] == 11'h555);   // unlock cycles 1 & 3
wire        unlock_b = (cpu_addr[11:1] == 11'h2AA);   // unlock cycle 2

logic       old_cart_wr;
wire        wr_rise = cart_wr & ~old_cart_wr;         // one event per CPU write
wire        wr_fall = ~cart_wr & old_cart_wr;

typedef enum logic [2:0] {J_IDLE, J_AA, J_55, J_PROG, J_E1, J_E2, J_E3} jedec_t;
jedec_t     jedec_st;
logic       prog_arm;

always @(posedge clk) begin
   if (reset) begin
      jedec_st    <= J_IDLE;
      prog_arm    <= 1'b0;
      old_cart_wr <= 1'b0;
   end else begin
      old_cart_wr <= cart_wr;
      if (wr_fall) prog_arm <= 1'b0;                  // program write finished
      if (wr_rise) begin
         case (jedec_st)
            J_IDLE: jedec_st <= ((din == 8'hAA) & unlock_a) ? J_AA : J_IDLE;
            J_AA:   jedec_st <= ((din == 8'h55) & unlock_b) ? J_55 :
                                ((din == 8'hAA) & unlock_a) ? J_AA : J_IDLE;
            J_55:   jedec_st <= ((din == 8'hA0) & unlock_a) ? J_PROG :
                                ((din == 8'h80) & unlock_a) ? J_E1   :
                                ((din == 8'hAA) & unlock_a) ? J_AA   : J_IDLE;
            J_PROG: begin                             // this write = program data
                       prog_arm <= ~mem_unmaped;      // only program in-bounds
                       jedec_st <= J_IDLE;
                    end
            J_E1:   jedec_st <= ((din == 8'hAA) & unlock_a) ? J_E2 : J_IDLE;
            J_E2:   jedec_st <= ((din == 8'h55) & unlock_b) ? J_E3 :
                                ((din == 8'hAA) & unlock_a) ? J_AA : J_IDLE;
            J_E3:   jedec_st <= J_IDLE;               // 30/10 confirm: flash.sv fills
            default: jedec_st <= J_IDLE;
         endcase
      end
   end
end

assign prog_we   = prog_arm & cart_wr;                // held across the program write
assign flash_addr = 23'(mem_addr);
// The register and SCC windows are not the flash chip, and ROMDIS hides it
// entirely -- keep those cycles out of flash.sv's shared command FSM.
// WRITES are additionally gated on WREN, matching openMSX (Yamanooto.cc writeMem
// only reaches flash.write() inside `if (enableReg & WREN)`).  Without this, an
// ordinary K4 bank write that happens to carry 0xAA at word offset 0x555 can walk
// the SHARED flash command FSM into autoselect, after which every cart read
// returns manufacturer id bytes until an 0xF0.  K4 banking covers 0x6000-0xBFFF
// in full, so 0x?AAA is reachable there -- a much larger surface than ASCII16X's
// two bank addresses.  Reads stay ungated: openMSX's readMem has no WREN test,
// and autoselect/CFI results must still be readable.
// cpu_mreq is essential, not decoration: an I/O read such as `IN A,(0x12)` puts
// {A,port} on cpu_addr, so A=0x50 gives 0x5012 -- inside page_ok, with cpu_rd
// asserted and cpu_mreq clear.  Without the mreq term that IORQ cycle asserts
// flash_rq, and while a driver legitimately has autoselect or CFI active the
// flash's dout is ANDed into the shared cpu_din tree, corrupting the IN result.
assign flash_rq  = cs & cpu_mreq & page_ok & ~romdis & ~scc_req & ~reg_rd
                 & (cpu_rd | flash_wr_en);

endmodule
`default_nettype wire
