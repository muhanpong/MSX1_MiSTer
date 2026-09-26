//  dev_midi under CPU strobes that last W clk21m, not one.
//
//  msx_slots hands the device `cpu_wr = ~wr_n` and `cpu_rd = ~rd_n` -- levels
//  that stay up for the whole bus cycle (several clk21m on both CPUs; the R800
//  path holds an I/O write for at least GUARD_WR+2 and until a ce_3m58).  The
//  older benches drove 3-4 clock strobes at a fixed phase and happened to pass.
//  Every access here is W clocks long and lands at a random phase.
//
//      A  E8h: a byte written to an idle transmitter goes out exactly once.
//      B  8254 RW=3: LSB then MSB written, latched and read back byte by byte.
//      C  8254 mode 3: period N and high half ceil(N/2), odd N included
//         (openMSX I8254.cc Counter::writeLoad).
//
//  Rules fixed before looking at a result:
//    * W=1 is the negative control: a one-clock strobe cannot repeat a side
//      effect.  If A or B fails at W=1 the bench is broken -> RESULT INVALID.
//    * A counts its exposures -- a TxC edge inside the strobe, after its first
//      clock, with the transmitter idle before the write.  A W>1 row with no
//      exposure proves nothing and is NOEXPOSURE, which is not a pass.
//    * A decodes midi_tx on its own at 31250 baud; it never reads the DUT's
//      shift register.
`timescale 1ns/1ps

module tb_midi_strobe;

localparam real HALF = 23.2831;              // 21.477272 MHz
localparam real BIT  = 32000.0;              // ns, 31250 baud
reg clk = 0;
always #(HALF) clk = ~clk;

reg        reset = 1;
reg        iorq = 0, m1 = 0, wr = 0, rd = 0;
reg  [7:0] addr = 8'h00, din = 8'h00;
wire [7:0] dout;
wire       int_n, midi_tx;

dev_midi dut
(
   .clk(clk), .reset(reset),
   .cpu_iorq(iorq), .cpu_m1(m1), .cpu_wr(wr), .cpu_rd(rd),
   .cpu_addr(addr), .cpu_dout(din), .cs(1'b1), .dout(dout), .int_n(int_n),
   .midi_rx(1'b1), .midi_tx(midi_tx), .external(1'b0)
);

int W;                                       // strobe length in clk21m

task automatic io_out(input [7:0] a, input [7:0] d);
   @(negedge clk); addr = a; din = d; iorq = 1; wr = 1;
   repeat (W) @(posedge clk);
   @(negedge clk); wr = 0; iorq = 0;
   repeat (2) @(posedge clk);
endtask

//  The CPU takes the data at the END of the strobe: 1 ns before the last clock
//  edge it covers, i.e. before anything that edge does.  Sampling after it read a
//  one-clock strobe's own side effect (the first run of this bench: 4E20 -> 204E
//  at W=1, which is the bench, not the device).
task automatic io_in(input [7:0] a, output [7:0] d);
   @(negedge clk); addr = a; iorq = 1; rd = 1;
   #((2 * W - 1) * HALF - 1.0) d = dout;
   @(posedge clk);
   @(negedge clk); rd = 0; iorq = 0;
   repeat (2) @(posedge clk);
endtask

task automatic status(output [7:0] s);
   int w; w = W; W = 1; io_in(8'hE9, s); W = w;
endtask

//  ── A: the line, decoded independently ─────────────────────────────────────
logic [7:0] got [$];
initial forever begin
   logic [7:0] b;
   @(negedge midi_tx);
   #(BIT * 1.5);
   for (int i = 0; i < 8; i++) begin b[i] = midi_tx; #(BIT); end
   got.push_back(b);
end

//  exposure: a TxC edge on clock 2..W of an E8h strobe, transmitter idle before it
int  expo = 0;
int  e8_clk = 0;
bit  e8_idle = 0;
always @(posedge clk) begin
   if (iorq & wr & (addr == 8'hE8)) begin
      if (e8_clk == 0) e8_idle = ~dut.tx_busy;
      else if (e8_idle & dut.txc_rise) expo++;
      e8_clk++;
   end else e8_clk = 0;
end

//  ── C: OUT0 period and high time in 4 MHz ticks ─────────────────────────────
int  c_ticks = 0, c_high = 0, c_period = -1, c_hi_meas = -1;
bit  c_prev = 1;
always @(posedge clk) if (dut.ce_4m) begin
   c_ticks++;
   if (dut.cnt_out[0]) c_high++;
   if (dut.cnt_out[0] & ~c_prev) begin      // rising edge closes a period
      c_period = c_ticks; c_hi_meas = c_high;
      c_ticks = 0; c_high = 0;
   end
   c_prev = dut.cnt_out[0];
end

int invalid = 0, fails = 0, noexp = 0;

initial begin
   logic [7:0] s, lo, hi;
   int seed, n;
   int Ws [] = '{1, 2, 3, 4, 5, 6, 7, 8, 11, 12, 16};
   logic [15:0] vals [] = '{16'h4E20, 16'h1234, 16'h0FA0, 16'h00C8, 16'hABCD, 16'h0001};

   if (!$value$plusargs("seed=%d", seed)) seed = 1;
   void'($urandom(seed));
   $display("seed=%0d", seed);

   repeat (8) @(posedge clk); @(negedge clk); reset = 0;
   repeat (8) @(posedge clk);

   //  the FS-A1GT BIOS sequence (sim/tb_midi.sv), with one-clock strobes
   W = 1;
   io_out(8'hE9, 8'h00); io_out(8'hE9, 8'h00); io_out(8'hE9, 8'h00);
   io_out(8'hE9, 8'h40); io_out(8'hE9, 8'h4E); io_out(8'hE9, 8'h00);
   io_out(8'hEF, 8'h16); io_out(8'hEC, 8'h08);
   io_out(8'hEF, 8'hB4); io_out(8'hEE, 8'h20); io_out(8'hEE, 8'h4E);
   io_out(8'hE9, 8'h03);                                    // TxEN | DTR

   // ── A ───────────────────────────────────────────────────────────────────
   foreach (Ws[k]) begin
      logic [7:0] src [$];
      int dups, bad;
      W = Ws[k]; n = (W == 1) ? 48 : 200;
      got.delete(); expo = 0; src.delete();
      for (int i = 0; i < n; i++) begin
         logic [7:0] b; b = 8'($urandom);
         src.push_back(b);
         s = 0; while (!s[2]) status(s);                   // TxEMPTY: line idle
         repeat ($urandom_range(0, 63)) @(posedge clk);
         io_out(8'hE8, b);
      end
      s = 0; while (!s[2]) status(s);
      #(BIT * 12);
      dups = 0; bad = 0;
      begin
         int i, j; i = 0; j = 0;
         while (i < src.size() && j < got.size()) begin
            if (got[j] == src[i]) begin i++; j++; end
            else if (j > 0 && got[j] == got[j-1]) begin dups++; j++; end
            else begin bad++; break; end
         end
         bad += (src.size() - i);
      end
      if (W == 1) begin
         if (got.size() != n || dups || bad) begin
            $display("INVALID: A W=1 sent %0d got %0d dup %0d bad %0d", n, got.size(), dups, bad);
            invalid++;
         end else $display("PASS: A W=1  sent %0d got %0d (control)", n, got.size());
      end else if (got.size() != n || dups || bad) begin
         $display("FAIL: A W=%-2d sent %0d got %0d dup %0d bad %0d exposure %0d",
                  W, n, got.size(), dups, bad, expo);
         fails++;
      end else if (expo == 0) begin
         $display("NOEXPOSURE: A W=%-2d sent %0d got %0d", W, n, got.size());
         noexp++;
      end else
         $display("PASS: A W=%-2d sent %0d got %0d exposure %0d", W, n, got.size(), expo);
   end

   // ── B ───────────────────────────────────────────────────────────────────
   //  Counter 1 is clocked by OUT2; counter 2 is stopped (control rewritten, no
   //  count), so counter 1 holds exactly what was written and reads back as-is.
   foreach (Ws[k]) begin
      int wrong; wrong = 0;
      W = Ws[k];
      foreach (vals[v]) begin
         io_out(8'hEF, 8'hB4);                              // counter 2: stop
         io_out(8'hEF, 8'h74);                              // counter 1: RW=3, mode 2
         io_out(8'hED, vals[v][7:0]);
         io_out(8'hED, vals[v][15:8]);
         io_out(8'hEF, 8'h40);                              // latch counter 1
         io_in(8'hED, lo); io_in(8'hED, hi);
         if ({hi, lo} !== vals[v]) begin
            if (wrong < 2) $display("      B W=%0d wrote %04h read %04h", W, vals[v], {hi, lo});
            wrong++;
         end
         io_in(8'hED, lo); io_in(8'hED, hi);                // unlatched
         if ({hi, lo} !== vals[v]) begin
            if (wrong < 2) $display("      B W=%0d wrote %04h read %04h (unlatched)", W, vals[v], {hi, lo});
            wrong++;
         end
      end
      if (W == 1 && wrong) begin $display("INVALID: B W=1 %0d wrong", wrong); invalid++; end
      else if (wrong)      begin $display("FAIL: B W=%-2d %0d/12 wrong", W, wrong); fails++; end
      else                       $display("PASS: B W=%-2d 12/12", W);
   end

   // ── C ───────────────────────────────────────────────────────────────────
   W = 1;
   for (int N = 3; N <= 10; N++) begin
      io_out(8'hEF, 8'h36);                                 // counter 0: RW=3, mode 3
      io_out(8'hEC, 8'(N)); io_out(8'hEC, 8'h00);
      c_period = -1;
      repeat (3) @(posedge dut.cnt_out[0]);                 // settle
      repeat (2) @(posedge dut.cnt_out[0]);
      #1;
      if (c_period != N || c_hi_meas != (N + 1) / 2) begin
         $display("FAIL: C N=%0d period %0d high %0d, want %0d / %0d",
                  N, c_period, c_hi_meas, N, (N + 1) / 2);
         fails++;
      end else $display("PASS: C N=%0d period %0d high %0d", N, c_period, c_hi_meas);
   end

   if (invalid)            $display("RESULT INVALID (%0d)", invalid);
   else if (fails | noexp) $display("RESULT FAIL (%0d fail, %0d noexposure)", fails, noexp);
   else                    $display("RESULT PASS");
   $finish;
end

endmodule
