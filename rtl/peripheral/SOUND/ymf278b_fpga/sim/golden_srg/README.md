# srg320 YMF278B PCM engine vs the openMSX oracle (simulation only)

Question: could srg320's YMF278B PCM engine (about 960 ALM) replace ours,
`rtl/pcm/ymf278_pcm_engine2.sv` (2,852 ALM)? This directory runs it through
the PCM golden scenarios in `../golden` and measures how far it is from
openMSX. Measured 2026-10-21.

**Verdict: not adoptable as it is.** Four expression-width/signedness bugs
corrupt the output: negative samples under attenuation, interpolation at zero
crossings, vibrato, and right pan. With those four patched, it is still 5–100 %
rms away from openMSX on every scenario (our engine: 0 % against
`golden_pcm.py`). It also has behavioural differences that matter on an MSX:
CPU sample upload writes one byte too high, attack can stall for up to 93 ms,
the header load takes 12 samples and overwrites register writes made during
it, and it has no wave-table-header relocation, DAMP or pseudo-reverb. Details
follow.

## Rerun

    ./run_srg_golden.sh                 # about 3.5 min; prints every number below
    SKIP_OURS=1 SKIP_NEG=1 ./run_srg_golden.sh

Build products go to `$WORK` (default: the session scratchpad; set `WORK=` to
move it). The run prints measurements; it is not a pass/fail gate. Our engine
is run through the unchanged `../golden/run_pcm_golden_vl.sh` (which regenerates
`../golden/mem.*`/`sc_*.txt` with identical content and writes
`../golden/out/*_vl.txt`).

## Files

| file | what |
|---|---|
| `YMF278B.sv`, `YMF278B_pkg.sv` | srg320/Arcade-PsikyoSH2_MiSTer `rtl/PSH2/`, commit 28ddb1b7ab53 (2026-08-15), **unchanged** (md5 b822f467…, 843b9eee…) |
| `altsyncram_sim.sv` | behavioural altsyncram for the only configuration used: DUAL_PORT, read address registered on clock0, q_b unregistered, power-up 0. Mixed-port read-during-write is DONT_CARE in the instance, so `+define+RDW_NEW` switches old/new data and the run checks both |
| `tb_srg.sv` | plays a `sc_*.txt` script into the chip and writes one `L R` line per 44.1 kHz sample |
| `tb_signedness.sv` | unit check of the package functions as written vs as intended (Verilator on the package, iverilog on verbatim copies) |
| `compare_srg.py` | raw / best-lag / lag+gain / per-window-lag / envelope metrics |
| `summarize.py` | the results table |
| `run_srg_golden.sh` | everything |

The build strips one line, `` `define SIM ``, from a scratch copy of `YMF278B.sv`
(checked by diff). The line sits inside a `synopsys translate_off` comment,
which Verilator does not honour, and the `SIM` RAM branch it enables is illegal
SystemVerilog (procedural assignment to output net `Q`, PROCASSWIRE).
iverilog cannot parse the package (unpacked array parameter), so the full
engine runs under Verilator 5.052 only.

## Oracles

* **ref278** = `../golden/ref278.cpp`, a C++ port of openMSX YMF278.cc with
  the tables copied verbatim. It is the pure openMSX oracle. Its 12-bit decode
  matches openMSX597 `YMF278.cc:438-449`.
* **gold** = `../golden/golden_pcm.py`, the RTL-frame-semantics model.
* `golden_pcm_omsx.py` is **not** a pure openMSX model. It is `golden_pcm.py`
  plus one restored behaviour (position clear on a wave write while not keyed)
  and the reg-06h memory writes. On these 8 scenarios its output is identical
  to `golden_pcm.py`.
* gold and ref278 differ on 5 of 8 scenarios. For example, sc_square16 has 292
  of 1798 samples differing by more than 1 LSB (nrms 42 %, maxd 32768). The
  cause is that `golden_pcm.py` applies a new step in the frame of the write,
  while openMSX applies it one sample later because it advances after output.
  The waves keep the same pitch but have a different phase. This is the floor
  that any sample-exact comparison against ref278 has. The `seg` column
  (per-100-sample-window alignment) and the envelope columns are there to get
  below that floor.

## Testbench (and why to trust it)

* **Clock:** CE = CLK/2, as `PSH2.sv` drives it (`SYS_CE_R`). One slot is 32 CE
  and one output sample is 768 CE, so 44.1 kHz needs CE = 33.8688 MHz, the
  chip's own master clock. Measured pitch confirms this: the square16
  half-periods are 12/48/24/12/6 samples, identical to ref278 in every
  octave segment.
* **Memory:** `MDI = mem[{MCS_N[0], MA}]`, combinational. `MCS_N[0]` equals
  A21, and `PSH2.sv` uses `{.., MCS_N[0], MA}` in the same way. This covers the
  full 22-bit (4 MB) space. The chip samples MDI 7 clocks after it drives MA.
  A 1-clock registered memory (`+memlat=1`) gives bit-identical streams.
* **Register writes:** NEW2 is set first (A=2 05h, A=3 03h); without it A=4/5
  are ignored. Each register write is A=4 address then A=5 data, with WR_N low
  for 2 CE, then a 24-clock wait (REG_WR is consumed at the next CYCLE1_CE,
  every 16 clocks). Frame-N writes are issued during frame N-1 at
  apply_cycle/1948, as in `tb_golden_pcm.sv`.
* **LD polling (`+ldwait=1`):** after a wave-number write, the TB does real
  status reads at A=0 until LD clears, as a driver that honours LD would. LD2
  (set by the NEW2 write) only clears on a status read's RD_N rise.
* **Output:** OUT1 (raw 24-slot sum, TrimWave-saturated, no MIXPCM) is
  sampled the clock after `PCM_L` latches. Our TB uses `pcm_vol=3` (raw sum)
  and ref278 ignores 0xF9, so all three are on the same scale.
* **Self-checks:** across 8 scenarios × 2 checks (RAM read-during-write
  old/new, memory latency 0/1), 16 of 16 gave bit-identical streams. Reruns
  give an identical summary.

## Gain and lag (stated, not normalised away)

* **Gain:** the output is 127/128 (-0.068 dB) of openMSX at 0 attenuation, by
  construction. `VolCalc` multiplies by `{01,~L[5:0]}` = 127-L, where openMSX
  uses 128-L. Measured: square16 is ±16256 where ref278 has ±16384. The
  least-squares "gain" in the table is not a level difference. It falls with
  waveform mismatch. Use the envelope level column for level (srg_fix: -0.65 to
  +0.62 dB).
* **Lag:** the first non-zero sample comes at index 15 in srg against 1 in
  ref278, so there is 14 samples of start latency. The source is the 12-sample
  header load (one header byte per sample, LD set) plus the pipeline. After
  every later wave-number write, sound restarts after the same 12-sample load.
  Best global lag: +14 to +32. On periodic material the lag search can lock
  one period away (square16 +31/+32), which is one reason for the `seg`
  column.

## Results (lag-aligned, vs ref278; vs gold the srg numbers are within a few %)

`nrms` = rms error / rms of the reference. `seg` is the same after each
100-sample window is aligned on its own (±48). "env" is the overall level
difference of the 64-sample block-rms envelope. "blk" is the worst block
difference where ref > -40 dBFS.

| scenario | srg nrms / corr / seg | srg_fix nrms / corr / seg / env / blk | ours nrms / corr / seg / env / blk |
|---|---|---|---|
| sc_single8 | 23.7 % / 0.974 / 20.9 % | 11.0 % / 0.994 / 11.1 % / -0.08 dB / 0.3 dB | 0 / 1.000 / 0 / 0 / 0 |
| sc_square16 | 121.5 / 0.362 / 67.8 | 112.0 / 0.353 / 59.9 / -0.27 / 0.6 | 42.5 / 0.911 / 14.0 / +0.08 / 0.4 |
| sc_tri12_loop | 168.7 / 0.125 / 154.3 | 91.0 / 0.583 / 73.9 / +0.62 / 4.4 | 0 / 1.000 / 0 / 0 / 0 |
| sc_multi | 112.4 / 0.544 / 107.1 | 80.3 / 0.677 / 80.1 / +0.19 / 4.9 | 0 / 1.000 / 0 / 0 / 0 |
| sc_lfo | 21.9 / 0.981 / 15.6 | 10.5 / 0.995 / 5.7 / +0.30 / 1.1 | 0.02 / 1.000 / 0.02 / 0 / 0 |
| sc_pitchbend | 149.7 / 0.335 / 144.8 | 54.8 / 0.832 / 56.3 / -0.08 / 0.4 | 6.4 / 0.998 / 6.4 / 0 / 0.1 |
| sc_wavehi | 99.9 / 0.688 / 99.9 | 99.9 / 0.722 / 99.9 / **-54.2 dB** / 59.5 | 0.59 / 1.000 / 0.59 / 0 / 0 |
| sc_odd16 | 96.9 / 0.572 / 50.9 | 86.6 / 0.594 / 33.7 / -0.65 / 1.9 | 21.8 / 0.977 / 19.3 / +0.15 / 0.6 |

* exact / off-by-1 / bad: srg and srg_fix have 0–200 exact samples out of
  1500–3000 per scenario, and every one of the 16 rows is "bad" by
  `compare_pcm.py`. maxd is 15857–65535.
* Ours has 0 bad against `golden_pcm.py` on all 8 scenarios. Against ref278,
  ours is bit-exact on single8, tri12_loop and multi. The residual on the
  others is the gold-vs-ref278 step-timing floor above.
* `+ldwait=1` changes little except multi and lfo (see the full table in
  `$WORK/summary.md`).
* **srg_fix is not the DUT.** It is a scratch copy of the package with the four
  bugs below patched, to separate bugs from architecture.

## srg320 bugs (expression semantics, IEEE 1800 §11.8.1 / §11.6.1)

`tb_signedness.sv` output is the same in Verilator and in iverilog:

* **`VolCalc`:** `$signed(WAVE) * {2'b01,~L}` is an unsigned multiply. Negative
  samples get `-512*(L[5:0]+1)` added. Examples: VolCalc(-16384, 0) =
  **-16768** (intended -16256); VolCalc(-16384, 0x3F) = **+24576** (intended
  -8192). Every attenuated note has a sign-flipped or offset negative
  half-wave.
* **`Interpolate`:** both products are unsigned. When the two neighbours have
  opposite signs the result is wrong by ±1024·phase. Interp(-1024, 0, 32) =
  **32256** (intended -512). This gives a spike at every zero crossing; in
  single8 they come once per wave period.
* **`PhaseCalc`:** `$signed(PLFO) * F[10:4]` is unsigned. A negative vibrato
  becomes a large upward jump: lfo=-8 gives phase 10176 (intended about 8128).
* **`LevelAddPanR`:** `~PAN[2:0]` is inverted after being widened to 10 bits.
  Right attenuation for pan 10–15 is 0x3A0–0x300 (-87 to -72 dB) instead of
  0x0A0–0x000. Measured in tri12_loop: R at -89 dB where ref278 has -20 dB.

## Architectural and feature differences vs openMSX and our engine

| item | srg320 | openMSX / ours |
|---|---|---|
| interpolation | 6-bit fraction, between the *previous fetched* word (PWD RAM) and the current one; for step > 1 the "previous" word is last frame's, not pos-1 | 16-bit fraction, s[pos] to s[pos+1] |
| attack | `EVOL + ~EVOL*INC` with no `>>4`, so it jumps to 0 on the first step | exponential `(~env*inc)>>4` |
| EG increment index (rates < 0x30) | always SCNT[14:12], changing every 4096 samples. Measured on sc_wavehi (AR=10): chip idle 0 → **silent, -54 dB**; idle 4096 → instant attack, +5.4 dB vs ref278. That is an attack stall of up to 93 ms depending on uptime | `(eg_cnt>>shift)&7` |
| EG end | runs to 0x3FF; reading stops at ≥ 0x3C0 | EG_OFF at 0x280 (silent) |
| header load | 12 samples, one byte per sample, LD flag; CPU writes to LFO/AM/rate fields during it are **overwritten** (sc_lfo without LD wait plays without LFO; a halved-AM mutant gives a bit-identical stream) | immediate (openMSX), dirty-masked backfill (ours) |
| re-trigger on wave write while keyed | phase restart only; envelope not restarted (KON only from RELEASE) | keyOnHelper (envelope restart) |
| 12-bit nibble order | MAME order (even: b1[7:4]; odd: b1[3:0]) | openMSX order, the reverse (≤ 240 LSB per sample) |
| right pan | buggy (above); with the bug fixed, srg_fix has 3 dB/step from pan 15 = 0 dB, one step softer than openMSX (pan 15 = -2.5 dB) | openMSX table |
| wavetblhdr (reg 02h bits 4:2), waves ≥ 384 | not implemented (always wave*12) | implemented |
| reg 02h bit1 (memory type) | stored and read back, no effect | ROM/RAM map |
| reg 03h | only `REG_D[4:0]`, so A21 (SRAM at 0x200000+) is not reachable from the CPU | 6 bits |
| CPU memory write (reg 06h) | a reg-05h write triggers a prefetch read that post-increments MEMADDR, so **every reg-06h write after setting the address lands at address+1**. sc_memhit: 120 of 120 writes off by one | write at memAdr |
| memory access mode (reg 02h bit0) | required, as in openMSX; while it is set, **wave fetch stops** (`!MEMMODE[0]`) | playback continues |
| DAMP (field 4 bit6), PRVB pseudo-reverb | not decoded (PRVB latched, unused) | implemented |
| LFO | MAME-style per-slot divider/8-bit counter, shift-based depths | openMSX lfo_cnt/period tables |
| reg F9h PCM mix | OUT1 none; OUT2 shifts by 2·MIX bits (12 dB/step) | 3 dB/step |
| status / read-back | BUSY, LD, register read-back and reg-06h read present | present |

## Negative controls

* **Comparator:** these are on the sc_square16 reference, through
  `compare_pcm.py` / `compare_srg.py`.
  * The reference against itself: 0 bad, 0 bad.
  * Delayed by 7 samples: `compare_pcm.py` gives 1030 bad, because its ±2 lag
    window misses it. `compare_srg.py` finds lag +7 and 0 bad.
  * Noise: 1796 bad; corr 0.03.
  * Half gain: 1796 bad. The lag+g stage recovers gain 0.5000 exactly with 0
    bad.
* **Mutants:** built on srg_fix and run with ldwait.
  * **Interpolation disabled:** clearly worse where interpolation is
    exercised. Against ref278 (baseline srg_fix_ld):
    * single8: 10.98 % → 18.99 % nrms
    * lfo: 10.24 % → 15.85 %
    * pitchbend: 56.9 % → 87.4 %
    * tri12: 91.1 % → 96.5 %
    * odd16 and square16: slightly worse
    * multi: 97.3 % → 96.5 %, slightly *better*, consistent with srg's
      interpolation neighbour being wrong for step > 1
    * wavehi: silent, unchanged

    Direct A/B against srg_fix_ld: 25–105 % nrms.
  * **EncIncTbl row 0x10 (release, RR=4):** the A/B differs (2.7 % single8,
    3.9 % multi). Against ref278 it is invisible (11.26 % vs 10.98 %). No
    scenario releases long enough to show it, which is a coverage gap of the
    scenario set.
  * **AM depth halved:** A/B 0.29 % on sc_lfo; invisible elsewhere. The
    1500-sample sc_lfo covers about 1/7 of an LFO cycle, also a coverage gap.

## Limits

* Simulation only. The bug claims rest on the LRM and on two simulators, not on
  Quartus or hardware.
* `PSH2.sv` runs CE at 28.6 MHz (about 37.3 kHz output). The arcade core may
  never have been heard at 44.1 kHz.
* sc_memhit audio is not comparable: in srg the mode bit stops playback.
