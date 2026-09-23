module kanji
(
   input         clk,
   input         reset,
   input   [7:0] din,
   input   [7:0] addr,
   input         cpu_wr,
   input         cpu_rd,
   input         cpu_iorq,
   input         cs,
   input  [26:0] base_ram,
   input  [15:0] rom_size,
   output [26:0] mem_addr,
   output        ram_ce
);

logic [26:0] addr1, addr2;

wire kanji_en = cpu_iorq & addr[7:2] == 6'b1101_10;

assign mem_addr = base_ram + (addr[1] ? addr2 : addr1);
assign ram_ce   = cs & addr[0] & cpu_rd & kanji_en & (rom_size == 16'd16 | ~addr[1]);

//  The post-read increment fires one clock AFTER ram_ce falls, and which counter
//  it bumps used to be decided by addr[1] on THAT clock.  T80s still shows the
//  port address there; nz_bus (NextZ80 / R800) drops the strobes on the same
//  edge that puts the next stage's address on the bus, so the increment went to
//  addr2 whenever the following opcode address had bit 1 set -- the R800 read
//  the same JIS1 byte twice (INIR: "each new word lags"; a plain IN loop: byte 0
//  forever, "all 00").  sim/fullsys/tb_kanji.sv reproduces it; latch the counter
//  select while the read is in progress instead.
logic last_ce = 1'b0, last_sel = 1'b0;

always @(posedge clk) begin
   if (reset) begin
      addr1 <= 27'h00000;
      addr2 <= 27'h20000;
   end else begin
      if (kanji_en) begin
         if (cpu_wr) begin
            case (addr[1:0])
               2'd0: addr1 <= (addr1 & 27'h1f800) | ((27'(din) & 27'h3f) << 5 );
               2'd1: addr1 <= (addr1 & 27'h007e0) | ((27'(din) & 27'h3f) << 11);
               2'd2: addr2 <= (addr2 & 27'h3f800) | ((27'(din) & 27'h3f) << 5 );
               2'd3: addr2 <= (addr2 & 27'h207e0) | ((27'(din) & 27'h3f) << 11);
            endcase
         end
      end
      if (ram_ce) last_sel <= addr[1];
      if (last_ce & ~ram_ce) begin
         if (last_sel)
            addr2 <= (addr2 & ~27'h1f) | ((addr2 + 27'd1) & 27'h1f);
         else
            addr1 <= (addr1 & ~27'h1f) | ((addr1 + 27'd1) & 27'h1f);
      end
      last_ce <= ram_ce;
   end
end

endmodule