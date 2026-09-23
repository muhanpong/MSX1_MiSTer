//  nvram_backup: a LOAD request that arrives while reset is still asserted must
//  survive it.
//
//  `load_sram` is one clock wide and memory_upload raises it on the same edge its
//  FSM goes idle -- the edge `reset_rq` falls -- while MSX1.sv stretches the
//  machine reset 63 clk21m past that (`rst_hold`, 8d1d8bf).  Sampling the request
//  inside the `else` of `if (reset)` threw that pulse away, so a ROM load never
//  read its .sav; the OSD's SRAM Load kept working because that path has no
//  reset.  This is the same defect the flash_dirtysave T6 case covers, on the
//  other save engine -- the one every non-ASCII16X cart uses.
`timescale 1ns/1ps

module tb_nvram_load_reset;

import MSX::*;

reg clk = 0;
always #5 clk = ~clk;

reg          reset = 1;
reg          load_req = 0, save_req = 0;
reg    [3:0] img_mounted = 4'b0;
reg          img_readonly = 0;
reg   [63:0] img_size = 64'd0;
wire  [31:0] sd_lba[4];
wire   [3:0] sd_rd, sd_wr;
reg    [3:0] sd_ack = 4'b0;
wire   [7:0] sd_buff_din[4];
wire  [17:0] ram_addr;
wire         ram_we;
wire  [26:0] sdram_addr;
wire         sdram_req, sdram_rnw;
wire   [7:0] sdram_din;
wire         dma_active, dma_save;

lookup_SRAM_t lut[4];
initial for (int i = 0; i < 4; i++) lut[i] = '{addr: 18'd0, size: 16'd8};

nvram_backup dut
(
   .clk(clk), .reset(reset),
   .lookup_SRAM(lut),
   .load_req(load_req), .save_req(save_req),
   .img_mounted(img_mounted), .img_readonly(img_readonly), .img_size(img_size),
   .sd_lba(sd_lba), .sd_rd(sd_rd), .sd_wr(sd_wr), .sd_ack(sd_ack),
   .sd_buff_addr(14'd0), .sd_buff_dout(8'h00), .sd_buff_din(sd_buff_din),
   .ram_addr(ram_addr), .ram_we(ram_we), .ram_dout(8'h00),
   .flash16x_active(1'b0), .flash16x_base(27'd0), .flash16x_size(16'd0),
   .sdram_addr(sdram_addr), .sdram_req(sdram_req), .sdram_rnw(sdram_rnw),
   .sdram_din(sdram_din), .sdram_dout(8'h00), .sdram_ready(1'b1),
   .dma_active(dma_active), .dma_save(dma_save)
);

int errors = 0;
task check(input bit cond, input string name);
   if (cond) $display("PASS: %0s", name);
   else begin $display("FAIL: %0s", name); errors++; end
endtask

initial begin
   //  A mounted, writable save image on VD0, as the HPS gives after a ROM load.
   @(negedge clk); img_size = 64'd8192; img_mounted = 4'b0001;
   @(posedge clk); @(negedge clk); img_mounted = 4'b0000;

   //  The whole point: the pulse lands INSIDE the stretched reset.
   repeat (4) @(posedge clk);
   @(negedge clk); load_req = 1;
   @(posedge clk);
   @(negedge clk); load_req = 0;
   repeat (60) @(posedge clk);                       // rest of the 63-clock stretch
   check(dut.request_load !== 4'b0000, "load request survives the stretched reset");

   @(negedge clk); reset = 0;

   //  Once reset releases the engine must actually go and read a sector.
   begin
      int w = 0;
      while (sd_rd == 4'b0000 && w < 2000) begin @(posedge clk); w++; end
      check(w < 2000, "a read is issued after reset releases");
   end

   $display("RESULT: %0d error(s)", errors);
   if (errors) $fatal(1, "tb_nvram_load_reset FAILED");
   $finish;
end

endmodule
