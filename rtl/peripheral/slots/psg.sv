module psg
(
   input clk,
   input clk_en,       // 3.58MHz: sets the PSG pitch - must never change
   input clk_en_cpu,   // CPU rate: bus strobe generator only (== clk_en unless turbo)
   input reset,
   input [7:0] cpu_dout,
   input [7:0] cpu_addr,
   input       cpu_wr,
   input       cpu_iorq,
   input       cpu_m1,
   input [1:0] cs,
   output        [7:0] dout,     // 0xFF when this cart is not answering
   output signed [15:0] sound
);

logic [3:0] reg_latch;

assign sound = (cs[0] ? {2'b00, sound_PSG1, 4'b0000} : 16'd0) +
               (cs[1] ? {2'b00, sound_PSG2, 4'b0000} : 16'd0);

wire psg_n  = ~((cpu_addr[7:3] == 5'b00010) & cpu_iorq & ~cpu_m1);
// Bus strobe generator on clk_en_cpu (see the identical note in msx.sv): it
// needs two enable edges inside the I/O window, which the turbo bus guard does
// not promise on the 3.58MHz train.  jt49_bus below keeps clk_en -> pitch fixed.
logic u21_1_q = 1'b0;
always @(posedge clk,  posedge psg_n) begin
   if (psg_n)
      u21_1_q <= 1'b0;
   else if (clk_en_cpu)
      u21_1_q <= ~psg_n;
end

logic u21_2_q = 1'b0;
always @(posedge clk, posedge psg_n) begin
   if (psg_n)
      u21_2_q <= 1'b0;
   else if (clk_en_cpu)
      u21_2_q <= u21_1_q;
end

wire psg_e = !(!u21_2_q | clk_en_cpu) | psg_n;
wire psg_bc   = !(cpu_addr[0] | psg_e);
wire psg_bdir = !(cpu_addr[1] | psg_e);

wire [7:0] dout_PSG1, dout_PSG2;
wire [9:0] sound_PSG1;
jt49_bus psg1
(
    .rst_n(~reset),
    .clk(clk),
    .clk_en(clk_en),
    .bdir(psg_bdir & cs[0]),
    .bc1(psg_bc & cs[0]),
    .din(cpu_dout),
    .sel(0),
    .dout(dout_PSG1),
    .sound(sound_PSG1),
    .A(),
    .B(),
    .C(),
    .sample(),
    .IOA_in(),
    .IOA_out(),
    .IOB_in(),
    .IOB_out()
);

wire [9:0] sound_PSG2;
jt49_bus psg2
(
    .rst_n(~reset),
    .clk(clk),
    .clk_en(clk_en),
    .bdir(psg_bdir & cs[1]),
    .bc1(psg_bc & cs[1]),
    .din(cpu_dout),
    .sel(0),
    .dout(dout_PSG2),
    .sound(sound_PSG2),
    .A(),
    .B(),
    .C(),
    .sample(),
    .IOA_in(),
    .IOA_out(),
    .IOB_in(),
    .IOB_out()
);

// Register readback.  The Yamanooto User Manual lists its PSG at "port 10H-12H",
// and 12H is the AY read strobe (BC1=1, BDIR=0) that psg_bc/psg_bdir above already
// decode -- only the data path back to the CPU was missing, so reads returned 0xFF
// off the wired-AND in msx_slots.  Write-then-read-back is how software detects a
// second PSG, so without this the cartridge PSG is found to be absent and never
// used, silently.  openMSX has the same gap ("PSG is not readable", Yamanooto.cc),
// so this cannot be found by diffing against it -- only against the manual.
// Gated exactly like the internal PSG at msx.sv:533: port decode only, because
// jt49_bus presents the latched register on dout continuously.
wire psg_rd = ~psg_n & ~cpu_wr;
assign dout = !psg_rd ? 8'hFF :
              cs[0]   ? dout_PSG1 :
              cs[1]   ? dout_PSG2 : 8'hFF;

endmodule