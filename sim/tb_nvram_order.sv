//  tb_nvram_order -- nvram_backup must never write the wrong BRAM contents into an
//  image: not the fill pattern of an upload, not the previous image's data.
//
//  Same SD model as tb_nvram_layout (four in-memory images served with the hps_io
//  handshake) and a BRAM behind ram_addr/ram_we.  One SRAM: bank 1, FM-PAC, 8 kB,
//  VD1 entry 0 (header LBA 0, data LBA 8..23).
//
//  O1  load before save.  After an upload the BRAM holds the fill pattern until the
//      load has run.  A load and a save asked for together (SRAM Save, or an OSD
//      autosave, right after the upload's own load request) must load first: the
//      image keeps its data.  Served save-first, the fill pattern lands in it.
//  O2  nothing moves while memory_upload rebuilds the layout.  A save asked for
//      during the upload (autosave when the OSD opens mid-load) is not served in
//      it, and not afterwards either; the image keeps its data and no sector is
//      written.
//  O3  a newly mounted image is read.  BRAM holds data from image X; image Y is
//      mounted on the same VD (an OSD pick); the next save must write Y's data
//      back, not X's.  Before: mounting read nothing, so X went into Y.
//  O4  guard -- what save_guard holds a reset or an upload on -- stays high from
//      the save request to the end of the LAST bank's transfer, with no gap
//      between banks (an upload starting in a gap refills the BRAM under the
//      second bank's save), and drops when all is done.
//
//  Mutants are made by run_nvram_order.sh; each must fail its own case.
`timescale 1ns/1ps
import MSX::*;
module tb_nvram_order;

logic clk = 0; always #23.3 clk = ~clk;
logic reset = 1;
lookup_SRAM_t lut[4];
logic load_req = 0, save_req = 0, upload_busy = 0;
logic  [3:0] img_mounted = 0;
logic        img_readonly = 0;
logic [63:0] img_size = 0;
wire  [31:0] sd_lba[4];
wire   [3:0] sd_rd, sd_wr;
logic  [3:0] sd_ack = 0;
logic [13:0] sd_buff_addr = 0;
logic  [7:0] sd_buff_dout = 0;
wire   [7:0] sd_buff_din[4];
wire  [17:0] ram_addr; wire ram_we; logic [7:0] ram_dout;
wire         guard;

nvram_backup dut (
   .clk(clk), .reset(reset), .lookup_SRAM(lut), .load_req(load_req), .save_req(save_req),
   .upload_busy(upload_busy),
   .img_mounted(img_mounted), .img_readonly(img_readonly), .img_size(img_size),
   .sd_lba(sd_lba), .sd_rd(sd_rd), .sd_wr(sd_wr), .sd_ack(sd_ack),
   .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_din(sd_buff_din),
   .ram_addr(ram_addr), .ram_we(ram_we), .ram_dout(ram_dout),
   .flash16x_active(1'b0), .flash16x_base(27'd0), .flash16x_size(16'd0),
   .sdram_dout(8'h00), .sdram_ready(1'b1), .guard(guard));

//  ---- models (as tb_nvram_layout)
logic [7:0] bram [0:65535];
always @(posedge clk) if (ram_we) bram[ram_addr[15:0]] <= sd_buff_dout;
assign ram_dout = bram[ram_addr[15:0]];

localparam IMG_SECTORS = 512;
logic [7:0] img [4][IMG_SECTORS*512];
int rd_log[4][$], wr_log[4][$];
int busy = 0;

task automatic serve(input int n, input bit is_wr);
   int lba; lba = sd_lba[n];
   if (is_wr) wr_log[n].push_back(lba); else rd_log[n].push_back(lba);
   busy = 1;
   @(negedge clk); sd_ack[n] = 1;
   for (int i = 0; i < 512; i++) begin
      sd_buff_addr = 14'(i);
      if (!is_wr) sd_buff_dout = (lba < IMG_SECTORS) ? img[n][lba*512 + i] : 8'hEE;
      @(negedge clk);
      if (is_wr && lba < IMG_SECTORS) img[n][lba*512 + i] = sd_buff_din[n];
   end
   sd_ack[n] = 0; sd_buff_addr = 0; busy = 0;
   @(negedge clk);
endtask

always @(posedge clk) begin
   if (!busy) begin
      for (int n = 0; n < 4; n++) begin
         if (sd_rd[n] && !busy) serve(n, 0);
         else if (sd_wr[n] && !busy) serve(n, 1);
      end
   end
end

//  ---- helpers
int errors = 0;
task check(input bit cond, input string name);
   if (cond) $display("PASS: %s", name); else begin $display("FAIL: %s", name); errors++; end
endtask
task automatic put_hdr(input int n, input int entry, input byte kind, input int size_kb);
   int b; b = entry*128*512;
   for (int i = 0; i < 512; i++) img[n][b+i] = 8'h00;
   {img[n][b+0],img[n][b+1],img[n][b+2],img[n][b+3],img[n][b+4],img[n][b+5],img[n][b+6],img[n][b+7]} = "MSX1SRAM";
   img[n][b+8] = 8'd1; img[n][b+9] = kind;
   img[n][b+10] = size_kb[7:0]; img[n][b+11] = size_kb[15:8]; img[n][b+12] = 8'd1;
endtask
task automatic fill_img(input int n, input int first_lba, input int bytes, input byte seed);
   for (int i = 0; i < bytes; i++) img[n][first_lba*512 + i] = 8'(seed + i);
endtask
task automatic fill_bram(input int base, input int bytes, input byte v);
   for (int i = 0; i < bytes; i++) bram[base + i] = v;
endtask
function automatic bit img_is(input int n, input int first_lba, input int bytes, input byte seed);
   for (int i = 0; i < bytes; i++) if (img[n][first_lba*512 + i] !== 8'(seed + i)) return 0;
   return 1;
endfunction
function automatic bit bram_is(input int base, input int bytes, input byte seed);
   for (int i = 0; i < bytes; i++) if (bram[base + i] !== 8'(seed + i)) return 0;
   return 1;
endfunction
function automatic bit img_all(input int n, input int first_lba, input int bytes, input byte v);
   for (int i = 0; i < bytes; i++) if (img[n][first_lba*512 + i] !== v) return 0;
   return 1;
endfunction
task automatic clear_logs;
   for (int k = 0; k < 4; k++) begin rd_log[k].delete(); wr_log[k].delete(); end
endtask
task automatic mount(input int n, input longint bytes);
   @(negedge clk); img_size = bytes; img_mounted = 4'(1 << n);
   @(negedge clk); img_mounted = 0;
endtask
//  idle = nothing in flight and nothing servable pending; bounded
task automatic settle(input int max_cycles);
   int w; w = 0;
   repeat (4) @(posedge clk);
   while ((busy || dut.state != 0 || dut.wr || dut.rd ||
           ((dut.request_load & dut.can_load) | (dut.request_save & dut.can_save)) != 0) && w < max_cycles) begin
      @(posedge clk); w++;
   end
   repeat (20) @(posedge clk);
endtask
task automatic reset_engine;
   @(negedge clk); dut.request_load = 4'b0; dut.request_save = 4'b0; dut.pend_age = '0;
   @(negedge clk);
endtask

localparam int B1 = 18'h2000, SZ = 8192, DATA_LBA = 8;

initial begin
   for (int i = 0; i < 4; i++) lut[i] = '{addr: 18'd0, size: 16'd0, kind: SRAM_KIND_RAW};
   for (int n = 0; n < 4; n++) for (int i = 0; i < IMG_SECTORS*512; i++) img[n][i] = 8'h00;
   for (int i = 0; i < 65536; i++) bram[i] = 8'h55;
   repeat (5) @(negedge clk); reset = 0; repeat (5) @(negedge clk);
   reset_engine();
   lut[1] = '{addr: B1, size: 16'd8, kind: SRAM_KIND_FMPAC};

   //  ---- O1 load before save
   put_hdr(1, 0, SRAM_KIND_FMPAC, 8); fill_img(1, DATA_LBA, SZ, 8'h31);
   mount(1, 256*1024); settle(800000);
   check(bram_is(B1, SZ, 8'h31), "O1 setup: mounting VD1 loaded its data");
   //  an upload rebuilds the BRAM: fill pattern, then its own load request
   @(negedge clk); upload_busy = 1; fill_bram(B1, SZ, 8'hFF);
   repeat (50) @(negedge clk); upload_busy = 0;
   clear_logs();
   @(negedge clk); load_req = 1; save_req = 1; @(negedge clk); load_req = 0; save_req = 0;
   settle(800000);
   check(img_is(1, DATA_LBA, SZ, 8'h31), "O1 load+save together after an upload: image keeps its data");
   check(bram_is(B1, SZ, 8'h31), "O1 BRAM holds the image data again");
   check(rd_log[1].size() > 0, "O1 a load was served");

   //  ---- O2 nothing moves while memory_upload rebuilds the layout
   reset_engine(); clear_logs();
   @(negedge clk); upload_busy = 1;
   @(negedge clk); save_req = 1; @(negedge clk); save_req = 0;        // autosave mid-upload
   fill_bram(B1, SZ, 8'hFF);                                           // the refill
   repeat (40000) @(negedge clk);
   check(wr_log[1].size() == 0, "O2 no sector written while the upload runs");
   upload_busy = 0;
   settle(800000);
   check(wr_log[1].size() == 0, "O2 the save asked for during the upload is not served after it");
   check(img_is(1, DATA_LBA, SZ, 8'h31), "O2 image keeps its data");

   //  ---- O3 a newly mounted image is read
   reset_engine(); clear_logs();
   fill_bram(B1, SZ, 8'h00); for (int i = 0; i < SZ; i++) bram[B1 + i] = 8'(8'h71 + i);   // X, from an earlier image
   put_hdr(1, 0, SRAM_KIND_FMPAC, 8); fill_img(1, DATA_LBA, SZ, 8'hA5);                 // Y, the file picked now
   mount(1, 256*1024); settle(800000);
   check(bram_is(B1, SZ, 8'hA5), "O3 mounting image Y loads Y into the BRAM");
   @(negedge clk); save_req = 1; @(negedge clk); save_req = 0; settle(800000);
   check(img_is(1, DATA_LBA, SZ, 8'hA5), "O3 the next save writes Y's data back, not the earlier X");

   //  ---- O4 guard spans the whole save, across banks
   reset_engine(); clear_logs();
   lut[3] = '{addr: 18'h8000, size: 16'd16, kind: SRAM_KIND_HALNOTE};
   put_hdr(3, 0, SRAM_KIND_HALNOTE, 16); mount(3, 256*1024); settle(800000);
   clear_logs();
   begin
      int gaps, highs, w; bit seen_done;
      gaps = 0; highs = 0; w = 0;
      @(negedge clk); save_req = 1; @(negedge clk); save_req = 0;
      @(posedge clk); @(posedge clk);
      //  until both banks have written their data (header + data sectors)
      while (!(wr_log[1].size() >= 1 + 16 && wr_log[3].size() >= 1 + 32) && w < 2000000) begin
         @(posedge clk); w++;
         if (guard) highs++; else gaps++;
      end
      $display("  O4: %0d cycles high, %0d low, before both saves finished", highs, gaps);
      check(gaps == 0 && highs > 0, "O4 guard high from the request to the end of the last bank");
      settle(800000);
      check(guard == 1'b0, "O4 guard low once everything is done");
   end

   $display("RESULT: %0d error(s)", errors);
   if (errors) $fatal(1, "tb_nvram_order FAILED");
   $finish;
end
endmodule
