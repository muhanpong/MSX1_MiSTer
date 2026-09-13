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
module az80_clkgen
(
   input        clk_sdram,      // 85.909090 MHz
   input        reset,
   input  [2:0] cpu_speed,      // 0=3.58 1=5.37 2=7.16 3=10.7 4=21.5
   input        cpu_bus_idle,   // safe point to change the divisor
   output logic az80_clk,
   output [2:0] cpu_speed_q
);

//  Half-period in clk_sdram cycles: the output toggles every HALF counts, so
//  the full divisor is 2*HALF.
function automatic [3:0] half_of(input [2:0] spd);
   case (spd)
      3'd0:    half_of = 4'd12;   // /24 -> 3.579545
      3'd1:    half_of = 4'd8;    // /16 -> 5.369318
      3'd2:    half_of = 4'd6;    // /12 -> 7.159090
      3'd3:    half_of = 4'd4;    //  /8 -> 10.738635
      default: half_of = 4'd2;    //  /4 -> 21.477270
   endcase
endfunction

logic [2:0] speed_q = 3'd0;
logic [3:0] cnt     = 4'd0;

assign cpu_speed_q = speed_q;

always @(posedge clk_sdram) begin
   if (reset) begin
      speed_q  <= 3'd0;
      cnt      <= 4'd0;
      az80_clk <= 1'b0;
   end else if (cnt >= half_of(speed_q) - 4'd1) begin
      cnt      <= 4'd0;
      az80_clk <= ~az80_clk;
      //  Take a new divisor only on the falling edge of the generated clock and
      //  only while the bus is idle.  On the falling edge the CPU has just
      //  finished a T-state, so lengthening or shortening the next low phase
      //  cannot truncate one that is already in progress.
      if (~az80_clk && cpu_bus_idle) speed_q <= cpu_speed;
   end else begin
      cnt <= cnt + 4'd1;
   end
end

endmodule
