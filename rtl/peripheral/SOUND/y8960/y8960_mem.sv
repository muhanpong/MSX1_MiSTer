// Y8960 Cartridge: the ADPCM RAM (256 KB) in the SDRAM.
//
// The cartridge's memory is one 512 KB block of the SDRAM (memory_upload.sv pads the
// BIOS image to that size): 000000h BIOS ROM + RAM banks, 040000h ADPCM RAM.  The
// slot memory goes the CPU's way (ch2).  The ADPCM unit reads and writes on its own
// schedule, so it takes the upload channel (ch1), which is idle while the machine
// runs; the loader, the flash dump and the NVRAM backup keep their priority and stop
// the machine while they use it (MSX1.sv), so the ADPCM unit just waits.
//
// ch1 handshake (sdram_tdm.sv): a rising req latches the request and drops ready in
// the same clk_sdram cycle; ready returns with the data.  clk is clk21m.
//
// ADPCM side (upstream adpcm.v): valid is held until ready; a read then waits for
// rdata_en, which must come at least one clock after ready.

module y8960_mem
(
   input               clk,
   input               reset,
   input        [26:0] base,         // SDRAM address of the cartridge's block
   input               base_valid,   // the block is known (the cartridge has been accessed)
   input               ch1_busy,     // another ch1 client owns the channel
   // ADPCM unit
   input        [17:0] ya_addr,
   input               ya_valid,
   input               ya_write,
   input         [7:0] ya_wdata,
   output logic        ya_ready,
   output logic  [7:0] ya_rdata,
   output logic        ya_rdata_en,
   // SDRAM ch1
   output logic [26:0] sdram_addr,
   output logic  [7:0] sdram_din,
   output logic        sdram_req,
   output logic        sdram_rnw,
   input         [7:0] sdram_dout,
   input               sdram_ready
);

typedef enum logic [1:0] {S_IDLE, S_REQ, S_WAIT} state_t;
state_t state;
logic   rd;

always_ff @(posedge clk) begin
   ya_ready    <= 1'b0;
   ya_rdata_en <= 1'b0;
   sdram_req   <= 1'b0;
   if (reset) begin
      state <= S_IDLE;
   end else case (state)
      S_IDLE: if (ya_valid & ~ya_ready & base_valid & ~ch1_busy & sdram_ready) begin
         sdram_addr <= base + 27'h40000 + 27'(ya_addr);
         sdram_din  <= ya_wdata;
         sdram_rnw  <= ~ya_write;
         sdram_req  <= 1'b1;
         rd         <= ~ya_write;
         ya_ready   <= 1'b1;
         state      <= S_REQ;
      end
      S_REQ:  state <= S_WAIT;            // ready has dropped by now (6 clk_sdram per clk)
      S_WAIT: if (sdram_ready) begin
         ya_rdata    <= sdram_dout;
         ya_rdata_en <= rd;
         state       <= S_IDLE;
      end
      default: state <= S_IDLE;
   endcase
end

endmodule
