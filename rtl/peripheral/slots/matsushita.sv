//  ---------------------------------------------------------------------------
//  -- Matsushita switched I/O device (manufacturer ID 8) -- the Panasonic turbo
//  ---------------------------------------------------------------------------
//
//  Present only on Panasonic FS-A1FX / FS-A1WX / FS-A1WSX.  Declared per machine
//  through the pack's <device typ="MATSUSHITA">, so it never appears on a machine
//  that lacks the hardware.
//
//  Protocol (three independent primary sources agree; see the project notes):
//
//      OUT &H40, 8      ' the manufacturer ID is written DIRECTLY, not complemented
//      INP(&H40) = &HF7 ' the complement reads back -> the device exists
//      OUT &H41, 0      ' bit0 = 0 -> 5,369,318 Hz     *** both control bits are
//      OUT &H41, 1      ' bit0 = 1 -> 3,579,545 Hz         ACTIVE LOW ***
//      INP(&H41) bit2 = 0 -> the turbo hardware exists (read-only)
//                bit7 = 0 -> the firmware switch is ON
//
//  Unused bits read 1; the base is &HFF and bits are only ever cleared.
//
//  Answering ID 8 does NOT imply a turbo: Sanyo PHC-70FD, National FS-4500 /
//  FS-4700F / CF-2000 and SVI-728 all return &HF7 and have no turbo at all.
//  Software must decide on bit2 of port &H41, which is why bit2 is wired to a
//  constant 0 here rather than to anything configurable -- this module is only
//  ever instantiated for machines that really do have the hardware.
//
//  *** Two deliberate divergences from the real machine ***
//
//  1. `turbo` reports ONLY what was written to port &H41.  The OSD "CPU Speed"
//     setting is deliberately NOT visible here.  On real hardware turbo also
//     multiplies the internal PSG clock by 1.5 (a perfect fifth up, envelopes
//     too); this core keeps ce_3m58 textually invariant at every speed, by
//     design (see clock.sv).  MGSDRV detects the turbo and PRE-COMPENSATES its
//     PSG register values, so reporting an OSD-driven turbo would make it
//     compensate for a pitch shift that never happens -- it would play a fifth
//     flat.  Keeping the two paths separate means the OSD turbo stays invisible
//     to software, exactly as it is today.
//
//  2. bit7 reads 1 (firmware switch OFF).  The FS-A1WX pack carries no 3-3
//     firmware ROM -- there is no built-in software to switch to.
//
module dev_matsushita
(
   input                   clk,
   input                   reset,
   input                   cpu_iorq,
   input                   cpu_m1,
   input                   cpu_wr,
   input                   cpu_rd,
   input             [7:0] cpu_addr,
   input             [7:0] cpu_dout,
   input                   cs,
   output            [7:0] dout,
   output                  turbo        // 1 = software asked for 5.37MHz
);

localparam [7:0] MANUFACTURER_ID = 8'd8;

logic [7:0] sel_id;
logic       turbo_n;                    // active low, mirrors port 41H bit0

wire selected = sel_id == MANUFACTURER_ID;
wire io_40    = cpu_iorq & ~cpu_m1 & cs & cpu_addr == 8'h40;
wire io_41    = cpu_iorq & ~cpu_m1 & cs & cpu_addr == 8'h41 & selected;

always @(posedge clk) begin
   if (reset) begin
      sel_id  <= 8'h00;                 // nothing selected
      turbo_n <= 1'b1;                  // power-on is 3.58MHz
   end else begin
      if (cpu_wr & io_40) sel_id  <= cpu_dout;
      if (cpu_wr & io_41) turbo_n <= cpu_dout[0];
   end
end

//  Port 40H reads the complement of the selected ID, but only when THIS device
//  is the one selected; an unselected switched port floats to FFH.
//  Port 41H: base FFH with bit2 cleared (turbo present) and bit0 = the switch.
assign dout = ~cpu_rd                ? 8'hFF                          :
              io_40 & selected       ? ~MANUFACTURER_ID               :
              io_41                  ? {5'b11111, 1'b0, 1'b1, turbo_n}:
                                       8'hFF                          ;

assign turbo = ~turbo_n;

endmodule
