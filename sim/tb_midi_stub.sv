// tb_midi_stub -- dev_midi answers a plain IN A,(E9h) with 05h and nothing else.
// The bug this pins: the decode required M1 (interrupt acknowledge), so the IN
// read FFh and Illusion City's handler took its MIDI branch (2026-09-23).
`timescale 1ns/1ps
module tb_midi_stub;
   logic clk = 0, reset = 0, iorq = 0, m1 = 0, wr = 0, rd = 0, cs = 1;
   logic [7:0] addr = 0, dout_cpu = 0;
   wire  [7:0] dout;
   int fails = 0;
   dev_midi dut (.clk(clk), .reset(reset), .cpu_iorq(iorq), .cpu_m1(m1), .cpu_wr(wr), .cpu_rd(rd),
                 .cpu_addr(addr), .cpu_dout(dout_cpu), .cs(cs), .dout(dout));
   task chk(input [7:0] want, input string what);
      #1; if (dout !== want) begin $display("FAIL %s: dout=%02h want=%02h", what, dout, want); fails++; end
   endtask
   initial begin
      iorq = 1; rd = 1; m1 = 0; addr = 8'hE9; chk(8'h05, "IN A,(E9): i8251 status 05h");
      m1 = 1;                              chk(8'hFF, "interrupt acknowledge with A=E9 is not a status read");
      m1 = 0; addr = 8'hE8;                chk(8'hFF, "E8 (data) not decoded");
      addr = 8'hEA;                        chk(8'hFF, "EA not decoded");
      addr = 8'hE9; cs = 0;                chk(8'hFF, "pack without the MIDI device: FF");
      cs = 1; rd = 0; wr = 1;              chk(8'hFF, "OUT (E9) drives nothing");
      if (fails) begin $display("FAILED"); $fatal(1); end
      $display("PASSED"); $finish;
   end
endmodule
