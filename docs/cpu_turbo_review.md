# CPU turbo + MoonSound +3 dB — code review

**Date:** 2026-08-19  **Branch:** `moonsound_ascii16x`  **Scope:** uncommitted working tree
**Reviewers:** 4 independent agents (clock / bus / audio / adversarial) + main-session cross-verification
**Status of the code at review time:** not committed, not built, not deployed

> **UPDATE — fixes applied (same day, still uncommitted, still not built).**
> T1 + T2 (the two hangs), T3 (the test suite), H3 (`VDP_GAP18`), L1 (`cpu_turbo`
> from the latched speed) and the pacer resets are now in the working tree.
> `sim/run_turbo.sh` gates on real exit codes and reports 4/4 PASS, with the
> guard-OFF negative control firing as required. Measured with the fix:
> read/write windows back to the stock 12/6 clk21m, zero windows without a
> `ce_3m58_p`, zero windows under the SDRAM deadline, **1.48x at 7.16MHz and
> 1.72x at 10.7MHz**.
> Still open and NOT addressed: **H1** (SDC multicycle premise), **H4** (the OPLL
> write-gap, which no guard can fix), **M1** (wd1793 real-time constants), and the
> ghdl re-verification of T1/T2 against the real VHDL.

---

## Verdict

| Change | Verdict |
|---|---|
| **CPU turbo** (1x / 2x / 3x) | **Does not work.** Two independent deadlocks. Do not build until T1 and T2 are fixed. |
| **MoonSound +3 dB trim** | **Correct.** Zero defects found. Ships independently, subject to three conditions (C1–C3). |

Turbo-OFF (`cpu_speed == 0`) was checked hard by three reviewers and is clean: `ce_cpu_p/n` reduce to
literally the same expressions as `ce_3m58_p/n`, and every new term is ANDed with `cpu_turbo`.
The only change that is **not** turbo-gated is the MoonSound pipeline stage, which was verified
correct by simulation.

---

## Blocking defects

### T1 — the turbo bus guard can never release; any turbo mode hangs the CPU

**`rtl/msx.sv:290`** counts on `req`, but `req` (`rtl/msx.sv:642`) is a **one-shot**, not a level:

```verilog
// msx.sv:629-639 — iack kills req one clk21m cycle after it rises
if (iorq_n & mreq_n) iack <= 0;      // clear only when the M-cycle ends
else if (req)        iack <= 1;
// msx.sv:642
wire req = ~((iorq_n & mreq_n) | (wr_n & rd_n) | iack | vdp_hold);
```

`req` is therefore high for exactly one `clk21m` cycle per bus cycle — that is precisely what makes it
usable as the V9938's `REQ` one-shot. So `guard_cnt` saturates at **1** and can never reach
`GUARD_RD = 8` or `GUARD_WR = 2` (`msx.sv:273-274`). `bus_guard_n` (`msx.sv:300`) collapses to
`~cpu_turbo | ~bus_cycle`, holding `wait_n` (`msx.sv:346`) low for the whole bus cycle.

`WAIT_n` low keeps `MREQ_n` asserted, so `bus_cycle` never clears — **self-locking**. T80pa samples
`WAIT_n` only at the TState-2 `CEN_n` edge (`rtl/cpu/T80pa.vhd:169-170`, `CEN_pol <= not WAIT_n`), so
`CEN_pol` latches at 1 forever; every later `ce_cpu_p` is a no-op. The CPU is not slowed, it is stopped.

**Confirmed independently four times**, three of them by simulation. Representative measurement
(A-clock, guard fed the real `req` vs. a level wire):

```
fix=0 speed=0   M-cycles in 20000 clk21m = 919    guard_cnt=1
fix=0 speed=1   M-cycles in 20000 clk21m = 0      guard_cnt=1   *** CPU HUNG ***
fix=0 speed=2   M-cycles in 20000 clk21m = 0      guard_cnt=1   *** CPU HUNG ***
fix=1 speed=1   M-cycles in 20000 clk21m = 1333
fix=1 speed=2   M-cycles in 20000 clk21m = 1569
```

**User-visible symptom:** selecting 7.16 MHz or 10.7 MHz freezes the machine on the next opcode
fetch. Video keeps running (own clock), sound chips hold their last state, keyboard dead.
**Recoverable** — setting CPU Speed back to 3.58 MHz releases `WAIT_n` via `~cpu_turbo`.

---

### T2 — the interrupt-acknowledge cycle is a *second*, independent deadlock, and it survives the T1 fix

An INTA cycle asserts **`IORQ_n` only** — `RD_n` and `WR_n` both stay high. So `bus_cycle` is 1 while
no transfer strobe ever appears. A guard counting on any strobe-derived level never advances.

Timing chain, from source:
- `rtl/cpu/T80.vhd:1179` — `Auto_Wait <= '1'` during `IntCycle`, `MCycle = "001"`
- `rtl/cpu/T80.vhd:1165-1168` — that holds `TState = 1` for **three** core ticks
- `rtl/cpu/T80pa.vhd:178-182` — `IORQ_n <= IntCycleD_n(1)` shifts on each of those ticks, so
  `IORQ_n` goes **low on the third**, i.e. just before `TState` advances to 2
- `rtl/cpu/T80pa.vhd:155-159` — the branch that raises `IORQ_n` again fires at the `CEN_p` edge
  *leaving* T2, which is **after** the `CEN_n` edge where `WAIT_n` is sampled

Simulated with the proposed T1 fix already applied:

```
T2 CEN_n sample #1: iorq_n=1 mreq_n=1 rd_n=1 wr_n=1 | bus_cycle=0 bus_xfer=0 -> WAIT_n=1
T2 CEN_n sample #2: iorq_n=0 mreq_n=1 rd_n=1 wr_n=1 | bus_cycle=1 bus_xfer=0 -> WAIT_n=0
T2 CEN_n sample #3: iorq_n=0 mreq_n=1 rd_n=1 wr_n=1 | bus_cycle=1 bus_xfer=0 -> WAIT_n=0
...  HANG.  the bus_xfer fix alone is INCOMPLETE.
```

> **Caveat that belongs on the record.** No VHDL simulator is installed on this machine (no ghdl, no
> nvc; Verilator and iverilog cannot elaborate VHDL). *Every* statement in this document about the T80
> interaction — T1 and T2 alike — rests on faithful transliterations of `T80pa.vhd` / `T80.vhd`, not on
> a run of the shipping CPU. The transliterations were built branch-for-branch and the INTA wait-state
> count was **derived** from `T80.vhd`'s own recurrence rather than assumed, and it is insensitive to
> `IORQ_i`. Still: this is a hang-class bug. **Install ghdl and re-run the INTA case against the real
> `rtl/cpu/T80pa.vhd` before committing a fix.**

**Found by A-bus alone.** A-clock concluded the opposite ("INTA is safe") from source reading without
simulating, and said so explicitly; the main session had also raised INTA early and then wrongly
dropped it after discovering that `iack` is a one-shot latch rather than an interrupt-acknowledge
signal. The confusion is worth recording: **`iack` in `msx.sv` has nothing to do with interrupts.**

---

### Combined fix (both deadlocks) — measured end to end

```verilog
wire bus_xfer    = ~((iorq_n & mreq_n) | (wr_n & rd_n));   // COUNT on this, not on req
...
end else if (bus_xfer) begin                               // was: else if (req)
   if (guard_cnt != 4'hF) guard_cnt <= guard_cnt + 4'd1;
   if (ce_3m58_p)         guard_ce  <= 1'b1;
end
...
wire bus_guard_n = ~cpu_turbo | ~bus_cycle
                 | (mreq_n & rd_n & wr_n)                  // RELEASE: the INTA signature
                 | (guard_ce & (guard_cnt >= guard_min));
```

`bus_cycle` (`~(mreq_n & iorq_n)`) still **arms** the guard one T-state early, which is required:
T80pa asserts `WR_n` on the *same* `CEN_n` edge at which it samples `WAIT_n` (`T80pa.vhd:169` and
`:200`), so a guard armed on the strobe alone is one edge too late and would never stall a write.
`bus_xfer` **counts**, so `guard_ce` is measured over the real strobe window.

**Do not use the obvious repair `| (rd_n & wr_n)`.** It was measured and it silently defeats the write
guard: at the `WAIT_n` sample on a memory write `wr_n` is still high, so the term is 1 on every write
and the guard releases immediately — minimum write window back to 2 `clk21m`, and **1010 of 13131
write windows contained no `ce_3m58_p` at all**. That is exactly the SCC/OPLL write loss the feature
exists to prevent. Adding `mreq_n` is what makes the term INTA-specific: any memory cycle has
`mreq_n = 0` at that edge, and any I/O cycle already has a strobe asserted by the time `IORQ_n` drops
(`T80pa.vhd:162-166` drops `IORQ_n` and `WR_n`/`RD_n` together on the T1→T2 `CEN_p` edge).

An equivalent formulation that names the condition instead of deriving it — also verified against the
INTA case, and arguably clearer — is to exclude INTA from arming:

```verilog
wire inta      = ~iorq_n & ~m1_n;              // canonical Z80 interrupt-acknowledge signature
wire bus_cycle = ~(mreq_n & iorq_n) & ~inta;
```

`m1_n` is already used this way in the same file (`msx.sv:323`, `vdp_bus`). Either form works; the
`mreq_n & rd_n & wr_n` form is the one that has been measured end to end.

**Constraint — do not widen `req` itself.** The RTC depends on `req` staying a one-shot
(`rtc.vhd:132`, `w_wrt <= req and wrt`), and the V9938 uses it as its `REQ` one-shot. Every fix above
leaves `req` untouched and gives the guard its own wire.

**Measured with the fix, windows counted on the real strobe:**

```
config                 minRD  minWR  windows  no-CE-hit  <6cyc   M-cycles/run
3.58MHz stock            12      6      7472       0        0        9196
7.16MHz guard ON         12      6     10832       0        0       13334      (1.45x)
10.7MHz guard ON         12      6     12745       0        0       15687      (1.71x)
10.7MHz guard OFF         4      2     22414    4599    10345       27586      (unsafe)
```

Read and write windows at both turbo settings are restored to **exactly** the stock 12/6 `clk21m`,
with zero windows lacking a `ce_3m58_p` and zero windows under the SDRAM ch2 deadline. That is the
invariant the design was reaching for, achieved.

---

### T3 — the turbo test suite cannot fail

Two separate problems, both confirmed by inspection:

**(a) The TBs model a `req` the RTL does not have.** `sim/tb_turbo_guard.sv:186-188`:

```verilog
// the core's own bus-cycle wire (msx.sv:511); iack omitted - it only ever
// extends req, so leaving it out is the pessimistic choice here
wire req = ~((iorq_n & mreq_n) | (wr_n & rd_n));
```

The stated justification is **inverted**: `iack` *truncates* `req`, it never extends it, so omitting it
is the optimistic choice. `sim/tb_turbo_slowdev.sv:219` carries the identical wire, which voids its
"0 writes lost in every shipped configuration" result.

**(b) `tb_turbo_guard` has no assertions at all.**

```
tb_turbo_guard.sv:260   int errors = 0;   <- declared, never incremented, never read
tb_turbo_guard.sv:293   $display("  stock 3.58MHz reference: read window 12, write window 6, ...")
tb_turbo_guard.sv:294   $finish;          <- no argument => always exit 0
```

Line 293 is a **hardcoded string literal, not a measurement**, and `sim/run_turbo.sh` reports these TBs
with `tail -1` without ever setting `rc`. `tb_turbo_slowdev` does count errors but also ends in a bare
`$finish;`, so a FAIL likewise exits 0.

> This is the same failure mode the project already documented after `tb_sccplus` passed 44/44 while
> defending a defect. The rule stands and was violated: **a TB that cannot fail is not evidence.**
> It also caught out this review: the main session initially relayed the line at 293 to the user as a
> measured result before checking how it was produced.

`sim/tb_turbo_clock.sv` (divider only) and `sim/tb_fdc_edge.sv` (wd1793 edge capture, with a genuine
negative control) do **not** use this `req` model and remain valid.

---

## Peripheral coverage — what the guard actually protects

Every device that can latch a CPU write, with the enable it captures on, and whether the guard covers
it. Verified from source.

| Device | Captures on | Sense | Guard covers it? |
|---|---|---|---|
| **SCC / IKASCC** FREQ, VOL, deform | `ce_3m58_p` (`IKASCC.v:118`, `IKASCC_player_s.v:508-515`) | level | **Yes — this is the device the guard was designed for.** Memory-mapped at 0x9800 via `cpu_mreq`, so covering *memory* cycles is not optional |
| SCC wave RAM | raw `clk21m`, `RAMCTRL_ASYNC=1` (`IKASCC_player_s.v:493,743-749`) | level | Not at risk |
| **OPLL / MSX-MUSIC / FM-PAC** | raw `clk` (`jt2413.v:75`, `jtopll_mmr.v:87`) | level | **NOT PROTECTED — and the width is not the problem. See H4.** |
| PSG registers (internal + cart) | raw `clk21m` (`jt49.v:219-247`, `jt49_bus.v:57-78`) | level | Not at risk. Only the 74LS74 *strobe generator* needed the `ce` move, and it got it |
| **FDC / wd1793** | `clk_en_cpu` after this diff | **edge** | Guard fundamentally cannot help — an edge capture needs the strobe idle before *and* after, which `WAIT_n` can never create. Re-clocking is the right call |
| VDP MSX2 (V9938) | `req` one-shot, `.ACK()` unconnected; toggle handshake merges lost requests (`vdp_register.vhd:547,558`) | one-shot | Not by the guard — by the pacer. `VDP_GAP38 = 32` is sound (worst arbiter gap 7 dots × 4 = 28) |
| **VDP MSX1 (vdp18)** | `clk_en_10m7` FSM, single `buffer_q` | one-shot | Pacer covers the width, **but `VDP_GAP18 = 12` is far too small. See H3.** |
| PPI / 8255 | raw `clk21m` (`jt8255`) | level | Not at risk |
| RTC | raw `clk21m` via the `req` one-shot (`rtc.vhd:132`) | one-shot | Not at risk — but this is *why* `req` must stay a one-shot |
| All mappers (ascii8/16, konami, konami_scc, yamanooto, mfrsd, gm2, fmpac, halnote, ram_mapper) | raw `clk21m` | level | Not at risk |
| Cheat engine | raw `clk21m`, needs address stable ≥2 cycles (`msx.sv:417-445`) | level | Adequate — at x3 a read M-cycle holds the address ≥4 `clk21m` even unguarded |
| MoonSound / YMF278B | raw `clk21m` edge-detect **plus a real handshake** (`msx.sv:865-916`) | edge + ack | Fully turbo-transparent |
| **SDRAM ch2** (the CPU's own memory path) | open loop, no handshake, fixed deadline | — | **The guard is the only protection.** See M5 |

**Not protected:** OPLL (gap, not window — the guard cannot help), the MSX1 vdp18 VRAM path (gap
constant too small), and SDRAM ch2 (guard is the only protection, and it currently never fires).

---

## Non-blocking findings, ranked

| ID | Sev | Finding |
|---|---|---|
| H1 | high | **SDC exceptions lose their stated premise under turbo.** `MSX1.sdc:35-40` grants `-setup -end 6` to `*sdram*ch2_*` because "T80 … only updates on `ce_3m58_p` ticks (every 24 `clk_sdram` cycles)". At x3 the T80pa strobes change every 4 `clk_sdram`. Same wording at `MSX1.sdc:54-59` (`opl4latch` → `pcm_engine`). *Mitigating:* once the guard works it stretches every bus cycle to ≥8 `clk21m` = 32 `clk_sdram`, largely restoring the premise. Re-run STA and reword before shipping turbo. |
| H3 | high | **`VDP_GAP18 = 12` is roughly 3× too small** (`msx.sv:320`). `vdp18_cpuio` holds exactly one write-back byte (`buffer_q`) plus the `wrvram_sched_q`/`wrvram_q` pair (`vdp18_cpuio.vhd:176-220`); a second write while one is pending overwrites `buffer_q` **and** desynchronises `addr_q`, which only increments when the write-back executes. CPU access slots are one per 8 `clk21m` (`vdp18_ctrl.vhd:368`), but in Graphics 1/2/Multicolor the pattern fetches claim three of every four (`vdp18_ctrl.vhd:150-186`), so a CPU slot arrives once per **32** `clk21m` — worse during the sprite phase. At x3 an unrolled `OUT (98H),A` pair is 24 `clk21m` apart and the pacer adds nothing because 24 > 12. Symptom: corrupted tiles and sprites during uploads, silent, no hang. **Raise `VDP_GAP18` to at least 32.** |
| H4 | high | **OPLL / MSX-MUSIC is unprotected, and the diff's stated reason is factually wrong.** `msx.sv:244-245` claims "opll latches on `.cen`". It does not — `jtopll_mmr.v:87` says in so many words *"this runs at clk speed, no clock gating here"*, and the write is `if(write)` on raw `posedge clk` (`jt2413.v:75`). Window width is a non-issue. The real hazard is the **gap**: `jtopll_mmr` sets `up_inst`/`up_fnumlo`/`up_fnumhi` and they are consumed only when the addressed channel rotates past in the CSR (`jtopll_reg.v:178-186`), while the next write clears them first (`jtopll_mmr.v:111-118`). Rotation is `cen/4 × 18 slots = 432 clk21m ≈ 20 µs` (`jtopl_div.v:30`), which matches the real YM2413's 84-cycle (23.5 µs) post-write wait that drivers honour with software delay loops. At x3 those loops shrink to ~7 µs, so the earlier write is overwritten before it lands. **Fixing the guard will not fix this.** Expect wrong instruments and stuck notes in FM-PAC / MSX-MUSIC titles at turbo. Mechanism verified from source; drop rate not measured. |
| H2 | high | **MoonSound trim: multiply and saturation share one `clk_sdram` cycle.** `ymf278b_top.sv:415-422`. The added pipeline stage sits *before* the multiply, so `trim_l_q → 17×9 multiply → >>>7 → two 18-bit compares → 3:1 mux → audio_left` is a single combinational cloud at 85.9 MHz with 0.860 ns slack. Split it: register the raw product, saturate in a third stage. Cost is one register bank against a 49.7 kHz sample rate — effectively free. See **C1**. |
| M1 | med | **wd1793 real-time constants scale with turbo.** `wd1793.sv:259-266` index pulse `cnt<=35000` (9.8 ms → 3.26 ms at x3); `wd1793.sv:250-256` watchdog `wd_timer<=4096` (1.14 ms → 0.38 ms). The `msx_slots.sv:545` comment claims CPU↔FDC *ratios* are preserved — true — but absolute drive timing changes. SD/HPS is handshaked (`wd1793.sv:460`) and the watchdog is armed only after the buffer is filled, so the common path is safe. Risk is format/verify and protection loaders that time the index pulse against the (unchanged) VDP interrupt. **Test disk writes on a copy only.** |
| M2 | med | **The trim is unconditional and unswitchable.** Every other MoonSound knob is on the OSD (`status[46]`, `[47]`, `[50:49]`). Headroom drops 3.01 dB: clipping now starts at \|sum\| ≥ 23173 instead of 32768, and it happens *after* the 0xF8/0xF9 software mix so no driver can compensate. See **C3**. |
| M3 | med | **`MS_TRIM_MUL` is `signed [8:0]`.** `ymf278b_top.sv:327`. 181 fits, but the next person wanting +6 dB writes `9'sd256` and silently gets **−256** — both channels phase-inverted. Widen to `signed [10:0]`. See **C2**. |
| M4 | med | **Delivered speed is well below the menu labels.** Measured with the fix: **x2 ≈ 1.45×, x3 ≈ 1.71×** (independently calculated as 1.33× / 1.71×). By design — the guard reproduces stock bus-window lengths, so only non-bus T-states speed up. `GUARD_RD = 8` applies to BRAM/SRAM fetches too, which is conservative but costly. **Optimisation:** the `guard_cnt` half is genuinely needed on reads (M5), but the `guard_ce` half is only needed on *writes* (IKASCC). Qualifying `guard_ce` with `~wr_n` would recover most of the lost speed without weakening anything. Labels `7.16MHz (x2)` / `10.7MHz (x3)` describe the core clock, not throughput. |
| L1 | low | `cpu_turbo` uses raw `status[37:36]` (`MSX1.sv:384`) while the rate follows `speed_q`, latched up to 6 `clk21m` later. Turning turbo *off* can leave one unguarded turbo bus cycle. Export `\|speed_q` from `clock.sv` instead. |
| L2 | low | `guard_cnt` is not pause-gated (`msx.sv:286`) and saturates at `4'hF` under `msx_pause`, briefly voiding the "window is at least N cycles" invariant the comment at `msx.sv:259-262` claims is exact. `guard_ce` still requires a real `ce_3m58_p`, so capture stays safe. |
| L3 | low | No reset on `vdp_gap` / `vdp_hcnt` / `vdp_grant` (`msx.sv:328-341`) or `trim_l_q` / `trim_r_q` / `trim_v_q` (`ymf278b_top.sv:329-331`). Benign on Cyclone V (registers power up to 0) and consistent with the surrounding pre-existing style in `ymf278b_top`, but inconsistent with `guard_cnt`/`guard_ce` 40 lines above. |
| L4 | low | `wait_n` changed from a flop to combinational logic carrying `mreq_n`/`iorq_n`/`rd_n`/`wr_n`/`m1_n` and the VDP decode back into the CPU (`msx.sv:346`). Functionally identical at turbo-off, but physically present in every build. `clk21m` slack is 2.006 ns; whether it moves the worst path needs a fit. |
| L5 | low | `ce_3m58_n` now has **zero consumers** — its only user was T80pa's `CEN_n`. Expect a Quartus unused-port warning. |
| L6 | low | Comment inaccuracies: `msx.sv` says `ch2_ready` is "left unconnected in MSX1.sv" (it is connected at `MSX1.sv:887` to `sdram_ready`, which is then never consumed — the substance, that ch2 is open-loop, is correct); and `//[35] RESERVA` is wrong because `msx_config.sv:44` uses `HPS_status[35:32]` for mapper B (pre-existing; bits 36–37 really are free). |

---

## MoonSound +3 dB trim — detail

Placement is **post-sum, pre-saturation** in `ymf278b_top.sv`, gain `181/128 = 1.41406` (+3.0094 dB).

Verified by exhaustive sweep over all 131,072 input values plus three independent testbenches:

```
opl3_l_eff   signed [16:0]   ±32768                        (opl3_pkg.sv:56,84-85; dac_prep.sv:62-63)
mix_*_tmp    signed [16:0]   −65536 .. +65534              exact fit, zero margin
trim_*_mul   signed [25:0]   ±11,862,016                   26 bits hold ±33.5M — no truncation
trim_*_sh    signed [17:0]   ±92,672                       18 bits hold ±131,072 — lossless
gain measured through the RTL expression: 1.41317 .. 1.41495  ->  3.0093 dB
truncation bias: −0.496 LSB (≈ −96 dBFS); trim(0) == 0, so silence stays bit-exact
```

Checked and clean: no sample loss or duplication (including the real 6-`clk_sdram`-wide
`opl3_sample_valid` and a 5-distinct-back-to-back worst case); `trim_v_q` one-shot ordering; blocking
assignment of module-scope temporaries (no cross-process reader anywhere in the repo); reset /
X-propagation is no worse than the pre-existing block; the downstream 17-bit sum and saturation in
`msx.sv:161-165` still cannot wrap; `moonsound_en == 0` still yields a bit-identical core; both
signed-literal traps (`-18'sd32768`, `18'(x >>> 7)`) do **not** fire.

Existing golden harnesses are **not** invalidated — `run_pcm_golden.sh` taps `pcm_left/right` and
`fm/run_fm_golden.sh` verilates `opl3` directly, both upstream of the trim.

**Placement is correct.** `fm_mix_gain` applies 0xF8 to FM only and `pcm_mix_gain`
(`ymf278_pcm_engine2.sv:460-461`) applies 0xF9 to PCM only, both before the sum, so trimming the sum
leaves the 0xF8/0xF9 ratio untouched. Scaling the paths separately is strictly worse — PCM saturates
independently at `ymf278_pcm_engine2.sv:462-465` and would clip 3 dB early on its own, stacking with
`pcm_vol`. Doing it in `msx.sv` would put the multiply in a combinational chain straight to `AUDIO_L/R`
and add a second saturation in series.

### Conditions before shipping the trim

- **C1** split the multiply and the saturation into separate pipeline stages (H2)
- **C2** widen `MS_TRIM_MUL` to `signed [10:0]` (M3)
- **C3** decide: OSD menu entry (a `128` vs `181` mux, one 2:1 mux) or hardcoded — **open question for the user** (M2)

### `sim/tb_ms_trim.sv` — honest assessment

Transcription of the RTL expressions is exact (diffed operator by operator and width by width), the
negative control is real, and it passes 62,236 checks. But it is a **copy, not a binding** — it never
instantiates the module, so editing `ymf278b_top.sv` stage 2 leaves it passing. It is a spec test, not
a regression test. It also does not cover stage 1's sum, the valid sequencing, the multi-cycle
`opl3_sample_valid`, the `pcm_valid` hold interaction, or reset/X. The negative control exercises one
assertion of four (T2 and T3 pass happily at unity gain), and T1's ±0.05 dB band would accept
`MS_TRIM_MUL = 180`.

---

## Verified clean (turbo)

- `ce_cpu_p/n` at `cpu_speed == 0` are textually identical to `ce_3m58_p/n`; `tb_turbo_clock` asserts
  this cycle by cycle and measures 1.00 / 2.00 / 3.00 ratios with `ce_3m58_p` invariant at 33,334
- All 6 mode transitions preserve strict p/n alternation (enumerated by hand and fuzzed 100k cycles);
  `speed_q` latches at `clkdiv6 == 0` where every mode's last event is an `n`
- `p` and `n` never coincide; correct polarity on the first edge after reset
- No other `clkdiv6` consumer changed; `ce_10m7_*`/`ce_5m39_*`/`ce_10hz` come from other counters
- `status[36]`/`status[37]` genuinely unused; `status` is `[63:0]`; CONF_STR item is far below the
  reserved `i = 1` slot and shifts nothing above it; `cpu_speed == 3` decodes safely as x3
- `psg` is instantiated once (`msx_slots.sv:508`) with `.*`, so the new `clk_en_cpu` port connects —
  no dangling port, no dead cartridge PSG
- Pause gating matches the existing `ce_3m58_*` treatment
- The VDP pacer terminates (`vdp_gap` decrements unconditionally, `vdp_hcnt` saturates) — no second
  deadlock hides behind T1
- PPI runs on raw `clk21m` (`jt8255.v`) — turbo-agnostic
- The guard's *justification* is sound: SCC wave RAM is `RAMCTRL_ASYNC(1)` (`scc_sound.sv:111,135`) and
  therefore immune, while IKASCC's FREQ/VOL registers really do latch under `ce_3m58_p`
  (`IKASCC.v:118`) and OPLL under `.cen` — only the counter's input signal was wrong
- Resources and timing have headroom: ALM 29,114/41,910 (69 %), M10K 351/553 (63 %), DSP 52/112,
  worst setup +0.344 ns (pll_hdmi), `clk_sdram` +0.860 ns, TNS 0

## Not examined

- **No VHDL simulator is installed** — see the caveat under T2. All T80 reasoning is transliteration.
  Installing ghdl and re-running the INTA case is the single highest-value follow-up.
- Whether `VDP_GAP38 = 32` holds in **text modes**, where `TXVRAMREADEN` covers states 5-7
  (`vdp.vhd:1390-1395`, `vdp_text12.vhd:187-188`) and the worst gap may exceed 28
- Whether `GUARD_RD = 8` is optimal (it is the right order of magnitude and load-bearing — see M5)
- OPLL write-drop **rate** at turbo (mechanism verified from source; not measured)
- FDC index-period effects on real protection loaders (M1) — needs hardware
- Whether L4's new combinational `WAIT_n` path becomes the worst `clk21m` path — needs a fit

## Suggested order of work

1. **Install ghdl** and reproduce T1 and T2 against the real `rtl/cpu/T80pa.vhd`. Both blockers are
   hang-class and every current proof is a transliteration.
2. Apply the combined T1 + T2 fix (one new wire, one changed condition, one added release term).
   Do **not** use the `| (rd_n & wr_n)` form — it was measured and it defeats the write guard.
3. Give `tb_turbo_guard` real assertions driven by the correct `req`, and add an **INTA M-cycle** to
   its stimulus — `sim/tb_turbo_guard.sv:59-80` has no INTA cycle at all (`K_INT` is "internal, 2T, no
   bus"), which is why the second blocker went unseen. Make `run_turbo.sh` gate on exit codes rather
   than `tail -1`.
4. Re-verify `tb_turbo_slowdev` with the corrected `req`.
5. Raise `VDP_GAP18` to ≥32 (H3).
6. Decide what to do about OPLL (H4) — it is not fixable by the guard. Options: accept that
   MSX-MUSIC titles misbehave at turbo, force `cpu_speed = 0` while an OPLL cartridge is selected, or
   pace OPLL writes the way the VDP is paced.
7. Then H1 (re-run STA, reword the SDC comments) and M1 (disk write test **on a copy**).
8. Consider the `guard_ce & ~wr_n` optimisation (M4) to recover throughput.
9. Reword the menu labels or accept M4.

The MoonSound trim is independent of all of the above and can ship on its own once C1–C3 are settled.

## Reproduction

The decisive harnesses were written to the session scratchpad and are **ephemeral** (`/tmp`). The two
load-bearing ones are reproduced here so the evidence survives.

**T1 — `req` is a one-shot, the guard never releases.** Copy `iack`/`req`/the guard block verbatim from
`msx.sv`, drive a memory read that respects `WAIT_n`, and count how long `bus_guard_n` stays low:

```
guard NEVER released in 2000 clk21m cycles (~93 us)
   guard_cnt       = 1   (threshold for a read = 8)
   req_high_cycles = 1   <- req is a ONE-SHOT
   bus_cycle       = 1   (stuck: CPU cannot end T2)
```

Swapping the counter's gate to the level `bus_xfer` gives `guard RELEASED after 8 cycles`.

**T2 — INTA deadlocks even with that fix.** Model `Auto_Wait` (`T80.vhd:1165-1179`, holds `TState = 1`
for 3 core ticks), the `IntCycleD_n` shift (`T80pa.vhd:178-182`), and T80pa's `CEN_pol` FSM; sample
`WAIT_n` at the TState-2 `CEN_n` edge. Adding `~inta` to `bus_cycle` is what releases it.
