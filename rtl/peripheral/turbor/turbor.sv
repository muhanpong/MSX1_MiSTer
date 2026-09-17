//  MSX turbo R features for an MSX2+ machine (OSD "Turbo R features").
//
//  Register behaviour follows openMSX (MSXS1990, MSXE6Timer, MSXTurboRPCM,
//  MSXTurboRPause); BIOS entry definitions follow the MSX BIOS reference.
//  Everything here is dormant while `en` is 0: no ports, no overlay, no mute.
//
//    E4h/E5h  S1990: register select / data.  Reg 6 bit 5: 1 = Z80, 0 = R800;
//             bit 6: 1 = ROM mode, 0 = DRAM mode.  60h after reset.
//    E6h/E7h  16-bit up-counter at 3.579545 MHz / 14 (~3.91 us); any write clears
//             it (the tick grid keeps running); E6h = low byte, E7h = high byte.
//    A4h      read: 2-bit counter at 3.579545 MHz / 228 (~15.7 kHz); write: 8-bit
//             unsigned D/A value, clears the counter (grid keeps running).
//    A5h      bit 0 BUFF (D/A takes the value on the next counter tick), bit 1 MUTE
//             (0 mutes ALL sound, once written), bit 2 FILT, bit 3 SEL, bit 4 SMPL
//             (sample/hold); read: bit 7 comparator (sample >= D/A value), bits 4..0.
//             There is no audio input: the sampled level is 80h.
//    A7h      read: bit 0 pause key state (each Pause press toggles it);
//             write: bit 0 pause LED, bit 1 hardware pause enable, bit 7 turbo LED.
//             Hardware pause = bit 1 and the key state.
//
//  BIOS overlay, only on reads of slot 0-0 page 0 (the main BIOS, `main_rom0`):
//    002Dh    03h (MSX version: turbo R)
//    0180h    CHGCPU  D3 E5 C9  OUT (E5h),A / RET
//    0183h    GETCPU  DB E5 C9  IN A,(E5h) / RET
//    0186h    PCMPLY  B7 C9 00  OR A / RET   (not implemented: returns, carry clear)
//    0189h    PCMREC  B7 C9 00  OR A / RET   (not implemented: returns, carry clear)
//  The opcode fetch of 0180h / 0183h arms a one-shot that makes the E5h access of
//  that same instruction use the BIOS formats instead of register 6:
//    CHGCPU A = LED 0 0 0 0 0 m m   (m: 0 Z80, 1 R800 ROM, 2 R800 DRAM; LED: the
//                                    turbo LED follows the CPU)
//    GETCPU A = 0 0 0 0 0 0 m m
//  The stub bytes are always present, so an interrupt between OUT and RET returns
//  into the stub.
module turbor
(
   input  logic        clk,           // clk21m
   input  logic        reset,
   input  logic        en,
   input  logic        ce_3m58,       // 3.58 MHz enable, stopped while the machine is paused
   //  CPU bus (Z80 levels, active low)
   input  logic [15:0] a,
   input  logic  [7:0] din,           // data from the CPU
   input  logic        mreq_n,
   input  logic        iorq_n,
   input  logic        rd_n,
   input  logic        m1_n,
   input  logic        iowr_stb,      // one clock per I/O write cycle
   input  logic        main_rom0,     // the current memory access is slot 0-0 page 0
   output logic        mem_ov,        // drive `dout` for this memory read
   output logic        io_sel,        // drive `dout` for this I/O read
   output logic  [7:0] dout,
   //  CPU selection
   input  logic        set_stb,       // OSD: force the CPU (turbo LED untouched)
   input  logic        set_r800,
   output logic        r800,
   output logic        dram,
   //  PCM
   output logic  [7:0] pcm_dac,       // unsigned, 80h = silence
   output logic        mute_all,
   //  Pause key and LEDs
   input  logic [10:0] ps2_key,
   output logic        hw_pause,
   output logic        pause_led,
   output logic        turbo_led
);

//  ------------------------------------------------------------------ decode
wire io     = en & ~iorq_n & m1_n;
wire p_s19  = io & (a[7:1] == 7'b1110_010);     // E4h/E5h
wire p_tmr  = io & (a[7:1] == 7'b1110_011);     // E6h/E7h
wire p_pcm  = io & (a[7:1] == 7'b1010_010);     // A4h/A5h
wire p_pau  = io & (a[7:0] == 8'hA7);
assign io_sel = ~rd_n & (p_s19 | p_tmr | p_pcm | p_pau);
wire wr     = iowr_stb & en;

//  ------------------------------------------------------------------ BIOS overlay
logic [7:0] ov_byte;
always_comb begin
   ov_byte = 8'hFF;
   case (a)
      16'h002D: ov_byte = 8'h03;
      16'h0180: ov_byte = 8'hD3;  16'h0181: ov_byte = 8'hE5;  16'h0182: ov_byte = 8'hC9;
      16'h0183: ov_byte = 8'hDB;  16'h0184: ov_byte = 8'hE5;  16'h0185: ov_byte = 8'hC9;
      16'h0186: ov_byte = 8'hB7;  16'h0187: ov_byte = 8'hC9;  16'h0188: ov_byte = 8'h00;
      16'h0189: ov_byte = 8'hB7;  16'h018A: ov_byte = 8'hC9;  16'h018B: ov_byte = 8'h00;
      default: ;
   endcase
end
wire ov_addr = (a == 16'h002D) | (a >= 16'h0180 & a <= 16'h018B);
assign mem_ov = en & main_rom0 & ~mreq_n & ~rd_n & ov_addr;

//  One-shots: evaluated on every clock of an opcode fetch (NextZ80 can fetch back to
//  back without releasing M1), held through the instruction's own I/O cycle.
logic chg_arm = 1'b0, get_arm = 1'b0;
wire  fetch = ~m1_n & ~mreq_n & ~rd_n;
always_ff @(posedge clk) begin
   if (reset | ~en) begin
      chg_arm <= 1'b0;
      get_arm <= 1'b0;
   end else if (fetch) begin
      chg_arm <= main_rom0 & (a == 16'h0180);
      get_arm <= main_rom0 & (a == 16'h0183);
   end else if (wr & p_s19) begin
      chg_arm <= 1'b0;
   end
end

//  ------------------------------------------------------------------ S1990
logic [7:0] regsel = 8'h00;
logic [1:0] cpust  = 2'b11;                     // {reg 6 bit 6, bit 5}
assign r800 = ~cpust[0];
assign dram = ~cpust[1];

logic [7:0] s19_dout;
always_comb begin
   if (!a[0])                  s19_dout = regsel;
   else if (get_arm)           s19_dout = {6'd0, cpust[0] ? 2'd0 : (cpust[1] ? 2'd1 : 2'd2)};
   else case (regsel)
      8'd5:    s19_dout = 8'h00;
      8'd6:    s19_dout = {1'b0, cpust, 5'b00000};
      8'd13:   s19_dout = 8'h03;
      8'd14:   s19_dout = 8'h2F;
      8'd15:   s19_dout = 8'h8B;
      default: s19_dout = 8'hFF;
   endcase
end

logic [7:0] pau_st = 8'h00;
always_ff @(posedge clk) begin
   if (reset) begin
      regsel <= 8'h00;
      cpust  <= 2'b11;
   end else begin
      if (wr & p_s19 & ~a[0]) regsel <= din;
      if (wr & p_s19 &  a[0]) begin
         if (chg_arm)             cpust <= (din[1:0] == 2'd0) ? 2'b11 : (din[1:0] == 2'd1) ? 2'b10 : 2'b00;
         else if (regsel == 8'd6) cpust <= din[6:5];
      end
      if (set_stb) cpust[0] <= ~set_r800;
   end
end

//  ------------------------------------------------------------------ E6h timer
logic [3:0]  tmr_pre = 4'd0;
logic [15:0] tmr     = 16'd0;
always_ff @(posedge clk) begin
   if (ce_3m58) tmr_pre <= (tmr_pre == 4'd13) ? 4'd0 : tmr_pre + 4'd1;
   if (reset | (wr & p_tmr))                 tmr <= 16'd0;
   else if (ce_3m58 && tmr_pre == 4'd13)     tmr <= tmr + 16'd1;
end

//  ------------------------------------------------------------------ PCM
logic [7:0] pcm_pre = 8'd0;
logic [1:0] pcm_cnt = 2'd0;
logic [7:0] dval    = 8'h80;
logic [4:0] pcm_st  = 5'd0;
logic [7:0] hold    = 8'h80;
logic       pend    = 1'b0;                     // BUFF: D/A takes dval on the next tick
logic       muted_w = 1'b0;                     // MUTE applies once A5h has been written
wire        pcm_tick = ce_3m58 && pcm_pre == 8'd227;
localparam [7:0] PCM_IN = 8'h80;                // no audio input
wire  [7:0] smp  = pcm_st[4] ? hold : PCM_IN;
wire        comp = smp >= dval;
always_ff @(posedge clk) begin
   if (ce_3m58) pcm_pre <= pcm_tick ? 8'd0 : pcm_pre + 8'd1;
   if (reset) begin
      pcm_cnt <= 2'd0;
      dval    <= 8'h80;
      pcm_st  <= 5'd0;
      hold    <= 8'h80;
      pend    <= 1'b0;
      pcm_dac <= 8'h80;
      muted_w <= 1'b0;
   end else begin
      if (pcm_tick) pcm_cnt <= pcm_cnt + 2'd1;
      if (pcm_tick & pend) begin
         pcm_dac <= dval;
         pend    <= 1'b0;
      end
      if (wr & p_pcm & ~a[0]) begin
         pcm_cnt <= 2'd0;
         dval    <= din;
         if (pcm_st[1]) begin
            if (pcm_st[0]) pend    <= 1'b1;
            else           pcm_dac <= din;
         end
      end
      if (wr & p_pcm & a[0]) begin
         pcm_st  <= din[4:0];
         muted_w <= 1'b1;
         if (pcm_st[0] & ~din[0]) begin
            pcm_dac <= dval;
            pend    <= 1'b0;
         end
         if (~pcm_st[4] & din[4]) hold <= PCM_IN;
      end
   end
end
assign mute_all = en & muted_w & ~pcm_st[1];

//  ------------------------------------------------------------------ pause (A7h)
logic key_q = 1'b0, pause_key = 1'b0;
always_ff @(posedge clk) begin
   key_q <= ps2_key[10];
   if (reset) begin
      pause_key <= 1'b0;
      pau_st    <= 8'h00;
   end else begin
      //  hps_io reports Pause as {pressed, extended, 77h} = 377h, press only.
      if (en && key_q != ps2_key[10] && ps2_key[9:0] == 10'h377) pause_key <= ~pause_key;
      if (wr & p_pau) pau_st <= din;
      if (wr & p_s19 & a[0] & chg_arm & din[7]) pau_st[7] <= (din[1:0] != 2'd0);
   end
end
assign hw_pause  = en & pau_st[1] & pause_key;
assign pause_led = en & (pau_st[0] | hw_pause);
assign turbo_led = en & pau_st[7];

//  ------------------------------------------------------------------ read mux
always_comb begin
   if (mem_ov)      dout = ov_byte;
   else if (p_s19)  dout = s19_dout;
   else if (p_tmr)  dout = a[0] ? tmr[15:8] : tmr[7:0];
   else if (p_pcm)  dout = a[0] ? {comp, 2'b00, pcm_st} : {6'd0, pcm_cnt};
   else if (p_pau)  dout = {7'd0, pause_key};
   else             dout = 8'hFF;
end

endmodule
