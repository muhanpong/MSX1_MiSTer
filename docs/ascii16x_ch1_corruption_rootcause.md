# ASCII16X flash DMA — "SDRAM ch1 sustained read corrupts the controller" ROOT-CAUSE study

Branch: `ascii16x-flash-research` (worktree, off `moonsound` @ d8cc031).
Method: 4 parallel research agents + Claude independent cross-verification (grep/read of actual RTL).
Status: research only, no RTL changed.

---

## TL;DR — the prior mental model was wrong

The sealed comment (`nvram_backup.sv:148-149`) and project memory say:
> "SDRAM ch1 DMA corrupts SDRAM controller after sustained read traffic."

**That framing is misleading.** ch1 is **not** intrinsically cursed and "sustained read" is **not** the mechanism. The hang is a **fit-fragile, unconstrained `SDRAM_DQ` IOB timing path** that the flash DMA tips over the edge. The same failure family already bit this core twice (the `compute_vib` /12 cloud → 2 MB RAM flaky; the f94b2be "same logic, different fit → MFRSD halt").

Three independent facts, all cross-verified in code, dismantle the old model:

1. **The per-channel SDRAM read logic is byte-identical for ch1/ch2/ch3/ch4** (`sdram.sv` request edge-detect, `data_ready_delay` capture, `chN_saved_data <= SDRAM_DQ`, output mux are copies; only arbitration *priority* differs). So ch1 has no special read logic that could "corrupt the controller."
2. **ch4 (MoonSound PCM) does sustained sequential SDRAM reads and works fine.** If sustained reads corrupted the controller, ch4 would too. It doesn't.
3. **There are ZERO SDRAM I/O timing constraints** (`grep set_input_delay|set_output_delay|FAST_*_REGISTER` over `MSX1.sdc` + `sys/sys_top.sdc` matching SDRAM = nothing). The DQ in/out/OE flops are placed into the IOB or spilled to fabric **at fitter discretion** — a coin flip per build.

In-code corroboration that DQ timing is already known-marginal: `rtl/msx.sv:800` comment — *"the thin 0.303ns slack / SDRAM_DQ path"* — with a live **canary** (msx.sv:806-816, 865-904) that re-reads a fixed SDRAM address on ch4 to watch for DQ failures.

---

## The unified root cause

**An unconstrained `SDRAM_DQ` bidirectional path with ~0.3 ns slack.** With no `set_input_delay`/`set_output_delay`, Quartus has no pressure to pack the DQ registers into IOB cells. The interface works only because the PLL phase-shifts the SDRAM clock AND the fitter happens to keep DQ in/near the IOB.

The flash DMA adds congestion that makes the fitter spill a DQ register to core fabric → +routing delay → either a **setup violation on the CAS-2 capture** (garbage reads) or the **output-enable deassert slips into the SDRAM's read-drive window → DQ bus contention** (FPGA and SDRAM both driving the bus). Sustained bus contention returns garbage and can wedge the chip until power/RBF reload — i.e. it explains a **hang**, not merely corrupted data.

### What the flash DMA adds (ranked aggravators)

1. **`sector_buf[512]` async-read combinational cloud — PRIME suspect.**
   `nvram_backup.sv:112` `logic [7:0] sector_buf[512];` (4096 bits), read **combinationally** at `:118` (`assign sd_buff_din[0] = ... sector_buf[sd_buff_addr[8:0]]`) with a *second* read index `flash_byte_ptr` (`:257`) and two write indices (`:209`, `:246`). An async (flow-through) read **cannot map to M10K** (M10K read is synchronous), so this becomes ~4096 FFs + a 512:1 byte read mux — exactly the "large combinational cloud + dense FF cluster" that broke DQ IOB packing before. Damage = routing congestion / placement spill near the SDRAM IO bank, **not** a BRAM cliff.
2. **27-bit ch1 input muxes** (`MSX1.sv:819-822`): `ch1_din/ch1_addr/ch1_req/ch1_rnw` each gain a 2:1 mux (upload vs nvbak), sitting directly in the ch1 datapath feeding the controller's IDLE-state capture. Small but worst-placed (inside the timing-critical SDRAM region).
3. The `STATE_FLASH_*` FSM itself: negligible direct contribution, only incremental ALM/routing pressure.

### The trigger: ch1 + ch4 concurrency (the "CPU paused" reassurance is false)

`msx_pause` (`MSX1.sv:443`) gates **only** the MSX core's clock enables `ce_10m7_p/ce_3m58_p/n/ce_5m39_n/ce_10hz` (`:447-451`) = CPU/VDP/PSG = **ch2 only**. The MoonSound PCM bridge that drives `pcm_sdram_req` (ch4) runs on bare `clk_sdram` (`rtl/msx.sv:831`, `:984 always @(posedge clk_sdram)`) and is **not** pause-gated. The `dma_active` input is wired into `msx` (`MSX1.sv:458`) but is **completely unused inside msx.sv** (exactly one occurrence: the port decl at `rtl/msx.sv:12`). The canary also issues ch4 reads whenever the engine is idle. So during a flash save, **ch1 DMA runs concurrently with ch4** — the trigger is ch1+ch4 contention, not ch1 alone. (Caveat: ch2+ch4 concurrency happens constantly in normal play without hanging, so concurrency alone isn't novel — it's concurrency *plus* the added DQ-path congestion that tips the marginal fit.)

---

## What was DISPROVEN

- **Refresh starvation — RULED OUT.** `refresh_count` is a free-running counter (`sdram.sv:187`) never touched by channel activity; emergency refresh is the FIRST branch in `STATE_IDLE` (`sdram.sv:262`) with absolute priority; the FSM always returns to IDLE. Real refresh period = 500 × (1/85.909 MHz) = **5.82 µs**, full array 47.7 ms < 64 ms JEDEC. Clock-error direction is the SAFE one (faster clock → over-refresh). `doRefresh` is tied to `1'b0` (`MSX1.sv:816`), so emergency refresh is the only live path, and it suffices.
- **Logical arbitration / handshake fault — RULED OUT as the HANG cause.** ch1 mux is clean (memory_upload vs nvram_backup are mutually exclusive in time; never dual-driven). ch1 has a *real* `ch1_ready` handshake in the controller.
- **Dead-reckoning hangs the controller — RULED OUT (proven).** nvram req is a 1-cycle pulse, never held (`nvram_backup.sv:199`→`:205`); controller req is self-clearing edge detect (`sdram.sv:161`→`:295`); every state has an unconditional exit to IDLE; nvram never blocks on a controller signal. A too-short `sdram_wait` would corrupt *saved data*, never wedge the FSM. (68 clk21m ≈ 272 clk_sdram ≫ one CAS-2 access, so even data corruption is unlikely.)

> Note: dead-reckoning is still a real **data-integrity** bug — `nvram_backup` ignores the wired `ch1_ready` (`MSX1.sv:904`) and blindly counts `sdram_wait`. Worth fixing regardless (use the handshake like `memory_upload.sv:419-422` does), but it is not the hang.

---

## Why the ordinary SRAM `.sav` save is safe (the reference)

Structurally different — it **never touches SDRAM**. SRAM lives in BRAM (`systemRAM`, `dpram #(.addr_width(16))`, `MSX1.sv:855`); `nvram_backup`'s `STATE_PROCESS` (`:180-192`) reads BRAM port B directly (`ram_addr`/`ram_dout`, `MSX1.sv:893-895`) and only toggles `sd_wr/sd_rd`. It never asserts `sdram_req`. Safe by construction (BRAM port, deterministic, no DQ path), and small (≤~64 KB). The flash path is the *only* SDRAM-read DMA consumer — which is why it is the only one that hit the DQ fragility.

---

## Revised recommendation (supersedes the dirty-bitmap-first plan)

The existing plan's dirty-bitmap attacks "sustained read length." If the real cause is **DQ timing + contention** (not read length per se), shortening the read may *reduce the odds* but does not make it deterministic. Highest-value actions, in order:

1. **Constrain the SDRAM_DQ I/O path** — add `set_input_delay`/`set_output_delay` for the SDRAM pins, or `FAST_INPUT_REGISTER`/`FAST_OUTPUT_REGISTER`/`FAST_OUTPUT_ENABLE_REGISTER ON` on `SDRAM_DQ[*]`. Converts the IOB-packing coin-flip into a closed, build-stable path. **Highest value of all — fixes the root for the entire core (the 0.303 ns canary, the 2 MB-flaky history), not just flash.** Re-fit, read TimeQuest DQ slack + IOB-packing report.
2. **Make `sector_buf` a synchronous-read dual-port BRAM** (single registered read index) so it maps to 1 M10K instead of 4096 FF + 512:1 mux. Removes the prime congestion aggravator.
3. **Gate ch4 during the save** — use the already-wired-but-unused `dma_active` input (`rtl/msx.sv:12`) to stall `pcm_sdram_req`/canary during DMA, removing the concurrent-traffic trigger.
4. **Replace dead-reckoning with the real `ch1_ready` handshake** — data integrity.

Only after 1-3 should the `1'b0` seal (`nvram_backup.sv:150`) be lifted, then A/B-fit (build twice with a trivial unrelated change) to confirm it's no longer fit-dependent.

### Alternative architecture (sidesteps SDRAM reads entirely)
Small **BRAM write-mirror captured at write time**: tap `mapper_ascii16x_prog_we` + addr/data, mirror each programmed byte into a BRAM, stream that to SD exactly like the SRAM save (zero SDRAM reads → cannot hit the DQ path). Now affordable: `systemRAM addr_width(16)` already freed ~192 M10K (≈61% util), leaving room for a ~48-64 KB mirror (the full 8 MB mirror the plan rejected is still impossible). Limitation: only captures a bounded save window; bytes programmed outside it are lost. Best as a hybrid (small mirror for the hot window; dirty-bitmap/SDRAM read only as out-of-window fallback once the DQ path is constrained).

---

## Decisive HW experiments (priority order)
1. Add DQ I/O constraints (#1 above), re-fit, check DQ slack/IOB report. Cheapest, highest value, helps the whole core.
2. Re-enable the seal with `sector_buf`→sync BRAM + `ch1_ready` handshake; test full 8 MB read-back, no RBF reload, RAM intact.
3. Prove ch4 concurrency: gate ch4 via `dma_active` during a deliberate ch1 read storm; if the hang stops → confirmed ch1+ch4 physical contention.
4. A/B fit-dependence: build seal-removed RTL twice with a trivial unrelated change; hang-vs-boot tracking the fit confirms the marginal-timing model.

---

## File:line index (all verified in this worktree)
- `nvram_backup.sv:112` sector_buf decl; `:118` async read; `:150` `1'b0` seal; `:180-192` SRAM STATE_PROCESS; `:196-283` STATE_FLASH_*; `:199-209` dead-reckoning req/sample.
- `sdram.sv:24` stale "64MHz" comment; `:90` `cycles_per_refresh=500`; `:154,161-166` ch1 req edge; `:187` refresh_count; `:195-205` per-channel DQ capture; `:207,343` DQ drive/`z`; `:261-267` emergency refresh; `:285-299` ch1 service.
- `MSX1.sv:379` clk_sdram 85.909 MHz; `:443-451` msx_pause ce gating; `:458` dma_active→msx; `:798,818-823` ch1 mux + ch1_ready; `:816` doRefresh=0; `:855` systemRAM addr_width(16); `:893-895` SRAM BRAM port; `:904` ch1_ready wired-but-ignored.
- `rtl/msx.sv:12` dma_active unused port; `:800` "0.303ns slack / SDRAM_DQ" comment; `:806-816,865-904` canary; `:831,984` pcm ch4 on clk_sdram.
- `MSX1.sdc` / `sys/sys_top.sdc`: NO SDRAM I/O delay/register constraints.

---

## Three-defect fix designs

The save path has three INDEPENDENT defects, each with a different mechanism and fix.
Apply in this order (cheap+safe logical fixes first; physical last, behind the seal).

### D1 — `.sav` write corruption (checksum mismatch) → use the real handshake
- **Defect:** `STATE_FLASH_RD_WAIT` (`nvram_backup.sv:204-221`) latches `sdram_dout` after a
  fixed `sdram_wait` countdown, ignoring the wired-but-unused `sdram_ready`
  (`MSX1.sv:904`). Under ch2 (CPU, absolute priority) contention the ch1 read finishes
  after the fixed sample point → stale byte → wrong `.sav`.
- **Fix:** replace dead-reckoning with the controller's `ch1_ready` handshake, exactly as
  `memory_upload.sv:419-422` does.
  ```
  STATE_FLASH_PREFETCH:                       // drop the `sdram_wait <= 68`
     sdram_addr <= flash16x_base + {flash_sector, flash_byte_ptr};
     sdram_rnw  <= 1'b1; sdram_req <= 1'b1;
     state      <= STATE_FLASH_RD_WAIT;
  STATE_FLASH_RD_WAIT:
     sdram_req <= 1'b0;
     if (sdram_ready) begin                   // ★ wait for real completion
        sector_buf[flash_byte_ptr] <= sdram_dout;
        ... (advance flash_byte_ptr / sector as before)
     end
  ```
  Apply the symmetric change to the WRITE side `STATE_FLASH_WR_WAIT` (`:263-283`,
  drop `sdram_wait<=3`, wait on `sdram_ready` set in the controller's STATE_RW1).
- **Note:** the bandwidth-throttle intent of `sdram_wait=68` becomes moot once the CPU
  is fully paused (it already is, via `dma_active`, `:127-132`). If throttle is ever
  wanted again, add an explicit gap AFTER `sdram_ready`, never instead of it.
- **Risk:** low. Sim-verifiable with a variable-latency controller stub. Cannot hang
  (controller always reaches ready; if it ever didn't, pair with D2's watchdog).

### D2 — permanent pause / no resume → add a load-path timeout + mount guard
- **Defect:** `dma_active` is held for the entire op (`:127-132`) so `msx_pause` only
  releases when the FSM returns to `STATE_SLEEP`. The LOAD state `STATE_FLASH_SD_RD`
  (`:244-252`) has **no timeout** — if HPS never acks (VD0 unmounted / no `.sav` /
  readonly), `~sd_ack[0] & last_ack` never fires → FSM stalls forever → CPU never
  resumes. (The SAVE state already has a ~6.3 s timeout at `:225`; LOAD lacks it.)
- **Fix:** mirror the save-path timeout onto the load path, and add a guard so a
  missing/unwritable sidecar cleanly no-ops instead of entering the DMA.
  ```
  STATE_FLASH_SD_RD:
     sd_rd_timeout <= sd_rd_timeout + 1'd1;
     if (&sd_rd_timeout) begin                // ★ same ~6.3s abort as save
        sd_rd[0] <= 1'b0; done <= 1'b1; state <= STATE_SLEEP;
     end else begin
        if (sd_ack[0]) sector_buf[sd_buff_addr[8:0]] <= sd_buff_dout;
        if (~sd_ack[0] & last_ack) begin sd_rd[0]<=1'b0; ... state<=STATE_FLASH_SDRAM_WR; end
     end
  ```
  Reset `sd_rd_timeout<=0` when entering SD_RD (in SLEEP `:160-161` and after each
  sector in WR_WAIT `:272-274`). Strengthen the SLEEP entry guard (`:150-151`) so LOAD
  requires `image_mounted[0] & image_size[0]>0`; SAVE requires `~img_readonly`.
- **Belt-and-suspenders:** an op-level watchdog that forces `state<=STATE_SLEEP` if
  `dma_active` has been high beyond a max bound — guarantees resume under ANY stall.
- **Risk:** low. Sim with `sd_ack` never asserting → must return to SLEEP and drop
  `dma_active` within the timeout.

### D3 — reset-unrecoverable hang (the physical root) → constrain DQ + cut aggravators
- **Defect:** unconstrained `SDRAM_DQ` IOB path (~0.3 ns slack) tipped over by the
  flash DMA's congestion under ch1+ch4 concurrency → DQ contention/setup violation →
  controller/chip wedged. Not recoverable by soft reset because `sdram.init =
  ~locked_sdram` (`MSX1.sv:814`, re-inits only on PLL relock) and `reload` is
  menu-driven (corrupted SDRAM not re-staged on soft reset). Only RBF/power cycle
  recovers. Three sub-fixes, all needed:
  - **(a) Constrain the DQ I/O — highest value, fixes the whole core.** In `MSX1.sdc` /
    `sys/sys_top.sdc` add SDRAM `set_input_delay`/`set_output_delay`, and force the DQ
    flops into IOB: `set_instance_assignment -name FAST_INPUT_REGISTER ON`,
    `FAST_OUTPUT_REGISTER ON`, `FAST_OUTPUT_ENABLE_REGISTER ON` to `SDRAM_DQ[*]`
    (and `SDRAM_DQ` OE). Converts fitter coin-flip into a closed, build-stable path.
    Verify post-fit TimeQuest DQ slack > 0 and IOB packing report shows DQ in IOB.
  - **(b) `sector_buf` → synchronous-read BRAM.** `nvram_backup.sv:112` array +
    `:118` combinational `assign` read become ~4096 FF + 512:1 mux. Convert to a
    registered single-read-index dual-port RAM (1 M10K), removing the prime congestion
    cloud near the SDRAM IO bank.
  - **(c) Gate ch4 during DMA.** The wired-but-unused `dma_active` (`rtl/msx.sv:12`)
    → stall `pcm_sdram_req`/canary while a save/load runs, removing the ch1+ch4
    concurrency trigger.
- **Sequencing:** keep the `1'b0` seal (`:150`) until (a)-(c) land; then lift it and
  **A/B-fit** (build twice with a trivial unrelated change) to confirm the result is no
  longer fit-dependent. Run the 2 MB RAM integrity test + full 8 MB dump no-hang.
- **Risk:** moderate. (a) is the linchpin; if the path is genuinely too slow at
  85.9 MHz it may need a clock-phase tweak (`pll` shift) or a slower DMA clock — that
  is the residual uncertainty (see estimate below).

### Cleanest alternative (sidesteps D1+D3 entirely)
The **write-time BRAM mirror** (tap `mapper_ascii16x_prog_we`, mirror programmed bytes
into a ~48-64 KB sync-read BRAM, stream to SD via the proven SRAM `STATE_PROCESS`
path) performs **zero SDRAM reads** → never touches the DQ-read path or the
dead-reckoning sampler. It inherits D2's timeout concern only. Reuse the cheat
engine's verified sync-read M10K pattern. Limitation: bounded save window (bytes
programmed outside the mirror are lost) — best as hybrid with the SDRAM dump (once
DQ-constrained) as out-of-window fallback.

---

## Implementation success estimate (current research + plan)

Confidence is layered — the *logical* fixes are near-certain, the *physical* fix is the
swing factor, and several *Phase-0 unknowns* gate end-to-end success independently of RTL.

| Item | P(works) | Basis |
|---|---|---|
| D1 `.sav` handshake fix | **~90-95%** | Textbook handshake, sim-verifiable, mirrors working `memory_upload` |
| D2 load timeout + guard | **~95%** | Mirrors existing save timeout; trivial; sim-verifiable |
| D3 hang resolved (1st serious build) | **~60-70%** | Diagnosis well-supported but not yet HW-proven; I/O constraint usually closes such paths, but 85.9 MHz DQ may need phase/clock iteration |
| D3 hang resolved (with iteration) | **~80-85%** | Phase tweak / slower DMA clock / further congestion cuts are available fallbacks |
| Root-cause diagnosis correct (DQ-dominant) | **~75-85%** | Cross-verified, in-code 0.303 ns canary, two matching precedents — but inference, not yet measured |

**Phase-0 gating unknowns (independent of RTL quality):**
- Writable sidecar VD0 mount for the ASCII16X load path exists/configurable: **~70-80%** (may need core/Main config; if impossible, nothing persists).
- Volatile `prog_we` write is HW-correct (currently sim 5/5 only): **~85%**.
- Neon Horizon does NOT rely on sector-erase (MVP captures byte-program only): **~50%** unknown; if it erases, restored data is incomplete (a correctness gap, not a hang).

**Compounded outcomes:**
- *"The three fixes each do what they claim"* (corrupt-save gone, pause-resume robust,
  and—if diagnosis right—hang gone): **~70-80%**.
- *"End-to-end MVP works reliably on HW on the FIRST full attempt"*
  (write→save→power-cycle→load→progress restored, no hang): **~35-45%**, dragged down by
  the compounding Phase-0 unknowns + first-build DQ uncertainty.
- *"End-to-end MVP eventually shipped"* after Phase-0 verification + a few build/iter
  cycles: **~65-75%**. Phase-0 is decisive: cheaply confirming the writable mount, the
  HW write-correctness, and the erase question BEFORE RTL moves the estimate the most.

**Highest-leverage de-riskers (do first, cheap):**
1. Add the DQ I/O constraints (a) and re-fit — helps the WHOLE core (the 0.303 ns canary
   path, the 2 MB-flaky history), independent of the flash feature. Single best action.
2. Phase-0 HW checks (writable mount? write-correct? erase used?) — convert the three
   unknowns above into knowns before investing in the DMA path.
3. If the writable-mount or DQ closure looks doubtful, pivot to the **write-mirror
   alternative**, whose success estimate is higher (**~75-85%**) because it avoids the
   DQ-read path and the dead-reckoning sampler entirely — at the cost of bounded-window
   coverage.
