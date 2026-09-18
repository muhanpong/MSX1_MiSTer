# cpuswap — T80s ⇄ NextZ80 hand-over without reset

Branch `cpuswap` (from `nextz80` 0e04047).  Goal: switch the MSX CPU between the
cycle-accurate T80s and the fast NextZ80 at run time, triggered by the OSD or by
software, with no reset and no lost state.  Decisions: undocumented flag bits 3/5
are not carried, NextZ80 stays on clk21m for now (2026-09-17); the branch carries
T80s + NextZ80 only (A-Z80 dropped), and the software switch mimics the turbo R
Z80/R800 switch, NextZ80 standing in for the R800 (2026-09-18).

Status (branch `cpuswap-cores`, 2026-09-18): **wired into `msx.sv`**, A-Z80
removed from the build; lockstep bench passing on the shared, msx.sv-shaped bus
with mutation checks.  **Confirmed on hardware 2026-09-18** (build 20260918b):
switching works and games run across a swap; a few minor defects reported, not yet
characterised.

## Pieces

| file | |
|---|---|
| `cpuswap_ctl.sv` | RUN → XFER → FLIP → SETTLE hand-over state machine |
| `nz_bus.sv` | NextZ80 on a Z80-shaped bus: one masked clock after every advance, ≥1 visible clock, WAIT extends |
| `cpuswap.qip` | NextZ80 (`../nextz80/patched`), `cpuswap_ctl.sv`, `nz_bus.sv` |
| `../../peripheral/turbor/turbor.sv` | turbo R S1990 (E4h/E5h, reg 6 bit 5 = Z80/R800), BIOS overlay, E6h timer, PCM, pause |
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

## Integration (`rtl/msx.sv`, `MSX1.sv`)

- **Owner.** `cpuswap_ctl.want_nz` = `turbor.r800`.  Software: `OUT (E4h),6 /
  OUT (E5h),0` or BIOS `CHGCPU` (Turbo R features On).  OSD `O[118]` "CPU (turbo
  R)" drives `turbor.set_stb/set_r800` when the menu closes and the choice changed,
  and again after every reset (the S1990 resets to Z80).
- **Bus.** Owner's strobes, forced idle while `busy`; address/data muxed by
  `use_nz`.  NextZ80 through `nz_bus` (`RESET` tied 0: LOAD is the only entry; a
  reset sample taken while frozen would survive LOAD).
- **Pacing.** Everything that keyed on `cpu_turbo` (bus guard, SDRAM closed loop
  `hs_win`, VDP/SD/OPLL pacers) keys on `cpu_paced = cpu_turbo | use_nz |
  resume_guard`.  `resume_guard` covers the first bus cycle after a hand-over: a
  resumed T80s sits in T2 and latches DI on its next CEN, at stock speed before a
  fresh SDRAM read is home.
- **SDRAM.** No NextZ80-specific request delay or pacer: the slot decode gates
  `sdram_ce` on MREQ/RD, and `nz_bus` gives the address a full clk21m of lead, the
  same head window the generic `-end 6` on `*sdram*ch2_*` was argued for (T80 at
  10.74).  Reads use the T80s-turbo closed loop.
- **M1 wait.** T80s: the 74LS74 pair.  NextZ80: MoonSound `exwait_n` only.
- **ce_cpu.** `MSX1.sv` feeds `clock.sv` speed 4 while NextZ80 owns the bus (PSG
  bus strobe, M1 wait pair and FDC run at full rate); the OSD speed returns with
  T80s.  `clock.sv` changes rate at a bus-idle point.
- **SDC.** NextZ80 → every clk21m register `-end 2` (clock-based rule): nz_bus
  masks all strobes for the clock after an advance, so no strobe-qualified capture
  can act on the first edge and reads are sampled on the second at the earliest.
  Needed: NextZ80's address is combinational out of its stage state, ~9 ns deeper
  than T80s' post-map.  Single-cycle exceptions (node rules outrank the clock
  rule): the cheat lookup (`a_q`, cheat RAM address registers, feeds `d_to_cpu`
  on a first-clock SDRAM cache hit) and `cpuswap_ctl` (SWAPPT → state).  T80s →
  NextZ80 and → `nz_bus.ph` `-end 2` (each core frozen while the other owns the
  bus).  An audit of registers sampling the bare address every clock found only
  debug latches besides the cheat lookup; re-audit when adding such a register.
  `tools/buildgate/relations.tcl` asserts all of these.
- **Triage.** `tools/sta/cpuswap_postmap_triage.tcl` (post-map, no fit).

## Bench additions for the integration

`tb_swap.sv` now drives both cores through the msx.sv mux: a registered memory
read, writes / OUTs / the IN 99h acknowledge taken on the `req` one-shot, one
`iowr_stb` per I/O write, a WAIT source (I/O 12h, 60h–63h reads and 56h writes
take 3 extra clocks and return junk until then).  `+sdlat=n` models SDRAM: data
home n clocks after the request edge, junk before, WAIT until home when paced
(NextZ80, `+turbo=1`, resume guard).  An unpaced T80s at CEN/6 tolerates n ≤ 4
(at CEN/3 only 1), so `sdram stock` runs at CEN/6 with n = 4.

| run | |
|---|---|
| `sdram stock`, `sdram st every` | random / every-point swaps at stock rate, SDRAM latency 4 |
| `sdram turbo` | every-point swaps, T80s paced, latency 7 |
| `sdram nz`, `sdram soft` | NextZ80 only (latency 6); S1990 switching (latency 4) |
| `no resume grd` | `+norg=1`, must DIFF (T80s executes junk after a swap) |

Further mutations, each turns the bench to FAIL: `nz_bus` without the masked
clock (`vis = run`: NextZ80-only times out, every swap run diffs — back-to-back
writes merge on `req`); `nz_bus` ignoring WAIT (junk I/O reads land in RAM).

## Next

1. `quartus_map`, post-map triage, then `tools/buildgate/build.sh --expect NextZ80`.
2. Hardware: boot at every speed on T80s, Z80BENCH; OSD R800 mid-BASIC;
   `OUT (E4h),6 / OUT (E5h),0` from BASIC; `CHGCPU` with Turbo R features On.
3. Later: PCMPLY hardware player, OSD LEDs, MULUB/MULUW, whether `002Dh = 03h`
   breaks anything (only with Turbo R features On).
