//  dev_midi: push a byte stream out of the MSX-MIDI UART and read it back off
//  the wire, so what the machine actually transmits can be diffed against the
//  same stream from openMSX.
//
//      +bytes=<file>   raw bytes to transmit (what software writes to E8h)
//      +out=<file>     the bytes decoded back off midi_tx
//      +max=<n>        stop after n bytes (default: the whole file)
//
//  The initialisation is the FS-A1GT BIOS sequence, verbatim from sim/tb_midi.sv,
//  plus the one thing the BIOS leaves to software: the 8251 command byte that
//  enables the transmitter.  The BIOS ends its setup with command 00, so nothing
//  goes out until a player writes TxEN.
//
//  The decoder is independent of the device: it waits for a start bit, samples
//  in the middle of each of the eight data bits, and never looks at anything
//  inside the DUT.
//
//  Baud is MEASURED, not assumed, and measured off the line alone: the shortest
//  run of low on midi_tx is exactly one bit time.  (A start bit followed by a
//  data bit 1 gives one; so does any isolated 0 inside a character.  Nothing
//  shorter can occur.)  Timing the gap between start bits instead reads low,
//  because the transmitter takes a moment to reload between characters -- that
//  mistake put the first version of this bench at 31,059 baud.
`timescale 1ns/1ps

module tb_midi_stream;

localparam real HALF = 23.2831;              // 21.477272 MHz
reg clk = 0;
always #(HALF) clk = ~clk;

reg        reset = 1;
reg        iorq = 0, m1 = 0, wr = 0, rd = 0;
reg  [7:0] addr = 8'h00, din = 8'h00;
wire [7:0] dout;
wire       int_n;
wire       midi_tx;

dev_midi dut
(
   .clk(clk), .reset(reset),
   .cpu_iorq(iorq), .cpu_m1(m1), .cpu_wr(wr), .cpu_rd(rd),
   .cpu_addr(addr), .cpu_dout(din), .cs(1'b1),
   .dout(dout), .int_n(int_n),
   .midi_rx(1'b1), .midi_tx(midi_tx)
);

int cyc = 0;
always @(posedge clk) cyc++;

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

//  ── the stream to send ──────────────────────────────────────────────────────
localparam int MAXB = 1 << 16;
logic [7:0] src [MAXB];
logic [7:0] got [MAXB];
int  n_src = 0, n_got = 0;
int  want  = MAXB;
string in_file, out_file;

//  ── one bit time, straight off the line ─────────────────────────────────────
int min_low = 1 << 30;
initial begin
   int t0;
   forever begin
      @(negedge midi_tx); t0 = cyc;
      @(posedge midi_tx);
      if ((cyc - t0) < min_low) min_low = cyc - t0;
   end
end

//  ── the decoder, running the whole time ─────────────────────────────────────
initial begin
   logic [7:0] b;
   forever begin
      @(negedge midi_tx);                       // start bit
      #(32000.0 * 1.5);                         // into the middle of bit 0
      for (int i = 0; i < 8; i++) begin
         b[i] = midi_tx;
         #(32000.0);
      end
      if (n_got < MAXB) got[n_got] = b;
      n_got++;
   end
end

//  ── the CPU side ────────────────────────────────────────────────────────────
int errors = 0;
initial begin
   int fd, c;
   logic [7:0] st;

   if (!$value$plusargs("bytes=%s", in_file)) begin
      $display("RESULT FAIL: +bytes=<file> is required"); $finish;
   end
   void'($value$plusargs("max=%d", want));
   fd = $fopen(in_file, "rb");
   if (fd == 0) begin $display("RESULT FAIL: cannot open %0s", in_file); $finish; end
   c = $fgetc(fd);
   while (c >= 0 && n_src < MAXB && n_src < want) begin
      src[n_src] = 8'(c); n_src++; c = $fgetc(fd);
   end
   $fclose(fd);
   $display("stream: %0d bytes from %0s", n_src, in_file);

   repeat (8) @(posedge clk); @(negedge clk); reset = 0;
   repeat (8) @(posedge clk);
   bios_init();
   io_out(8'hE9, 8'h37);                 // TxEN | DTR | RxEN | ER | RTS

   //  Write each byte the way a player does: wait for TxRDY, then store it.
   for (int i = 0; i < n_src; i++) begin
      st = 8'h00;
      while (!st[0]) io_in(8'hE9, st);
      io_out(8'hE8, src[i]);
   end
   //  Wait for TxEMPTY, the way software does: TxRDY only says the holding
   //  register is free, so the last character is still going out when it sets.
   //  Stopping at a fixed delay instead dropped the final byte.
   st = 8'h00;
   while (!st[2]) io_in(8'hE9, st);
   #(32000.0 * 2);

   //  ── compare ──────────────────────────────────────────────────────────────
   if (n_got != n_src) begin
      $display("FAIL: sent %0d bytes, decoded %0d", n_src, n_got);
      errors++;
   end else $display("PASS: byte count %0d", n_got);

   for (int i = 0; i < n_src && i < n_got; i++)
      if (got[i] !== src[i]) begin
         $display("FAIL: byte %0d differs: sent %02X, wire carried %02X", i, src[i], got[i]);
         errors++;
         if (errors > 8) break;
      end
   if (errors == 0) $display("PASS: every byte came off the wire unchanged");

   //  One bit at 31250 baud is 32 us; 21.477272 MHz makes that 687.3 cycles.
   if (min_low < (1 << 30)) begin
      real baud;
      baud = 21477272.0 / real'(min_low);
      if (baud >= 31250.0 * 0.99 && baud <= 31250.0 * 1.01)
         $display("PASS: measured %0.1f baud (%0d cycles per bit)", baud, min_low);
      else begin
         $display("FAIL: measured %0.1f baud (%0d cycles per bit), want 31250 +/- 1%%",
                  baud, min_low);
         errors++;
      end
   end

   if ($value$plusargs("out=%s", out_file)) begin
      fd = $fopen(out_file, "wb");
      if (fd == 0) $display("WARN: cannot write %0s", out_file);
      else begin
         for (int i = 0; i < n_got; i++) $fwrite(fd, "%c", got[i]);
         $fclose(fd);
         $display("wrote %0d decoded bytes to %0s", n_got, out_file);
      end
   end

   $display(errors == 0 ? "RESULT PASS" : "RESULT FAIL");
   $finish;
end

endmodule
