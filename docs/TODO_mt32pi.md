# TODO — MT32-pi on the USER port

Registered 2026-09-27 at the user's request.  **Implemented the same day** (MSX1.sv,
build 20260927a_mt32pi) -- not yet run on the board.  Open risks: status bits
120-126 are above the highest this core had used (119), and menumask 'F' is new;
if either does not take, the page does not show or the Synth/ROM/SoundFont
requests stay 0 (Munt, MT-32 v1).

## What it is

MT32-pi is a Raspberry Pi MIDI synth (MT-32/CM-32L emulation and SoundFonts) that
plugs into the MiSTer USER port.  The framework ships the driver: `sys/mt32pi.sv`
(already listed in `sys/sys.qip`, not instantiated in `MSX1.sv`).  It carries MIDI
out, takes the synth's I2S audio back into the core, and reports the synth's mode,
ROM and SoundFont plus its LCD bitmap.

## Where we are

* `MSX1.sv:192` drives `USER_OUT = {5'b11111, midi_tx, 1'b1}` -- MIDI out on
  USER pin 1, the MiSTer MIDI pinout.  So a plain serial synth on the USER port
  already gets the MSX-MIDI stream.  No audio comes back, nothing is shown in the
  OSD, and a core reset leaves notes hanging.
* The HPS path (System > UART mode = MIDI, MIDILINK) works since 20260926b and is
  what the user plays through today (`mt32d`, CM-32L).

## Reference: the X68000 core (MiSTer_build/X68000_MiSTer, X68000.sv)

* `mt32pi` instance at X68000.sv:606, fed `(inj_act ? inj_txd : UART_TXD) | mt32_mute`.
* **Hanging-note quiet** after a core reset (X68000.sv:546-600): waits ~2,000,000
  clk_sys, then bit-bangs CC 78h (All Sound Off) and CC 7Bh (All Notes Off) on all
  16 channels into the MT32-pi's MIDI line.
* `mt32_mute = mt32_available & mt32_disable`: "Use MT32-pi = No" holds the line
  idle instead of disconnecting it.
* OSD: `h1P5,MT32-pi;` page hidden unless `mt32_available` (via `status_menumask`),
  options for mode (MT-32 / SoundFont), ROM, SoundFont #, info display; mode-change
  info popup through `info_req`/`info`.
* Audio: `out_l <= aud_l + mt32_i2s_l` (X68000.sv:893) -- summed after the core's
  own mix.
* LCD: MT32-pi's 128x32 LCD overlaid on the video (X68000.sv:921).

Also named as a reference by msx1-audit (2026-09-27, not read here): ao486.sv:414 and
814-819, the USER_OUT selection and the mt32pi wiring.

## Pins (msx1-audit, code reading, not measured)

* sys_top.v:1617 passes user_out[1] through as open drain: 0 pulls low, 1 releases,
  so the receiving device supplies the pull-up.
* Pin 0 is our MIDI IN and, in mt32pi.sv, I2C SDA as well; with no I2C from the core
  SDA idles high on its pull-up and should not disturb MIDI IN.  Pins 2-6 are
  released (1) by us, so the MT32-pi's I2S lines do not collide.
* Today an MT32-pi on the USER port should already PLAY as a plain MIDI receiver,
  with its audio only on the Pi's own output.  That also gives a second, independent
  synth for the "notes go missing" question: missing on both the MT32-pi and mt32d
  points at the byte stream, only on mt32d points downstream.

## Things to settle before starting

* **CONF_STR / status bits**: the menu silently ignores tokens and bit indices past
  what the repo has used (landmine `confstr`, memory feedback-stay-inside-proven-range).
  X68000 uses status up to [68] and a hidden page `h1P5` driven by `status_menumask`;
  check our highest proven bit and menumask width first.
* **Audio mix point and level**: where the I2S pair enters our mixer and at what
  gain.  Gain changes need the user's permission (memory
  feedback-gain-changes-need-permission); the volume ladder is 2 dB steps.
* **Clocks**: `mt32pi` wants CLK_AUDIO, CLK_VIDEO/CE_PIXEL/VGA_VS/VGA_DE for the
  LCD; check which of ours match.
* **USER port ownership**: `USER_OUT`/`USER_IN` are currently MIDI only; confirm
  nothing else (joystick/SNAC) is planned on the same pins.
* **MIDI IN**: `midi_rx = UART_RXD & USER_IN[0]`; `mt32pi` has its own `midi_rx`.
  The 8251 receive path has known defects (sampling at the bit boundary, read vs
  completion on the same edge -- see the KNOWN WRONG note in
  `rtl/peripheral/slots/midi.sv`); an MT32-pi does not send, so this only matters
  if it is wired through.
