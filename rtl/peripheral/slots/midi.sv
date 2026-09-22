//  dev_midi -- the status byte of the FS-A1GT's built-in MSX-MIDI, and nothing else.
//
//  The GT's BIOS services MIDI from inside its interrupt handler:
//      1A74  in a,(#e9) / and #02 / call nz,#ff75      (receive)
//      1A7B  in a,(#e9) / and #80 / call nz,#ff93      (timer)
//  On a real FS-A1GT that read returns 05h every frame -- i8251 TxRDY and
//  TxEMPTY set, RxRDY clear -- so neither hook is ever called.  With E9h left
//  undecoded it reads FF, both bits are set, and the handler calls the two RAM
//  hooks on every interrupt.  Those hold C9 (RET) once the BIOS has filled them,
//  so it mostly only costs time -- but any moment the fetch comes back FF (the
//  hook area not yet filled, or page 3 not on RAM) turns into RST 38h inside the
//  interrupt handler, which nests and never returns: the board's stack walked
//  down 10h per turn until it died (JTAG capture, 2026-09-20).
//
//  The FS-A1ST has no MIDI and its BIOS has no such code, which is why only GT
//  packs hit this.  So this answers only when the machine pack declares the
//  device, exactly like the kanji and reset-status stubs.
//
//  Status only: no i8251, no i8254, no MIDI in or out.  Software that tries to
//  USE MIDI still finds nothing -- this just stops the firmware from servicing a
//  receiver that does not exist.
module dev_midi
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
   output            [7:0] dout
);

localparam [7:0] I8251_STATUS = 8'h05;   // TxRDY | TxEMPTY, RxRDY clear (measured on openMSX FS-A1GT)

//  ~cpu_m1, like every other I/O stub here (cpu_m1 is ~m1_n, high only in the
//  interrupt acknowledge).  It was `cpu_m1` until 2026-09-23, so a plain IN A,(E9)
//  never matched and read FFh -- bit 7 set -- and Illusion City's own interrupt
//  handler (E6DC: IN A,(E9) / BIT 7,A) took its MIDI branch, which never reads
//  the VDP status; the frame interrupt was never cleared, the handler re-entered
//  every 35 us and the stack walked down into the slot register (board ring,
//  GT DOS2 pack).  The reference machine reads 05h there 255 times in 22 s.
wire status_rd = cs & cpu_iorq & ~cpu_m1 & cpu_rd & (cpu_addr == 8'hE9);

assign dout = status_rd ? I8251_STATUS : 8'hFF;

endmodule
