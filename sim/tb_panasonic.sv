// tb_panasonic -- the Panasonic firmware mapper (turbo R slot 3-3).
//
// Checks the semantics taken verbatim from openMSX RomPanasonic.cc (writeMem /
// peekMem) and the sizes from the FS-A1ST / FS-A1GT machine XMLs:
//   * eight 8 kB regions cover 0000-FFFF, region = cpu_addr[15:13],
//   * a write in 6000-7FEF sets the low 8 bits of the bank for the region named by
//     cpu_addr[12:10], with regions 5 and 6 EXCHANGED (openMSX `region ^= 3`),
//   * 7FF8 sets bit 8 of all eight banks, bit i -> region i,
//   * 7FF9 is the control register and gates the read-backs:
//       control[2] 7FF0-7FF7 low bits, control[4] 7FF8 high bits, control[3] 7FF9,
//   * banks 0x80.. are SRAM inside the sram-mirrored=false window
//     (ST 16 kB -> 2 banks, GT 32 kB -> 4), everything else is ROM,
//   * banks >= 0x180 are the main-RAM window: NOT implemented, so they must report
//     unmapped rather than alias ROM (see panasonic.sv).
// Reference: docs/panasonic_mapper.md.
//
// Written for Verilator 4 (no --timing): the clock comes from sim_panasonic.cpp and
// the stimulus is an op table walked two cycles per op -- drive, then check.
module tb (input logic clk);

   localparam OP_END = 0, OP_WRITE = 1, OP_ADDR = 2, OP_DOUT = 3,
              OP_SRAM = 4, OP_NOSRAM = 5, OP_UNMAP = 6, OP_SRAMKB = 7, OP_SRAMWE = 8, OP_ROMSZ = 9;

   typedef struct packed {
      logic  [3:0] op;
      logic [15:0] addr;
      logic  [7:0] data;
      logic [24:0] exp;      // OP_ADDR: expected mem_addr, OP_DOUT: expected dout
   } op_t;

   localparam int NOPS = 68;
   op_t prog [NOPS];

   initial begin : prog_init
      prog[ 0] = '{OP_ADDR,    16'h0000, 8'h00, 25'h0000000};   // reset: region 0 on bank 0
      prog[ 1] = '{OP_ADDR,    16'hE000, 8'h00, 25'h0000000};   // reset: region 7 on bank 0
      prog[ 2] = '{OP_WRITE,   16'h6000, 8'h01, 25'h0000000};   // write 6000 <- 01
      prog[ 3] = '{OP_ADDR,    16'h0000, 8'h00, 25'h0002000};   // 6000 -> region 0
      prog[ 4] = '{OP_WRITE,   16'h6400, 8'h02, 25'h0000000};   // write 6400 <- 02
      prog[ 5] = '{OP_ADDR,    16'h2000, 8'h00, 25'h0004000};   // 6400 -> region 1
      prog[ 6] = '{OP_WRITE,   16'h6800, 8'h03, 25'h0000000};   // write 6800 <- 03
      prog[ 7] = '{OP_ADDR,    16'h4000, 8'h00, 25'h0006000};   // 6800 -> region 2
      prog[ 8] = '{OP_WRITE,   16'h6C00, 8'h04, 25'h0000000};   // write 6C00 <- 04
      prog[ 9] = '{OP_ADDR,    16'h6000, 8'h00, 25'h0008000};   // 6C00 -> region 3
      prog[10] = '{OP_WRITE,   16'h7000, 8'h05, 25'h0000000};   // write 7000 <- 05
      prog[11] = '{OP_ADDR,    16'h8000, 8'h00, 25'h000A000};   // 7000 -> region 4
      prog[12] = '{OP_WRITE,   16'h7C00, 8'h08, 25'h0000000};   // write 7C00 <- 08
      prog[13] = '{OP_ADDR,    16'hE000, 8'h00, 25'h0010000};   // 7C00 -> region 7
      prog[14] = '{OP_WRITE,   16'h7400, 8'h11, 25'h0000000};   // write 7400 <- 11
      prog[15] = '{OP_ADDR,    16'hC000, 8'h00, 25'h0022000};   // 7400 writes region 6, not 5
      prog[16] = '{OP_WRITE,   16'h7800, 8'h12, 25'h0000000};   // write 7800 <- 12
      prog[17] = '{OP_ADDR,    16'hA000, 8'h00, 25'h0024000};   // 7800 writes region 5, not 6
      prog[18] = '{OP_ADDR,    16'hC000, 8'h00, 25'h0022000};   // 7800 left region 6 alone
      prog[19] = '{OP_ROMSZ,   16'h0000, 8'h04, 25'h0000000};   // ROM 4 MB
      prog[20] = '{OP_WRITE,   16'h6000, 8'h00, 25'h0000000};   // write 6000 <- 00
      prog[21] = '{OP_WRITE,   16'h7FF8, 8'h01, 25'h0000000};   // write 7FF8 <- 01
      prog[22] = '{OP_ADDR,    16'h0000, 8'h00, 25'h0200000};   // 7FF8 bit0 -> region 0 bank 0x100
      prog[23] = '{OP_WRITE,   16'h7FF8, 8'h00, 25'h0000000};   // write 7FF8 <- 00
      prog[24] = '{OP_ADDR,    16'h0000, 8'h00, 25'h0000000};   // 7FF8 cleared
      prog[25] = '{OP_ROMSZ,   16'h0000, 8'h02, 25'h0000000};   // ROM 2 MB
      prog[26] = '{OP_WRITE,   16'h6000, 8'h5A, 25'h0000000};   // write 6000 <- 5A
      prog[27] = '{OP_DOUT,    16'h7FF0, 8'h00, 25'h00000FF};   // control 0 -> no read-back
      prog[28] = '{OP_WRITE,   16'h7FF9, 8'h04, 25'h0000000};   // write 7FF9 <- 04
      prog[29] = '{OP_DOUT,    16'h7FF0, 8'h00, 25'h000005A};   // control[2] -> bank low byte
      prog[30] = '{OP_DOUT,    16'h7FF9, 8'h00, 25'h00000FF};   // control[3] clear -> 7FF9 not claimed
      prog[31] = '{OP_WRITE,   16'h7FF9, 8'h08, 25'h0000000};   // write 7FF9 <- 08
      prog[32] = '{OP_DOUT,    16'h7FF9, 8'h00, 25'h0000008};   // control[3] -> control byte
      prog[33] = '{OP_WRITE,   16'h7FF9, 8'h10, 25'h0000000};   // write 7FF9 <- 10
      prog[34] = '{OP_WRITE,   16'h7FF8, 8'h81, 25'h0000000};   // write 7FF8 <- 81
      prog[35] = '{OP_DOUT,    16'h7FF8, 8'h00, 25'h0000081};   // control[4] -> nine-bit flags
      prog[36] = '{OP_WRITE,   16'h7FF8, 8'h00, 25'h0000000};   // write 7FF8 <- 00
      prog[37] = '{OP_WRITE,   16'h7FF9, 8'h00, 25'h0000000};   // write 7FF9 <- 00
      prog[38] = '{OP_WRITE,   16'h6000, 8'h80, 25'h0000000};   // write 6000 <- 80
      prog[39] = '{OP_SRAM,    16'h0000, 8'h00, 25'h0000000};   // bank 0x80 -> SRAM block 0
      prog[40] = '{OP_SRAM,    16'h1FFF, 8'h00, 25'h0001FFF};   // SRAM block 0 top
      prog[41] = '{OP_WRITE,   16'h6000, 8'h81, 25'h0000000};   // write 6000 <- 81
      prog[42] = '{OP_SRAM,    16'h0000, 8'h00, 25'h0002000};   // bank 0x81 -> SRAM block 1
      prog[43] = '{OP_WRITE,   16'h6000, 8'h82, 25'h0000000};   // write 6000 <- 82
      prog[44] = '{OP_NOSRAM,  16'h0000, 8'h00, 25'h0000000};   // bank 0x82 past the 16 kB window
      prog[45] = '{OP_WRITE,   16'h6000, 8'h80, 25'h0000000};   // write 6000 <- 80
      prog[46] = '{OP_SRAMWE,  16'h0100, 8'hA5, 25'h0000000};   // sram write 0100
      prog[47] = '{OP_SRAMKB,  16'h0000, 8'h20, 25'h0000000};   // sram 32 kB
      prog[48] = '{OP_WRITE,   16'h6000, 8'h83, 25'h0000000};   // write 6000 <- 83
      prog[49] = '{OP_SRAM,    16'h0000, 8'h00, 25'h0006000};   // 32 kB: bank 0x83 is block 3
      prog[50] = '{OP_WRITE,   16'h6000, 8'h84, 25'h0000000};   // write 6000 <- 84
      prog[51] = '{OP_NOSRAM,  16'h0000, 8'h00, 25'h0000000};   // 32 kB: bank 0x84 past the window
      prog[52] = '{OP_SRAMKB,  16'h0000, 8'h10, 25'h0000000};   // sram 16 kB
      prog[53] = '{OP_WRITE,   16'h6000, 8'h80, 25'h0000000};   // write 6000 <- 80
      prog[54] = '{OP_WRITE,   16'h7FF8, 8'h01, 25'h0000000};   // write 7FF8 <- 01
      prog[55] = '{OP_UNMAP,   16'h0000, 8'h00, 25'h0000000};   // bank 0x180 is main RAM: unmapped
      prog[56] = '{OP_NOSRAM,  16'h0000, 8'h00, 25'h0000000};   // bank 0x180 is not SRAM
      prog[57] = '{OP_WRITE,   16'h7FF8, 8'h00, 25'h0000000};   // write 7FF8 <- 00
      prog[58] = '{OP_WRITE,   16'h6000, 8'h00, 25'h0000000};   // write 6000 <- 00
      prog[59] = '{OP_WRITE,   16'h7FF8, 8'h01, 25'h0000000};   // write 7FF8 <- 01
      prog[60] = '{OP_ADDR,    16'h0000, 8'h00, 25'h0000000};   // bank 0x100 wraps on a 2 MB ROM
      prog[61] = '{OP_WRITE,   16'h7FF8, 8'h00, 25'h0000000};   // write 7FF8 <- 00
      prog[62] = '{OP_WRITE,   16'h6000, 8'h07, 25'h0000000};   // write 6000 <- 07
      prog[63] = '{OP_WRITE,   16'h4000, 8'h55, 25'h0000000};   // write 4000 <- 55
      prog[64] = '{OP_ADDR,    16'h0000, 8'h00, 25'h000E000};   // a write at 4000 moves no bank
      prog[65] = '{OP_WRITE,   16'h9000, 8'h55, 25'h0000000};   // write 9000 <- 55
      prog[66] = '{OP_ADDR,    16'h0000, 8'h00, 25'h000E000};   // a write at 9000 moves no bank
      prog[67] = '{OP_END,     16'h0000, 8'h00, 25'h0000000};   // end
   end

   logic        reset = 1'b1, mreq = 1'b0, wr = 1'b0, rd = 1'b0;
   logic [15:0] a = 16'h0000;
   logic  [7:0] d = 8'h00;
   logic [15:0] sram_kb  = 16'd16;
   logic [24:0] rom_size = 25'h200000;   // FS-A1ST 2 MB; the GT is 4 MB
   wire  [24:0] mem_addr;
   wire         mem_unmaped, sram_cs, sram_we;
   wire   [7:0] dout;

   mapper_panasonic dut (.clk(clk), .reset(reset), .rom_size(rom_size),
                         .cpu_addr(a), .din(d), .cpu_mreq(mreq), .cpu_rd(rd), .cpu_wr(wr),
                         .cs(1'b1), .sram_kb(sram_kb),
                         .mem_unmaped(mem_unmaped), .mem_addr(mem_addr),
                         .sram_cs(sram_cs), .sram_we(sram_we), .dout(dout));

   int unsigned idx = 0, fails = 0, checks = 0, settle = 0;
   logic phase = 1'b0;

   //  Does the current op's expectation hold right now?
   logic ok;
   always_comb begin
      case (prog[idx].op)
         OP_ADDR:   ok = mem_addr === prog[idx].exp;
         OP_DOUT:   ok = dout     === prog[idx].exp[7:0];
         OP_SRAM:   ok = sram_cs && mem_addr === prog[idx].exp;
         OP_NOSRAM: ok = !sram_cs;
         OP_UNMAP:  ok = mem_unmaped;
         OP_SRAMWE: ok = sram_cs && sram_we;
         default:   ok = 1'b1;
      endcase
   end

   always_ff @(posedge clk) begin
      if (settle < 4) begin
         settle <= settle + 1;
         if (settle == 2) reset <= 1'b0;
      end else if (!phase) begin : drive
         //  drive
         a    <= prog[idx].addr;
         d    <= prog[idx].data;
         mreq <= prog[idx].op != OP_END && prog[idx].op != OP_SRAMKB && prog[idx].op != OP_ROMSZ;
         wr   <= prog[idx].op == OP_WRITE || prog[idx].op == OP_SRAMWE;
         rd   <= prog[idx].op == OP_ADDR || prog[idx].op == OP_DOUT || prog[idx].op == OP_SRAM
                 || prog[idx].op == OP_NOSRAM || prog[idx].op == OP_UNMAP;
         if (prog[idx].op == OP_SRAMKB) sram_kb  <= 16'(prog[idx].data);
         if (prog[idx].op == OP_ROMSZ)  rom_size <= prog[idx].data == 8'd4 ? 25'h400000 : 25'h200000;
         phase <= 1'b1;
      end else begin : evaluate
         //  check: the outputs are combinational from `a` and the bank registers
         if (prog[idx].op != OP_END && prog[idx].op != OP_WRITE && prog[idx].op != OP_SRAMKB
             && prog[idx].op != OP_ROMSZ) begin
            checks <= checks + 1;
            if (!ok) begin
               fails <= fails + 1;
               $display("FAIL op %0d (kind %0d): addr %04x -> mem_addr %07x dout %02x sram_cs %b sram_we %b unmaped %b, expected %07x",
                        idx, prog[idx].op, prog[idx].addr, mem_addr, dout, sram_cs, sram_we, mem_unmaped, prog[idx].exp);
            end
         end
         mreq  <= 1'b0;
         wr    <= 1'b0;
         rd    <= 1'b0;
         phase <= 1'b0;
         if (prog[idx].op == OP_END) begin
            if (fails == 0) $display("PASSED (%0d checks)", checks);
            else            $display("FAILED %0d of %0d", fails, checks);
            $finish;
         end
         idx <= idx + 1;
      end
   end
endmodule
