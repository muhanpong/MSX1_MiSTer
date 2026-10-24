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
| `golden` | PCM engine output bit-exact (comparator lag 0, no +-1) to `sim/golden/golden_pcm_omsx.py` (golden_pcm.py, checked against `ref278.cpp`, the openMSX YMF278.cc port, plus the wave-write position reset and reg 06h writes) on 18 scenarios, at 128.86 MHz (the PIPE datapath the board runs) and SDRAM read latency 1 and 20 | `mutants` |
| `mutants` | every engine mutant FAILS golden. For `ymf278_pcm_engine2.sv` they are generated from the file under test by `mutants/make_engine2_mutants.py` (19: interpolation, EG, DAMP/PRVB, TL ramp, LFO, pan/DO1, header backfill/dirty mask/table bank, loop end/loop address, wave-write position reset, F9h mix, +1 LSB); a new engine brings its own `MUT_DIR` | a mutant that passes means the gate is blind there: add a scenario |
| `cpuvis` | CPU-visible behaviour of `ymf278b_top` access by access against an openMSX YMF278B model (`sim/cpuvis`): read data, status/BUSY/LD timing, io_ack hold, NEW2/ID, reg 2/3-6, slot read-back, F8h/F9h, OPL2 remap, warm reset. Known differences are model flags D1..D9 (`docs/opl4_scratch/SPEC.md` D); every flag must change at least one observation | its 15 mutants (`mutants/make_cpuvis_mutants.py`) must all fail (built in) |
| `stress` | the current engine's per-byte MLAB register file under writes aimed at slot reads, warm resets (`sim/lockstep/run_stress.sh`) | its own 4 mutants + `reset_len=8` must fail (built in) |
| `memwr` | fullsys (FS-A1GT, tdm128, +moonsound): R800 OTIR 1024-byte wave-memory upload + readback, 0 errors | `REGS=` a ymf278b_regs.sv with `MEM_WRITE_DELAY` 0 must FAIL (`MEMWR_TAG=` keeps the two runs apart) |
| `resource` | fit report (`FIT_DIR`, default `$W/output_files`): PCM <= `PCM_ALM_MAX` (1200), MoonSound <= `MS_ALM_MAX` (2500), no warning 10999 | the current engine fails the 1200 budget (2,826 ALM, 2026-10-24) and passes 3000/4200 |

`harness.sh all` = golden mutants cpuvis resource; `HEAVY=1` adds stress and memwr (fullsys builds take
tens of minutes; `GEN=` points at `sim/fullsys/prep.sh` output when it lives outside the tree).
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
| golden_pcm.py | `sim/golden/` | per-scenario comparison (checked against ref278) |
| current engine | `rtl/pcm/ymf278_pcm_engine2.sv` | lockstep / regression reference; keep it in the repo |
| Nuked-OPL3 | `sim/golden/fm/run_fm_golden.sh` | FM |
| openMSX | `~/data/openmsx_v9968` | BUSY, timers, software register traces |
| cpuvis model | `sim/cpuvis/cpuvis_check.py` | openMSX YMF278B/YMF278/YMF262 CPU-visible behaviour, cited by line, with the RTL's deviations as flags |

Known intended differences between the RTL and openMSX (the python model mirrors them):
eg_cnt off-by-one, no LFO advance on EG_OFF slots, vibrato ÷12 truncation toward zero
(`sim/golden/RESULTS.md`). A new engine either keeps them or removes them on purpose, with a
scenario that shows which.

## Reporting

- Report every number with its control: `GATE golden PASS` + `mutant X caught`.
- Say what was not run (board, FM, 32 MB map, other machines).
- User-facing text in Korean; commits, code comments and this harness stay English.
