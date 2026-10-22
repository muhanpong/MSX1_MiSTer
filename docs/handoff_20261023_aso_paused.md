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
