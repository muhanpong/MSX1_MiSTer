//  dev_midi in its CARTRIDGE form: the variant that can go in a machine that is
//  not a turbo R.
//
//  The built-in device owns E8h-EFh unconditionally, which is fine on an FS-A1GT
//  and wrong anywhere else.  The cartridge instead answers E2h alone until told
//  otherwise: bit 7 of the byte written there disables it, bit 0 limits it to
//  E0h-E1h.  Reset leaves it 81h -- disabled and limited -- so a machine that
//  never writes E2h never sees it at all.  That is what makes the device safe to
//  declare on any machine, and it is the behaviour openMSX gives its <external>
//  MSX-MIDI (MSXMidi.cc registerIOports).
//
//  Both variants are instantiated here, because the point of the change is that
//  the built-in one did not move.
`timescale 1ns/1ps

module tb_midi_ext;

localparam real HALF = 23.2831;              // 21.477272 MHz
reg clk = 0;
always #(HALF) clk = ~clk;

reg        reset = 1;
reg        iorq = 0, m1 = 0, wr = 0, rd = 0;
reg  [7:0] addr = 8'h00, din = 8'h00;
wire [7:0] dout_ext, dout_int;
wire       midi_tx_ext, midi_tx_int;

dev_midi #() cart
(
   .clk(clk), .reset(reset),
   .cpu_iorq(iorq), .cpu_m1(m1), .cpu_wr(wr), .cpu_rd(rd),
   .cpu_addr(addr), .cpu_dout(din), .cs(1'b1),
   .dout(dout_ext), .int_n(), .midi_rx(1'b1), .midi_tx(midi_tx_ext),
   .external(1'b1)
);

dev_midi #() builtin
(
   .clk(clk), .reset(reset),
   .cpu_iorq(iorq), .cpu_m1(m1), .cpu_wr(wr), .cpu_rd(rd),
   .cpu_addr(addr), .cpu_dout(din), .cs(1'b1),
   .dout(dout_int), .int_n(), .midi_rx(1'b1), .midi_tx(midi_tx_int),
   .external(1'b0)
);

int errors = 0;
task check(input bit cond, input string name);
   if (cond) $display("PASS: %0s", name);
   else begin $display("FAIL: %0s", name); errors++; end
endtask

task io_out(input [7:0] a, input [7:0] d);
   begin
      @(negedge clk); addr = a; din = d; iorq = 1; wr = 1;
      repeat (3) @(posedge clk);
      @(negedge clk); wr = 0; iorq = 0;
      repeat (2) @(posedge clk);
   end
endtask

task io_in(input [7:0] a, output [7:0] de, output [7:0] di);
   begin
      @(negedge clk); addr = a; iorq = 1; rd = 1;
      repeat (2) @(posedge clk);
      de = dout_ext; di = dout_int;
      @(negedge clk); rd = 0; iorq = 0;
      repeat (2) @(posedge clk);
   end
endtask

localparam real BIT_NS = 32000.0;
task tx_capture(output [7:0] b);
   begin
      @(negedge midi_tx_ext);
      #(BIT_NS * 1.5);
      for (int i = 0; i < 8; i++) begin b[i] = midi_tx_ext; #(BIT_NS); end
   end
endtask

logic [7:0] e, i;
logic [7:0] rxb;

initial begin
   repeat (8) @(posedge clk); @(negedge clk); reset = 0;
   repeat (8) @(posedge clk);

   //  T1 -- after reset the cartridge is invisible; the built-in one is not.
   io_in(8'hE9, e, i);
   check(e === 8'hFF, "T1 cartridge answers nothing at E9h before E2h is written");
   check(i === 8'h05, "T1 the built-in device still answers E9h with 05");
   io_in(8'hE1, e, i);
   check(e === 8'hFF, "T1 cartridge answers nothing at E1h either");

   //  T2 -- E2h = 00: enabled, full window.
   io_out(8'hE2, 8'h00);
   io_in(8'hE9, e, i);
   check(e === 8'h05, "T2 E2h=00 puts the cartridge on E8h-EFh");
   io_in(8'hE1, e, i);
   check(e === 8'hFF, "T2 and not on E0h-E1h");

   //  T3 -- E2h = 01: enabled, limited to the 8251's two registers.
   io_out(8'hE2, 8'h01);
   io_in(8'hE1, e, i);
   check(e === 8'h05, "T3 E2h=01 moves it to E0h-E1h");
   io_in(8'hE9, e, i);
   check(e === 8'hFF, "T3 and takes it off E8h-EFh");
   check(i === 8'h05, "T3 the built-in device is unaffected by E2h");

   //  T4 -- bit 7 disables, whatever bit 0 says.
   io_out(8'hE2, 8'h80);
   io_in(8'hE9, e, i);  check(e === 8'hFF, "T4 E2h=80 takes it off E8h-EFh");
   io_in(8'hE1, e, i);  check(e === 8'hFF, "T4 and off E0h-E1h");
   io_out(8'hE2, 8'h81);
   io_in(8'hE1, e, i);  check(e === 8'hFF, "T4 E2h=81 is the reset state, still nothing");

   //  T5 -- a byte transmitted through the limited window reaches the wire.
   io_out(8'hE2, 8'h01);
   io_out(8'hE1, 8'h00); io_out(8'hE1, 8'h00); io_out(8'hE1, 8'h00);
   io_out(8'hE1, 8'h40);              // internal reset -> next write is MODE
   io_out(8'hE1, 8'h4E);              // async x16, 8N1
   io_out(8'hE1, 8'h37);              // TxEN | DTR | RxEN | ER | RTS
   //  The baud generator is counter 0, which lives in the FULL window only, so
   //  a cartridge limited to E0-E1 has to be widened to program it.  Do that the
   //  way software would: widen, program, narrow again.
   io_out(8'hE2, 8'h00);
   io_out(8'hEF, 8'h16); io_out(8'hEC, 8'h08);
   io_out(8'hE2, 8'h01);
   fork
      begin io_out(8'hE0, 8'h9C); end
      begin tx_capture(rxb); end
   join
   check(rxb === 8'h9C, "T5 a byte written at E0h comes off midi_tx unchanged");

   //  T6 -- the built-in device never had an E2h and still does not.
   io_out(8'hE2, 8'h80);
   io_in(8'hE9, e, i);
   check(i === 8'h05, "T6 E2h=80 does not silence the built-in device");

   //  A $display whose argument is a ternary picking between two string
   //  literals prints NOTHING here, which silently cost this bench its summary
   //  line.  Spell the two cases out.  (And a comment must not open with the
   //  tool's own name, or it is read as a pragma.)
   if (errors == 0) $display("RESULT PASS");
   else             $display("RESULT FAIL (%0d)", errors);
   $finish;
end

endmodule
