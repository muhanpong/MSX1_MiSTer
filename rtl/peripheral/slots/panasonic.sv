//  Panasonic firmware mapper (turbo R slot 3-3, FS-A1FM/FX/WX family firmware)
//
//  Eight 8 kB regions cover the WHOLE address space (0000-FFFF), each with its own
//  9-bit bank register.  Semantics follow openMSX `RomPanasonic.cc` (verbatim read
//  of writeMem/peekMem, 2026-09-23); the FS-A1ST/GT machine XMLs give the sizes:
//
//    machine   ROM banks (8 kB)   SRAM      openMSX
//    FS-A1ST   0-255  (2 MB)      16 kB     <sramsize>16</sramsize>
//    FS-A1GT   0-511  (4 MB)      32 kB     <sramsize>32</sramsize>
//
//  Bank register writes, region = cpu_addr[12:10] of the write address:
//    6000-7FEF   low 8 bits of that region's bank.  Regions 5 and 6 are SWAPPED
//                (`region ^= 3` in openMSX), so 7400-77FF writes region 6 and
//                7800-7BFF writes region 5.
//    7FF8        bit 8 of all eight banks at once, bit i -> region i.
//    7FF9        control register.
//
//  Read-back, gated by the control register (otherwise the ROM byte is returned):
//    control[2]  7FF0-7FF7 -> low 8 bits of bank[addr[2:0]]
//    control[4]  7FF8      -> {bank7[8] ... bank0[8]}
//    control[3]  7FF9      -> control itself
//
//  A bank value selects, in this order:
//    0x080 .. 0x080+sram_blocks-1   SRAM    (block = bank - 0x80; sram-mirrored is
//                                            false on both turbo R machines, so the
//                                            window is exactly the SRAM size)
//    0x180 ..                       main RAM  -- NOT IMPLEMENTED, see below
//    anything else                  ROM     (bank * 8 kB, wrapped to the ROM size)
//
//  NOT IMPLEMENTED: the RAM banks (>= 0x180).  On the real machine they page the
//  main RAM into this slot (openMSX wires `<device idref="Main RAM"/>` into the
//  mapper).  Reaching another slot's RAM allocation is an msx_slots-level change,
//  so those banks read FF and ignore writes here.  If turbo R firmware turns out to
//  need them, that is the next piece of work -- see docs/panasonic_mapper.md.
module mapper_panasonic
(
   input               clk,
   input               reset,
   input        [24:0] rom_size,     // bytes, power of two (ST 2 MB, GT 4 MB)
   input        [15:0] cpu_addr,
   input         [7:0] din,
   input               cpu_mreq,
   input               cpu_rd,
   input               cpu_wr,
   input               cs,
   input        [15:0] sram_kb,      // SRAM size in kB from the pack (16 = ST, 32 = GT)
   output              mem_unmaped,
   output       [24:0] mem_addr,
   output              sram_cs,
   output              sram_we,
   output        [7:0] dout          // FF when this mapper is not answering the read
);

logic [8:0] bank[8];
logic [7:0] control;

//  Which region a bank-register WRITE addresses.  openMSX: region = (a & 0x1C00) >> 10,
//  then regions 5 and 6 are exchanged.
wire [2:0] wr_region_raw = cpu_addr[12:10];
wire [2:0] wr_region     = (wr_region_raw == 3'd5 | wr_region_raw == 3'd6) ? wr_region_raw ^ 3'd3
                                                                          : wr_region_raw;

wire write   = cs & cpu_mreq & cpu_wr;
wire w_bank  = write & cpu_addr >= 16'h6000 & cpu_addr < 16'h7FF0;
wire w_hi    = write & cpu_addr == 16'h7FF8;
wire w_ctl   = write & cpu_addr == 16'h7FF9;

always @(posedge clk) begin
   if (reset) begin
      bank    <= '{default: '0};
      control <= 8'h00;
   end else begin
      if (w_bank) bank[wr_region][7:0] <= din;
      if (w_hi)   for (int i = 0; i < 8; i++) bank[i][8] <= din[i];
      if (w_ctl)  control <= din;
   end
end

//  ---------------------------------------------------------------- read-back
wire rd       = cs & cpu_mreq & cpu_rd;
wire rb_low   = rd & control[2] & cpu_addr >= 16'h7FF0 & cpu_addr < 16'h7FF8;
wire rb_hi    = rd & control[4] & cpu_addr == 16'h7FF8;
wire rb_ctl   = rd & control[3] & cpu_addr == 16'h7FF9;
wire [7:0] hi_bits = {bank[7][8], bank[6][8], bank[5][8], bank[4][8],
                      bank[3][8], bank[2][8], bank[1][8], bank[0][8]};

assign dout = rb_low ? bank[cpu_addr[2:0]][7:0] :
              rb_hi  ? hi_bits                  :
              rb_ctl ? control                  : 8'hFF;

//  ---------------------------------------------------------------- address map
wire [2:0] region   = cpu_addr[15:13];
wire [8:0] sel      = bank[region];
//  sram-mirrored = false on both machines: the SRAM window is sram_kb/8 banks wide.
wire [8:0] sram_max = 9'h080 + 9'(sram_kb[15:3]);      // kB / 8
wire       is_sram  = sram_kb != 16'd0 & sel >= 9'h080 & sel < sram_max;
wire       is_ram   = sel >= 9'h180;                    // main RAM: not implemented

//  ROM address wraps like openMSX's Rom8kBBlocks::setRom (modulo the block count);
//  both turbo R ROM regions are a power of two, so a mask does it.
wire [24:0] rom_addr = 25'({sel, cpu_addr[12:0]}) & (rom_size - 25'd1);

//  SRAM offset inside this block's own SRAM allocation: block * 8 kB + offset.
wire [24:0] sram_addr = 25'({sel - 9'h080, cpu_addr[12:0]});

assign sram_cs     = is_sram & cs;
assign sram_we     = sram_cs & cpu_mreq & cpu_wr;
assign mem_unmaped = cs & is_ram;
assign mem_addr    = is_sram ? sram_addr : rom_addr;

endmodule
