//  dev_midi: the MSX-MIDI device driven exactly as the FS-A1GT BIOS drives it.
//
//  The initialisation below is not invented -- it is the sequence measured on a
//  stock FS-A1GT at PC 1A31-1A6B (peer session, openMSX): three dummy command
//  writes, an 8251 internal reset, the mode byte, then counter 0 for the baud
//  clock and counter 2 for the 200 Hz timer.  If this bench passes, the BIOS's
//  own setup works; the rest checks what software then does with it.
`timescale 1ns/1ps

module tb_midi;

//  21.477272 MHz
localparam real HALF = 23.2831;
reg clk = 0;
always #(HALF) clk = ~clk;

reg        reset = 1;
reg        iorq = 0, m1 = 0, wr = 0, rd = 0;
reg  [7:0] addr = 8'h00, din = 8'h00;
wire [7:0] dout;
wire       int_n;
reg        midi_rx_drv = 1;
reg        loopback = 0;
wire       midi_tx;
//  With loopback on, the device hears exactly what it says.
wire       midi_rx = loopback ? midi_tx : midi_rx_drv;
logic [7:0] note [3] = '{8'h90, 8'h3C, 8'h64};   // note-on, middle C, velocity 100

dev_midi dut
(
   .clk(clk), .reset(reset),
   .cpu_iorq(iorq), .cpu_m1(m1), .cpu_wr(wr), .cpu_rd(rd),
   .cpu_addr(addr), .cpu_dout(din), .cs(1'b1),
   .dout(dout), .int_n(int_n),
   .midi_rx(midi_rx), .midi_tx(midi_tx)
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

task io_in(input [7:0] a, output [7:0] d);
   begin
      @(negedge clk); addr = a; iorq = 1; rd = 1;
      repeat (2) @(posedge clk);
      d = dout;
      @(negedge clk); rd = 0; iorq = 0;
      repeat (2) @(posedge clk);
   end
endtask

//  The BIOS sequence, verbatim.
task bios_init;
   begin
      io_out(8'hE9, 8'h00); io_out(8'hE9, 8'h00); io_out(8'hE9, 8'h00);
      io_out(8'hE9, 8'h40);              // internal reset -> next write is MODE
      io_out(8'hE9, 8'h4E);              // async x16, 8 bits, no parity, 1 stop
      io_out(8'hE9, 8'h00);              // command: everything off
      io_out(8'hEF, 8'h16);              // counter 0: LSB only, mode 3
      io_out(8'hEC, 8'h08);              //   count 8 -> 4 MHz/8 = 500 kHz
      io_out(8'hEF, 8'hB4);              // counter 2: LSB+MSB, mode 2
      io_out(8'hEE, 8'h20);              //   count 0x4E20 = 20000
      io_out(8'hEE, 8'h4E);              //   -> 200 Hz
   end
endtask

localparam real BIT_NS = 32000.0;        // 31250 baud

//  Decode one character off midi_tx, sampling in the middle of each bit.
task tx_capture(output [7:0] b);
   begin
      @(negedge midi_tx);                // start bit
      #(BIT_NS * 1.5);
      for (int i = 0; i < 8; i++) begin
         b[i] = midi_tx;
         #(BIT_NS);
      end
   end
endtask

//  Send one character into midi_rx at the same rate.
task rx_send(input [7:0] b);
   begin
      midi_rx_drv = 1'b0; #(BIT_NS);     // start
      for (int i = 0; i < 8; i++) begin midi_rx_drv = b[i]; #(BIT_NS); end
      midi_rx_drv = 1'b1; #(BIT_NS);     // stop
   end
endtask

logic [7:0] st, rb;
//  Everything timed is measured in clk21m CYCLES, not in $time: Verilator
//  reports $time in the precision unit here, not the time unit, and a bound
//  written in "ns" silently became a bound a thousand times too loose.  Cycles
//  have no such ambiguity -- 21.477272 MHz, so 1 us = 21.477 cycles.
int cyc = 0;
always @(posedge clk) cyc++;
int c0, c1;

initial begin
   repeat (8) @(posedge clk); @(negedge clk); reset = 0;
   repeat (8) @(posedge clk);

   // T1 -- the value the old stub returned is the real reset state
   io_in(8'hE9, st);
   check(st == 8'h05, "T1 status after reset is 05 (TxRDY|TxEMPTY)");

   // T1b -- the decode itself, carried over from the retired tb_midi_stub: E9h
   //        must answer a PLAIN IN, not the interrupt acknowledge.  Decoding it
   //        on cpu_m1 instead of ~cpu_m1 made the port read FFh, and Illusion
   //        City's own ISR took its MIDI branch and never cleared the frame
   //        interrupt (board, 2026-09-23).  And a pack that does not declare
   //        the device must answer FFh everywhere.
   @(negedge clk); addr = 8'hE9; iorq = 1; rd = 1; m1 = 1;
   repeat (2) @(posedge clk);
   check(dout === 8'hFF, "T1b an interrupt acknowledge at E9h is not a status read");
   @(negedge clk); m1 = 0; rd = 0; iorq = 0;
   repeat (2) @(posedge clk);
   force dut.cs = 1'b0;
   io_in(8'hE9, st);
   check(st === 8'hFF, "T1b a pack without the device reads FF");
   release dut.cs;
   repeat (2) @(posedge clk);

   bios_init();

   // T2 -- counter 0 gives the MIDI bit clock: OUT0 period is 2 us (500 kHz)
   @(posedge dut.cnt_out[0]); c0 = cyc;
   repeat (10) @(posedge dut.cnt_out[0]);
   c1 = cyc;
   //  10 periods at 500 kHz = 20 us = 429.5 clk21m cycles.
   check((c1 - c0) > 420 && (c1 - c0) < 440,
         $sformatf("T2 counter 0 runs at 500 kHz (10 periods = %0d cycles, want ~430)", c1 - c0));

   // T3 -- with DTR off the latch must not even ARM.  openMSX stops generating
   //       OUT2's edge events while the interrupt is disabled, so several timer
   //       periods can pass and nothing is pending.
   repeat (3) @(posedge dut.cnt_out[2]);
   repeat (4) @(posedge clk);
   check(dut.timer_latch === 1'b0, "T3 the timer does not latch while DTR is off");
   io_in(8'hE9, st);
   check(st[7] === 1'b0, "T3 DSR stays 0 while DTR is off");
   check(int_n === 1'b1, "T3 no interrupt while DTR is off");

   // T4 -- enabling DTR must NOT fire instantly: the interrupt belongs to the
   //       NEXT timer edge, which is what gives the firmware its window to put
   //       a hook at FF93h.  Latching regardless of DTR made the GT fire the
   //       moment it wrote command 03h and the opening screen never came up.
   io_out(8'hE9, 8'h02);
   repeat (4) @(posedge clk);
   check(int_n === 1'b1, "T4 enabling DTR does not fire an interrupt by itself");
   io_in(8'hE9, st);
   check(st[7] === 1'b0, "T4 DSR is still 0 right after enabling DTR");
   c0 = cyc;
   wait (int_n === 1'b0);
   c1 = cyc;
   check((c1 - c0) > 1000, "T4 the interrupt waits for the next timer edge");
   io_in(8'hE9, st);
   check(st[7] === 1'b1, "T4 and then shows on status bit 7");

   // T5 -- writing EAh is what clears it (the BIOS's acknowledge)
   io_out(8'hEA, 8'h00);
   repeat (4) @(posedge clk);
   io_in(8'hE9, st);
   check(st[7] === 1'b0 && int_n === 1'b1, "T5 a write to EAh clears the timer IRQ");

   // T6 -- it comes back on the next 200 Hz tick, ~5 ms later
   c0 = cyc;
   wait (int_n === 1'b0);
   c1 = cyc;
   //  5 ms at 21.477272 MHz = 107,386 cycles.
   check((c1 - c0) > 102_000 && (c1 - c0) < 113_000,
         $sformatf("T6 the timer repeats at 200 Hz (%0d cycles, want ~107386)", c1 - c0));
   io_out(8'hEA, 8'h00);

   // T7 -- transmit: TxEN plus a byte to E8h puts it on the wire
   io_out(8'hE9, 8'h03);                 // TxEN | DTR
   fork
      begin tx_capture(rb); end
      begin repeat (4) @(posedge clk); io_out(8'hE8, 8'h9C); end   // note-on, ch 13
   join
   check(rb == 8'h9C, $sformatf("T7 the transmitted byte is 9C (got %02h)", rb));

   // T8 -- TxRDY drops while the character is going out and comes back after
   io_out(8'hE8, 8'h40);
   repeat (4) @(posedge clk);
   io_in(8'hE9, st);
   check(st[0] === 1'b0, "T8 TxRDY clears once a byte is queued");
   #(BIT_NS * 12);
   io_in(8'hE9, st);
   check(st[0] === 1'b1, "T8 TxRDY returns when the shifter is free");

   // T9 -- receive needs RxE; the byte appears and E8h clears RxRDY
   io_out(8'hE9, 8'h07);                 // TxEN | DTR | RxE
   rx_send(8'h3C);
   repeat (20) @(posedge clk);
   io_in(8'hE9, st);
   check(st[1] === 1'b1, "T9 RxRDY sets after a character arrives");
   io_in(8'hE8, rb);
   check(rb == 8'h3C, $sformatf("T9 the received byte is 3C (got %02h)", rb));
   repeat (4) @(posedge clk);
   io_in(8'hE9, st);
   check(st[1] === 1'b0, "T9 reading E8h clears RxRDY");

   // T10 -- RTS is what lets a receive interrupt out
   io_out(8'hEA, 8'h00);                 // park the timer so only RxRDY can fire
   io_out(8'hE9, 8'h05);                 // TxEN | RxE, RTS still 0
   rx_send(8'h7F);
   repeat (20) @(posedge clk);
   check(int_n === 1'b1, "T10 RxRDY alone does not interrupt while RTS is 0");
   io_out(8'hE9, 8'h25);                 // + RTS, with the byte already waiting
   repeat (4) @(posedge clk);
   check(int_n === 1'b1,
         "T10 enabling RTS over a waiting byte does not raise the interrupt");
   io_in(8'hE8, rb);                     // consume it, then send another
   repeat (4) @(posedge clk);
   rx_send(8'h41);
   repeat (20) @(posedge clk);
   check(int_n === 1'b0, "T10 a byte arriving with RTS on does interrupt");
   io_in(8'hE8, rb);
   repeat (4) @(posedge clk);
   check(int_n === 1'b1, "T10 reading the byte clears the receive interrupt");

   // T12 -- counter 1 is CASCADED off OUT2, one step per 200 Hz tick.
   //        This case exists because the cascade was removed here once, on a
   //        misreading of openMSX: the I8254 constructor's nullptr is OUT1's
   //        listener, not CLK1, and the cascade is made in Counter2::signal.
   //        Measured on a stock FS-A1GT: counter 1 loaded with 100 steps down
   //        by 10 every 50 ms.  With CLK1 held low it would not move at all.
   io_out(8'hEF, 8'h54);                 // counter 1: LSB only, mode 2
   io_out(8'hED, 8'd100);
   @(posedge dut.cnt_out[2]);            // line up just after a tick
   repeat (4) @(posedge clk);
   io_in(8'hED, rb);  c0 = int'(rb);
   repeat (3) @(posedge dut.cnt_out[2]);
   repeat (4) @(posedge clk);
   io_in(8'hED, rb);  c1 = int'(rb);
   check(c0 - c1 == 3,
         $sformatf("T12 counter 1 follows OUT2 (%0d -> %0d over 3 ticks, want -3)", c0, c1));

   // T11 -- loopback: tie the port's own output back to its input and send a
   //        three-byte note-on.  This is the whole path at once, and it is also
   //        what MiSTer's MIDI link does on the host side when it is pointed at
   //        a local synth, so it is worth being sure the device can talk to
   //        itself before blaming a cable.
   loopback = 1'b1;
   io_out(8'hE9, 8'h07);                 // TxEN | DTR | RxE
   io_out(8'hEA, 8'h00);
   for (int k = 0; k < 3; k++) begin
      io_out(8'hE8, note[k]);
      #(BIT_NS * 11);
      repeat (40) @(posedge clk);
      io_in(8'hE9, st);
      if (!st[1]) begin
         check(1'b0, $sformatf("T11 loopback byte %0d never arrived", k));
      end else begin
         io_in(8'hE8, rb);
         check(rb == note[k],
               $sformatf("T11 loopback byte %0d is %02h (got %02h)", k, note[k], rb));
      end
   end
   loopback = 1'b0;

   $display("RESULT: %0d error(s)", errors);
   if (errors) $fatal(1, "tb_midi FAILED");
   $finish;
end

//  Safety net: never let a broken device hang the run.
initial begin
   #400_000_000;
   $display("RESULT FAIL: tb_midi timed out");
   $fatal(1, "timeout");
end

endmodule
