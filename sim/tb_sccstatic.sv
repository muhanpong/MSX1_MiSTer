`timescale 1ns/1ps
// Static transfer function: fill all 32 wave slots with the same value, so the
// output must equal (w*vol)>>4 at every position, with no freq write involved.
module tb_sccstatic;
reg clk=0; always #23.3 clk=~clk;
reg [2:0] div=0; always @(posedge clk) div <= (div==5)?0:div+1;
wire clk_en = (div==0);
reg [4:0] chen=5'b11111;
reg reset=1, cs=0, cpu_wr=0, cpu_mreq=0; reg [15:0] cpu_addr=0; reg [7:0] din=0;
wire [7:0] dout; wire signed [15:0] wave;
scc_sound dut(.clk(clk),.clk_en(clk_en),.reset(reset),.cart_num(1'b0),.cs(cs),.oe(2'b11),.cpu_rd(1'b0),.cpu_wr(cpu_wr),.cpu_mreq(cpu_mreq),
  .cpu_addr(cpu_addr),.din(din),.scc_dout(dout),.wave(wave),.sccPlusChip(2'b01),.scc_ch_en(chen), .sccPlusMode(2'b01),.debug_scc_wr());
wire signed [7:0] c1 = dut.scc_wave_A.ch1_sound;
task tick(input integer n); integer k; begin for(k=0;k<n;k=k+1) begin @(posedge clk); while(!clk_en) @(posedge clk); end end endtask
task wr(input [7:0] a, input [7:0] d); begin @(negedge clk); cpu_addr={8'hB8,a}; din=d; cs=1; cpu_mreq=1; cpu_wr=1; repeat(9) @(posedge clk); @(negedge clk); cs=0; cpu_mreq=0; cpu_wr=0; end endtask
integer w, v, j, exp, got, bad, tot, shown;
initial begin
  repeat(60) @(posedge clk); reset=0; tick(10);
  wr(8'hC0,8'h20); wr(8'hAF,8'h01);       // deform 0x20, ch1 enable
  wr(8'hA0,8'h00); wr(8'hA1,8'h01);       // freq 0x100
  bad=0; tot=0; shown=0;
  for (v=15; v>=1; v=v-7) begin
    wr(8'hAA, v);
    for (w=-128; w<128; w=w+1) begin
      for (j=0;j<32;j=j+1) wr(j, w[7:0]);
      tick(400);
      exp = (w*v) >>> 4; got = c1; tot=tot+1;
      if (got !== exp) begin bad=bad+1;
        if (shown<10) begin shown=shown+1; $display("  vol=%0d w=%0d  exp=%0d got=%0d  diff=%0d", v, w, exp, got, got-exp); end
      end
    end
    $display("vol %0d: %0d / 256 wrong", v, bad); bad=0;
  end
  // ---- per-channel mute (SCC_DIAG) ------------------------------------
  // Every slot already holds the same value, so with all five audible the sum
  // is 5x one channel; dropping one bit must remove exactly one channel's
  // worth and leave the others bit-identical.
  wr(8'hAA,4'd15); wr(8'hAB,4'd15); wr(8'hAC,4'd15); wr(8'hAD,4'd15); wr(8'hAE,4'd15);
  wr(8'hAF,8'h1F);
  for (j=0;j<32;j=j+1) begin wr(j,8'h40); wr(8'h20+j,8'h40); wr(8'h40+j,8'h40); wr(8'h60+j,8'h40); wr(8'h80+j,8'h40); end
  wr(8'hA2,8'h00); wr(8'hA3,8'h01); wr(8'hA4,8'h00); wr(8'hA5,8'h01);
  wr(8'hA6,8'h00); wr(8'hA7,8'h01); wr(8'hA8,8'h00); wr(8'hA9,8'h01);
  wr(8'hA0,8'h00); wr(8'hA1,8'h01);
  tick(400);
  bad=0;
  chen=5'b11111; tick(40); exp=wave;
  if (exp !== 16'sd0*5 && exp === 0) begin bad=bad+1; $display("  all-on gave silence"); end
  for (j=0;j<5;j=j+1) begin
    chen=5'b11111 & ~(5'b00001<<j); tick(40);
    got=wave;
    if (got !== exp - (exp/5)) begin bad=bad+1; $display("  ch%0d mute: all-on=%0d one-off=%0d (want %0d)", j+1, exp, got, exp-(exp/5)); end
  end
  chen=5'b00000; tick(40);
  if (wave !== 0) begin bad=bad+1; $display("  all-off gave %0d, want 0", wave); end
  chen=5'b11111; tick(40);
  if (wave !== exp) begin bad=bad+1; $display("  unmute did not restore (%0d vs %0d)", wave, exp); end
  $display("per-channel mute: %0d wrong", bad);
  $finish;
end
endmodule
