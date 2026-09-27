//  Single-OPLL wrapper vs the old three-instance wrapper, same stimulus, output
//  compared on every clock.  Scenarios (+sc=):
//
//    A  cs=100, writes on wr[2]          built-in only            -> identical
//    B  cs=001, writes on wr[0]          slot A FM-PAC only       -> identical
//    C  cs=000, writes on wr[2]          no OPLL, stray OUT (7C)  -> both silent
//    D  cs=101, writes on wr[2]&wr[0]    built-in + FM-PAC, I/O enable on:
//                                        old = two identical chips summed,
//                                        new = one chip           -> ref == 2*dut
//    E  cs=101, writes on wr[2] only     built-in + FM-PAC, I/O enable off
//                                        (cart chip never written) -> identical
//    F  cs=100, writes on wr[0]          built-in present, a write arrives on
//                                        the slot-A FM-PAC path although no
//                                        FM-PAC exists: old design sent it to a
//                                        deselected chip -> both silent.  The
//                                        mutant without the per-source gate
//                                        feeds it to the one chip and plays.
//
//  Every PASS also needs the tone to be audible (nonzero samples > 0) except C,
//  where the check is that BOTH stay at zero for the whole run.
`timescale 1ns/1ps
module tb_opll_single;

logic clk = 0; always #23.3 clk = ~clk;      // ~21.48 MHz
logic cen = 0; logic [2:0] cen_div = 0;
always @(posedge clk) begin cen_div <= (cen_div == 3'd5) ? 3'd0 : cen_div + 3'd1; cen <= (cen_div == 3'd5); end

logic        rst = 1;
logic [7:0]  din = 0;
logic        addr = 0;
logic [2:0]  wr = 0, cs = 0;
wire signed [15:0] s_ref, s_dut;

opll_ref3 u_ref (.clk(clk), .cen(cen), .rst(rst), .din(din), .addr(addr), .wr(wr), .cs(cs), .sound(s_ref));
opll      u_dut (.clk(clk), .cen(cen), .rst(rst), .din(din), .addr(addr), .wr(wr), .cs(cs), .sound(s_dut));

//  One OPLL register write through the given strobe bits: address then data,
//  each held for two 3.58 MHz periods, with the chip's own settling time after.
task automatic opll_write(input [2:0] mask, input [7:0] a, input [7:0] d);
   @(negedge clk); addr = 0; din = a; wr = mask; repeat (12) @(negedge clk); wr = 0;
   repeat (120) @(negedge clk);
   @(negedge clk); addr = 1; din = d; wr = mask; repeat (12) @(negedge clk); wr = 0;
   repeat (600) @(negedge clk);
endtask

string  sc;
int     mism = 0, nz_ref = 0, nz_dut = 0, dbl_bad = 0, n = 0;
logic   run = 0;

always @(posedge clk) if (run) begin
   n++;
   if (s_ref != 0) nz_ref++;
   if (s_dut != 0) nz_dut++;
   if (sc == "D") begin
      if (s_ref != (s_dut <<< 1)) dbl_bad++;      // two identical chips summed
   end else begin
      if (s_ref != s_dut) mism++;
   end
end

initial begin
   if (!$value$plusargs("sc=%s", sc)) sc = "A";
   repeat (2000) @(negedge clk); rst = 0;
   repeat (2000) @(negedge clk);
   case (sc)
      "A": cs = 3'b100;
      "B": cs = 3'b001;
      "C": cs = 3'b000;
      "D", "E": cs = 3'b101;
      "F": cs = 3'b100;
      default: begin $display("bad sc"); $finish; end
   endcase
   run = 1;
   begin
      logic [2:0] m;
      m = (sc == "B" || sc == "F") ? 3'b001 : (sc == "D") ? 3'b101 : 3'b100;
      opll_write(m, 8'h0E, 8'h00);          // rhythm off
      opll_write(m, 8'h30, 8'h10);          // ch0: instrument 1, volume 0
      opll_write(m, 8'h10, 8'h80);          // fnum low
      opll_write(m, 8'h20, 8'h18);          // key on, block 4
   end
   repeat (400000) @(negedge clk);          // ~19 ms of tone
   run = 0;
   $display("OPLLSINGLE sc=%s cycles=%0d mismatches=%0d nz_ref=%0d nz_dut=%0d dbl_bad=%0d", sc, n, mism, nz_ref, nz_dut, dbl_bad);
   $finish;
end

endmodule
