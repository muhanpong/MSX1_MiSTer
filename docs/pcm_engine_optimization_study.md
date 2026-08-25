# YMF278B PCM Engine — ALM/Resource Optimization Study

Retrievable record of the optimization feasibility work on `ymf278_pcm_engine2.sv`.
Created 2026-06-17. The engine is **functionally frozen-good**: golden harness
`sim/golden/run_pcm_golden.sh` = 5/5 bit-exact vs the YMF278.cc model. Any
optimization MUST keep that bit-exact (it is the regression gate).

## 0. Resource baseline (reglog build, Cyclone V 5CSEBA6, fit.rpt 2026-06-17)

Whole core `sys_top`: **ALMs 26,761 / 41,910 (64%)**, regs 36,591, **M10K 527/553 (95%)**, DSP 52/112, block-mem 67%.

MoonSound `ymf278b_top:u_moonsound`: **ALMs 7,451 (~28% of core)**, regs 9,761, M10K 15, DSP 10. Breakdown:
| block | ALMs | regs | M10K | DSP | note |
|---|---|---|---|---|---|
| **PCM engine** `ymf278_pcm_engine2` | **6,280** | 8,735 | 0 | 9 | 84% of MoonSound ALM |
| OPL3 FM `opl3:u_opl3` | 1,027 | 820 | 14 | 1 | memory-based (gtaylormb) |
| regs `ymf278b_regs` | 102 | 126 | 1 | 0 | FM shadow + status |

### Where the PCM engine's logic goes (fit.rpt entity table + map.rpt; cross-verified in RTL)
- The engine is **flat**: ALU/EG are SystemVerilog `package` functions inlined into `u_pcm`. Only named sub-entities = two `lpm_divide` (~42 ALMs, the EG-rate divide/mod).
- **~85% of the 8,735 registers are the 24× per-slot STATE ARRAYS held in flip-flops** (0 M10K), and the **24:1 read muxes + 24-wide write decoders over those arrays are the dominant ALM cost** — the classic sequential-slot-machine hog.

Per-slot arrays (ymf278_pcm_engine2.sv, all `[0:23]`, verified):
| array | bits/slot | ×24 | line |
|---|---|---|---|
| `ram_regs` (slot_regs_t) | 72 | 1,728 | 159 |
| `ram_header` (slot_header_t) | 56 | 1,344 | 160 |
| `ram_dyn` (slot_dyn_t) | 63 | 1,512 | 161 |
| `cache_tagA/tagB/w0..w3` | 109 | 2,616 | 279-281 |
| `tl_cur` 8 / `bf_dirty` 5 / 5× 24b masks | — | ~456 | 162-166,173,282 |
Total per-slot state ≈ **7,500 bits** (matches the ~85% register figure).

## 1. Optimization opportunities (ranked)

### Tier 1 — slot-state register-array → BRAM (BIG payoff, double-edged) ⚠️
Move 24× state arrays from flops to a small dual-port M10K (read slot N → process → write back). Removes the arrays' registers AND their 24:1 muxes/decoders.
| candidate | bits | difficulty | why |
|---|---|---|---|
| `cache_*` | 2,616 | **easy** | single read (SL_CHIT ~502) / single write (SL_F_WAIT ~534), all `w_slot` |
| `ram_dyn` | 1,512 | easy–mod | single read/write per pass; reset non-zero default needs init seq |
| `ram_header` | 1,344 | moderate | read (slot FSM) vs write (service FSM) → true-dual-port + init seq |
| `ram_regs` | 1,728 | **HARD — leave in flops** | arbitrary multi-port RMW from async CPU reg bus; verified backfill/retrig/TL semantics would have to be rebuilt |

Estimated: cache + dyn (+ header) → **~2,000–3,000 ALM and ~5,000 register reduction**, using **2–3 of the ~26 free M10K**. Needs +1 FSM state per migrated array for BRAM read latency (72-cycle/slot budget has slack).

**★Decisive caveat — ALM is NOT this core's binding resource.** ALM=64% (roomy); the binding resources are **M10K (95%)** and **clk_sdram timing margin**. Tier 1 trades ALM↓ for M10K↑ — i.e. spends the scarce resource to free the abundant one. And per the recorded lesson, BRAM-pressure (95%) previously broke `SDRAM_DQ` IOB packing → flaky 2 MB RAM. So Tier 1 **must re-verify 2 MB SDRAM** after the fit, and may be net-negative unless freeing ALM is a specific goal. (Counterpoint: less logic/routing congestion could *help* IOB packing — net effect uncertain.)

### Tier 2 — pure logic reduction (small–medium, LOW risk, bit-exact, no BRAM cost) ✅
The safe wins — reduce ALM without touching the binding M10K:
- **Dead-code removal**: `calc_vol` (alu.sv:149-169, incl. 16×32 mult) is unreferenced; package `compute_vib`/`compute_am` are used only by the LEGACY `ymf278_pcm_engine.sv` (engine2 inlines them) → dead in the engine2 build. Verify `engine.sv`/legacy_v1 is not compiled, then delete.
- **`byte_addr` ×3 single-sourcing**: called 6× (engine2:305-310) for only 2 distinct `p` (w_pos2, w_posb). Compute `pos2*3`/`posb*3` once in SL_ADDR (already a registered boundary) → removes ~4 redundant ×3 units.
- **`eg_rate_shift_rom(w_rate)` CSE**: recomputed 3× in SL_EGROM (engine2:573,574,576) → one temp. Same-cycle CSE, no added depth.
- Payoff ~hundreds of ALMs; risk ~0; golden 5/5 preserved; no IOB-packing impact.

### Tier 3 — EG tables logic→M10K (NOT recommended) ⚠️
`eg_inc_rom` (128×8), `eg_rate_select/shift_rom` (64×8) are logic LUTs. Could be M10K, but that **spends the binding resource (M10K)** = wrong direction. Skip unless M10K frees up.

## 2. DO-NOT list (would worsen fitting — hard-won lessons)
1. **No constant dividers** (`/12`, `/9`…). The signed `/12` LUT cloud broke `SDRAM_DQ` IOB packing → flaky 2 MB RAM; replaced by reciprocal `(mag*43691)>>19` (alu.sv:88). Canonical trap.
2. **Don't merge the staged multiplies** SL_MUL1/SL_MUL2/SL_PAN (engine2:264-266: 32×32 single-cycle missed clk_sdram by 0.28 ns) or SL_VIB/SL_VIB2 (≈1 ns) or SL_ADDR ×3 isolation (≈0.5 ns). Deliberately split for timing.
3. **Don't remove eg_step latch-avoidance default inits** (eg_step.sv:148-156) — without them Quartus infers latches → comb loops → big clk_sdram failure.
4. **Don't add BRAM when M10K is the binding resource.**
5. **Don't widen w_gain_e/t/w_inner back to 32-bit** (engine2:266-267) — 17-bit keeps the per-stage multiply shallow.

## 3. Verdict
- **Feasible?** Yes. Tier 1 ≈ 2–3k ALM (well-known register→BRAM pattern); Tier 2 ≈ hundreds of ALM safely.
- **Worth it?** PCM-engine ALM is not the core's bottleneck (ALM 64%). Bottleneck = M10K 95% + timing. Tier 1's big ALM win costs scarce M10K and risks the flaky-RAM lesson → only pursue if ALM headroom is a specific goal, with full golden + 2 MB-RAM re-verification.
- **Recommended path if pursued**: Tier 2 safe wins first (zero risk) → Tier 1 only with the caveats above.

## 4. Part 2 — FPGA-parallelism-optimal re-examination (2 subagents, cross-verified)

**Premise tested:** "FPGA-native parallelism/pipelining is the optimal implementation target."
**Verdict: for THIS core the premise is inverted — max parallelism is the WRONG target.** Both
independent reviews converged; key claims re-verified in RTL.

### Why parallelism buys nothing here
- **Time-rich, not throughput-bound.** Frame budget = 1948 cycles @ 85.9 MHz → 44.1 kHz (engine2.sv:92). 24 voices × ~22-state turn + ≤4 word-reads ≈ 1728 cyc, finishing with a ~220-cyc CPU-reserve tail (engine2.sv:96-97). Dispatch is variable-length (`dispatch_now`, :334) — the next slot launches the instant the prior hits SL_IDLE. **Throughput is already solved with slack; more parallelism = idle silicon, no audio gain.**
- **Binding constraints all WORSEN with parallelism.** Binding = M10K 95%, clk_sdram sub-ns margin ("placement roulette"), SDRAM_DQ IOB-packing/routing congestion. Non-binding = ALM 64%, regs, DSP. Deep pipeline (≈1 slot/cyc) or N lanes attack timing + SDRAM-IOB routing (and lanes also M10K), to improve only the non-binding throughput/ALM.
- **Bottleneck is ch4 SDRAM bandwidth/latency, which parallelism can't fix and may worsen.** ch4 = lowest priority, shared with CPU ch2 (sdram.sv:268 vs 315), edge-detected single requests, CH4_HOLD retired. The engine issues reads strictly serially, gated `!mem_busy && !mem_rd_en` (engine2.sv:516,781,819) → never >1 outstanding = **self-throttling that protects the CPU**. The per-slot word cache (tagged by absolute word addr, :272-282,489-513) makes sustained/low-pitch voices issue **zero** SDRAM traffic — the real bandwidth defense. A steadier/parallel multi-requester pattern raises peak demand on the lowest-priority channel → more PCM stalls + pressure to re-add CH4_HOLD (the move that once corrupted CPU ch2 reads). So parallelism on ch4 is strictly worse.

### Spectrum × binding-constraint matrix (qualitative)
| axis | ALM | regs | M10K(BIND) | clk_sdram(BIND) | SDRAM-IOB routing(BIND) | ch4 BW |
|---|---|---|---|---|---|---|
| (A) current coarse sequential FSM | baseline | baseline (85% in flop arrays) | 0 | known-good | known-good | low/self-throttled |
| (B) lightly pipelined sequential | ~same | ~same | 0 | HIGH RISK↓ (re-litigates won splits) | neutral | slightly steadier |
| (C) deep streaming pipeline | ↑ | ↑↑ | 0 (or M10K if state) | SEVERE↓ | SEVERE↓ | bursty-heavy |
| (D) N parallel lanes | ↑↑↑ | ↑↑↑ | N× (spends scarce) | SEVERE↓ | SEVERE↓ | WORST (N requesters) |

### What IS worth doing (none of it is "more parallelism")
1. **Direction-dependency fix = SCHEDULING, not parallelism.** The header re-fetch is deferred to a narrow per-frame window (`frame_cycle < CPU_RESERVE_AT-130`, engine2.sv:770; hf_pending :166,985). Fix = start the header fetch **eagerly on `wr_sets_hf`** (:985) and stall only THAT slot until it lands (openMSX-like synchronous load), instead of deferring. Small targeted change, NOT a datapath rewrite. (This is the real lever for the [[direction-dependency]] / sc_dirdep finding.)
2. **Tier-2 safe logic cleanups** (§1) — bit-exact, no M10K cost.
3. **ch4 sustain robustness** — reconsider a *bounded* ch4 burst-hold (retired CH4_HOLD) — addresses the real bottleneck directly, but carefully (it once starved CPU ch2).

### Effort/risk if one ignored the above and rewrote anyway
Major rewrite (pipeline + BRAM state + variable-latency memory scheduler + BRAM reset-init), touching the most timing-sensitive module; biggest risks = bit-exact regression vs golden harness (the v2→v3 semantics are subtle and hardware-verified), M10K-95%→flaky-2MB IOB trap, sub-ns timing, and re-introducing the multi-FSM coupling that caused the original cpu_mem_busy freeze (the very reason v3 exists). **Not recommended.**

### Bottom line
The "FPGAs love parallelism" instinct is inverted here. The sequential slot-machine with an absolute-word-tagged per-slot cache is **well-matched** to a time-rich, M10K-bound, timing-fragile, bandwidth-contended MSX-shared-SDRAM context: latency-tolerant, traffic-minimizing, BUSY-bounded, bit-exact. Optimize by *scheduling polish + safe logic cleanups*, not by adding compute lanes.

_Subagent records (resumable): arch eval `ac88b453fdd507cd9`, parallelism-vs-constraints `a7c722df3fbe1f719`, plus the Part-1 agents `af215824159a44712` / `a34b41485804a1b97` / `ae002eb2a6610f89b`._
