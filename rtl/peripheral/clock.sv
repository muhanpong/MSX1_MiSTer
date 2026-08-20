module clock
(
   input      clk21m,
   input      reset,
   output     ce_10m7_p,
   output     ce_10m7_n,
   output     ce_5m39_p,
   output     ce_5m39_n,   
   output     ce_3m58_p,
   output     ce_3m58_n,
   output     ce_10hz,
   //  -- CPU turbo ------------------------------------------------------------
   input      [1:0] cpu_speed,   // 0 = 3.58MHz (stock), 1 = 5.37MHz, 2 = 7.16MHz, 3 = 10.74MHz
   input      cpu_bus_idle,      // ~(mreq_n|iorq_n) low: safe point to change speed
   output     ce_cpu_p,
   output     ce_cpu_n,
   output     cpu_turbo,        // |speed_q: tracks the CE rate, not the raw OSD word
   output     [1:0] cpu_speed_q // the LATCHED speed, for speed-dependent guard limits
);

reg  [1:0] clkdiv4 =  2'd1;
reg  [2:0] clkdiv6 =  3'd5;
reg [21:0] div     = 22'd2147727;

always @(posedge clk21m, posedge reset) begin
   if (reset) 
      clkdiv4 <= 2'd1;
   else
      clkdiv4 <= clkdiv4 + 1'd1;
end

always @(posedge clk21m, posedge reset) begin
   if (reset) 
      clkdiv6 <= 3'd5;
   else    
      if (clkdiv6 == 3'd0) 
         clkdiv6 <= 3'd5;
      else
         clkdiv6 <= clkdiv6 - 1'b1;
end

always @(posedge clk21m) begin
   if (div == 22'd0)
      div <= 22'd2147727;
   else
      div <= div - 1'd1; 
end

assign ce_10m7_p = clkdiv4[0];
assign ce_10m7_n = ~clkdiv4[0];
assign ce_5m39_p = &clkdiv4;
assign ce_5m39_n = ~clkdiv4[1] & clkdiv4[0];
assign ce_3m58_p = clkdiv6 == 3'd5;
assign ce_3m58_n = clkdiv6 == 3'd2;
assign ce_10hz   = div == 22'd0;

//  ---------------------------------------------------------------------------
//  -- CPU clock enable (turbo)
//  ---------------------------------------------------------------------------
//  All four trains are DECODES of the existing clkdiv6 counter plus ONE extra
//  flip-flop (`half`), which turns the mod-6 counter into an effective mod-12.
//  The extra bit exists only because 5.37MHz = clk21m/4 does not fit a mod-6
//  period; /6, /3 and /2 do, and their decodes are textually unchanged.
//
//  Properties this buys:
//    1. ce_3m58_p/n are TEXTUALLY untouched -> PSG / SCC / OPLL / FDC keep
//       their pitch, and the invariant is a property of the source rather than
//       of an argument.  That matters for a signal with ce_3m58_p's fanout.
//    2. cpu_speed == 0 reduces to literally the same expression as
//       ce_3m58_p / ce_3m58_n -> turbo OFF is bit-identical to the stock core.
//
//  NOTE (corrected): it is NOT true that ce_3m58_p is a subset of ce_cpu_p in
//  every mode.  At /4 the 3.58MHz p-phase can land on a /4 n-phase.  Nothing
//  depends on a subset relation -- what the bus guard needs is merely that a
//  ce_3m58_p occurs somewhere INSIDE the transfer window, which is measured,
//  not assumed (sim/tb_turbo_guard.sv reports no-CE-hit = 0 at every speed).
//
//  clkdiv6 counts 5,4,3,2,1,0,5,...  and `half` toggles on each wrap:
//
//    0: /6  3.579545 MHz   p @ 5              n @ 2
//    1: /4  5.369318 MHz   p @ ~h:5,1  h:3    n @ ~h:3  h:5,1     <- Panasonic
//    2: /3  7.159090 MHz   p @ 5,2            n @ 3,0
//    3: /2 10.738635 MHz   p @ 5,3,1          n @ 4,2,0  (= parity)
//
//  Glitch-free switching: the mode is latched only at the mod-12 wrap
//  (clkdiv6 == 0 && half).  Every mode's last event before that point is an
//  'n' and every mode's first event after it is a 'p' at clkdiv6 == 5, so
//  T80pa's CEN_pol is 0 across the boundary in all four modes and a switch can
//  neither emit two 'p' pulses nor swallow an 'n'.
//
//  The latch is ALSO gated on the bus being idle.  With an OSD-only control
//  that was cosmetic, but a speed change taken mid-bus-cycle invalidates the
//  guard's calibration: the guard decides to release in units of clk21m at the
//  T2 sample, and the T-states after that decision then run at the NEW rate.
//  Measured without this gate: 2 of 2801 windows fell below the SDRAM ch2
//  deadline.  With it: zero.
//  ---------------------------------------------------------------------------
reg       half    = 1'b0;
reg [1:0] speed_q = 2'd0;
always @(posedge clk21m, posedge reset) begin
   if (reset) begin
      half    <= 1'b0;
      speed_q <= 2'd0;
   end else begin
      if (clkdiv6 == 3'd0) half <= ~half;
      if (clkdiv6 == 3'd0 && half && cpu_bus_idle) speed_q <= cpu_speed;
   end
end

// Derived from speed_q so the guard's enable and the actual clock rate change on
// the SAME edge.  Off the raw status word they disagree for up to 12 clk21m, and
// on a turbo->stock switch that lets one turbo bus cycle run unguarded.
assign cpu_turbo   = |speed_q;
assign cpu_speed_q = speed_q;

wire p_div4 = (~half & ((clkdiv6 == 3'd5) | (clkdiv6 == 3'd1))) | ( half & (clkdiv6 == 3'd3));
wire n_div4 = (~half &  (clkdiv6 == 3'd3))                      | ( half & ((clkdiv6 == 3'd5) | (clkdiv6 == 3'd1)));

assign ce_cpu_p = (speed_q == 2'd0) ?  (clkdiv6 == 3'd5)                      :
                  (speed_q == 2'd1) ?   p_div4                                :
                  (speed_q == 2'd2) ? ((clkdiv6 == 3'd5) | (clkdiv6 == 3'd2)) :
                                        clkdiv6[0];
assign ce_cpu_n = (speed_q == 2'd0) ?  (clkdiv6 == 3'd2)                      :
                  (speed_q == 2'd1) ?   n_div4                                :
                  (speed_q == 2'd2) ? ((clkdiv6 == 3'd3) | (clkdiv6 == 3'd0)) :
                                       ~clkdiv6[0];

endmodule
