//  cpuswap_ctl -- hand the Z80 bus between T80s and NextZ80 without a reset.
//
//  Both cores run on the same clock.  Only the core that owns the bus (use_nz)
//  advances; the other is frozen (T80s: CEN withheld, NextZ80: WAIT forced).
//  A change of want_nz is carried out at the owning core's next swap point:
//
//    RUN    owning core runs.  When want_nz differs and the core reports its swap
//           point (T80s SWAPPT / NextZ80 SWAPPT, both registered on the edge that
//           reached it), the hold is asserted combinationally in that same clock,
//           so the core never takes another edge.
//    XFER   both frozen.  The frozen owner's state (T80s REG / NextZ80 XREG) is
//           loaded into the other core: one DIRSet or LOAD pulse.
//    FLIP   use_nz toggles.
//    SETTLE both still frozen for one clock: the bus mux now shows the new owner, and
//           anything registered from the bus (a memory's registered read, a decoder)
//           catches up before that core takes its first edge.  Without it NextZ80 could
//           latch data read at the previous owner's address (found in the bench: a
//           hand-over right at a BIOS-overlay fetch executed RAM bytes instead).
//
//           SETTLE also lasts until `rate_ok`: the CPU clock-enable rate follows
//           the owner (NextZ80 runs at full rate, T80s at the OSD speed), but
//           clock.sv latches a new rate only when one phase in twelve coincides
//           with an idle bus.  Released after one clock, T80s came back from an
//           R800 stint still clocked at 21.5 MHz and STAYED there until that
//           coincidence happened by luck -- a window in which a stack read
//           returned the previous opcode byte (board, 2026-09-22: the firmware's
//           RET at 790Dh popped F3C9h where the reference pops F392h; C9h is the
//           RET opcode itself) and the machine died in the boot, intermittently.
//           Both cores are frozen here and the bus mux holds every strobe idle, so
//           the latch is reached within 12 clk21m; SETTLE_MAX is only a backstop.
//
//  At a swap point the architectural state sits between two instructions with the
//  next opcode not yet executed (T80.vhd "Swap point", nextz80 patches/README.md).
//  WZ (MEMPTR) and Q are not transferred: undocumented flag bits 3/5 may differ for
//  the first instruction after a swap.
//
//  The swap point excludes prefixes, EI, HALT and an interrupt being accepted, so
//  a swap can be deferred; a halted CPU swaps after its next interrupt.
module cpuswap_ctl
(
   input  logic clk,
   input  logic reset,          // synchronous; T80s owns the bus after reset
   input  logic want_nz,        // requested owner (OSD / software port), any time
   input  logic t80_swappt,
   input  logic nz_swappt,
   output logic use_nz,         // owner of the bus
   output logic t80_hold,       // withhold T80s CEN
   output logic nz_hold,        // force NextZ80 WAIT
   output logic t80_dirset,     // load T80s from NextZ80 XREG
   output logic nz_load,        // load NextZ80 from T80s REG
   output logic busy,
   input  logic rate_ok         // the CE rate has been latched for the NEW owner
);

typedef enum logic [1:0] { RUN, XFER, FLIP, SETTLE } st_t;
st_t st = RUN;
logic [5:0] settle_n = 6'd0;       // SETTLE_MAX = 63 clocks, a backstop only
initial use_nz = 1'b0;

wire pending = want_nz != use_nz;
wire at_pt   = use_nz ? nz_swappt : t80_swappt;
wire freeze  = (st != RUN) | (pending & at_pt);

assign t80_hold   = use_nz  | freeze;
assign nz_hold    = ~use_nz | freeze;
assign t80_dirset = (st == XFER) &  use_nz;
assign nz_load    = (st == XFER) & ~use_nz;
assign busy       = freeze;

always_ff @(posedge clk) begin
   if (reset) begin
      st     <= RUN;
      use_nz <= 1'b0;
   end else case (st)
      RUN:  if (pending & at_pt) st <= XFER;
      XFER: st <= FLIP;
      FLIP: begin
         settle_n <= 6'd0;
         use_nz <= ~use_nz;
         st     <= SETTLE;
      end
      SETTLE: begin
         settle_n <= settle_n + 6'd1;
         if (rate_ok | (&settle_n)) st <= RUN;
      end
      default: st <= RUN;
   endcase
end

endmodule
