//  nvram_backup image layout (docs/sram_images.md): VD0 raw from LBA 0; VD1..3
//  hold one 64 kB entry per SRAM kind -- header sector at LBA 128n (magic
//  "MSX1SRAM", version, kind, size, save counter), data from LBA 128n + 8.
//
//  The bench is an SD model: four images in memory, sd_rd/sd_wr served sector
//  by sector with the hps_io handshake (ack high while the 512 bytes stream,
//  sd_buff_addr counting), and a BRAM model behind ram_addr/ram_we.
//
//  T1  VD0 load: raw, sectors 0..15 -> BRAM
//  T2  VD1 FM-PAC load: header at LBA 0 verified, data from LBA 8
//  T3  VD1 GameMaster2 load: entry 1 -> header LBA 128, data from LBA 136
//  T4  VD3 FS-A1GT (32 kB) load: entry 2 -> header LBA 256, data from 264, 64 sectors
//  T5  wrong magic: no data sectors are read, nothing lands in BRAM, request completes
//  T6  wrong kind in a valid header: same
//  T7  image too small for the entry: skipped, request completes, no reads
//  T8  save VD1 GM2: header written at LBA 128 with counter = old + 1, then data
//      at 136.. from BRAM; T9 save on a zero-filled image writes counter 1
//  T10 VD0 save still raw at LBA 0 (no header sector)
`timescale 1ns/1ps
import MSX::*;
module tb_nvram_layout;

logic clk = 0; always #23.3 clk = ~clk;
logic reset = 1;
lookup_SRAM_t lut[4];
logic load_req = 0, save_req = 0;
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

nvram_backup dut (
   .clk(clk), .reset(reset), .lookup_SRAM(lut), .load_req(load_req), .save_req(save_req), .upload_busy(1'b0),
   .img_mounted(img_mounted), .img_readonly(img_readonly), .img_size(img_size),
   .sd_lba(sd_lba), .sd_rd(sd_rd), .sd_wr(sd_wr), .sd_ack(sd_ack),
   .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_din(sd_buff_din),
   .ram_addr(ram_addr), .ram_we(ram_we), .ram_dout(ram_dout),
   .flash16x_active(1'b0), .flash16x_base(27'd0), .flash16x_size(16'd0),
   .sdram_dout(8'h00), .sdram_ready(1'b1));

//  ---- models
logic [7:0] bram [0:65535];
always @(posedge clk) if (ram_we) bram[ram_addr[15:0]] <= sd_buff_dout;
assign ram_dout = bram[ram_addr[15:0]];

localparam IMG_SECTORS = 512;                  // 256 kB per image
logic [7:0] img [4][IMG_SECTORS*512];
int rd_log[4][$], wr_log[4][$];                // LBAs served, in order
int busy = 0;

//  serve one sector: 512 clocks of ack with the buffer address counting
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
task automatic put_hdr(input int n, input int entry, input byte kind, input int size_kb, input int cnt);
   int b; b = entry*128*512;
   {img[n][b+0],img[n][b+1],img[n][b+2],img[n][b+3],img[n][b+4],img[n][b+5],img[n][b+6],img[n][b+7]} = "MSX1SRAM";
   img[n][b+8] = 8'd1; img[n][b+9] = kind;
   img[n][b+10] = size_kb[7:0]; img[n][b+11] = size_kb[15:8];
   img[n][b+12] = cnt[7:0]; img[n][b+13] = cnt[15:8]; img[n][b+14] = cnt[23:16]; img[n][b+15] = cnt[31:24];
endtask
task automatic fill_data(input int n, input int first_lba, input int sectors, input byte seed);
   for (int i = 0; i < sectors*512; i++) img[n][first_lba*512 + i] = 8'(seed + i);
endtask
//  Between tests: wipe images, logs and BRAM, and drop the requests still
//  pending for banks with no SRAM (the engine keeps those for ~3 s by design,
//  so a later test would otherwise inherit them).
task automatic clear_all;
   for (int n = 0; n < 4; n++) begin
      for (int i = 0; i < IMG_SECTORS*512; i++) img[n][i] = 8'h00;
      rd_log[n].delete(); wr_log[n].delete();
   end
   for (int i = 0; i < 65536; i++) bram[i] = 8'h55;
   @(negedge clk); dut.request_load = 4'b0; dut.request_save = 4'b0; dut.pend_age = '0;
   @(negedge clk);
endtask
task automatic mount(input int n, input longint bytes);
   @(negedge clk); img_size = bytes; img_mounted = 4'(1 << n);
   @(negedge clk); img_mounted = 0;
endtask
//  Mounting an image now READS it (nvram_backup, 2026-10-04: the firmware mounts
//  without asking, and an image that was never read got the previous data saved
//  into it).  A save test therefore mounts first, lets that load finish, and only
//  then puts its pattern in the BRAM -- the order a real session has.
task automatic mount_settled(input int n, input longint bytes);
   mount(n, bytes); settle(400000);
   for (int k = 0; k < 4; k++) begin rd_log[k].delete(); wr_log[k].delete(); end
endtask
task automatic pulse_load;
   @(negedge clk); load_req = 1; @(negedge clk); load_req = 0;
endtask
task automatic pulse_save;
   @(negedge clk); save_req = 1; @(negedge clk); save_req = 0;
endtask
//  wait until every request bit is gone (served or expired); bound it
task automatic settle(input int max_cycles);
   int w; logic [3:0] live; w = 0;
   for (int n = 0; n < 4; n++) live[n] = (lut[n].size != 0);
   while (((dut.request_load | dut.request_save) & live) != 0 && w < max_cycles) begin @(posedge clk); w++; end
   repeat (20) @(posedge clk);
endtask
function automatic bit data_ok(input int n, input int first_lba, input int bytes, input int bram_base);
   for (int i = 0; i < bytes; i++) if (bram[bram_base + i] !== img[n][first_lba*512 + i]) return 0;
   return 1;
endfunction
function automatic bit img_eq_bram(input int n, input int first_lba, input int bytes, input int bram_base);
   for (int i = 0; i < bytes; i++) if (img[n][first_lba*512 + i] !== bram[bram_base + i]) return 0;
   return 1;
endfunction

initial begin
   for (int i = 0; i < 4; i++) lut[i] = '{addr: 18'd0, size: 16'd0, kind: SRAM_KIND_RAW};
   clear_all();
   repeat (5) @(negedge clk); reset = 0; repeat (5) @(negedge clk);

   //  T1 VD0 raw
   lut[0] = '{addr: 18'h0000, size: 16'd8, kind: SRAM_KIND_RAW};
   fill_data(0, 0, 16, 8'h10); mount(0, 8192);
   pulse_load(); settle(200000);
   check(rd_log[0].size() == 16 && rd_log[0][0] == 0 && rd_log[0][15] == 15, "T1 VD0 raw: sectors 0..15 read");
   check(data_ok(0, 0, 8192, 0), "T1 VD0 raw: 8 kB landed in BRAM");
   lut[0].size = 0;

   //  T2 VD1 FM-PAC entry 0
   clear_all(); lut[1] = '{addr: 18'h2000, size: 16'd8, kind: SRAM_KIND_FMPAC};
   put_hdr(1, 0, SRAM_KIND_FMPAC, 8, 3); fill_data(1, 8, 16, 8'h20); mount(1, 64*1024);
   pulse_load(); settle(200000);
   check(rd_log[1].size() == 17 && rd_log[1][0] == 0 && rd_log[1][1] == 8 && rd_log[1][16] == 23, "T2 VD1 FM-PAC: header LBA 0 then data 8..23");
   check(data_ok(1, 8, 8192, 18'h2000), "T2 VD1 FM-PAC: data at BRAM 2000h");
   check(bram[18'h2000 - 1] == 8'h55 && bram[18'h2000 + 8192] == 8'h55, "T2 header sector did not spill into BRAM");

   //  T3 VD1 GM2 entry 1
   clear_all(); lut[1] = '{addr: 18'h2000, size: 16'd8, kind: SRAM_KIND_GM2};
   put_hdr(1, 1, SRAM_KIND_GM2, 8, 1); fill_data(1, 136, 16, 8'h30); mount(1, 128*1024);
   pulse_load(); settle(200000);
   check(rd_log[1].size() == 17 && rd_log[1][0] == 128 && rd_log[1][1] == 136, "T3 VD1 GM2: entry 1 -> header 128, data 136..");
   check(data_ok(1, 136, 8192, 18'h2000), "T3 VD1 GM2: data landed");
   lut[1].size = 0;

   //  T4 VD3 GT entry 2, 32 kB
   clear_all(); lut[3] = '{addr: 18'h4000, size: 16'd32, kind: SRAM_KIND_PAN32};
   put_hdr(3, 2, SRAM_KIND_PAN32, 32, 7); fill_data(3, 264, 64, 8'h40); mount(3, 192*1024);
   pulse_load(); settle(400000);
   check(rd_log[3].size() == 65 && rd_log[3][0] == 256 && rd_log[3][1] == 264 && rd_log[3][64] == 327, "T4 VD3 GT: header 256, data 264..327");
   check(data_ok(3, 264, 32768, 18'h4000), "T4 VD3 GT: 32 kB landed");

   //  T5 wrong magic
   clear_all(); put_hdr(3, 2, SRAM_KIND_PAN32, 32, 7); img[3][256*512] = "X"; fill_data(3, 264, 64, 8'h50); mount(3, 192*1024);
   pulse_load(); settle(400000);
   check(rd_log[3].size() == 1, "T5 wrong magic: only the header was read");
   check(bram[18'h4000] == 8'h55, "T5 wrong magic: BRAM untouched");
   check(dut.request_load[3] == 1'b0, "T5 wrong magic: bank 3 request completed, not left pending");

   //  T6 wrong kind
   clear_all(); put_hdr(3, 2, SRAM_KIND_PAN16, 32, 7); fill_data(3, 264, 64, 8'h60); mount(3, 192*1024);
   pulse_load(); settle(400000);
   check(rd_log[3].size() == 1 && bram[18'h4000] == 8'h55, "T6 wrong kind: header read, nothing loaded");

   //  T7 too small (entry 2 needs 264+64 sectors = 164 kB)
   clear_all(); put_hdr(3, 2, SRAM_KIND_PAN32, 32, 7); mount(3, 64*1024);
   pulse_load(); settle(400000);
   check(rd_log[3].size() == 0 && dut.request_load[3] == 1'b0, "T7 image too small: no reads, bank 3 request completed");
   lut[3].size = 0;

   //  T8 save VD1 GM2 with an existing header (counter 5)
   clear_all(); lut[1] = '{addr: 18'h2000, size: 16'd8, kind: SRAM_KIND_GM2};
   put_hdr(1, 1, SRAM_KIND_GM2, 8, 5); mount_settled(1, 128*1024);
   for (int i = 0; i < 8192; i++) bram[18'h2000 + i] = 8'(8'hA0 + i);
   pulse_save(); settle(200000);
   check(rd_log[1].size() == 1 && rd_log[1][0] == 128, "T8 save: header read first (for the counter)");
   check(wr_log[1].size() == 17 && wr_log[1][0] == 128 && wr_log[1][1] == 136 && wr_log[1][16] == 151, "T8 save: header 128 then data 136..151");
   check({img[1][128*512+0],img[1][128*512+7]} == {"M","M"} && img[1][128*512+9] == SRAM_KIND_GM2 && img[1][128*512+10] == 8'd8, "T8 save: header magic/kind/size written");
   check({img[1][128*512+15],img[1][128*512+14],img[1][128*512+13],img[1][128*512+12]} == 32'd6, "T8 save: counter 5 -> 6");
   check(img_eq_bram(1, 136, 8192, 18'h2000), "T8 save: data written from BRAM");
   check(img[1][8*512] == 8'h00, "T8 save: entry 0 (FM-PAC) untouched");

   //  T9 save on a zero-filled image
   clear_all(); mount_settled(1, 128*1024);
   for (int i = 0; i < 8192; i++) bram[18'h2000 + i] = 8'(8'hB0 + i);
   pulse_save(); settle(200000);
   check(wr_log[1].size() == 17 && {img[1][128*512+15],img[1][128*512+14],img[1][128*512+13],img[1][128*512+12]} == 32'd1, "T9 save on blank image: header written with counter 1");
   check(img_eq_bram(1, 136, 8192, 18'h2000), "T9 save on blank image: data written");
   lut[1].size = 0;

   //  T10 VD0 save stays raw
   clear_all(); lut[0] = '{addr: 18'h0000, size: 16'd8, kind: SRAM_KIND_RAW};
   mount_settled(0, 8192);
   for (int i = 0; i < 8192; i++) bram[i] = 8'(8'hC0 + i);
   pulse_save(); settle(200000);
   check(wr_log[0].size() == 16 && wr_log[0][0] == 0 && rd_log[0].size() == 0, "T10 VD0 save: raw sectors 0..15, no header read");
   check(img_eq_bram(0, 0, 8192, 0), "T10 VD0 save: data written");

   $display("RESULT: %0d error(s)", errors);
   if (errors) $fatal(1, "tb_nvram_layout FAILED");
   $finish;
end
endmodule
