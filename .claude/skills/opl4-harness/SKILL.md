---
name: opl4-harness
description: Verification harness for (re)building the MSX1 MiSTer core's OPL4 / MoonSound (YMF278B PCM + OPL3 FM) RTL. Use whenever a change touches rtl/peripheral/SOUND/ymf278b_fpga (engine, regs, top) or the MoonSound CPU/SDRAM glue, before claiming anything works, and before asking for a board run.
---

# OPL4 harness

Gates are executable. A claim about the OPL4 RTL is reported only with the gate line that proves it
and the negative control that shows the gate can fail. "It should work" is not a result.

Runner: `scripts/harness.sh <gate>` (bundled with this skill). Each gate prints one line
`GATE <name> PASS|FAIL <detail>`; the run ends `HARNESS PASS|FAIL`. Outputs land under `$OUT`
(default `/data/_claude/tmp/opl4h`; `/` is full, big output goes to `/data/_claude/tmp/<session>/`).
What each scenario and each cpuvis block covers, and every intended difference from openMSX:
`docs/opl4_scratch/SPEC.md`.

## Gates

| Gate | What it proves | Negative control |
|---|---|---|
| `oracle` | the golden model is exactly "openMSX + SPEC section C": `sim/golden/ref278.cpp` (openMSX YMF278.cc port) with `REF_OMSX=1 REF_DEV=I1,I2,I4,I5,I7,I8,I9,I11` equals `golden_pcm_omsx.py` byte for byte on every golden scenario | built in: dropping any one flag must change at least one scenario (a flag nothing needs is a FAIL); a ref278 run that dies or writes a short stream is a FAIL, not a "diff" (`ORACLE_REF=` a stand-in that crashes without I4: FAIL). It proves model = openMSX + named differences, not that the differences are right |
| `golden` | PCM engine output bit-exact (comparator lag 0, no +-1) to `sim/golden/golden_pcm_omsx.py` on 22 scenarios (`SCEN` entries `name:frames:model[:lats]`), at 128.86 MHz (the PIPE datapath), SDRAM read latency 1 and 20 (`sc_songchange24`: 1 only) | `mutants` |
| `load` | heavy load bit-exact at longer latencies: `sc_songchange24` (24 voices, 96 writes in one frame) at lat 6/10/20. **The current engine FAILS** (SPEC H4); a new engine must pass | the current engine |
| `mutants` | every engine mutant FAILS golden. For `ymf278_pcm_engine2.sv` they are generated from the file under test by `mutants/make_engine2_mutants.py` (20: interpolation, EG, DAMP/PRVB, TL ramp, LFO, pan/DO1, header backfill/dirty mask/table bank, loop end/loop address, wave-write position reset, F9h mix, +1 LSB, slots 12-23 never dispatched); another engine brings its own `MUT_DIR` | the mutants are the control; none of them touches scheduling yet (SPEC H8) |
| `cpuvis` | CPU-visible behaviour of `ymf278b_top` access by access against an openMSX YMF278B model (`sim/cpuvis`): read data, status/BUSY/LD timing, io_ack hold, NEW2/ID, reg 2/3-6, slot read-back, F8h/F9h, OPL2 remap, warm reset. Known differences are model flags D1..D9 (`docs/opl4_scratch/SPEC.md` D; D3/D4/D5/D7 are tolerated RTL defects); every flag must change at least one observation; at least `CPUVIS_MIN_CHECKS` (717) judged and at most `CPUVIS_MAX_UNJUDGED` (0) unjudged, and the judged check keys equal `sim/cpuvis/checks_baseline.txt` (`CPUVIS_BASELINE`, named as BASELINE OVERRIDE on the PASS line; a new engine that moves ack timing changes them: review the diff, commit a new baseline) | its 16 mutants (`mutants/make_cpuvis_mutants.py`) must all fail (built in) |
| `stress` | the current engine's per-byte MLAB register file under writes aimed at slot reads, warm resets (`sim/lockstep/run_stress.sh`) | its own 4 mutants + `reset_len=8` must fail (built in) |
| `reset` | the register file's reset sweep: the cpuvis warm reset (op block G-RESET: every slot's fields 4 and 9 written before, read after) at the engine's minimum length (engine2 24 clk, engine3 48) passes, 8 clk shorter fails | built in (the short run is the control) |
| `memwr` | fullsys (FS-A1GT, tdm128, +moonsound), with `ENGINE` swapped in for the filelist's PCM engine (`PCM_ENGINE` in `assets/run1.sh`): R800 OTIR 1024-byte wave-memory upload + readback; PASS needs the probe to reach phase 15 and an error count line for phases 1, 6, 7, 8, 9, all 0 (only per-phase lines are summed: the closing VPROBE line repeats phase 7). The fullsys generated sources are rebuilt from `$W` on every run (`sim/fullsys/prep.sh` into the output dir; `gen/` is gitignored, so another tree's copy carries that tree's ports and stubs); a `GEN` outside `$W` or a filelist path outside the tree is a FAIL; the PASS line names the tree commit (+dirty from `git status --porcelain`, untracked files included), the gen hash and the engine+regs hash; an `ENGINE`/`REGS` file outside `$W` makes even 0 errors a FAIL | `REGS=` a ymf278b_regs.sv with `MEM_WRITE_DELAY` 0 must FAIL (1269 = phase 7 249 + phase 9 1020, 2026-10-24); `MEMWR_LOG=<r800.log>` judges a saved log (truncated / missing-phase logs FAIL); `ENGINE=` an engine whose reg 6 address does not advance: FAIL 2040; `GEN=` sdram128's gen: FAIL |
| `resource` | fit report (`FIT_DIR`, default `$W/output_files`): PCM (`u_pcm`, whatever the module) <= `PCM_ALM_MAX` (1200), MoonSound <= `MS_ALM_MAX` (2500), no warning 10999. FAIL when the map report is missing, the fit report is older than any MoonSound RTL file, the ALM count is not found, or `u_pcm`'s module is not the engine under test. A PASS line says BUDGET OVERRIDE / which report dir (resolved, so a symlink into another tree shows) when not the defaults. Timing is not judged: a fit that failed timing still passes here | the current engine fails the 1200 budget (2,826 ALM, 2026-10-24) and passes 3000/4200; each FAIL path was run once |

`harness.sh all` = oracle golden mutants cpuvis reset load resource (the current engine FAILS `load`); `HEAVY=1` adds stress and memwr (fullsys builds take
tens of minutes; memwr regenerates the fullsys sources itself, `GEN=` only for a prep.sh output inside the tree).
`W` defaults to the worktree the skill is installed in and is printed first; check it.
`ENGINE="<files>"` selects the engine under test; the last file is the one mutants replace.
A new engine keeps the `ymf278_pcm_engine2` module ports, so `tb/tb_golden_pcm.sv` and the
lockstep benches run unchanged; if a port must change, change the benches in the same commit and
rerun every gate on the OLD engine first.

## Rules (each one is a past failure in this repo)

1. **A build that fails is a FAIL.** The runner deletes the whole build dir before building and fails
   when no binary appears. (An old runner printed ALL MATCH from a stale binary.)
2. **No PASS without a caught mutant** for the gate that matters to the change. Write the mutant
   first: the smallest edit that breaks the behaviour you are about to rely on.
3. **RAM inference is proven by the map report's RAM summary**, not by the absence of warnings.
   Arrays with `ramstyle` inside a generate block became flops with no warning; fixed-index debug
   reads broke MLAB inference (10999).
4. **Register-file changes rerun `stress`.** The golden scenarios almost never write a register near
   the moment its slot is read. The MLAB file clears while reset is held and needs ≥ 24 clk of reset.
5. **CPU-visible timing comes from openMSX**, not from what the current RTL does:
   `~/data/openmsx_v9968` `YMF278B.cc` (memory write busy ≈ 28 master clocks, a status bit). The
   current RTL drops BUSY when a write is *issued*, not when it *lands*, and `MEM_WRITE_DELAY` 1024
   covers the gap; values ≤ 200 lose bytes in R800 mode (`memwr`).
6. **One Quartus job at a time** (check `pgrep -x quartus_map/quartus_fit/quartus_sta` — not
   `pgrep -f`, which matches your own command). ALMs need a fit; map-only gives ALUTs.
7. **Simulation results are judged from files**, not from scrolled stdout (lines can be lost).
8. **Board runs are expensive.** Ask for one only when every gate passes and the question is one
   only hardware can answer; give the checklist from PLAN.md §6.

## Oracles

| Oracle | Where | Use |
|---|---|---|
| ref278 (openMSX YMF278.cc, verbatim math) | `sim/golden/ref278.cpp` | the chip reference for PCM samples |
| golden_pcm.py | `sim/golden/` | per-scenario comparison (checked against ref278 by the `oracle` gate) |
| current engine | `rtl/pcm/ymf278_pcm_engine2.sv` | lockstep / regression reference; keep it in the repo |
| Nuked-OPL3 | `sim/golden/fm/run_fm_golden.sh` | FM |
| openMSX | `~/data/openmsx_v9968` | BUSY, timers, software register traces |
| cpuvis model | `sim/cpuvis/cpuvis_check.py` | openMSX YMF278B/YMF278/YMF262 CPU-visible behaviour, cited by line, with the RTL's deviations as flags |

Known intended differences between the RTL and openMSX are SPEC section C; the ones that change
samples are ref278 flags (I1 EG step order, I2 no LFO on EG_OFF, I4 position before sample, I5 F9h
timing/integer, I7 no pause while silent, I8 R#2 memory type ignored, I9 writes into the ROM
half, I11 key events at the slot's turn). A new engine either keeps one or drops it on purpose: drop the flag from `ORACLE_DEV`, change the model, same commit.
CPU-visible ones are cpuvis flags; D3/D4/D5/D7 there are RTL defects the gate only tolerates.
cpuvis prints how many BUSY/LD checks it could not judge (the next access started inside the window).

## Reporting

- Report every number with its control: `GATE golden PASS` + `mutant X caught`.
- Say what was not run (board, FM, 32 MB map, other machines).
- User-facing text in Korean; commits, code comments and this harness stay English.

## Engine selection (P2, 2026-10-25)

The module the last `ENGINE` file defines picks the engine: `ymf278_pcm_engine3` makes the
harness (memwr `-DPCM_ENGINE3`, cpuvis `+define+PCM_ENGINE3` in `run_cpuvis.sh`) select it in
`ymf278b_top.sv`, which also sets ymf278b_regs `MEM_WRITE_DELAY` to 107 for it, and the cpuvis
model drops the flags that engine does not have (`ENGINE_DROPS` in `cpuvis_check.py`: D10, D11,
D12) and expects that delay. `harness.sh p2` = cpuvis + reset (+ memwr with HEAVY=1), the P2
gates; golden on engine3 FAILS until P3 (no sound yet, and `tb_golden_pcm.sv` instantiates engine2).
