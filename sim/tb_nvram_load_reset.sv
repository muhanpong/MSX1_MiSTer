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

//  Each case starts from a known state.  Chaining them through the engine hid a
//  broken completion handshake: the first load sat in STATE_PROCESS for the rest
//  of the run, so every later case asserted against an engine that never reached
//  the decision it was supposed to be testing, and two deliberate mutations
//  still passed.  A reset returns the FSM to SLEEP; it deliberately does NOT
//  clear a pending request, so the bench clears those itself.
task restart;
   begin
      @(negedge clk); reset = 1; sd_ack = 4'b0000;
      repeat (4) @(posedge clk);
      @(negedge clk); reset = 0;
      dut.request_load = 4'b0; dut.request_save = 4'b0;
      repeat (2) @(posedge clk);
   end
endtask

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

   restart();

   //  T2 -- the request arrives BEFORE the image is mounted.  The engine looks
   //  at the bank, cannot act, and must keep the request rather than consume it.
   //  Consuming it is what makes an auto-load go missing: nothing asks again.
   @(negedge clk);
   for (int i = 0; i < 4; i++) begin dut.image_mounted[i] = 1'b0; dut.image_size[i] = 64'd0; end
   @(negedge clk); load_req = 1; @(posedge clk); @(negedge clk); load_req = 0;
   repeat (200) @(posedge clk);
   check(dut.request_load !== 4'b0000, "T2 a request for an unmounted image stays pending");

   //  and is served as soon as the image turns up.
   @(negedge clk); img_size = 64'd8192; img_mounted = 4'b0001;
   @(posedge clk); @(negedge clk); img_mounted = 4'b0000;
   begin
      int w = 0;
      while (sd_rd == 4'b0000 && w < 4000) begin @(posedge clk); w++; end
      check(w < 4000, "T2 and is served once the image is mounted");
   end
   restart();

   //  T3 -- a READ-ONLY image must still be readable.  Read-only is a reason not
   //  to write it, not a reason to skip the auto-load.
   @(negedge clk);
   for (int i = 0; i < 4; i++) begin dut.image_mounted[i] = 1'b0; dut.image_ro[i] = 1'b0; end
   img_readonly = 1; img_size = 64'd8192; img_mounted = 4'b0001;
   @(posedge clk); @(negedge clk); img_mounted = 4'b0000; img_readonly = 0;
   @(negedge clk); load_req = 1; @(posedge clk); @(negedge clk); load_req = 0;
   begin
      int w = 0;
      while (sd_rd == 4'b0000 && w < 4000) begin @(posedge clk); w++; end
      check(w < 4000, "T3 a read-only image is still loaded");
   end
   restart();

   //  T4 -- but a SAVE to it must not be attempted.  The image is still the
   //  read-only one mounted in T3.
   @(negedge clk); save_req = 1; @(posedge clk); @(negedge clk); save_req = 0;
   begin
      int w = 0;
      while (sd_wr == 4'b0000 && w < 3000) begin @(posedge clk); w++; end
      check(w >= 3000, "T4 a read-only image is never written");
   end

   $display("RESULT: %0d error(s)", errors);
   if (errors) $fatal(1, "tb_nvram_load_reset FAILED");
   $finish;
end

endmodule
