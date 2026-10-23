# Handoff 2026-10-23 — ASO 224 on V9968: analysis paused (user)

Branch `V9968_Geo3D` (renamed from v9968_v9990, pushed to origin on the user's word).
Report in Korean.

## Board results
| rbf | contains | ASO 224 (R800) after SPACE |
|---|---|---|
| MSX1_20261022b_sdram128v9968_7fcf4fe | same-clock IRQ-event fix | black screen, **no sound** (CPU stuck) |
| MSX1_20261023a_sdram128v9968_ff50884 (md5 70d5ac44...) | + clear-only-what-was-returned (status latch 1 clk late) | **still fails** |

The V9958 build (nextz80) runs the same game. Neither fix explains the hang: both are real
V9968 bugs (sim/v9968_vram `+aso=30 +pollpad=0..11`: 17 of 1440 FH lost -> 0), but in the
bench a lost FH costs one frame, never a hang.

## Facts gathered
- R800 VDP I/O is paced on this branch too (`rtl/msx.sv:839` vdp_bus feeds v99_pending;
  gap 186 clk21m = ~744 clk_vdp by default, OSD "R800 VDP access wait"). core_builder: the
  NextZ80 runs ~1.8x a real R800 between I/O.
- The `+aso` bench only drives the four line-IRQ stages from the oracle trace; it is not
  the game. It cannot show where the board CPU stops.

## Next, when resumed
1. Find where the CPU stops on the board: a DEBUG build (MSX1_V9968.qsf now has DEBUG=1;
   evt_trace / PC forensics) or the overlay, if a hardware run is acceptable.
2. Or run the real game: fullsys V9968 + R800 with the ASO 224 disk (long boot; look for a
   shortcut first), first stop PC vs the openMSX msx2pp trace (skill openmsx-oracle).
3. Check what differs in the R800 path only: V9968 bus wait/ack with use_nz, port 9Ah/9Bh
   writes ASO makes, R#25+ registers the V9958 path ignores.

## Board debug capture (user, 2026-10-23)
`docs/evidence_20261023/aso224_ff50884_hang_overlay.png`: rbf ff50884, ASO 224 hung after
SPACE, OSD open (paused), DEBUG OVERLAY ON. The left panel shows the overlay rows at the hang;
not decoded yet. Start the resumed analysis by decoding it (rtl/debug_overlay.sv row map,
tools/decode_probe_shot.py). Note: this rbf was built with DEBUG=1 (qsf regenerated in 5128f0f).

### Decoded (2026-10-23)
Rows 7-29 are T80-only forensics (`dbg_pc_now` = t80_reg): in R800 mode they show the idle
Z80 (PC 0661), not the R800 -- ignore them here. Sanity: row 28 AB mode-set PC = 042A (BIOS
init) and row 26 = MS=1 ctrl=02, as on a healthy boot, so the decode is aligned.
Reg-probe rows (rtl/vdp_regprobe.sv; NOTE rows labelled r9/r19 are really R#5/R#8):

| reg | value | frame | oracle state at 555.09 ms after R#1=02 |
|---|---|---|---|
| R#23 | 00 | 0B54 | 00 |
| R#2 | 3F | 0B5C | 3F |
| R#5 | BF | 0B5C | BF |
| R#1 | 02 (display off, IE0 off) | 0B5E | 02 |
| R#8 | 28 | 0B5E | 28 |
| R#0 | 16 (SCREEN 5, IE1 on) | 0B7F | 16 |
| frame now | 1382 | | |

R#0=16 came 0x21 = 33 frames after R#1=02; the oracle's first in-game R#0=16 is at 555.09 ms
= 33.3 frames after R#1=02. Nothing of these six registers was written for 2051 frames after.
So the board stops exactly where the oracle (tr_aso.io) does: R#9=00, R#19=68h, R#0=16, then
the game does NOT poll -- it waits for the line interrupt as a CPU interrupt (oracle: next
access is the handler at 563.86 ms: R#15=1, S#1 read = 05, FH set). In-game R#1 is 02/42:
IE0 is off, so the line IRQ is the ONLY interrupt; music runs from it too -> silence.

Gap: nothing tested that path. sim/v9968_vram +aso polls S#1; VPROBE phase 4 tests IE0
(VBLANK) only. Next decisive sim: the register state above (oracle, full list via the
snippet in this session: R#0 16, R#1 02, R#9 00, R#19 68, R#23 00, R#25 02, ...), display
off, no CPU polling; watch int_n for the line-104 FH, then the same through fullsys with the
R800 (IM 1 -> 0038h) as a VPROBE phase "IE1 line interrupt, display off".
