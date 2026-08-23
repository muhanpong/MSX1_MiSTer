// tb_erase_hijack — a CPU write during an erase must not steal the fill
//
// flash.sv's program branch was guarded on `(quadrupleProgram | write_cnt > 0)`.
// The ERASE loop borrows that same counter -- it is loaded with erase_span, so
// write_cnt stays non-zero for all 65536 bytes while erase_block is high for
// exactly one cycle.  One ordinary CPU write reaching `ce` therefore retargeted
// sdram_addr and substituted its own byte for 0xFF; the loop then incremented
// from the new address, running past the sector and bypassing the erase_limit
// clamp (which only executes in that single erase_block cycle).
//
// Gating flash_rq on WREN does NOT cover this: a flash driver holds WREN set
// across the whole erase by construction, which is what this TB reproduces --
// ENAR <- 0x12, the value the Selica translations use.
//
// Measured before the fix: 65528 of 65536 bytes written as the CPU's data,
// range running past the 64KB sector end.  After: 65536 x 0xFF, exact sector.
//
// Negative control (NEGCTL=1) removes the `& ~erase` guard from a /tmp copy of
// flash.sv; the hijack MUST then reappear.
`timescale 1ns/1ps
`default_nettype none
module tb_erase_hijack;
   logic clk=0, reset=1;
   logic [15:0] cpu_addr=0; logic [7:0] din=0;
   logic cpu_mreq=0, cpu_wr=0, cpu_rd=0, cs=1, cart_num=0;
   logic [24:0] mem_size = 25'(8*1024*1024);
   wire mem_unmaped, cart_dout_en, scc_req, flash_wr_en, y_rq, prog_we;
   wire [24:0] mem_addr; wire [7:0] cart_dout; wire [1:0] scc_mode; wire [22:0] y_addr;
   cart_yamanooto yam(.clk(clk),.reset(reset),.mem_size(mem_size),.cpu_addr(cpu_addr),
      .din(din),.cpu_mreq(cpu_mreq),.cpu_wr(cpu_wr),.cpu_rd(cpu_rd),.cs(cs),.cart_num(cart_num),
      .mem_unmaped(mem_unmaped),.mem_addr(mem_addr),.cart_dout(cart_dout),.cart_dout_en(cart_dout_en),
      .scc_req(scc_req),.scc_mode(scc_mode),.flash_wr_en(flash_wr_en),.flash_addr(y_addr),
      .flash_rq(y_rq),.prog_we(prog_we));
   wire [7:0] fl_dout; wire fl_dv; wire dbg_erase;
   logic sdram_ready=1, sdram_done=0;
   wire [26:0] fl_addr; wire [7:0] fl_din; wire fl_req;
   flash fl(.clk(clk),.clk_sdram(clk),.addr(23'(y_addr)),.din(din),.dout(fl_dout),
      .data_valid(fl_dv),.we(cpu_mreq & cpu_wr),.ce(y_rq),
      .sdram_ready(sdram_ready),.sdram_done(sdram_done),
      .sdram_addr(fl_addr),.sdram_din(fl_din),.sdram_req(fl_req),
      .sdram_offset(27'h0C00000),.amd_family(1'b1),.boot_sector(1'b0),
      .erase_limit(27'h800000),.debug_erase(dbg_erase));
   always #5 clk=~clk;
   always @(posedge clk) sdram_done <= fl_req;
   // fill 관측
   int n_ff=0, n_other=0; logic [26:0] hi=0, lo=27'h7FFFFFF;
   always @(posedge clk) if (fl_req & sdram_done) begin
      if (fl_din==8'hFF) n_ff++; else n_other++;
      if (fl_addr>hi) hi=fl_addr; if (fl_addr<lo) lo=fl_addr;
   end
   task automatic w(input [15:0] a, input [7:0] d);
      begin @(negedge clk); cpu_addr=a; din=d; cpu_mreq=1; cpu_wr=1; cpu_rd=0;
            repeat(3) @(posedge clk); @(negedge clk); cpu_mreq=0; cpu_wr=0; repeat(2) @(posedge clk); end
   endtask
   initial begin
      repeat(4) @(posedge clk); reset=0; repeat(4) @(posedge clk);
      w(16'h7FFF, 8'h12);                       // ENAR <- WREN|SPIEN (Selica 값)
      $display("WREN=%0b (드라이버는 소거 내내 이 상태를 유지한다)", flash_wr_en);
      // 소거 시퀀스
      w(16'h4AAA,8'hAA); w(16'h4555,8'h55); w(16'h4AAA,8'h80);
      w(16'h4AAA,8'hAA); w(16'h4555,8'h55); w(16'h4000,8'h30);
      repeat(20) @(posedge clk);
      $display("소거 시작: erase=%0b addr=%07h", dbg_erase, fl_addr);
      // ★ fill 도중 평범한 쓰기 한 번
      w(16'h5F00, 8'h42);
      $display("탈취 시도 후: addr=%07h din=%02h", fl_addr, fl_din);
      // 완주 대기
      begin automatic int guard=0;
        while (dbg_erase && guard<400000) begin @(posedge clk); guard++; end
      end
      $display("");
      $display("fill 결과: 0xFF 바이트=%0d, CPU 데이터 바이트=%0d, 범위 %07h..%07h", n_ff, n_other, lo, hi);
      $display("tb_erase_hijack: %0d bytes hijacked (0 = safe), span %07h..%07h",
               n_other, lo, hi);
`ifdef NEGCTL
      if (n_other == 0)
         $fatal(1, "NEGCTL BROKEN: ~erase guard removed and the fill stayed clean. TB is worthless.");
      $display("negative control OK: %0d bytes hijacked as required", n_other);
      $finish;
`else
      if (n_other) $fatal(1, "tb_erase_hijack: erase hijacked, %0d bytes wrong", n_other);
      if (hi !== 27'h0C0FFFF || lo !== 27'h0C00000)
         $fatal(1, "tb_erase_hijack: fill span %07h..%07h is not the 64KB sector", lo, hi);
      $finish;
`endif
   end
endmodule
`default_nettype wire
