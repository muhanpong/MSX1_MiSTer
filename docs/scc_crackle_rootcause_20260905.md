# SCC+ crackle: root cause and fix (2026-09-05)

## Verdict

`IKASCC_player_control_s`'s serial multiplier, when **restarted while it is
already running**, skips one shift and emits a wrong sample — usually one code
high, and when the walk is cut short of the sign bit, the **one's complement**
of the correct value, i.e. a full-scale spike. SCMD rewrites each channel's
frequency as a **lo/hi pair four ticks apart**, ~360 times a second per channel,
so the second write of every pair restarts the first one's walk. On the captured
Passing Breeze stream that produced ~106 audible transients per second.

One-line fix (`rtl/IKASCC/src/IKASCC_modules/IKASCC_player_s.v`): clear
`accshft_en_z` on `mul_rst`, so a mid-walk restart looks exactly like a restart
from idle.

## Why the multiplier cares

Per sound sample the channel walks waveform bits 0..7 through a shift-accumulate
and latches `final_sound` on the tick `cyccntr` reaches 7. From idle,
`accshft_en_z` is 0 on the tick after `mul_rst`, so the accumulator holds still
for one **priming** tick while `wavedata_serial` fills with bit 0; the walk then
lines the sign step up with the latch tick.

Restarted mid-walk, `accshft_en_z` was already 1. The priming tick is skipped,
every shift moves up one place and the sign step lands on bit 6.

    waveform 0x7F, volume 15
      free-running restart      +119   (= openMSX (wav*vol)>>4)
      restart during a walk     -120   (one's complement of +119)

## How it was found

1. **SignalTap on the board.** `scc_stp[55:0]` in `scc_sound.sv` (behind
   `SCC_STP`) captures cs / addr / din / wave_A / mode plus a 3.58 MHz tick
   counter, sampled with a **storage qualifier on the write pulse** so 32K
   samples hold 248 ms of the register stream rather than 1.5 ms of clk21m.
   `tools/scc_replay/stp_to_events.py` turns the CSV export into replay events.
2. That capture **cleared the board**: its register stream matches openMSX's to
   within the same rates (66 349 vs 67 233 writes/s, same per-register mix), and
   the chip's own `wave_A` matched a Verilator replay of the same stream at
   corr 0.990. So the T80/slot gating was not injecting anything.
3. **The replay itself crackled.** Feeding openMSX's captured stream through our
   RTL and rendering it side by side with the openMSX-algorithm reference, the
   RTL render had the clicks and the reference did not — the defect was in our
   RTL and reproducible entirely in simulation.
4. Per-channel residuals localised it to freq writes; the wrong values turned out
   to be exact **one's complements** (0x77 -> 0x88, 0x6B -> 0x85, 0x5C -> 0x96).
5. A static transfer-function test (every waveform value x every volume, free
   running) was **exact, 768/768** — proving the multiplier itself is right and
   only its restart is wrong. `tb_phase.sv` then separated the two restart kinds:
   free-running 0/23 wrong, freq-write **39/40 wrong**, in the unmodified RTL.

## Measured effect (5 s Passing Breeze stream, vs the openMSX-algorithm render)

| | before | after | ideal |
|---|---|---|---|
| one's-complement samples at freq writes | 411 | **4** | 0 |
| freq writes landing within +-1 | 14 090 | **16 726** | 17 801 |
| residual rms (sum of 5 ch) | 14.94 | **8.37** | 0 |
| >48 transient clusters | 105.6/s | **55.4/s** | 0 |
| detector clicks (strong, z>12) | 10 | **3** | 0 |

Gates kept: `sim/run_sccplus.sh` 45/0, static transfer function 768/768.

## Two things that were tried and are NOT the fix

- **Narrowing the wrapper write strobe to one tick** (`scc_sound.sv`): a no-op.
  The replay TB's strobe is already one tick; the 2-tick window comes from
  IKASCC's own `freq_changed | freq_changed_z`.
- **Making the restart pulse itself single-tick** (`cycle_rst` on `mul_rst` and
  `cyccntr`'s SET): still 39/40 wrong. The pulse width was never the problem —
  the stale `accshft_en_z` was. Reverted.

## Second defect found the same way: ch5 played one sample behind

With the multiplier fixed, per-channel alignment showed ch1-3 **bit-exact**
against the reference (mismatch 0.000, residual 0.2 codes) and all of the
remaining error sitting on ch4/ch5 — the pair that shares one wave RAM.

`ch4_wavelatch` / `ch5_wavelatch` exist because the K051649 gives ch4 and ch5
turns on a **32-tick time-division grid**, so each refreshes its waveform byte
once per grid period. The multiplier runs for nine ticks once per **position
step**, so whenever the refresh lands after that window the sample is computed
from the previous position's byte. ch5 was one sample behind for ~85% of steps
(settled value matched the reference in only 15.5% of segments).

For ch4 that is the chip: openMSX does not model the time division at all, so
ch4's 12% divergence is ours being *more* accurate, and it stays. But the SCC+'s
fifth channel has **its own RAM** and shares with nobody, so in Plus mode ch5 now
reads that RAM directly instead of through the latch:

| ch5, Plus mode | before | after |
|---|---|---|
| samples differing from reference | 59.4% | **0.0%** |
| residual (codes) | 7.19 | **0.21** |

Real/Compat still use the latch — there ch5 *is* the ch4 mirror and must follow
ch4's shared-RAM timing exactly.

## What is still not matched

ch4 alone: 12% of samples differ (residual 3.68 codes), which is the shared-RAM
time division openMSX omits. Nothing else deviates.
