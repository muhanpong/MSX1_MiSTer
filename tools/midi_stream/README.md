# midi_stream — comparing the MSX-MIDI transmit stream against openMSX

The MIDI interface is a UART, not a synthesiser: `dev_midi` is an i8251 and an
i8254 on ports E8-EF, and `midi_tx` leaves the chip for `UART_TXD` and
`USER_OUT[1]`. The only thing an external MIDI module ever sees is the byte
stream on that wire, so that is what this compares.

    tools/midi_stream/run_compare.sh [bytes.bin]

Three streams, all of which must match:

| | |
|---|---|
| written | what software puts at E8h — generated, or the file you pass |
| wire | what our RTL puts on `midi_tx`, decoded back off the line |
| openMSX | what openMSX's own MSX-MIDI emits, via `midi-out-logger` |

`written` vs `openMSX` says openMSX passes the bytes through unchanged, which
is what makes it usable as the reference. `wire` vs `openMSX` is the comparison
that matters.

## Why no MSX-side software

openMSX exposes an `ioports` debuggable, so `omsx_capture.tcl` pokes the ports
directly with the FS-A1GT BIOS's own setup sequence. No assembler, no disk
image, and no player program that could itself be the thing that differs — both
implementations get byte-for-byte the same stimulus.

The GT is the machine to use: its `MSX-MIDI` device is built in, and booting it
gives the connectors `MSX-MIDI-in` and `MSX-MIDI-out`.

## The pieces

- `gen_stream.py` — makes a wire stream. It uses running status and slips
  realtime bytes between messages, because a transmitter that drops or repeats
  a byte shows up there first.
- `cmp_stream.py` — diffs two streams and prints the first index that differs
  with the bytes either side.
- `omsx_capture.tcl` — the openMSX leg.
- `../../sim/run_midi_stream.sh`, `../../sim/tb_midi_stream.sv` — our leg. The
  decoder never looks inside the DUT, and baud is measured off the line rather
  than assumed.

## Four traps, each of which produced a wrong answer first

- **TxRDY is not "done".** It says the holding register is free while the
  previous character is still shifting out. Stopping a fixed delay after the
  last write loses the final byte; wait for TxEMPTY.
- **Timing start bit to start bit reads the baud low** — 31,059 instead of
  31,250 — because the transmitter takes a moment to reload between characters.
  Measure the shortest run of low instead: that is exactly one bit time.
- **openMSX settings are global Tcl variables.** A plain `set` inside a proc
  makes a local of the same name; it reads back as the value you just wrote
  while the setting keeps its default. `midi-out-logger` then tries to open its
  default `/dev/midi` and the plug fails with "Error opening log file". Use
  `uplevel #0`.
- **`puts` in an openMSX script goes to openMSX's console**, not to stdout.
  Write to a file or you will see nothing at all.

## Result, 2026-09-25

A 155-byte stream: all three identical, and our transmitter measured at 31,262
baud, 687 cycles per bit at 21.477272 MHz, 0.04% off nominal.
