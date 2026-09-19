# Handoff 20260920 — turbo R: three hardware fixes, two open

Branch `nextz80` in `.claude/worktrees/readcache`, **12 commits ahead of
origin/nextz80, not pushed**.  Predecessors: `handoff_20260918_cpuswap.md` (the
peer's, the fuller narrative) and `handoff_20260918_session.md` (this machine's;
its §7/§8 cover MULUB and the VDP spacing).

## 0. What shipped today

| RBF | md5 | Contains |
|---|---|---|
| `MSX1_20260919a_r800clk` | `f…`/see output_files | R800 speed ladder 7.16 / 21.5, OSD rows swap on the CPU selection |
| `MSX1_20260919b_r800vdp` | `2c3934f5344d` | + VDP write spacing, fixed 10.1 us |
| **`MSX1_20260920a_sdwrvdp`** | **`b300544613cc`** | + SD **write** pacing, spacing became an OSD dial (default 8.66 us) |

BUILDGATE PASS on all three.  20260920a: slow setup +0.165, fast hold +0.004,
7/7 clock relations, ALM 77%, M10K 71%.

Board test assets, all under `games/MSX1/`:

- `DSKS/PCMTEST.dsk` (md5 `c87930b69b3b`) — PCMPLY: four rates timed with the
  E6h counter plus the BC=0 / VRAM / CTRL+STOP cases
- `DSKS/MULUTEST.dsk` (`5050964194…`) — MULUB/MULUW conformance, self-checking
- `DSKS/R800TIME.dsk` (`53d0db36…`) — per-path instruction cost
- `MSX/Panasonic/Panasonic FS-A1GT.MSX` and `FS-A1ST.MSX` (+ RAM variants) —
  from the peer: **real turbo R BIOS, so 002Dh really is 03** and the overlay's
  forced version byte is no longer the only way to get a turbo R

## 1. Fixed and confirmed on hardware

**MFRSD partition loss at speed.**  `cf405fa` paced SD *reads* against
spi_divmmc; hardware still lost the partitions at T80s 21.5 MHz and the R800
7.16 rung.  spi_divmmc ignores `tx` exactly as it ignores `rx`
(`spi_divmmc.sv:27`), and an SD command is six bytes written back to back, so a
dropped write malforms the command — which still surfaces as a read that cannot
find the partitions, which is why reads had looked like the whole story.  Fixed
by pacing writes too, through a new `sd_io_window` out of mfrsd (kept separate
from `sd_card_data_en`, which `mem_unmaped` keys on).  Partitions now read at
both speeds.

**ASO's missing bands, and Z80BENCH's missing characters, were one bug.**
A VDP port access cost 0.56 us here against 8.66 us on a real turbo R, so ASO's
24-write split-screen return block took 0.2 raster lines instead of 3.4, and
requests arrived inside the previous VRAM slot and were dropped.  Off-core proof
(openMSX, everything held fixed but the spacing): the screen flips broken →
correct between 4 and 6 us at a 10.74 MHz base, and the threshold rises with the
speed of the surrounding code.  Now `Video settings → R800 VDP wait`,
`O[77:75]`, eight steps, default 8.66 us, `use_nz` only.  On hardware: bands 0/0,
characters clean, SCMD fine at both rungs, non-VDP paths untouched.

**R800 speed ladder.**  NextZ80 ran straight off clk21m and the OSD speed steps
never reached it.  `nz_bus` now takes a stage-advance enable: `O[70]` picks
7.16 MHz (clk21m/3, the R800's own clock) or unpaced.  The Z80 and R800 ladders
share one menu slot, swapped by menumask 13/14 on the CPU selection.

## 2. Open

**ASO: no sprites at all, and 0-1 bad lines at the bottom.**  At 8.66 us the
bands are right but **every sprite is gone** (not just the top field, corrected
by the user).  The likely mechanism is in the peer's disassembly: the repoint
block writes `R#8 = 2Ah` (bit 1 = SPD = sprites off) and the return block writes
`R#8 = 28h` to turn them back on.  If the return's R#8 never takes effect, the
whole frame runs with sprites disabled — which is exactly "all sprites missing".
Board sweep so far: **7.5 us fails at the bottom**, 8.66 us gives bands 0/0 with
0-1 bad lines at the bottom, 9-10 us also acceptable, 10.1 us gives 2-3 flashing
lines.  So the bottom has an optimum near 8.66-9 and cannot go lower — but the
**sprites are gone at every setting tried (7.5, 8.66, 10.1)**, which means the
sprite loss is NOT a spacing effect and has to be a separate defect.

Where to look: `vdp_sprite.vhd:363` samples `REG_R8_SP_OFF` once per line, at
`DOTSTATE="01" AND DOTCOUNTERX = 256+8`, and that sample decides the next line.
A late R#8 would cost some lines; losing every sprite in every frame looks more
like R#8 never coming back to 28h at all.  The discriminator asked for: same
build, **CPU = Z80**, does ASO show sprites?  Yes -> R800-path only (suspect the
VDP wait's effect on the 99h byte-pair latch); no -> a pre-existing defect that
the broken band was masking, and a different investigation.

**Illusion City stops in a 4-byte loop at 08E4-08E7.**  Panel decode of the
board: every freeze detector dark (so the CPU is fetching, not halted), live PC
08E7, IM 1 with I=00, R#0/R#1/R#2 = 06/62/1F (display on), and **no VDP register
write for ~870 frames = 14.5 s** while the screen stays black.  Page 0 RAM, so a
routine the game copied there.  Sent to the peer for a breakpoint on
`illu_st`: what the loop reads, and what would let it out.  Note the pack used
was not yet confirmed (ST pack vs the older MSX2+ pack + forced 002Dh).

**002Dh and the 0180h overlay.**  Both still forced whenever the feature block is
on.  The GT/ST packs change the context: with a real turbo R BIOS the forced
version byte is unnecessary.  §2 of `handoff_20260918_session.md` has the detail;
the 0180h overlay decision (do not use the five affected packs with the option
on) stands.

**PCMPLY** is built and benched but nothing has ever called it; `PCMTEST.dsk` is
the program that would, with real-turbo-R reference numbers in §3 below.

## 3. Reference numbers worth keeping

Per-instruction cost, `R800TIME.COM`, us/op (openMSX Panasonic_FS-A1GT is the
real R800; ours is NextZ80 at the two rungs):

| | real R800 | ours 7.16 | ours 21.5 |
|---|---|---|---|
| NOP | 0.160 | 0.138 | 0.096 |
| `LD A,(BC)` same DRAM page | 0.660 | 0.279 | 0.191 |
| `LD A,(BC)` page cross / cache thrash | 1.167 | 0.838 | 0.612 |
| `OUT (A0h),A` (PSG) | 1.649 | 0.564 | 0.555 |
| `DJNZ $` | 0.441 | 0.240 | 0.163 |

Two things fall out of that table.  We are faster on every path, but by 1.16x to
2.93x depending on the path, so the *profile* is much flatter than a real R800's
— and `OUT` barely moves with CPU speed (1.02x from 7.16 to 21.5), because I/O
cost here is set by the bus guard, not the CPU.  That is why the VDP wait could
be dialled without touching CPU speed.

Z80BENCH 1.4.2: real R800 (FS-A1GT) = **575%, "20.59 MHz"**; ours = 921% at the
7.16 rung, 1381% unpaced; T80s = 600% at 21.48 MHz, 100% stock.  Its "CPU Speed"
line is Z80-equivalent throughput, not a clock.  Its R800 detection is purely
`MULUB` flags at 1E26h — nothing reads the S1990 register.

MULUB/MULUW on a real R800 (`MULUTEST.COM`, 9/9): `05*03`=000F F=00,
`FF*FF`=FE01 F=01, `01*00`=0000 **F=40 (Z set — this one case is the whole of
Z80BENCH's detection)**, `80*02`=0100 F=01, `11*0F`=00FF F=00, MULUW
`1234*5678` = DE:HL 0626:0060, `FFFF*FFFF` = FFFE:0001, `HL,SP 0100*0234` =
0002:3400, and `ED CB` must leave HL alone.

PCMPLY on a real turbo R (`PCMTEST.COM`, 1000 samples): the four rates come out
1 : 1.98 : 2.98 : 3.97 as they must; BC=0 returns at once; **the VRAM bit is
implemented there and plays**, where ours returns immediately.

## 4. Pitfalls from this session

- **BDOS destroys HL.**  `PCMTEST`'s `putc` did not preserve it, so `hex16`
  printed a corrupted low byte after the high one — which read as "openMSX's E6h
  low byte is stuck at 00" and sent me after an emulator bug that did not exist.
  The peer's debugger dump cleared openMSX; the same program with an HL-preserving
  `putc` (`R800TIME`) had been correct all along on both machines.  Fixed and
  redeployed.  Any MSX-side measurement tool: save the value before you print it.
- **The pause symbol in a screenshot proves nothing.**  Taking a screenshot
  pauses the core, so every screenshot carries it.  Confirmed against a control
  set from another day.
- **The debug overlay panel is a serial port.**  Both stalls this session were
  diagnosed from one PNG each: sample the centre of each cell, 39 rows, anchors
  `ab_pc=042A` and `ppi_ctl=8102` to prove the decode is aligned.  `noM1` lit +
  `WAIT` dark means the CPU stopped fetching; all detectors dark with a live PC
  means it is spinning.
- **An intermittent fault will hand you a passing run.**  SCMD was declared
  closed on one good run; it was not.  See §7 of the 20260918 session handoff.
