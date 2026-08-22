// tb_flash_seam — cart_yamanooto + flash.sv together, wired as msx_slots.sv wires them
//
// The per-cart TBs each stub the other side, so nothing covered the seam where
// the mapper's flash_rq drives the SHARED flash command FSM.  That is exactly
// where the real defect lived: flash_rq had no WREN term, so an ordinary cart
// write walked flash.sv into CFI / autoselect / erase with WREN clear.
//
// The trigger is not contrived.  `LD (0x50AA),A` with A=0x98 is a legitimate K5
// bank-register write (0x50AA has cpu_addr[12:11]==2'b10, yamanooto.sv bank_k5;
// openMSX agrees, Yamanooto.cc setMapper) carrying an ordinary segment number.
// flash.sv enters CFI on din==0x98 at word offset 0x055 -- which 0x50AA is.
// Worse, flash.sv has no system reset: `reset` there is an internal wire meaning
// "an F0 command arrived", so a wedged cart does NOT recover on MSX reset.
//
//   S1  a legitimate K5 bank write must not enter CFI
//   S2  autoselect (AA/55/90) with WREN clear must not wedge the read path
//   S3  an erase sequence with WREN clear must not touch SDRAM
//
// Negative control (NEGCTL=1) strips the `& (cpu_rd | flash_wr_en)` term from a
// /tmp copy of yamanooto.sv; all three MUST then fire.
`timescale 1ns/1ps
`default_nettype none
module tb_flash_seam;
   logic clk=0, reset=1;
   logic [15:0] cpu_addr=0; logic [7:0] din=0;
   logic cpu_mreq=0, cpu_wr=0, cpu_rd=0, cs=1, cart_num=0;
   logic [24:0] mem_size = 25'(8*1024*1024);
   wire mem_unmaped, cart_dout_en, scc_req, flash_wr_en, y_flash_rq, prog_we;
   wire [24:0] mem_addr; wire [7:0] cart_dout; wire [1:0] scc_mode; wire [22:0] y_flash_addr;
   cart_yamanooto yam(.clk(clk),.reset(reset),.mem_size(mem_size),.cpu_addr(cpu_addr),
      .din(din),.cpu_mreq(cpu_mreq),.cpu_wr(cpu_wr),.cpu_rd(cpu_rd),.cs(cs),.cart_num(cart_num),
      .mem_unmaped(mem_unmaped),.mem_addr(mem_addr),.cart_dout(cart_dout),.cart_dout_en(cart_dout_en),
      .scc_req(scc_req),.scc_mode(scc_mode),.flash_wr_en(flash_wr_en),.flash_addr(y_flash_addr),
      .flash_rq(y_flash_rq),.prog_we(prog_we));
   // msx_slots.sv 와 동일하게 배선
   wire [7:0] fl_dout; wire fl_dv;
   logic sdram_ready=1, sdram_done=0;
   wire [26:0] fl_sdram_addr; wire [7:0] fl_sdram_din; wire fl_sdram_req; wire dbg_erase;
   wire own_rq = y_flash_rq;
   flash fl(.clk(clk),.clk_sdram(clk),.addr(23'(y_flash_addr)),.din(din),.dout(fl_dout),
      .data_valid(fl_dv),.we(cpu_mreq & cpu_wr),.ce(y_flash_rq),
      .sdram_ready(sdram_ready),.sdram_done(sdram_done),
      .sdram_addr(fl_sdram_addr),.sdram_din(fl_sdram_din),.sdram_req(fl_sdram_req),
      .sdram_offset(27'h400000),.amd_family(own_rq),.boot_sector(1'b0),
      .erase_limit(27'h800000),.debug_erase(dbg_erase));
   always #5 clk=~clk;
   always @(posedge clk) sdram_done <= fl_sdram_req;
   task automatic w(input [15:0] a, input [7:0] d);
      begin @(negedge clk); cpu_addr=a; din=d; cpu_mreq=1; cpu_wr=1; cpu_rd=0;
            repeat(3) @(posedge clk); @(negedge clk); cpu_mreq=0; cpu_wr=0; repeat(2) @(posedge clk); end
   endtask
   task automatic rd(input [15:0] a, output [7:0] v, output bit dv);
      begin @(negedge clk); cpu_addr=a; cpu_mreq=1; cpu_rd=1; cpu_wr=0;
            repeat(2) @(posedge clk); v=fl_dout; dv=fl_dv;
            @(negedge clk); cpu_mreq=0; cpu_rd=0; repeat(2) @(posedge clk); end
   endtask
   logic [7:0] v; bit dv; int bad=0;
   initial begin
      repeat(4) @(posedge clk); reset=0; repeat(4) @(posedge clk);
      $display("WREN=%0b (clear)", flash_wr_en);
      rd(16'h4100,v,dv); $display("기준선   read 0x4100 -> dout=%02h data_valid=%0b", v, dv);

      $display("-- 공격: LD (0x50AA),A  A=0x98  (정당한 K5 뱅크 쓰기) --");
      w(16'h50AA, 8'h98);
      rd(16'h4100,v,dv); $display("공격 후  read 0x4100 -> dout=%02h data_valid=%0b", v, dv);
      if (dv) begin $display("  ★ CFI/autoselect 웨지 발생 — ROM 창 오염"); bad++; end

      rd(16'h4020,v,dv); $display("         read 0x4020 -> %02h (웨지면 51='Q')", v);
      if (v==8'h51) begin $display("  ★ CFI 시그니처 노출"); bad++; end

      $display("-- 공격2: WREN 없이 AA/55/90 autoselect --");
      w(16'h4AAA,8'hAA); w(16'h4555,8'h55); w(16'h4AAA,8'h90);
      rd(16'h4100,v,dv); $display("         read 0x4100 -> dout=%02h data_valid=%0b", v, dv);
      if (dv) begin $display("  ★ autoselect 웨지"); bad++; end

      $display("-- 공격3: WREN 없이 소거 시퀀스 --");
      w(16'h4AAA,8'hAA); w(16'h4555,8'h55); w(16'h4AAA,8'h80);
      w(16'h4AAA,8'hAA); w(16'h4555,8'h55); w(16'h4000,8'h30);
      repeat(4) @(posedge clk);
      $display("         erase=%0b sdram_addr=%07h din=%02h", dbg_erase, fl_sdram_addr, fl_sdram_din);
      if (dbg_erase) begin $display("  ★ WREN 없이 SDRAM 소거 발생"); bad++; end

      $display("");
      $display("tb_flash_seam: %0d attacks succeeded (0 = safe)", bad);
`ifdef NEGCTL
      if (bad == 0)
         $fatal(1, "NEGCTL BROKEN: WREN gate removed and nothing broke. TB is worthless.");
      $display("negative control OK: %0d attacks fired as required", bad);
      $finish;
`else
      if (bad) $fatal(1, "tb_flash_seam: %0d attack(s) SUCCEEDED", bad);
      $finish;
`endif
   end
endmodule
`default_nettype wire
