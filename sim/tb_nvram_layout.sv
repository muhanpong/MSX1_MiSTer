//  nvram_backup image layout (docs/sram_images.md): VD0 raw from LBA 0; VD1 is
//  the SRAM file -- one 64 kB entry per SRAM kind, entry = kind - 1, header
//  sector at LBA 128n (magic "MSX1SRAM", version, kind, size, save counter),
//  data from LBA 128n + 8.  Banks 1..4 (slot A FM-PAC/GM2, slot B FM-PAC/GM2,
//  machine SRAM, RTC) all live in that one file.
//
//  The bench is an SD model: two images in memory, sd_rd/sd_wr served sector by
//  sector with the hps_io handshake (ack high while the 512 bytes stream,
//  sd_buff_addr counting), and a BRAM model behind ram_addr/ram_we (18-bit, so
//  the RTC bank at 20000h does not alias the SRAM).
//
//  T1  VD0 load: raw, sectors 0..15 -> BRAM
//  T2  FM-PAC (bank 1) load: entry 0, header at LBA 0 verified, data from LBA 8
//  T3  GameMaster2 (bank 1) load: entry 1 -> header LBA 128, data from LBA 136
//  T4  FS-A1GT (bank 3, 32 kB) load: entry 4 -> header LBA 512, data 520..583
//  T5  wrong magic: no data sectors are read, nothing lands in BRAM, request completes
//  T6  wrong kind in a valid header: same
//  T7  file too small for the entry: skipped, request completes, no reads
//  T8  save GM2: header written at LBA 128 with counter = old + 1, then data
//      at 136.. from BRAM; T9 save on a zero-filled file writes counter 1
//  T10 VD0 save still raw at LBA 0 (no header sector)
//  T11 RTC (bank 4): save -> entry 5 (header 640, kind 6, 1 kB), data from 20000h;
//      load puts it back
//  T12 FM-PAC in slot A AND slot B: only slot A's is saved to entry 0 and only
//      slot A's is loaded; slot B's BRAM is left alone
//  T13 FM-PAC in slot B alone: it IS saved (the save follows the cart)
//  T14 mounting the SRAM file loads every bank that has an entry in it
//  A1  autosave: a CPU write into bank 1 -> saved after the quiet time, bank 0
//      (allocated, not written) is not
//  A2  autosave off: the same write saves nothing
//  A3  writes that never stop are saved by the age limit
//  A4  flush (download / reset button) saves at once, before the quiet time;
//      guard is high while the bank is dirty and low once it is written
//  A5  an upload drops what was dirty: nothing is saved afterwards
//  A6  an RTC settings write saves bank 4
//  A7  a write outside every bank saves nothing
`timescale 1ns/1ps
import MSX::*;
module tb_nvram_layout;

logic clk = 0; always #23.3 clk = ~clk;
logic reset = 1;
lookup_SRAM_t lut[4];
logic load_req = 0, save_req = 0, upload_busy = 0;
logic autosave_en = 0, cpu_wr = 0, rtc_dirty = 0, flush = 0;
logic [17:0] cpu_wr_addr = 0;
logic  [1:0] img_mounted = 0;
logic        img_readonly = 0;
logic [63:0] img_size = 0;
wire  [31:0] sd_lba[2];
wire   [1:0] sd_rd, sd_wr;
logic  [1:0] sd_ack = 0;
logic [13:0] sd_buff_addr = 0;
logic  [7:0] sd_buff_dout = 0;
wire   [7:0] sd_buff_din[2];
wire  [17:0] ram_addr; wire ram_we; logic [7:0] ram_dout;
wire         guard;

localparam int QB = 13, AB = 17;           // quiet 4096 clocks, age 65536
nvram_backup #(.QUIET_BITS(QB), .AGE_BITS(AB)) dut (
   .clk(clk), .reset(reset), .lookup_SRAM(lut), .load_req(load_req), .save_req(save_req), .upload_busy(upload_busy),
   .autosave_en(autosave_en), .cpu_wr(cpu_wr), .cpu_wr_addr(cpu_wr_addr), .rtc_dirty(rtc_dirty), .flush(flush),
   .img_mounted(img_mounted), .img_readonly(img_readonly), .img_size(img_size),
   .sd_lba(sd_lba), .sd_rd(sd_rd), .sd_wr(sd_wr), .sd_ack(sd_ack),
   .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_din(sd_buff_din),
   .ram_addr(ram_addr), .ram_we(ram_we), .ram_dout(ram_dout),
   .flash16x_active(1'b0), .flash16x_base(27'd0), .flash16x_size(16'd0),
   .sdram_dout(8'h00), .sdram_ready(1'b1), .guard(guard));

//  ---- models
logic [7:0] bram [0:262143];
always @(posedge clk) if (ram_we) bram[ram_addr] <= sd_buff_dout;
assign ram_dout = bram[ram_addr];

localparam IMG_SECTORS = 768;                  // 384 kB: the whole SRAM file
logic [7:0] img [2][IMG_SECTORS*512];
int rd_log[2][$], wr_log[2][$];                // LBAs served, in order
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
      for (int n = 0; n < 2; n++) begin
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
function automatic int hdr_cnt(input int n, input int entry);
   int b; b = entry*128*512;
   return {img[n][b+15], img[n][b+14], img[n][b+13], img[n][b+12]};
endfunction
task automatic fill_data(input int n, input int first_lba, input int sectors, input byte seed);
   for (int i = 0; i < sectors*512; i++) img[n][first_lba*512 + i] = 8'(seed + i);
endtask
task automatic fill_bram(input int base, input int bytes, input byte seed);
   for (int i = 0; i < bytes; i++) bram[base + i] = 8'(seed + i);
endtask
task automatic clear_logs;
   for (int k = 0; k < 2; k++) begin rd_log[k].delete(); wr_log[k].delete(); end
endtask
//  Between tests: wipe images, logs and BRAM, the lookup, and drop the requests
//  still pending for banks with no SRAM (the engine keeps those for ~3 s by
//  design, so a later test would otherwise inherit them).  Autosave state too.
task automatic clear_all;
   for (int n = 0; n < 2; n++)
      for (int i = 0; i < IMG_SECTORS*512; i++) img[n][i] = 8'h00;
   clear_logs();
   for (int i = 0; i < 262144; i++) bram[i] = 8'h55;
   for (int i = 0; i < 4; i++) lut[i] = '{addr: 18'd0, size: 16'd0, kind: SRAM_KIND_RAW};
   autosave_en = 0;
   @(negedge clk); dut.request_load = '0; dut.request_save = '0; dut.pend_age = '0; dut.dirty = '0;
   @(negedge clk);
endtask
task automatic mount(input int n, input longint bytes);
   @(negedge clk); img_size = bytes; img_mounted = 2'(1 << n);
   @(negedge clk); img_mounted = 0;
endtask
//  wait until every request bit of a live bank is gone (served or expired)
task automatic settle(input int max_cycles);
   int w; logic [4:0] live; w = 0;
   for (int n = 0; n < 4; n++) live[n] = (lut[n].size != 0);
   live[4] = 1'b1;
   while ((((dut.request_load | dut.request_save) & live) != 0 || dut.state != 0 || busy) && w < max_cycles) begin @(posedge clk); w++; end
   repeat (20) @(posedge clk);
endtask
//  Mounting an image READS it (the firmware mounts without asking, and an image
//  that was never read got the previous data saved into it).  A save test
//  therefore mounts first, lets that load finish, and only then puts its pattern
//  in the BRAM -- the order a real session has.
task automatic mount_settled(input int n, input longint bytes);
   mount(n, bytes); settle(800000);
   clear_logs();
endtask
task automatic pulse_load;
   @(negedge clk); load_req = 1; @(negedge clk); load_req = 0;
endtask
task automatic pulse_save;
   @(negedge clk); save_req = 1; @(negedge clk); save_req = 0;
endtask
task automatic cpu_write(input int addr);
   @(negedge clk); cpu_wr_addr = 18'(addr); cpu_wr = 1; @(negedge clk); cpu_wr = 0;
endtask
//  wait for an autosave to fire and finish: past the quiet time, then settle
task automatic settle_auto;
   repeat ((1 << (QB-1)) + 200) @(negedge clk);
   settle(400000);
endtask
function automatic bit data_ok(input int n, input int first_lba, input int bytes, input int bram_base);
   for (int i = 0; i < bytes; i++) if (bram[bram_base + i] !== img[n][first_lba*512 + i]) return 0;
   return 1;
endfunction

localparam longint FILE_BYTES = 384*1024;

initial begin
   clear_all();
   repeat (5) @(negedge clk); reset = 0; repeat (5) @(negedge clk);

   //  T1 VD0 raw
   lut[0] = '{addr: 18'h0000, size: 16'd8, kind: SRAM_KIND_RAW};
   fill_data(0, 0, 16, 8'h10); mount(0, 8192);
   pulse_load(); settle(200000);
   check(rd_log[0].size() >= 16 && rd_log[0][0] == 0 && rd_log[0][15] == 15, "T1 VD0 raw: sectors 0..15 read");
   check(data_ok(0, 0, 8192, 0), "T1 VD0 raw: 8 kB landed in BRAM");

   //  T2 FM-PAC entry 0
   clear_all(); lut[1] = '{addr: 18'h2000, size: 16'd8, kind: SRAM_KIND_FMPAC};
   put_hdr(1, 0, SRAM_KIND_FMPAC, 8, 3); fill_data(1, 8, 16, 8'h20); mount(1, FILE_BYTES);
   settle(400000);
   check(rd_log[1].find_index with (item == 0).size() == 1 && rd_log[1].find_index with (item == 8).size() == 1
         && rd_log[1].find_index with (item == 23).size() == 1, "T2 FM-PAC: header LBA 0 then data 8..23");
   check(data_ok(1, 8, 8192, 18'h2000), "T2 FM-PAC: data at BRAM 2000h");
   check(bram[18'h2000 - 1] == 8'h55 && bram[18'h2000 + 8192] == 8'h55, "T2 header sector did not spill into BRAM");

   //  T3 GM2 entry 1
   clear_all(); lut[1] = '{addr: 18'h2000, size: 16'd8, kind: SRAM_KIND_GM2};
   put_hdr(1, 1, SRAM_KIND_GM2, 8, 1); fill_data(1, 136, 16, 8'h30); mount(1, FILE_BYTES);
   settle(400000);
   check(rd_log[1].find_index with (item == 128).size() == 1 && rd_log[1].find_index with (item == 136).size() == 1
         && rd_log[1].find_index with (item == 0).size() == 0, "T3 GM2: entry 1 -> header 128, data 136.., entry 0 not read");
   check(data_ok(1, 136, 8192, 18'h2000), "T3 GM2: data landed");

   //  T4 GT entry 4, 32 kB
   clear_all(); lut[3] = '{addr: 18'h4000, size: 16'd32, kind: SRAM_KIND_PAN32};
   put_hdr(1, 4, SRAM_KIND_PAN32, 32, 7); fill_data(1, 520, 64, 8'h40); mount(1, FILE_BYTES);
   settle(800000);
   check(rd_log[1].find_index with (item == 512).size() == 1 && rd_log[1].find_index with (item == 520).size() == 1
         && rd_log[1].find_index with (item == 583).size() == 1, "T4 GT: header 512, data 520..583");
   check(data_ok(1, 520, 32768, 18'h4000), "T4 GT: 32 kB landed");

   //  T5 wrong magic
   clear_all(); lut[3] = '{addr: 18'h4000, size: 16'd32, kind: SRAM_KIND_PAN32};
   put_hdr(1, 4, SRAM_KIND_PAN32, 32, 7); img[1][512*512] = "X"; fill_data(1, 520, 64, 8'h50); mount(1, FILE_BYTES);
   settle(800000);
   check(rd_log[1].find_index with (item == 520).size() == 0 && rd_log[1].find_index with (item == 512).size() == 1,
         "T5 wrong magic: only the GT header was read, no GT data");
   check(bram[18'h4000] == 8'h55, "T5 wrong magic: BRAM untouched");
   check(dut.request_load[3] == 1'b0, "T5 wrong magic: bank 3 request completed, not left pending");

   //  T6 wrong kind
   clear_all(); lut[3] = '{addr: 18'h4000, size: 16'd32, kind: SRAM_KIND_PAN32};
   put_hdr(1, 4, SRAM_KIND_PAN16, 32, 7); fill_data(1, 520, 64, 8'h60); mount(1, FILE_BYTES);
   settle(800000);
   check(rd_log[1].find_index with (item == 520).size() == 0 && bram[18'h4000] == 8'h55, "T6 wrong kind: header read, nothing loaded");

   //  T7 too small (entry 4 needs 520+64 sectors = 292 kB)
   clear_all(); lut[3] = '{addr: 18'h4000, size: 16'd32, kind: SRAM_KIND_PAN32};
   put_hdr(1, 4, SRAM_KIND_PAN32, 32, 7); mount(1, 192*1024);
   settle(800000);
   check(rd_log[1].find_index with (item == 512).size() == 0 && dut.request_load[3] == 1'b0,
         "T7 file too small: entry 4 not read, bank 3 request completed");

   //  T8 save GM2 with an existing header (counter 5)
   clear_all(); lut[1] = '{addr: 18'h2000, size: 16'd8, kind: SRAM_KIND_GM2};
   put_hdr(1, 1, SRAM_KIND_GM2, 8, 5); mount_settled(1, FILE_BYTES);
   fill_bram(18'h2000, 8192, 8'hA0);
   pulse_save(); settle(400000);
   check(rd_log[1].find_index with (item == 128).size() == 1, "T8 save: GM2 header read first (for the counter)");
   check(wr_log[1].find_index with (item == 128).size() == 1 && wr_log[1].find_index with (item == 136).size() == 1
         && wr_log[1].find_index with (item == 151).size() == 1, "T8 save: header 128 then data 136..151");
   check({img[1][128*512+0],img[1][128*512+7]} == {"M","M"} && img[1][128*512+9] == SRAM_KIND_GM2 && img[1][128*512+10] == 8'd8, "T8 save: header magic/kind/size written");
   check(hdr_cnt(1, 1) == 6, "T8 save: counter 5 -> 6");
   check(data_ok(1, 136, 8192, 18'h2000), "T8 save: data written from BRAM");
   check(img[1][8*512] == 8'h00, "T8 save: entry 0 (FM-PAC) untouched");

   //  T9 save on a zero-filled file
   clear_all(); lut[1] = '{addr: 18'h2000, size: 16'd8, kind: SRAM_KIND_GM2};
   mount_settled(1, FILE_BYTES);
   fill_bram(18'h2000, 8192, 8'hB0);
   pulse_save(); settle(400000);
   check(hdr_cnt(1, 1) == 1, "T9 save on blank file: GM2 header written with counter 1");
   check(data_ok(1, 136, 8192, 18'h2000), "T9 save on blank file: data written");

   //  T10 VD0 save stays raw
   clear_all(); lut[0] = '{addr: 18'h0000, size: 16'd8, kind: SRAM_KIND_RAW};
   mount_settled(0, 8192);
   fill_bram(0, 8192, 8'hC0);
   pulse_save(); settle(400000);
   check(wr_log[0].size() == 16 && wr_log[0][0] == 0 && rd_log[0].size() == 0, "T10 VD0 save: raw sectors 0..15, no header read");
   check(data_ok(0, 0, 8192, 0), "T10 VD0 save: data written");

   //  T11 RTC entry 5
   clear_all(); mount_settled(1, FILE_BYTES);
   fill_bram(18'h20000, 1024, 8'h07);
   pulse_save(); settle(400000);
   check(wr_log[1].size() == 3 && wr_log[1][0] == 640 && wr_log[1][1] == 648 && wr_log[1][2] == 649, "T11 RTC save: header 640, data 648..649");
   check(img[1][640*512+9] == SRAM_KIND_RTC && img[1][640*512+10] == 8'd1 && hdr_cnt(1, 5) == 1, "T11 RTC save: kind 6, 1 kB, counter 1");
   check(data_ok(1, 648, 1024, 18'h20000), "T11 RTC save: data from 20000h");
   for (int i = 0; i < 1024; i++) bram[18'h20000 + i] = 8'h55;
   clear_logs(); pulse_load(); settle(400000);
   check(data_ok(1, 648, 1024, 18'h20000), "T11 RTC load: back at 20000h");

   //  T12 FM-PAC in both slots: slot A owns entry 0
   clear_all();
   lut[1] = '{addr: 18'h2000, size: 16'd8, kind: SRAM_KIND_FMPAC};
   lut[2] = '{addr: 18'h4000, size: 16'd8, kind: SRAM_KIND_FMPAC};
   put_hdr(1, 0, SRAM_KIND_FMPAC, 8, 9); fill_data(1, 8, 16, 8'h11); mount(1, FILE_BYTES);
   settle(800000);
   check(data_ok(1, 8, 8192, 18'h2000), "T12 both FM-PAC: slot A loaded from entry 0");
   check(bram[18'h4000] == 8'h55 && bram[18'h4000 + 8191] == 8'h55, "T12 both FM-PAC: slot B BRAM not loaded");
   fill_bram(18'h2000, 8192, 8'hA1); fill_bram(18'h4000, 8192, 8'hB2);
   clear_logs(); pulse_save(); settle(800000);
   check(data_ok(1, 8, 8192, 18'h2000), "T12 both FM-PAC: entry 0 holds slot A's data");
   check(hdr_cnt(1, 0) == 10, "T12 both FM-PAC: entry 0 written once (counter 9 -> 10)");

   //  T13 FM-PAC in slot B alone
   clear_all(); lut[2] = '{addr: 18'h4000, size: 16'd8, kind: SRAM_KIND_FMPAC};
   mount_settled(1, FILE_BYTES);
   fill_bram(18'h4000, 8192, 8'hC3);
   pulse_save(); settle(400000);
   check(hdr_cnt(1, 0) == 1 && data_ok(1, 8, 8192, 18'h4000), "T13 slot B FM-PAC alone: saved to entry 0");

   //  T14 mount loads every bank with an entry
   clear_all();
   lut[1] = '{addr: 18'h2000, size: 16'd8, kind: SRAM_KIND_GM2};
   lut[3] = '{addr: 18'h4000, size: 16'd16, kind: SRAM_KIND_HALNOTE};
   put_hdr(1, 1, SRAM_KIND_GM2, 8, 1);      fill_data(1, 136, 16, 8'h21);
   put_hdr(1, 2, SRAM_KIND_HALNOTE, 16, 1); fill_data(1, 264, 32, 8'h43);
   put_hdr(1, 5, SRAM_KIND_RTC, 1, 1);      fill_data(1, 648, 2, 8'h65);
   mount(1, FILE_BYTES); settle(800000);
   check(data_ok(1, 136, 8192, 18'h2000), "T14 mount: GM2 loaded");
   check(data_ok(1, 264, 16384, 18'h4000), "T14 mount: Halnote loaded (entry 2)");
   check(data_ok(1, 648, 1024, 18'h20000), "T14 mount: RTC loaded (entry 5)");

   //  ---- autosave
   //  A1 write -> save after the quiet time, only the written bank
   clear_all();
   lut[0] = '{addr: 18'h0000, size: 16'd8, kind: SRAM_KIND_RAW};
   lut[1] = '{addr: 18'h2000, size: 16'd8, kind: SRAM_KIND_FMPAC};
   mount_settled(0, 8192); mount_settled(1, FILE_BYTES);
   autosave_en = 1;
   fill_bram(18'h2000, 8192, 8'hD4);
   cpu_write(18'h2010);
   repeat (2000) @(negedge clk);
   check(wr_log[1].size() == 0, "A1 autosave: nothing written before the quiet time");
   settle_auto();
   check(wr_log[1].size() == 17 && wr_log[1][0] == 0 && data_ok(1, 8, 8192, 18'h2000), "A1 autosave: FM-PAC written after the quiet time");
   check(wr_log[0].size() == 0, "A1 autosave: bank 0 (not written) not saved");

   //  A2 autosave off
   clear_all(); lut[1] = '{addr: 18'h2000, size: 16'd8, kind: SRAM_KIND_FMPAC};
   mount_settled(1, FILE_BYTES);
   cpu_write(18'h2010);
   repeat (20000) @(negedge clk);
   check(wr_log[1].size() == 0, "A2 autosave off: write saves nothing");

   //  A3 writes that never stop: the age limit saves them
   clear_all(); lut[1] = '{addr: 18'h2000, size: 16'd8, kind: SRAM_KIND_FMPAC};
   mount_settled(1, FILE_BYTES);
   autosave_en = 1;
   for (int k = 0; k < 90 && wr_log[1].size() == 0; k++) begin cpu_write(18'h2000 + k); repeat (1000) @(negedge clk); end
   check(wr_log[1].size() > 0, "A3 continuous writes: saved by the age limit");

   //  A4 flush saves at once; guard tracks the dirty bank
   clear_all(); lut[1] = '{addr: 18'h2000, size: 16'd8, kind: SRAM_KIND_FMPAC};
   mount_settled(1, FILE_BYTES);
   autosave_en = 1;
   cpu_write(18'h2020);
   repeat (10) @(negedge clk);
   check(guard == 1'b1, "A4 guard high while the bank is dirty");
   @(negedge clk); flush = 1;
   repeat (200) @(negedge clk);
   check(wr_log[1].size() > 0 || dut.wr, "A4 flush: save started before the quiet time");
   settle(400000); flush = 0;
   check(wr_log[1].size() == 17, "A4 flush: FM-PAC written");
   check(guard == 1'b0, "A4 guard low once it is written");

   //  A5 an upload drops what was dirty
   clear_all(); lut[1] = '{addr: 18'h2000, size: 16'd8, kind: SRAM_KIND_FMPAC};
   mount_settled(1, FILE_BYTES);
   autosave_en = 1;
   cpu_write(18'h2030);
   @(negedge clk); upload_busy = 1; repeat (100) @(negedge clk); upload_busy = 0;
   repeat (20000) @(negedge clk);
   check(wr_log[1].size() == 0, "A5 upload: dirty bank dropped, nothing saved");

   //  A6 RTC settings write
   clear_all(); mount_settled(1, FILE_BYTES);
   autosave_en = 1;
   @(negedge clk); rtc_dirty = 1; @(negedge clk); rtc_dirty = 0;
   settle_auto();
   check(wr_log[1].size() == 3 && wr_log[1][0] == 640, "A6 RTC write: bank 4 saved to entry 5");

   //  A7 a write outside every bank
   clear_all(); lut[1] = '{addr: 18'h2000, size: 16'd8, kind: SRAM_KIND_FMPAC};
   mount_settled(1, FILE_BYTES);
   autosave_en = 1;
   cpu_write(18'h4000);
   repeat (20000) @(negedge clk);
   check(wr_log[1].size() == 0, "A7 write outside every bank: nothing saved");

   $display("RESULT: %0d error(s)", errors);
   if (errors) $fatal(1, "tb_nvram_layout FAILED");
   $finish;
end
endmodule
