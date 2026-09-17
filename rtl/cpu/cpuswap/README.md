# cpuswap — T80s ⇄ NextZ80 hand-over without reset

Branch `cpuswap` (from `nextz80` 0e04047).  Goal: switch the MSX CPU between the
cycle-accurate T80s and the fast NextZ80 at run time, triggered by the OSD or by
software, with no reset and no lost state.  Decisions: undocumented flag bits 3/5
are not carried, NextZ80 stays on clk21m for now (2026-09-17); the branch carries
T80s + NextZ80 only (A-Z80 dropped), and the software switch mimics the turbo R
Z80/R800 switch, NextZ80 standing in for the R800 (2026-09-18).

Status: **simulation only** — cores patched, controller written, lockstep bench
passing with mutation checks.  Not wired into `msx.sv` yet (see "Next").

## Pieces

| file | |
|---|---|
| `cpuswap_ctl.sv` | RUN → XFER → FLIP hand-over state machine |
| `s1990.sv` | turbo R S1990 CPU switch: E4h register select, E5h data, reg 6 bit 5 = Z80/R800, bit 6 = ROM/DRAM (read back only) |
| `../T80.vhd`, `../T80_Pack.vhd`, `../T80s.vhd` | `SwapPt` output; `DIRSet` also clears `Alternate` and the NMI latch |
| `../nextz80/patches/` → `../nextz80/patched/` | `LOAD`/`LDIR`, `XREG`, `SWAPPT`; LD R,A fix (see its README) |
| `sim/` | lockstep bench (`run.sh`, `tb_swap.sv`, `swaptest.asm`) |

## The hand-over

Both cores are clocked all the time; only the owner advances (T80s: `CEN`,
NextZ80: `WAIT`).  The state is transferred in the 212-bit layout T80 already used
for `REG`/`DIR`: A F A' F' I R SP PC BC DE HL IX BC' DE' HL' IY IM IFF1 IFF2.

1. `want_nz` changes (any time).
2. The owner reaches a **swap point** and says so on a registered output.  The
   controller holds the core combinationally in that same clock, so it takes no
   further edge.
3. XFER: one `DIRSet` (into T80s) or `LOAD` (into NextZ80) pulse from the frozen
   owner's state.
4. FLIP: `use_nz` toggles; the other core runs from the next clock.

A **swap point** is "between two instructions, next opcode not yet counted":

| | T80s | NextZ80 |
|---|---|---|
| where | T2 of the next M1 (after the T1 edge) | right after the last-stage edge, which already fetched the next opcode |
| why there | T80 commits the previous instruction's result (`Save_ALU_r`, `Read_To_Reg_r`) on the **T1 edge of the next M1**; PC/R count the opcode on the T2 edge | everything commits on that edge; `XREG` winds PC and R back by the fetch |
| resumes as | the frozen T2 state (strobes of that fetch still asserted) | `FETCH`=NOP, stage 0: a plain fetch at PC |

Excluded (the swap waits for the next instruction): prefixes (CB/ED/DD/FD),
EI (interrupt delay), HALT, an NMI/INT being accepted, reset.  A T80s block
instruction can hand over between repeats (it restarts on the other core); NextZ80
cannot (no fetch between iterations) and waits for the last iteration.

Not transferred: WZ/MEMPTR, Q.

## Bench

```
GHDL=<ghdl> SJASMPLUS=<sjasmplus> rtl/cpu/cpuswap/sim/run.sh [seeds]
```

Tools (none are in the repo; this session built them in its scratchpad):
GHDL 4.1.0 `ghdl-gha-ubuntu-22.04-mcode` (newer releases need glibc 2.38),
sjasmplus 1.20.3 (`make USE_LUA=0`), Verilator 4.038.  ModelSim ASE 17.0 is
installed but its `vsim` needs 32-bit X11 libraries that are not.

T80s is synthesised to Verilog by GHDL from the real `rtl/cpu` sources (sim copy:
`T80.vhd:611` `x"7"` widened — GHDL rejects the width mismatch, Quartus accepts
it).  One 64K memory, one I/O space, INT raised every N clocks and dropped by
`IN (99h)` like the VDP.  `swaptest.asm` exercises flags, EXX/EX DE,HL/EX AF,AF',
IX/IY with DD/FD CB and undocumented halves, CB/ED ops, R and I, block moves and
searches, calls/RST/stack, port I/O incl. block I/O, and IM 1/2/0 with HALT, six
iterations.

The compared trace is every data write below E000h plus every OUT, plus two
bench-side assertions:

- `P` — an ISR ran with no INT pending (phantom interrupt);
- `E` — a transfer happened at the instruction right after EI; INT is raised on
  it, and the program's ISR records an interrupt taken inside the EI delay (8050h).

Runs: T80s only (reference), NextZ80 only, eight random-swap seeds (20–3000
clocks apart), T80s at CEN/3, swap at **every** swap point (~72 000 swaps),
every point with INT every 997 clocks (~80 000), five EI rhythms, software
switching through S1990 register 6 (four switches per iteration: a bare `OUT` and a
turbo R `CHGCPU`-style routine that moves the context through the stack; register
read-backs 06h/60h/00h/60h/40h and reg 5/15 checked in the trace), and a negative
control (one bit flipped in one transfer, must differ).

### Mutations (each must turn the result to FAIL)

| mutation | caught by |
|---|---|
| T80 `DIRSet` does not clear `Alternate` | random, every-point |
| T80 swap point at T1 (before the deferred write) | random |
| T80 swap point ignores EI | EI rhythms (`E`) |
| NextZ80 swap point ignores EI (`status[11]`) | EI rhythms 0-12, 6-20 (`E`) |
| NextZ80 export ignores the DE/HL bank bits | random |
| NextZ80 export does not wind R back | every-point |
| NextZ80 `LOAD` keeps the stale INT sample | random (`P`) |
| NextZ80 `LOAD` does not restart `FETCH` | all swap runs (program crashes) |
| controller holds one clock late | random, NextZ80-only |

The NextZ80 EI rule is belt and braces: T80s resumes after its own interrupt
decision, so handing it the bus right after EI cannot take the interrupt early (no
8050h write in that mutant) — the `E` assertion is what catches it.  The T80s rule
is the one that matters: NextZ80 resamples INT on `LOAD`.

Bugs the bench found in the first version: the phantom interrupt (stale `SINT`),
and in NextZ80 itself R lagging by one after `LD R,A` (patch 0002) — both visible
in NextZ80-only runs or random swaps, both fixed.

Core differences that are masked, not transferred: flag bits 3/5 (both cores),
N after INIR/OTIR/INI/IND/OUTI/OUTD (T80 derives it from the byte, NextZ80 sets
the documented value) — the program logs only Z after block I/O.

## Next (integration, not started)

1. Which cores the branch carries: `nextz80` runs A-Z80 at 3.58–10.7 and T80s at
   21.5.  Seamless switching pairs T80s with NextZ80, so T80s must own the stock
   speeds again (A-Z80 dropped or kept as a third, non-swappable core).
2. NextZ80 bus contract in `msx.sv` (review `docs/nextz80_review_20260912.html` §4):
   one clock per bus cycle, registered-read latency via the half-rate enable, no
   RD/RFSH (`rd = MREQ & ~WR`), SDRAM ch2 and pacers re-derived.
3. Bus quiescence during XFER: a frozen T80s holds MREQ/RD of the interrupted fetch;
   the incoming T80s presents them again at T2 and must get a fresh read (and WAIT).
4. S1990 into the I/O decode and `d_to_cpu`; OSD and port interplay (`set_stb`).
   Turbo R software only switches after checking the MSX version (002Dh = 3) and
   calling BIOS CHGCPU/GETCPU (0180h/0183h), which this MSX2+ BIOS does not have:
   without those, only software that writes E4h/E5h directly uses the R800 path.
5. OSD speed menu, SDC for NextZ80, and the ~20 diagnostics that read `t80_reg`.
