`timescale 1ns/1ps
// Restart-kind regression for the SCC serial multiplier (see
// docs/scc_crackle_rootcause_20260905.md).  How many ticks does cyccntr sit at 0xF after each kind of restart, and is the
// latched sample right?  freq 0x101 -> 258-tick period, so the phase rotates.
module tb_sccrestart;
reg clk=0; always #23.3 clk=~clk;
reg [2:0] div=0; always @(posedge clk) div <= (div==5)?0:div+1;
wire clk_en = (div==0);
reg reset=1, cs=0, cpu_wr=0, cpu_mreq=0; reg [15:0] cpu_addr=0; reg [7:0] din=0;
wire [7:0] dout; wire signed [15:0] wave;
scc_sound dut(.clk(clk),.clk_en(clk_en),.reset(reset),.cart_num(1'b0),.cs(cs),.oe(2'b11),.cpu_rd(1'b0),.cpu_wr(cpu_wr),.cpu_mreq(cpu_mreq),
  .cpu_addr(cpu_addr),.din(din),.scc_dout(dout),.wave(wave),.sccPlusChip(2'b01),.scc_ch_en(5'b11111), .sccPlusMode(2'b01),.debug_scc_wr());
`define C dut.scc_wave_A.u_ctrl_ch1
wire signed [7:0] c1 = dut.scc_wave_A.ch1_sound;
integer nF=0, nrst=0, bad=0, tot=0; reg armed=0;
always @(posedge clk) if (clk_en) begin
  if (`C.mul_rst) begin armed<=1; nF<=0; end
  else if (armed) begin
    if (`C.cyccntr==4'hF) nF<=nF+1;
    if (`C.cyccntr==4'h7) begin armed<=0; tot=tot+1;
      if (c1 !== 119) bad=bad+1;
      if (tot<=10) $display("  restart#%0d: F-ticks=%0d snd=%0d %s", tot, nF, c1, (c1===119)?"":"<-- WRONG");
    end
  end
end
task tick(input integer n); integer k; begin for(k=0;k<n;k=k+1) begin @(posedge clk); while(!clk_en) @(posedge clk); end end endtask
task wr(input [7:0] a, input [7:0] d); begin @(negedge clk); cpu_addr={8'hB8,a}; din=d; cs=1; cpu_mreq=1; cpu_wr=1; repeat(9) @(posedge clk); @(negedge clk); cs=0; cpu_mreq=0; cpu_wr=0; end endtask
integer j;
initial begin
  repeat(60) @(posedge clk); reset=0; tick(10);
  wr(8'hC0,8'h20); wr(8'hAF,8'h01); wr(8'hAA,8'h0F);
  for (j=0;j<32;j=j+1) wr(j,8'h7F);           // every slot +127 -> answer is 119 always
  wr(8'hA0,8'h01); wr(8'hA1,8'h01);           // period 0x101 = 258 ticks (phase rotates)
  tot=0; bad=0; tick(50);
  $display("FREE-RUNNING restarts:"); tot=0; bad=0; tick(6000);
  $display("  -> %0d of %0d wrong", bad, tot);
  $display("FREQ-WRITE restarts (lo+hi 4 ticks apart, 40 times):");
  tot=0; bad=0;
  for (j=0;j<40;j=j+1) begin wr(8'hA0,8'h01); tick(4); wr(8'hA1,8'h01); tick(37); end
  $display("  -> %0d of %0d wrong", bad, tot);
  $finish;
end
endmodule
