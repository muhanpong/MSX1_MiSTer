# MSX-MIDI: how it reaches the outside world, and how to put it in any machine

## 1. The framework side

`dev_midi` is a UART, not a synthesiser. It makes no sound; it puts bytes on a
wire and something outside makes the sound. `MSX1.sv:189-193` is the whole of
the connection:

    assign UART_TXD = midi_tx;
    assign midi_rx  = UART_RXD & USER_IN[0];
    assign USER_OUT = {5'b11111, midi_tx, 1'b1};   // [1] = MIDI out

Two physical routes, driven at once:

- **The user port.** `USER_OUT[1]` carries MIDI out and `USER_IN[0]` MIDI in,
  which is where a MIDI adapter on the USER_IO connector picks it up.
- **The UART.** `UART_TXD` / `UART_RXD` go to the HPS, where MiSTer's own
  `uart_mode` decides what happens to them. This is what makes a USB MIDI
  interface or a network endpoint work without the core knowing.

Receive merges the two with an AND, because both idle high, so a start bit from
whichever is connected gets through. Transmitting on both at once is a
collision, and that is the user's choice rather than something to arbitrate
here. `UART_TXD` used to be tied low, which holds the line in a permanent break.

Nothing else is needed: there is no MIDI-specific framework module to
instantiate, and the core does not care which route is in use.

## 2. Putting it in a machine that is not an FS-A1GT

The built-in device owns E8h-EFh unconditionally. That is right for a turbo R
and wrong everywhere else, because a machine that has something else at those
ports would collide with it.

The real hardware solves this the same way, and so does openMSX: the cartridge
form of MSX-MIDI answers **E2h** alone until told otherwise, and the byte
written there decides the rest (`MSXMidi.cc`, `registerIOports`).

| bit | meaning |
|---|---|
| 7 | 1 disables the device entirely |
| 0 | 1 limits it to E0h-E1h, the 8251's two registers alone |

Reset leaves it at 81h, disabled and limited, so a machine that never writes
E2h never sees the device at all. That is what makes it safe to declare
anywhere.

`dev_midi` takes an `external` input that picks the variant. `external = 0` is
the FS-A1GT's built-in device, unchanged. `external = 1` is the cartridge.

## 3. Declaring it in a pack

`DEV_MIDI_EXT` is the new device bit, and `MIDI_EXT` the pack device type. In a
machine XML, beside the other `<device>` entries:

    <device typ="MIDI_EXT" id="MSX-MIDI cartridge"></device>

`MIDI` still means the built-in one. Both may not be declared at once on a real
machine, and declaring neither is the normal case.

Note the baud generator is counter 0 of the 8254, which lives in the full
window only. Software that limits the device to E0h-E1h has to widen it, program
the counter and narrow it again; the bench does exactly that.

## 4. What is checked

- `sim/run_midi_ext.sh` — thirteen checks on the E2h register: invisible after
  reset, each of the two windows, both ways of disabling it, a byte transmitted
  through the limited window, and the built-in variant unaffected throughout.
- `tools/midi_stream/run_compare.sh` — the transmitted byte stream against
  openMSX. Run with `+ext` and an openMSX machine carrying the external
  MSX-MIDI, an FS-A1WX with the cartridge produced the same 3,353 bytes as our
  RTL, byte for byte.
- The whole machine still lints: `verilator --lint-only --top-module msx`.

**What the stream comparison does NOT check, and it cost real notes.** `io_out` in
`sim/tb_midi_stream.sv` drives a FIXED 3-clock I/O strobe at a phase set by the polling
loop. `dev_midi` took `cpu_wr`/`cpu_rd` as LEVELS (`.cpu_wr(~wr_n)`) and repeated every
side effect on every `clk21m` of the strobe, so a byte written to an idle transmitter
went out TWICE whenever a TxC edge fell inside the strobe, RW=3 counter writes became
{MSB,MSB}, and RW=3 reads came back swapped. Because this bench never varies the strobe
width or phase, it passes on that RTL -- with or without the `+gap` idle mode added
2026-09-27, which varies the time BETWEEN bytes and not the geometry of the write
itself. So "963,241 bytes byte-for-byte against openMSX" was true and insufficient: the
bytes matched because the one phase this bench uses is a benign one.

Fixed on `stable_Turbo-R`'s branch by `7df8915`, with `sim/tb_midi_strobe.sv` as the
bench that can see it: W = 1..16 clocks, random phase 0..63, W = 1 as the negative
control, and a row with no exposure is explicitly not a pass. It fails the old RTL
(e.g. 48 duplicates in 200 at W = 16) and passes the fixed one. **Do not cite
`run_midi_stream.sh` as evidence of byte correctness without the strobe bench beside
it.** The general form: a bench that holds a parameter fixed cannot see a defect in that
parameter, and a negative control proves the RTL change matters, not that the stimulus
space was adequate.

