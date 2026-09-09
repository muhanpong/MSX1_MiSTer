// NEO-8 / NEO-16 mapper (openMSX RomNeo8.cc / RomNeo16.cc, introduced 2024-02-17
// by Manuel Bilderbeek as a concept mapper with >8-bit bank registers).
//
// One parameterized module, instantiated twice in msx_slots (BANK16 = 0 / 1).
// The two variants differ in exactly four places -- bank size (8/16 KB), region
// count (6/3), the write-window decode and the read-region decode -- everything
// else, including the split 12-bit register write, is shared, and a shared body
// cannot drift the way two copies can.
//
//   12-bit bank registers, one per region, reset to 0.
//     even address  -> bits [7:0]  = din
//     odd  address  -> bits [11:8] = din[3:0]        (upper nibble discarded)
//   Write windows decode ONLY cpu_addr[13:11] (bbb) -- cpu_addr[15:14] is not
//   part of the decode, so the windows repeat in every 16 KB quadrant,
//   INCLUDING page 3: a write to 0xD000 programs region 0 exactly like 0x1000.
//   Page 3 is unmapped for reads only.
//     NEO-8 : bbb = 2..7  -> region bbb-2      (windows 0x1000..0x3FFF step 0x800)
//     NEO-16: bbb = 2,4,6 -> region (bbb>>1)-1 (windows 0x1000/0x2000/0x3000, odd bbb ignored)
//   Reads: region = cpu_addr[15:13] (NEO-8) / cpu_addr[15:14] (NEO-16),
//   0xC000-0xFFFF unmapped (0xFF).
//   Out-of-range banks follow openMSX RomBlocks::setRom exactly:
//   block & (nrBlocks-1), and if still out of range the read is unmapped.
`default_nettype none

module cart_neo #(parameter BANK16 = 0)
(
    input  wire        clk,
    input  wire        reset,
    input  wire [26:0] rom_size,
    input  wire [15:0] cpu_addr,
    input  wire  [7:0] din,
    input  wire        cpu_mreq,
    input  wire        cpu_wr,
    input  wire        cs,
    input  wire        cart_num,
    output wire        mem_unmaped,
    output wire [26:0] mem_addr
);
/*verilator tracing_off*/
localparam REGIONS = BANK16 ? 3 : 6;
localparam ABITS   = BANK16 ? 14 : 13;   // offset bits inside one bank

logic [11:0] blk[2][REGIONS];

wire [2:0] bbb    = cpu_addr[13:11];
wire       wr_win = BANK16 ? (bbb[2:1] != 2'd0 & ~bbb[0]) : (bbb >= 3'd2);
wire [2:0] wreg   = BANK16 ? (3'({1'b0, bbb[2:1]}) - 3'd1) : (bbb - 3'd2);

always @(posedge clk) begin
    if (reset) blk <= '{'{default: '0}, '{default: '0}};
    else if (cs & cpu_mreq & cpu_wr & wr_win) begin
        if (cpu_addr[0]) blk[cart_num][wreg][11:8] <= din[3:0];
        else             blk[cart_num][wreg][7:0]  <= din;
    end
end

wire       page3  = &cpu_addr[15:14];
wire [2:0] rreg   = BANK16 ? {1'b0, cpu_addr[15:14]} : cpu_addr[15:13];
wire [2:0] rreg_g = page3 ? 3'd0 : rreg;             // keep the index inside the array

wire [12:0] nrblocks = 13'(rom_size >> ABITS);
wire [11:0] raw = blk[cart_num][rreg_g];
wire [11:0] eff = (13'(raw) < nrblocks) ? raw : raw & 12'(nrblocks - 13'd1);
wire        oob = 13'(eff) >= nrblocks;

assign mem_addr    = (27'(eff) << ABITS) | 27'(cpu_addr[ABITS-1:0]);
assign mem_unmaped = cs & (page3 | oob);

endmodule

`default_nettype wire
