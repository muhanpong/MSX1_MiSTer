# TODO: V9990 on nextz80_v9990 (on hold)

Recorded 2026-11-10. On hold by the user's decision; nothing here is started.
Background: `docs/handoff_20261110_packforge_joymega.md` section 2 (on nextz80).

## Output path
- B4 shows 75 % and B7 50 % of the pixels; B5 50 %, B6 43 %. The wrapper samples the core
  every 4 core clocks (10.74 MHz). Fix: a pixel path at 2-3 core clocks.
- B5/B6 high scan (25/31 kHz lines): `hscan_o` and `interlace_o` are unconnected. Needs a
  high-scan video path.
- Interlace output.

## Missing in the RTL
- ADVN (currently a no-op).
- PSET does not move DX/DY.
- CMMK (kanji ROM command): no kanji ROM interface.
- Ys superimpose: stored in the palette, no output.

## Differences from hardware
- Mid-line register changes apply from the next line.
- No command timing model (LMMV 9.2 ms vs openMSX ~6.4 ms); TR is set when the engine is ready.

## Safety
- Upload guard: an upload (pack + carts above 31.5 MB on a 32 MB board) can overwrite the
  V9990 VRAM at `0x1F80000`. Option: move the VRAM above 32 MB on 64/128 MB boards.

## Done
- Full BSD-3 text in the Readme (Third-party licences), 2026-11-10.
