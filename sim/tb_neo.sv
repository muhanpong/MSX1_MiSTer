// NEO-8 / NEO-16 mapper: the four points where the variants differ, the split
// 12-bit register write, the page-3 read/write asymmetry, and openMSX's
// mask-then-map bank bounding.  Also: mapper_detect's offset-16 signatures.
`timescale 1ns/1ps
import MSX::*;

module tb_neo;

reg clk=0; always #5 clk=~clk;
reg reset=1, mreq=0, wr=0, cs8=0, cs16=0, cart=0;
reg [15:0] a=0; reg [7:0] d=0;
wire un8, un16; wire [26:0] m8, m16;
reg [26:0] romsz = 27'h800000;   // 8MB

cart_neo #(.BANK16(0)) dut8  (.clk(clk),.reset(reset),.rom_size(romsz),.cpu_addr(a),.din(d),
   .cpu_mreq(mreq),.cpu_wr(wr),.cs(cs8),.cart_num(cart),.mem_unmaped(un8),.mem_addr(m8));
cart_neo #(.BANK16(1)) dut16 (.clk(clk),.reset(reset),.rom_size(romsz),.cpu_addr(a),.din(d),
   .cpu_mreq(mreq),.cpu_wr(wr),.cs(cs16),.cart_num(cart),.mem_unmaped(un16),.mem_addr(m16));

integer errors=0;
task check(input cond, input [200*8-1:0] name);
begin if(cond) $display("PASS: %0s",name); else begin $display("FAIL: %0s",name); errors=errors+1; end end
endtask
task wr8 (input [15:0] aa, input [7:0] dd); begin @(negedge clk); a=aa; d=dd; mreq=1; wr=1; cs8=1;  @(posedge clk); @(negedge clk); mreq=0; wr=0; cs8=0;  end endtask
task wr16(input [15:0] aa, input [7:0] dd); begin @(negedge clk); a=aa; d=dd; mreq=1; wr=1; cs16=1; @(posedge clk); @(negedge clk); mreq=0; wr=0; cs16=0; end endtask
// cs is a LEVEL in msx_slots (mapper-selected), so reads must assert it too.
task look16(input [15:0] aa); begin a=aa; cs16=1; cs8=0; #1; end endtask
task look8 (input [15:0] aa); begin a=aa; cs8=1; cs16=0; #1; end endtask

initial begin
  repeat(3) @(posedge clk); @(negedge clk); reset=0;

  // ---- reset state: every region at bank 0 ---------------------------------
  look16(16'h0000); check(m16==27'h0 && !un16, "16: reset region0 -> bank0");
  look16(16'h8123); check(m16==27'h0123 && !un16, "16: reset region2 offset");
  look8(16'hA234); check(m8==27'h0234 && !un8, "8: reset region5 offset");

  // ---- split 12-bit register: low byte, high nibble, independence ----------
  wr16(16'h2000, 8'h34);                      // region1 low
  wr16(16'h2001, 8'hF1);                      // region1 high nibble = 1 (0xF discarded)
  look16(16'h4000); check(m16==27'h134<<14, "16: split write assembles bank 0x134");
  wr16(16'h2000, 8'h56);
  look16(16'h4000); check(m16==27'h156<<14, "16: even write keeps the high nibble");

  // ---- window decode: odd bbb rejected on NEO-16, accepted on NEO-8 --------
  wr16(16'h1800, 8'h77);                      // bbb=3: NEO-16 must ignore
  look16(16'h0000); check(m16==27'h0, "16: odd-bbb write ignored");
  wr8 (16'h1800, 8'h05);                      // bbb=3 -> NEO-8 region1
  look8(16'h2000); check(m8==27'h5<<13, "8: bbb=3 programs region1");
  wr8 (16'h3800, 8'h07);                      // bbb=7 -> region5
  look8(16'hA000); check(m8==27'h7<<13, "8: bbb=7 programs region5");
  wr8 (16'h0800, 8'h3F);                      // bbb=1: below the windows
  look8(16'h0000); check(m8==27'h0, "8: bbb<2 write ignored");

  // ---- the windows repeat in page 3 (writes live, reads unmapped) ----------
  wr16(16'hD000, 8'h11);                      // 0xD000: bbb=2 -> region0
  look16(16'h0000); check(m16==27'h11<<14, "16: page-3 write programs region0");
  look16(16'hC000); check(un16, "16: page-3 read unmapped");
  look8(16'hC000); check(un8, "8: page-3 read unmapped");

  // ---- openMSX bounding: mask with nrBlocks-1, non-power-of-2 size ---------
  romsz = 27'd6<<14;                          // NEO-16: 6 blocks, mask=5
  wr16(16'h2000, 8'h0D); wr16(16'h2001, 8'h00); // bank 13 -> 13&5 = 5
  look16(16'h4000); check(m16==27'd5<<14 && !un16, "16: bank 13 & mask(5) -> 5");
  romsz = 27'h800000;

  // ---- cart_num independence ------------------------------------------------
  cart=1; wr16(16'h1000, 8'h22); look16(16'h0000);
  check(m16==27'h22<<14, "16: cart1 region0 = 0x22");
  cart=0; look16(16'h0000);
  check(m16==27'h11<<14, "16: cart0 untouched by cart1 write");

  $display("RESULT: %0d error(s)", errors);
  if (errors) $fatal(1, "tb_neo mapper FAILED");
  detect_go = 1;
end

// ================= mapper_detect: offset-16 signatures ======================
reg det_rst=1, det_wr=0, detect_go=0; reg [7:0] det_d=0;
wire mapper_typ_t det_map; wire [3:0] det_off; wire [7:0] det_mode, det_param;
mapper_detect u_det (.clk(clk), .rst(det_rst), .data(det_d), .wr(det_wr),
   .rom_size(27'h20000), .mapper(det_map), .offset(det_off), .mode(det_mode), .param(det_param));

task feed(input [7:0] b); begin @(negedge clk); det_d=b; det_wr=1; @(posedge clk); @(negedge clk); det_wr=0; end endtask
task stream(input [8*8-1:0] sig);
integer i;
begin
  @(negedge clk); det_rst=1; @(posedge clk); @(negedge clk); det_rst=0;
  feed("A"); feed("B");
  for (i=0;i<14;i=i+1) feed(8'h00);
  for (i=0;i<8;i=i+1) feed(sig[8*(7-i) +: 8]);
  for (i=0;i<40;i=i+1) feed(8'h00);
end
endtask

initial begin
  wait(detect_go);
  stream("ROM_NE16"); check(det_map==MAPPER_NEO16,    "det: ROM_NE16 -> NEO16");
  stream("ROM_NEO8"); check(det_map==MAPPER_NEO8,     "det: ROM_NEO8 -> NEO8");
  stream("ASCII16X"); check(det_map==MAPPER_ASCII16X, "det: ASCII16X -> ASCII16X");
  stream("NOTHING!"); check(det_map!=MAPPER_NEO16 && det_map!=MAPPER_NEO8 && det_map!=MAPPER_ASCII16X,
                            "det: no signature -> heuristic path");
  $display("RESULT: %0d error(s)", errors);
  if (errors) $fatal(1, "tb_neo FAILED");
  $finish;
end

endmodule
