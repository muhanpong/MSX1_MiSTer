//  ---------------------------------------------------------------------------
//  JoyMega -- a Mega Drive pad on an MSX joystick port
//
//  The MSX drives pin 8 of the port (PSG port B bit 4 for port A, bit 5 for
//  port B).  A Mega Drive pad uses that line as a phase clock: every toggle
//  steps an 8-phase cycle, and the six port inputs carry a different slice of
//  the pad on each phase.  Phases 5 and 7 differ only in the direction lines,
//  which is how software tells a 6-button pad from a 3-button one.
//
//  Transcribed from openMSX src/input/JoyMega.cc (read/write/checkTime).  Its
//  `status` word is active low, so it is mirrored here rather than re-deriving
//  the polarity:
//     0 Up  1 Down  2 Left  3 Right  4 A  5 B  6 C  7 Start
//     8 X   9 Y    10 Z    11 Mode
//
//  Always a 6-button pad (openMSX's cycleMask == 7).  It only picks 3-button
//  when Mode is held at plug-in time, which has no meaning for a USB pad that
//  is simply always present.
//  ---------------------------------------------------------------------------
module joymega #(
   parameter TIMEOUT = 16'd32216      // 1.5 ms at 21.477 MHz
)(
   input               clk,
   input               reset,
   input               pin8,          // MSX joystick port pin 8
   input        [11:0] btn,           // active high, in the status order above
   output logic  [5:0] dout           // active low: 0-3 U/D/L/R, 4 trigger A, 5 trigger B
);

wire [11:0] status = ~btn;

logic  [2:0] cycle = 3'd0;
logic [15:0] idle  = 16'd0;

// JoyMega.cc advances the cycle when the written pin 8 differs from cycle&1,
// which keeps `cycle[0] == pin8` as an invariant.  Testing that mismatch
// directly is the same thing as an edge detector, and it re-aligns by itself
// after the timeout below has forced the cycle back to 0.
always @(posedge clk) begin
   if (reset) begin
      cycle <= 3'd0;
      idle  <= 16'd0;
   end else if (pin8 != cycle[0]) begin
      cycle <= cycle + 3'd1;
      idle  <= 16'd0;
   end else if (idle == TIMEOUT) begin
      cycle <= 3'd0;                  // checkTime(): 1.5 ms idle resets the phase
   end else begin
      idle  <= idle + 16'd1;
   end
end

always_comb begin
   case (cycle)
      3'd0, 3'd2,
      3'd4:       dout = {status[6], status[5], status[3:0]};                          // U D L R  B C
      3'd1,
      3'd3:       dout = {status[7], status[4], 2'b00, status[1:0]};                   // U D 0 0  A Start
      3'd5:       dout = {status[7], status[4], 4'b0000};                              // 0 0 0 0  A Start
      3'd6:       dout = {status[6], status[5], status[11], status[8], status[9], status[10]}; // Z Y X Mode B C
      default:    dout = {status[7], status[4], 4'b1111};                              // 1 1 1 1  A Start
   endcase
end

endmodule
