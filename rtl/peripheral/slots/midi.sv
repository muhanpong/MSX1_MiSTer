//  dev_midi -- MSX-MIDI: an i8251 USART and an i8254 timer.
//
//  Two variants, chosen by `external`, exactly as openMSX splits them on the
//  presence of an <external> tag (MSXMidi.cc:27):
//
//    external = 0   the FS-A1GT's BUILT-IN device.  Always present, always at
//                   E8h-EFh.  There is no enable register.
//    external = 1   the CARTRIDGE.  E2h is write-only and always answers; the
//                   byte written to it decides whether the device is on the bus
//                   at all and which window it uses.  Bit 7 DISABLES it and
//                   bit 0 LIMITS it to E0h-E1h, the 8251's two registers alone
//                   (MSXMidi.cc:19-20, registerIOports).  Reset leaves it
//                   disabled AND limited, i.e. 81h, so a machine that never
//                   writes E2h never sees the device -- which is what lets this
//                   sit in a machine that is not a turbo R without colliding
//                   with whatever else lives at E8h.
//
//  Until 2026-09-24 this was a single constant: E9h answered 05h and nothing
//  else existed, which stopped the GT firmware servicing a receiver that was not
//  there.  That value was right because 05h IS the reset state (TxRDY|TxEMPTY,
//  nothing received, timer IRQ off), which is why the machine and Illusion City
//  were happy with it -- but software that actually uses MIDI found no device.
//
//  Reference: openMSX src/serial/MSXMidi.cc, I8251.cc, I8254.cc (2712dbd1c),
//  plus a stock FS-A1GT boot measured by the peer session.  Port map, `port & 7`:
//
//      E8  R: receive data (clears RxRDY)      W: transmit data
//      E9  R: 8251 STATUS                      W: 8251 mode / command
//      EA  R: FF                               W: clear the timer IRQ latch
//      EB  R: FF                               W: -
//      EC  R/W: 8254 counter 0
//      ED  R/W: 8254 counter 1
//      EE  R/W: 8254 counter 2
//      EF  R: 8254 (control read)              W: 8254 control word
//
//  Three things here are wiring, not chip behaviour, and getting them wrong
//  makes a device that looks right and does nothing:
//
//    * STATUS bit 7 is the 8251's DSR PIN, and DSR is tied to the timer IRQ
//      LINE -- not to anything inside the USART.  The GT BIOS interrupt hook
//      tests `and #80` to mean "MIDI timer pending" (MSXMidi.cc:272).
//    * The 8251's DTR output ENABLES the timer IRQ and RTS ENABLES the RxRDY
//      IRQ (MSXMidi.cc:260-270).  CTS is tied active.
//    * 8254 CLK0 and CLK2 are 4 MHz; CLK1 is OUT2 (cascade, made in
//      Counter2::signal).  OUT0 is the 8251's TxC/RxC, and OUT2's rising edge
//      sets the timer IRQ latch.
//
//  The GT BIOS programs it like this (measured at PC 1A31-1A6B):
//      E9 <- 00,00,00, 40 (internal reset), 4E (async x16, 8N1), 00 (command)
//      EF <- 16, EC <- 08          counter 0, mode 3, count 8
//                                  4 MHz / 8 = 500 kHz, /16 = 31,250 baud
//      EF <- B4, EE <- 20, EE <- 4E  counter 2, mode 2, count 20000 = 200 Hz
//
//  What is modelled: counter modes 2 and 3 (the rate generator and the square
//  wave), which is what the BIOS and MIDI software use.  Modes 0/1/4/5 count
//  and read back correctly but their OUT waveform is approximated as mode 2 --
//  if something ever depends on one of those, that is the thing to write next.
module dev_midi
(
   input               clk,          // clk21m
   input               reset,
   input               cpu_iorq,
   input               cpu_m1,
   input               cpu_wr,
   input               cpu_rd,
   input         [7:0] cpu_addr,
   input         [7:0] cpu_dout,
   input               cs,           // the machine pack declares DEV_MIDI
   output        [7:0] dout,
   output              int_n,        // wired-AND with the VDP's
   input               midi_rx,      // serial in  (idle high)
   output              midi_tx,      // serial out (idle high)
   input               external      // 1 = the cartridge variant, with E2h
);

//  ── 4 MHz enable ───────────────────────────────────────────────────────────
//  clk21m is 21.477272 MHz, which is not a multiple of 4 MHz, so this is a
//  fractional accumulator: 4/21.477272 * 2^16 = 12206.  The average is
//  4.00000 MHz and the edges jitter by one clk21m (47 ns).  The UART samples at
//  16x the bit rate (bit = 32 us), so per-edge jitter is irrelevant and what
//  matters -- the average -- is exact.
localparam [16:0] CE4_INC = 17'd12206;
logic [16:0] ce4_acc = '0;
wire         ce_4m = ce4_acc[16];
always_ff @(posedge clk) ce4_acc <= {1'b0, ce4_acc[15:0]} + CE4_INC;

//  ── port decode ────────────────────────────────────────────────────────────
//  E2h, the cartridge's enable register.  Write-only, and live whenever the
//  cartridge is present -- it is the one port that does not depend on itself.
logic [7:0] ext_ctl;
wire  io_cyc  = cs & cpu_iorq & ~cpu_m1;
wire  e2_wr   = io_cyc & cpu_wr & external & (cpu_addr == 8'hE2);
wire  ext_on  = ~ext_ctl[7];
wire  ext_lim =  ext_ctl[0];

wire  win_hi  = cpu_addr[7:3] == 5'b1110_1;      // E8-EF, all eight registers
wire  win_lo  = cpu_addr[7:1] == 7'b1110_000;    // E0-E1, the 8251 alone

wire       sel   = io_cyc & (external ? (ext_on & (ext_lim ? win_lo : win_hi))
                                      : win_hi);
//  In the limited window E0h is the data register and E1h the command register,
//  which are indices 0 and 1 of the same map.
wire [2:0] port  = (external & ext_lim) ? {2'b00, cpu_addr[0]} : cpu_addr[2:0];
wire       io_wr = sel & cpu_wr;
wire       io_rd = sel & cpu_rd;

//  ONE side effect per bus cycle.  cpu_wr/cpu_rd are levels (`~wr_n`, `~rd_n`)
//  that stay up for the whole cycle -- several clk21m on either CPU, and on the
//  R800 path an I/O write is held for at least GUARD_WR+2 and until a ce_3m58.
//  Acting on the level repeated every side effect once per clock: a byte written
//  to an idle transmitter went out twice whenever a TxC edge fell inside the
//  strobe, an RW=3 count was written as {MSB,MSB} (4E20 -> 4E4E), and an RW=3
//  read came back byte-swapped.  sim/tb_midi_strobe.sv drives W-clock strobes at
//  random phase and fails on all three.
//    * writes act on the strobe's FIRST clock (the data is valid there; same as
//      tr_iowr_stb in msx.sv);
//    * reads act on its END, because the CPU takes the data at the end and must
//      see the value from before the read's own side effect.  The port is held
//      from inside the strobe, since the address may already have moved on.
logic       io_wr_q, io_rd_q, e2_wr_q;
logic [2:0] rd_port;
wire        wr_stb = io_wr & ~io_wr_q;
wire        e2_stb = e2_wr & ~e2_wr_q;
wire        rd_end = io_rd_q & ~io_rd;

//  ── 8254: three counters ───────────────────────────────────────────────────
//  CLK0 = CLK2 = ce_4m, CLK1 = OUT2.  Loading follows the chip: a counter
//  starts when its full count has been written, and mode 3 halves the count
//  each half period (odd counts spend the extra tick high, as the chip does).
logic [15:0] cnt_init [0:2];
logic [15:0] cnt_val  [0:2];
logic  [1:0] cnt_rw   [0:2];   // 0 latch, 1 LSB, 2 MSB, 3 LSB then MSB
logic  [2:0] cnt_mode [0:2];
logic        cnt_arm  [0:2];   // a full count has been written -> counting
logic        cnt_wrhi [0:2];   // RW=3: the LSB is in, the MSB is next
logic        cnt_rdhi [0:2];   // RW=3: the LSB has been read, the MSB is next
logic [15:0] cnt_lat  [0:2];
logic        cnt_latched [0:2];
logic        cnt_out  [0:2];
logic        cnt_hi   [0:2];   // mode 3: which half of the square wave

wire [1:0] ctl_sel  = cpu_dout[7:6];
wire [1:0] ctl_rw   = cpu_dout[5:4];
wire [2:0] ctl_mode = cpu_dout[3:1];

//  Per-counter clock: counters 0 and 2 at 4 MHz, counter 1 CASCADED off OUT2.
//  `MSXMidi.cc:37 setState(false)` is only counter 1's initial level and the
//  `nullptr` in the I8254 constructor is OUT1's listener, not CLK1 -- the
//  cascade is made in `Counter2::signal`, which copies OUT2's waveform into
//  `getClockPin(1)` on every change.  Measured on a stock FS-A1GT: with
//  counter 2 at 200 Hz and counter 1 loaded with 100, counter 1 steps down by
//  10 every 50 ms, i.e. exactly OUT2's rate.
logic out2_q;
wire  out2_rise = cnt_out[2] & ~out2_q;
wire  cnt_tick [0:2];
assign cnt_tick[0] = ce_4m;
assign cnt_tick[1] = out2_rise;
assign cnt_tick[2] = ce_4m;

//  ── 8251 ───────────────────────────────────────────────────────────────────
logic       cmd_phase;          // 1 = the next E9h write is the MODE byte
logic [7:0] mode_reg, cmd_reg;
wire        tx_en  = cmd_reg[0];
wire        dtr    = cmd_reg[1];   // -> timer IRQ enable
wire        rx_en  = cmd_reg[2];
wire        rts    = cmd_reg[5];   // -> RxRDY IRQ enable

//  the divisor the mode byte selects: 1x, 16x or 64x of the TxC/RxC clock
wire [6:0] baud_div = (mode_reg[1:0] == 2'b01) ? 7'd1  :
                      (mode_reg[1:0] == 2'b10) ? 7'd16 : 7'd64;

logic [7:0] tx_buf,  tx_sr;
logic       tx_full, tx_busy;
logic [3:0] tx_bit;
logic [6:0] tx_div;
logic [7:0] rx_buf,  rx_sr;
logic       rx_rdy,  rx_busy, rx_ovr;
logic [3:0] rx_bit;
logic [6:0] rx_div;
logic       rx_sync1, rx_sync2, rx_q;

//  OUT0 is TxC/RxC; both shifters run off its rising edge, as the chip does.
logic out0_q;
wire  txc_rise = cnt_out[0] & ~out0_q;

//  ── timer / receive interrupts ─────────────────────────────────────────────
logic timer_latch;
wire  timer_irq = timer_latch & dtr;
//  The receive interrupt is NOT a plain `rx_rdy & rts`.  In openMSX the latch
//  follows the byte regardless of RTS, but the IRQ only moves on a latch
//  TRANSITION while RTS is on; turning RTS on with a byte already waiting does
//  not raise it (MSXMidi::setRxRDYIRQ / enableRxRDYIRQ), and turning RTS off
//  clears it.  An AND would fire the instant software enabled the interrupt,
//  which is the same shape as the timer bug that broke the GT opening.
logic rxrdy_irq;
logic rx_rdy_q;
assign int_n = ~(cs & (timer_irq | rxrdy_irq));

//  STATUS: bit 7 is the DSR pin = the timer IRQ line, NOT an 8251 register bit.
wire [7:0] status = { timer_irq,          // 7 DSR
                      1'b0,               // 6 SYNDET/BRKDET
                      1'b0,               // 5 FE
                      rx_ovr,             // 4 OE
                      1'b0,               // 3 PE
                      ~tx_busy & ~tx_full,// 2 TxEMPTY
                      rx_rdy,             // 1 RxRDY
                      ~tx_full };         // 0 TxRDY

//  ── counter read-back ──────────────────────────────────────────────────────
function automatic [7:0] cnt_read(input int i);
   logic [15:0] v;
   v = cnt_latched[i] ? cnt_lat[i] : cnt_val[i];
   case (cnt_rw[i])
      2'd1: cnt_read = v[7:0];
      2'd2: cnt_read = v[15:8];
      default: cnt_read = cnt_rdhi[i] ? v[15:8] : v[7:0];
   endcase
endfunction

assign dout = ~io_rd            ? 8'hFF        :
              (port == 3'd0)    ? rx_buf       :
              (port == 3'd1)    ? status       :
              (port == 3'd4)    ? cnt_read(0)  :
              (port == 3'd5)    ? cnt_read(1)  :
              (port == 3'd6)    ? cnt_read(2)  :
                                  8'hFF;

//  ── the one clocked block ──────────────────────────────────────────────────
integer i;
always_ff @(posedge clk) begin
   logic [15:0] half;

   io_wr_q  <= io_wr;
   io_rd_q  <= io_rd;
   e2_wr_q  <= e2_wr;
   if (io_rd) rd_port <= port;

   out0_q   <= cnt_out[0];
   out2_q   <= cnt_out[2];
   rx_sync1 <= midi_rx;
   rx_sync2 <= rx_sync1;
   rx_q     <= rx_sync2;

   if (reset) begin
      ext_ctl   <= 8'h81;           // cartridge: disabled, and limited when enabled
      cmd_phase <= 1'b1;            // after a reset the next E9h write is MODE
      mode_reg  <= 8'h00;
      cmd_reg   <= 8'h00;
      tx_full   <= 1'b0; tx_busy <= 1'b0; tx_sr <= 8'hFF; tx_bit <= 4'd0; tx_div <= 7'd0;
      rx_rdy    <= 1'b0; rx_busy <= 1'b0; rx_ovr <= 1'b0; rx_buf <= 8'h00;
      rx_bit    <= 4'd0; rx_div <= 7'd0;
      timer_latch <= 1'b0;
      rxrdy_irq   <= 1'b0; rx_rdy_q <= 1'b0;
      for (i = 0; i < 3; i++) begin
         //  The 8254 is NOT re-initialised by the machine reset in openMSX
         //  (only by the constructor), but a core has to start somewhere:
         //  the chip's own power-up is control 0x30 -- both bytes, mode 0,
         //  binary -- and the counters idle.  The BIOS reprograms all of this
         //  on every boot, so nothing observable depends on it.
         cnt_init[i] <= 16'd0; cnt_val[i] <= 16'd0;
         cnt_rw[i]   <= 2'd3;  cnt_mode[i] <= 3'd0;
         cnt_arm[i]  <= 1'b0;  cnt_wrhi[i] <= 1'b0; cnt_rdhi[i] <= 1'b0;
         cnt_lat[i]  <= 16'd0; cnt_latched[i] <= 1'b0;
         cnt_out[i]  <= 1'b1;  cnt_hi[i] <= 1'b1;
      end
   end else begin

      // ── 8254 counting ────────────────────────────────────────────────────
      for (i = 0; i < 3; i++) begin
         if (cnt_arm[i] && cnt_tick[i]) begin
            if (cnt_mode[i] == 3'd3) begin
               //  Mode 3, square wave.  The chip loads the FULL count and
               //  decrements by two per input clock, so a half period lasts
               //  N/2 clocks and the whole period lasts N -- count 8 at 4 MHz
               //  is 500 kHz, which is the MIDI bit clock x16.  (Reloading N/2
               //  instead made each half N/4 and the port ran at twice the
               //  baud rate; tb_midi T2 measures this.)  An odd N gives the
               //  extra clock to the high half: high ceil(N/2), low floor(N/2),
               //  period N (openMSX I8254.cc Counter::writeLoad).  Reloading N
               //  for both halves made the period N+1; the low half therefore
               //  reloads N-1.  tb_midi_strobe C measures N = 3..10.
               half = cnt_init[i] - {15'd0, cnt_hi[i] & cnt_init[i][0]};
               if (cnt_val[i] <= 16'd2) begin
                  cnt_val[i] <= (half < 16'd2) ? 16'd2 : half;
                  cnt_hi[i]  <= ~cnt_hi[i];
                  cnt_out[i] <= ~cnt_hi[i];
               end else
                  cnt_val[i] <= cnt_val[i] - 16'd2;
            end else begin
               //  mode 2 (and, approximated, the rest): one low tick at the end
               //  of every count, then reload.
               if (cnt_val[i] <= 16'd1) begin
                  cnt_val[i] <= cnt_init[i];
                  cnt_out[i] <= 1'b1;
               end else begin
                  cnt_val[i] <= cnt_val[i] - 16'd1;
                  cnt_out[i] <= (cnt_val[i] != 16'd2);
               end
            end
         end
      end

      // ── the receive interrupt, on the latch's edges only ─────────────────
      rx_rdy_q <= rx_rdy;
      if (!rts)                      rxrdy_irq <= 1'b0;
      else if (rx_rdy & ~rx_rdy_q)   rxrdy_irq <= 1'b1;
      else if (~rx_rdy)              rxrdy_irq <= 1'b0;

      // ── the timer IRQ latch ──────────────────────────────────────────────
      //  Only while DTR is set.  openMSX does this by not generating the edge
      //  events at all: `wantEdges = timerIRQenabled && !timerIRQlatch`
      //  (MSXMidi::updateEdgeEvents), so with the interrupt disabled the latch
      //  never arms.  Latching regardless looks harmless and is not: the GT
      //  firmware runs for a while with DTR=0, so the latch would already be
      //  standing when it writes command 03h (TxEN|DTR), and the interrupt
      //  would fire in that same instant instead of up to 5 ms later.  The
      //  BIOS hook at FF93h is not installed yet at that point -- it is still
      //  RET or, worse, unwritten RAM -- so the machine took an interrupt it
      //  could not service and never finished booting (board, 2026-09-24:
      //  the GT opening screen).
      if (out2_rise & dtr) timer_latch <= 1'b1;

      // ── 8251 transmit, on the TxC edges the 8254 produces ────────────────
      if (txc_rise) begin
         if (tx_busy) begin
            if (tx_div >= baud_div - 7'd1) begin
               tx_div <= 7'd0;
               if (tx_bit == 4'd9) begin                  // stop bit done
                  tx_busy <= 1'b0;
               end else begin
                  tx_bit <= tx_bit + 4'd1;
                  //  Do NOT shift leaving the START bit: bit 0 has not been on
                  //  the wire yet.  Shifting there dropped it and sent the byte
                  //  rotated -- 9C went out as CE (tb_midi T7).
                  if (tx_bit != 4'd0) tx_sr <= {1'b1, tx_sr[7:1]};
               end
            end else tx_div <= tx_div + 7'd1;
         end else if (tx_full & tx_en) begin
            tx_sr   <= tx_buf;
            tx_bit  <= 4'd0;
            tx_div  <= 7'd0;
            tx_busy <= 1'b1;
            tx_full <= 1'b0;
         end
      end

      // ── 8251 receive ────────────────────────────────────────────────────
      //  KNOWN WRONG, not fixed yet: the data bits are sampled when rx_div
      //  wraps, i.e. at the bit BOUNDARY, not the middle -- the half-bit check
      //  below only rejects a false start.  A sender a few % fast is misread
      //  (msx1-audit bench, 2026-09-26: +2% and +3.5% fail, -3.5..0% pass); a
      //  real 8251A samples mid-bit at x16.  The loopback in tb_midi passes
      //  because both sides run off the same TxC.  MIDI IN only.
      if (txc_rise) begin
         if (!rx_busy) begin
            if (rx_en & ~rx_q) begin                      // falling edge = start
               rx_busy <= 1'b1;
               rx_bit  <= 4'd0;
               rx_div  <= 7'd0;
            end
         end else begin
            if (rx_div >= baud_div - 7'd1) begin
               rx_div <= 7'd0;
               if (rx_bit == 4'd8) begin                  // stop bit: commit
                  rx_busy <= 1'b0;
                  if (rx_rdy) rx_ovr <= 1'b1;             // not read in time
                  rx_buf <= rx_sr;
                  rx_rdy <= 1'b1;
               end else begin
                  rx_bit <= rx_bit + 4'd1;
                  rx_sr  <= {rx_q, rx_sr[7:1]};
               end
            end else begin
               rx_div <= rx_div + 7'd1;
               //  half a bit in: this is where the chip samples
               if (rx_div == (baud_div >> 1)) begin
                  if (rx_bit == 4'd0 && rx_q) rx_busy <= 1'b0;   // false start
               end
            end
         end
      end

      // ── CPU writes ───────────────────────────────────────────────────────
      //  E2h sits outside `sel` on purpose: it is what decides whether the rest
      //  of the device is on the bus, so it cannot be gated by that decision.
      if (e2_stb) ext_ctl <= cpu_dout;

      if (wr_stb) begin
         case (port)
         3'd0: begin tx_buf <= cpu_dout; tx_full <= 1'b1; end      // E8 transmit
         3'd1: begin                                               // E9 mode/cmd
            if (cmd_phase) begin
               mode_reg  <= cpu_dout;
               cmd_phase <= 1'b0;
            end else begin
               cmd_reg <= cpu_dout;
               if (cpu_dout[4]) rx_ovr <= 1'b0;                    // error reset
               if (cpu_dout[6]) begin                              // internal reset
                  cmd_phase <= 1'b1;
                  cmd_reg   <= 8'h00;
                  tx_full   <= 1'b0; tx_busy <= 1'b0;
                  rx_rdy    <= 1'b0; rx_busy <= 1'b0; rx_ovr <= 1'b0;
               end
            end
         end
         3'd2: timer_latch <= 1'b0;                                // EA clears it
         3'd4, 3'd5, 3'd6: begin                                   // EC/ED/EE
            int c; c = int'(port) - 4;
            case (cnt_rw[c])
            2'd1: begin cnt_init[c][7:0]  <= cpu_dout; cnt_val[c] <= {8'd0, cpu_dout};
                        cnt_arm[c] <= 1'b1; end
            2'd2: begin cnt_init[c][15:8] <= cpu_dout; cnt_val[c] <= {cpu_dout, 8'd0};
                        cnt_arm[c] <= 1'b1; end
            default:
               if (!cnt_wrhi[c]) begin
                  cnt_init[c][7:0] <= cpu_dout;
                  cnt_wrhi[c]      <= 1'b1;
                  cnt_arm[c]       <= 1'b0;               // waits for the MSB
               end else begin
                  cnt_init[c][15:8] <= cpu_dout;
                  cnt_val[c]        <= {cpu_dout, cnt_init[c][7:0]};
                  cnt_wrhi[c]       <= 1'b0;
                  cnt_arm[c]        <= 1'b1;
               end
            endcase
         end
         3'd7: begin                                               // EF control
            if (ctl_rw == 2'd0) begin                              // latch command
               cnt_lat[ctl_sel]     <= cnt_val[ctl_sel];
               cnt_latched[ctl_sel] <= 1'b1;
               cnt_rdhi[ctl_sel]    <= 1'b0;
            end else begin
               cnt_rw[ctl_sel]   <= ctl_rw;
               cnt_mode[ctl_sel] <= ctl_mode;
               cnt_arm[ctl_sel]  <= 1'b0;                // stops until reloaded
               cnt_wrhi[ctl_sel] <= 1'b0;
               cnt_rdhi[ctl_sel] <= 1'b0;
               cnt_latched[ctl_sel] <= 1'b0;
               cnt_out[ctl_sel]  <= (ctl_mode == 3'd0) ? 1'b0 : 1'b1;
               cnt_hi[ctl_sel]   <= 1'b1;
            end
         end
         default: ;
         endcase
      end

      // ── CPU reads with a side effect ─────────────────────────────────────
      if (rd_end) begin
         if (rd_port == 3'd0) begin                                // E8 clears RxRDY
            rx_rdy <= 1'b0;
         end else if (rd_port >= 3'd4 && rd_port <= 3'd6) begin
            int c; c = int'(rd_port) - 4;
            if (cnt_rw[c] == 2'd3) begin
               cnt_rdhi[c] <= ~cnt_rdhi[c];
               if (cnt_rdhi[c]) cnt_latched[c] <= 1'b0;            // both bytes read
            end else cnt_latched[c] <= 1'b0;
         end
      end
   end
end

//  Idle high, and the line only leaves idle while a character is going out.
assign midi_tx = tx_busy ? ((tx_bit == 4'd0) ? 1'b0 : tx_sr[0]) : 1'b1;

endmodule
