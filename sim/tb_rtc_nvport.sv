//  tb_rtc_nvport -- the RP5C01 settings memory's second port (rtc.vhd, 2026-10-04),
//  through which the SRAM file saves SET SCREEN / SET BEEP / the title.  Runs on
//  the ghdl netlist sim/fullsys/prep.sh makes (gen/rtc.v).
//
//  R1  a CPU write to block 2 register 5 is read back on the second port at
//      {mode 2, reg 5} (low nibble)
//  R2  a second-port write is read back by the CPU (OUT B4h,5 / IN B5h), so a
//      load reaches what the BIOS sees
//  R3  mem_dirty pulses for that block 2 write, and for block 3
//  R4  mem_dirty stays low for the mode register (13), the test/reset registers
//      and every clock-block (0/1) write: the BIOS writes those on every access,
//      and counting them would autosave on every boot
`timescale 1ns/1ps
module tb_rtc_nvport;
logic clk = 0; always #23 clk = ~clk;
logic reset = 1, req = 0, wrt = 0;
logic [15:0] adr = 0;
logic  [7:0] dbo = 0;
wire   [7:0] dbi, nv_dbi;
logic  [5:0] nv_adr = 0;
logic        nv_we = 0;
logic  [7:0] nv_dbo = 0;
wire         mem_dirty, ack;
rtc dut (.clk21m(clk), .reset(reset), .setup(1'b0), .rt(65'd0), .clkena(1'b0),
         .req(req), .ack(ack), .wrt(wrt), .adr(adr), .dbi(dbi), .dbo(dbo),
         .nv_adr(nv_adr), .nv_we(nv_we), .nv_dbo(nv_dbo), .nv_dbi(nv_dbi), .mem_dirty(mem_dirty));

int dirty_count = 0;
always @(posedge clk) if (mem_dirty) dirty_count++;
int errors = 0;
task check(input bit c, input string n);
   if (c) $display("PASS: %s", n); else begin $display("FAIL: %s", n); errors++; end
endtask
task io_wr(input bit port, input byte v);      // port 0 = B4h (pointer), 1 = B5h (data)
   @(negedge clk); adr = {15'h5A, port}; dbo = v; wrt = 1; req = 1;
   @(negedge clk); req = 0; wrt = 0;
   repeat (2) @(negedge clk);
endtask
task io_rd(input bit port, output byte v);
   @(negedge clk); adr = {15'h5A, port}; wrt = 0; req = 1;
   @(negedge clk); req = 0;
   @(negedge clk); v = dbi;
   @(negedge clk);
endtask
task set_reg(input int r, input byte v); io_wr(0, 8'(r)); io_wr(1, v); endtask
task nv_read(input int a, output byte v);
   @(negedge clk); nv_adr = 6'(a); @(negedge clk); @(negedge clk); v = nv_dbi;
endtask

initial begin
   byte v; int d0;
   repeat (4) @(negedge clk); reset = 0; repeat (4) @(negedge clk);

   set_reg(13, 8'h02);                          // block 2
   d0 = dirty_count; set_reg(5, 8'h0A);
   nv_read({2'd2, 4'd5}, v);
   check(v[3:0] == 4'hA, $sformatf("R1 CPU write block 2 reg 5 seen on the second port (got %h)", v));
   check(dirty_count == d0 + 1, "R3 mem_dirty pulsed once for the block 2 write");

   @(negedge clk); nv_adr = {2'd2, 4'd7}; nv_dbo = 8'h06; nv_we = 1; @(negedge clk); nv_we = 0;
   io_wr(0, 8'd7); io_rd(1, v);
   check(v[3:0] == 4'h6, $sformatf("R2 second-port write read back by the CPU (got %h)", v));

   set_reg(13, 8'h03);                          // block 3
   d0 = dirty_count; set_reg(2, 8'h05);
   check(dirty_count == d0 + 1, "R3 mem_dirty pulsed for a block 3 write");

   d0 = dirty_count;
   set_reg(13, 8'h00);                          // mode register itself
   set_reg(14, 8'h00); set_reg(15, 8'h00);      // test, reset
   set_reg(3, 8'h04); set_reg(0, 8'h01);        // block 0 (clock) writes
   set_reg(13, 8'h01); set_reg(11, 8'h01);      // block 1 write
   check(dirty_count == d0, $sformatf("R4 no mem_dirty for mode/test/reset or clock-block writes (%0d)", dirty_count - d0));

   $display("RESULT: %0d error(s)", errors);
   if (errors) $fatal(1, "tb_rtc_nvport FAILED");
   $finish;
end
endmodule
