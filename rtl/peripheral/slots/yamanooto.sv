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
   output            scc_mode,      // 0 = Compatible, 1 = Plus  -> scc_sound sccPlusMode
   output            flash_wr_en    // WREN: writes may reach the flash
);

// ── register addresses / bits ────────────────────────────────────────────
localparam [15:0] ENAR = 16'h7FFF;
localparam [15:0] OFFR = 16'h7FFE;
localparam [15:0] CFGR = 16'h7FFD;

localparam [7:0] REGEN  = 8'h01;   // ENAR bit0
localparam [7:0] WREN   = 8'h10;   // ENAR bit4
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
                      cpu_addr == ENAR   ? enar  :
                                           8'hFF;     // 0x7FFC: FPGA channel not implemented

// ── SCC visibility ───────────────────────────────────────────────────────
// K4 (Konami4) has no SCC at all.  RAM mode (mode register bit4) hides the window.
wire        scc_ram_mode = |(sccm & 8'h10);
wire        scc_on       = ~|(cfgr & K4) & ~scc_ram_mode;

assign scc_mode = |(sccm & 8'h20);
assign scc_req  = cs & cpu_mreq & (cpu_rd | cpu_wr) & scc_on &
                  (scc_mode
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
      else if (regen & cpu_addr == OFFR)    offsetReg [cart_num] <= din;

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
assign mem_unmaped = cs & (~page_ok | romdis | scc_req | reg_hit
                           | (cpu_wr & cpu_mreq & ~flash_wr_en));

// 10-bit bank x 8KB already bounds this to the 8MB chip, exactly like openMSX's
// `bankRegs[page8kB] & 0x3ff`.  mem_size is not necessarily a power of two, so it is
// deliberately not used as a mask here.
assign mem_addr = {2'd0, bankReg[cart_num][page8kB], cpu_addr[12:0]};

endmodule
`default_nettype wire
