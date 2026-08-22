// tb_offr — 0x7FFE is three registers; only OFFR is implemented
//
// Per the vendor's own sources (yamacore/SRC/YAMASPI.Z8A:9-30) 0x7FFE is OFFR,
// or MOFFR when MSTEN (ENAR bit2), or SPICON when SPIEN (ENAR bit1).  We only
// implement OFFR, so an unqualified write let the genuine firmware destroy it:
// YAMABOOT.Z8A:175 sets ENAR=%101 (MSTEN), writes MOFFR, clears MSTEN, then
// writes OFFR=0 -- without the guard the MOFFR write lands in offsetReg.
// openMSX has the identical defect (Yamanooto.cc:223-225).
//
// This does NOT add MOFFR/SPICON; it only stops the corruption.
//
// Negative control (NEGCTL=1) strips the guard; the two "must NOT be clobbered"
// checks MUST then fail.
`default_nettype none
module tb_offr;
   logic clk=0, reset=1;
   logic [15:0] cpu_addr=0; logic [7:0] din=0;
   logic cpu_mreq=0, cpu_wr=0, cpu_rd=0, cs=1, cart_num=0;
   logic [24:0] mem_size = 25'(8*1024*1024);
   wire mem_unmaped, cart_dout_en, scc_req, flash_wr_en, y_rq, prog_we;
   wire [24:0] mem_addr; wire [7:0] cart_dout; wire [1:0] scc_mode; wire [22:0] y_addr;
   cart_yamanooto d(.clk(clk),.reset(reset),.mem_size(mem_size),.cpu_addr(cpu_addr),
      .din(din),.cpu_mreq(cpu_mreq),.cpu_wr(cpu_wr),.cpu_rd(cpu_rd),.cs(cs),.cart_num(cart_num),
      .mem_unmaped(mem_unmaped),.mem_addr(mem_addr),.cart_dout(cart_dout),.cart_dout_en(cart_dout_en),
      .scc_req(scc_req),.scc_mode(scc_mode),.flash_wr_en(flash_wr_en),.flash_addr(y_addr),
      .flash_rq(y_rq),.prog_we(prog_we));
   always #5 clk=~clk;
   task automatic w(input [15:0] a, input [7:0] d);
      begin @(negedge clk); cpu_addr=a; din=d; cpu_mreq=1; cpu_wr=1; cpu_rd=0;
            repeat(3) @(posedge clk); @(negedge clk); cpu_mreq=0; cpu_wr=0; repeat(2) @(posedge clk); end
   endtask
   int err=0;
   task automatic chk(input string n, input bit c);
      begin if(!c) begin $display("FAIL: %s", n); err++; end else $display("  ok: %s", n); end
   endtask
   initial begin
      repeat(4) @(posedge clk); reset=0; repeat(4) @(posedge clk);
      // REGEN 만 켜고 OFFR 쓰기 -> 정상 반영돼야 함
      w(16'h7FFF, 8'h01);            // ENAR = REGEN
      w(16'h7FFE, 8'h55);            // OFFR = 0x55
      chk("REGEN only: OFFR write lands", d.offsetReg[0] === 8'h55);
      // MSTEN 켠 상태에서 쓰기 -> MOFFR 이므로 OFFR 파괴 금지
      w(16'h7FFF, 8'h05);            // ENAR = REGEN|MSTEN
      w(16'h7FFE, 8'hAA);            // MOFFR 쓰기 (우리는 미구현)
      chk("MSTEN set: OFFR must NOT be clobbered", d.offsetReg[0] === 8'h55);
      // SPIEN 켠 상태 -> SPICON 이므로 역시 보호
      w(16'h7FFF, 8'h03);            // ENAR = REGEN|SPIEN
      w(16'h7FFE, 8'h33);
      chk("SPIEN set: OFFR must NOT be clobbered", d.offsetReg[0] === 8'h55);
      // MSTEN 해제 후 -> 다시 쓰기 가능 (YAMABOOT 시퀀스)
      w(16'h7FFF, 8'h01);
      w(16'h7FFE, 8'h00);
      chk("MSTEN cleared: OFFR writable again", d.offsetReg[0] === 8'h00);
      $display("");
      $display("tb_offr: %0d checks failed", err);
`ifdef NEGCTL
      if (err == 0) $fatal(1, "NEGCTL BROKEN: guard removed and nothing failed.");
      $display("negative control OK: %0d failed as required", err); $finish;
`else
      if (err) $fatal(1, "tb_offr: %0d FAILED", err);
      $display("tb_offr: all checks passed"); $finish;
`endif
   end
endmodule
`default_nettype wire
