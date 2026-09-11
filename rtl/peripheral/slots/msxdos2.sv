//  ---------------------------------------------------------------------------
//  MSX-DOS 2 ROM  (ASCII cartridge, and the Panasonic turboR internal disk ROM)
//  ---------------------------------------------------------------------------
//
//  One 16 kB block at page 1 (4000-7FFF); pages 0, 2 and 3 read as unmapped.
//  A single 8-bit register picks the block, masked down to the ROM's size.
//
//  Which address that register answers on is a property of the ROM, recorded in
//  its own byte 0x94 (openMSX RomMSXDOS2.cc): 0x00 -> 7FF0, 0x60 -> 6000-6FFF,
//  0x7F -> 7FFE.  The dumps in circulation really do use more than one:
//
//     msxdos22.rom        c36c9e0f   0x60   6000-6FFF   (generic, Europe)
//     ascii_msxdos22.rom  42f4e336   0x7F   7FFE        (ASCII, Japan)
//     mk_dos220.rom       0e253ee0   0x60   6000-6FFF   (MK DOS 2.20)
//     TurboRFDC.cc                   ---    7FF0        (FS-A1GT/ST disk ROM)
//
//  Rather than carry that byte through the pack loader, all three windows are
//  decoded.  Page 1 holds ROM, so a write there means nothing else -- there is
//  no second reading for the addresses this picks up.  Should some ROM turn out
//  to write into a window it does not bank on, the fix is to split the mapper
//  per variant, not to narrow this blindly.
//
//  The DOS 2 kernel carries no disk driver: it uses the one in the machine's
//  own disk ROM, so a pack that declares this block also needs an FDC, and at
//  least 128 kB of memory mapper (DOS 2 wants two free mapper pages).
//  ---------------------------------------------------------------------------
module mapper_msxdos2
(
   input               clk,
   input               reset,
   input        [24:0] rom_size,
   input        [15:0] cpu_addr,
   input         [7:0] din,
   input               cpu_mreq,
   input               cpu_wr,
   input               cs,
   output              mem_unmaped,
   output       [24:0] mem_addr
);

// 16 kB blocks, so the count is the ROM size shifted down by 14.
wire [10:0] blocks    = 11'(rom_size >> 14);
wire        bank_win  = cpu_addr[15:12] == 4'h6          // 6000-6FFF
                      | cpu_addr        == 16'h7FF0
                      | cpu_addr        == 16'h7FFE;

logic [7:0] bank;
always @(posedge clk) begin
   if (reset)
      bank <= 8'h00;                                     // reset() -> setRom(1, 0)
   else if (cs & cpu_mreq & cpu_wr & bank_win)
      bank <= din;
end

// Out-of-range blocks wrap, the way blockMask does on the real cartridge.
wire [7:0] bank_eff = (11'(bank) < blocks) ? bank : 8'(bank & 8'(blocks - 11'd1));

assign mem_addr    = 25'({bank_eff, cpu_addr[13:0]});
// Page 1 only.  Not the `~^cpu_addr[15:14]` the 16 kB cartridge mappers use --
// that admits page 2 as well, which is right for ASCII16 and wrong here.
assign mem_unmaped = cs & (cpu_addr[15:14] != 2'b01);

endmodule
