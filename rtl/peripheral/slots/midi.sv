//  dev_midi -- the FS-A1GT's built-in MSX-MIDI: an i8251 USART and an i8254
//  timer, on ports E8h-EFh.
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
//    * 8254 CLK0 and CLK2 are 4 MHz; CLK1 is OUT2 (cascade).  OUT0 is the
//      8251's TxC/RxC, and OUT2's rising edge sets the timer IRQ latch.
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
   output              midi_tx       // serial out (idle high)
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
wire       sel   = cs & cpu_iorq & ~cpu_m1 & (cpu_addr[7:3] == 5'b1110_1);
wire [2:0] port  = cpu_addr[2:0];
wire       io_wr = sel & cpu_wr;
wire       io_rd = sel & cpu_rd;

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

//  per-counter tick: counters 0 and 2 on the 4 MHz enable, counter 1 on OUT2
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
wire  rxrdy_irq = rx_rdy      & rts;
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

   out0_q   <= cnt_out[0];
   out2_q   <= cnt_out[2];
   rx_sync1 <= midi_rx;
   rx_sync2 <= rx_sync1;
   rx_q     <= rx_sync2;

   if (reset) begin
      cmd_phase <= 1'b1;            // after a reset the next E9h write is MODE
      mode_reg  <= 8'h00;
      cmd_reg   <= 8'h00;
      tx_full   <= 1'b0; tx_busy <= 1'b0; tx_sr <= 8'hFF; tx_bit <= 4'd0; tx_div <= 7'd0;
      rx_rdy    <= 1'b0; rx_busy <= 1'b0; rx_ovr <= 1'b0; rx_buf <= 8'h00;
      rx_bit    <= 4'd0; rx_div <= 7'd0;
      timer_latch <= 1'b0;
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
               //  baud rate; tb_midi T2 measures this.)  Odd counts are
               //  rounded here; the chip gives the extra clock to the high
               //  half, and nothing in this machine uses an odd one.
               half = cnt_init[i];
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

      // ── the timer IRQ latch: set by OUT2's rising edge ────────────────────
      if (out2_rise) timer_latch <= 1'b1;

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

      // ── 8251 receive: start bit, then sample each bit at its middle ──────
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
      if (io_wr) begin
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
      if (io_rd) begin
         if (port == 3'd0) begin                                   // E8 clears RxRDY
            rx_rdy <= 1'b0;
         end else if (port >= 3'd4 && port <= 3'd6) begin
            int c; c = int'(port) - 4;
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
