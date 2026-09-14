//
//  A-Z80 clock generator.
//
//  A-Z80 has no clock enable.  Its ports are the real Z80 pinout -- CLK and
//  nothing else -- because it is a gate-level reconstruction of the die, and
//  parts of it (address_pins.v:66, data_pins.v:83, and five flops in
//  control/resets.v) latch on ~clk.  So it needs a real clock at the Z80
//  frequency it is meant to be, not an enable on clk21m.
//
//  The source is clk_sdram, not clk21m, and that is not arbitrary.  3.579545 MHz
//  divides clk_sdram (85.909090) exactly 24 times, and every speed this core
//  offers is an EVEN divisor of it:
//
//      /24 = 3.579545   /16 = 5.369318   /12 = 7.159090
//       /8 = 10.738635   /4 = 21.477270
//
//  Even divisors give a 50% duty cycle.  From clk21m instead, 7.16 would be /3
//  and 21.5 would be /1 -- neither is 50% -- and A-Z80's ~clk pin latches sit on
//  a half-cycle path, so a skewed duty directly eats the timing margin of the
//  very paths that cap it at 29.2 MHz.
//
//  The divisor changes only at cpu_bus_idle, the same point the enable-based
//  divider used, and only at the end of a full output period, so the generated
//  clock never gets a short or stretched pulse across a speed change.
//
//  PHASE-LOCKED TO clk21m (20260914, after the first hardware boot failed).
//  Every az80_clk edge -- rising and falling -- is placed on a clk_sdram edge
//  that coincides with a clk21m RISING edge.  The PLL gives both outputs 0 ps
//  phase (pll_0002.v), so clk21m rises on every 4th clk_sdram edge; a clk21m
//  toggle sampled on the clk_sdram FALLING edge recovers which one.  With the
//  old free-running counter an az80_clk edge could sit half a clk21m before a
//  fabric edge, giving 23 ns (or 11.6 ns) to paths that are 20-30 ns long; the
//  SDC multicycles that "closed" those paths were hiding real violations.
//  Locked, every CPU<->fabric path is an honest full clk21m period.
//  Consequences: half-periods are whole clk21m periods, so 3.58/5.37/10.7 stay
//  50% (3+3, 2+2, 1+1) and 7.16 becomes 2+1 -- both phases still >= 46.6 ns,
//  above the ~24.5 ns the core's half-cycle paths need, and the /8 SDC
//  declaration (1+1) remains the fastest phase of every speed.
//
module az80_clkgen
(
   input        clk_sdram,      // 85.909090 MHz
   input        clk21m,         // 21.477270 MHz, same PLL, 0 ps -- the phase reference
   input        reset,
   input  [2:0] cpu_speed,      // 0=3.58 1=5.37 2=7.16 3=10.7 (4=T80s: clamped to /8 here)
   input        cpu_bus_idle,   // safe point to change the divisor
   output logic az80_clk,
   output [2:0] cpu_speed_q
);

//  High / low phase lengths in clk21m periods.
function automatic [1:0] hi_of(input [2:0] spd);
   case (spd)
      3'd0:    hi_of = 2'd3;   // 3+3 = /24 -> 3.579545
      3'd1:    hi_of = 2'd2;   // 2+2 = /16 -> 5.369318
      3'd2:    hi_of = 2'd2;   // 2+1 = /12 -> 7.159090 (33% low)
      //  /4 (21.477) is RETIRED: A-Z80's half-cycle latch paths cannot close
      //  23.28 ns on this device (best 20.99 MHz over 7 fits) -- speed 4 is
      //  T80s territory and MSX1.sv parks this divider at /8 then.
      default: hi_of = 2'd1;   // 1+1 =  /8 -> 10.738635 (and the speed-4 clamp)
   endcase
endfunction
function automatic [1:0] lo_of(input [2:0] spd);
   case (spd)
      3'd0:    lo_of = 2'd3;
      3'd1:    lo_of = 2'd2;
      3'd2:    lo_of = 2'd1;
      default: lo_of = 2'd1;
   endcase
endfunction

//  Which clk_sdram edge carries a clk21m rise.  t21 flips on every clk21m rise;
//  sampled on the clk_sdram falling edge (5.8 ns clear of any clk21m edge) and
//  compared across two rising edges, a change is seen on the 2nd clk_sdram edge
//  after the clk21m rise, so the NEXT one to carry a rise is 2 edges later.
logic t21 = 1'b0;
always @(posedge clk21m) t21 <= ~t21;
logic t21_n = 1'b0;
always @(negedge clk_sdram) t21_n <= t21;
logic s1 = 1'b0, s1_q = 1'b0;
logic [1:0] ph = 2'd0;         // index of the next clk_sdram edge within the clk21m period
always @(posedge clk_sdram) begin
   s1   <= t21_n;
   s1_q <= s1;
   ph   <= (s1 != s1_q) ? 2'd3 : ph + 2'd1;
end
wire on_rise = (ph == 2'd0);    // this clk_sdram edge coincides with a clk21m rise

logic [2:0] speed_q = 3'd0;
logic [1:0] cnt     = 2'd0;     // remaining clk21m periods in the current phase, minus 1

assign cpu_speed_q = speed_q;

always @(posedge clk_sdram) begin
   if (reset) begin
      speed_q  <= 3'd0;
      cnt      <= 2'd0;
      az80_clk <= 1'b0;
   end else if (on_rise) begin
      if (cnt != 2'd0) cnt <= cnt - 2'd1;
      else begin
         az80_clk <= ~az80_clk;
         if (~az80_clk) begin
            //  Rising now: a new period starts, the only point a divisor may
            //  change (and only with the bus idle).
            if (cpu_bus_idle) begin
               speed_q <= cpu_speed;
               cnt     <= hi_of(cpu_speed) - 2'd1;
            end else
               cnt     <= hi_of(speed_q) - 2'd1;
         end else
            cnt <= lo_of(speed_q) - 2'd1;
      end
   end
end

endmodule
