# ICS2115 (IGS PGM) vs. YMF278B (OPL4) PCM Engine — Comparison

A side-by-side comparison of two FPGA PCM/wavetable engines, written to extract
concrete lessons for our YMF278B PCM engine's two open problems: the **read-budget
voice-drop** symptom and the **sustained sample-upload (otir burst) freeze**.

This builds on the standalone ICS2115 analysis in
[`docs/ics2115_analysis.md`](./ics2115_analysis.md); read that first for the
ICS2115 internals. Here the focus is the *contrast in memory-access philosophy*
and what is portable to the OPL4.

Repos / files cited:

| Tag | Repo root |
|-----|-----------|
| **ICS** | `/home/muhanpong/Documents/github/Arcade-IGSPGM_MiSTer` |
| **OPL4** | `/home/muhanpong/Documents/github/MSX1_MiSTer` (this repo) |

---

## 0. Executive summary

The two engines compute essentially the same DSP (phase accumulation → 2 sample
reads → linear interpolation → envelope/volume/pan → accumulate). They differ in
**one structural axis that dominates everything**: how the engine couples to
sample memory.

- **ICS2115 is latency-AGNOSTIC.** Its oscillator issues a single-word read with
  a `rom_rd`/`rom_data_valid` handshake and *stalls* until valid
  (ICS `rtl/ics2115/ics2115_osc.sv:239,241`). A dedicated **per-voice cache**
  (`rtl/rom_cache.sv:159-232`) sits between the engine and SDRAM, so reads are
  almost always 0-stall hits and the engine never has a deadline.

- **OPL4 (ours) is latency-SENSITIVE.** All 24 slots are scheduled inside a
  **fixed 1948-cycle per-frame read budget** with 64-cycle per-slot windows
  (OPL4 `rtl/.../ymf278_pcm_engine.sv:125-130`). When SDRAM round-trips don't
  finish inside a slot's window, the slot either holds its last sample
  (`:767,789-792`) — audible voice-drop — or we lean on the **`CH4_HOLD` burst-
  priority hack** in the shared arbiter (OPL4 `rtl/peripheral/sdram.sv:124,325`)
  to claw the latency back.

- The ICS2115's immunity comes from three properties our engine lacks:
  (1) a **private per-voice cache slot keyed by channel** so voices can't evict
  each other (ICS `rtl/rom_cache.sv:184`); (2) the engine **stalls** rather than
  drops on a miss; (3) audio is the **top SDRAM priority + a 4-word burst line**
  (ICS `rtl/sdram.sv:239`, `BURST_LENGTH=4` at `:73`).

- The OPL4 also has a problem the ICS2115 simply *does not have*: the host (Z80)
  **writes** sample RAM through the chip (reg 0x06), and an unpaced `otir` burst
  of tens-to-hundreds of KB streams into the **same ch4** the engine reads from.
  The ICS2115 never writes sample memory (ICS `analysis §3.6`), so it has no
  analog of this freeze. Fixing it needs a **decoupled write path** (FIFO /
  separate channel), not a cache.

**Bottom line:** the read-budget drops are a *self-inflicted* architecture choice
that the ICS2115 cache model would largely eliminate; the otir freeze is a
genuinely OPL4-specific write-traffic problem that needs its own fix.

---

## 1. Side-by-side architecture table

| Aspect | ICS2115 (IGS PGM) | YMF278B / OPL4 (ours) |
|--------|-------------------|------------------------|
| **Voices / slots** | 32 (`active_osc` default 31) — ICS `ics2115_pkg.sv:10-11` | 24 slots — OPL4 `ymf278_pcm_engine.sv:126` |
| **Datapath** | **One** time-multiplexed oscillator, serialized by a top sequencer — ICS `ics2115.sv:367-389`, analysis §2 | **4-stage pipeline** (A/B/C/D), one slot per 64-cycle window staggered across stages — OPL4 `:1-27,326-328` |
| **Sample formats** | 16-bit signed, 8-bit linear, 8-bit µ-law — ICS `ics2115_osc.sv:96-111` | 8 / 12 / 16-bit (OPL4 set) — OPL4 alu `decode_sample()` `ymf278_pcm_alu.sv:236-252` |
| **Phase / interp** | 29-bit 20.9 accum, 9-bit linear interp — ICS `ics2115_osc.sv:155-164` | 16.16-style step accumulate, 16-bit-frac linear interp — OPL4 alu `calc_step()` `:12-23`, `calc_interp()` `:132-142` |
| **Output rate** | `ce_33m / ((active_osc+1)*32)` ≈ 33.1 kHz — ICS `ics2115.sv:264-288` | 1948-cycle frame @ ~85.9 MHz ≈ 44.1 kHz — OPL4 `:129,222` |
| **Host interface** | 4-port indirect 8-bit bus, same clock domain; per-voice writes via 16-entry FIFO committed when voice not in pipeline — ICS `ics2115.sv:822-839`, analysis §1 | reg writes cross **clk21m→clk_sdram CDC** (toggle sync) + **WAIT_n** flow-control hold — OPL4 `msx.sv:584-641` |
| **Sample-memory backing** | SDRAM ch2 (read-only); ROM uploaded once at load — ICS `PGM.sv:738-755`, analysis §3.6 | SDRAM **ch4** (read **and** write at runtime): yrw801 ROM + 2 MB custom RAM — OPL4 `msx.sv:570,666` |
| **Read protocol** | Engine → **`audio_rom_cache`** (64 slots, 2/voice, 64-bit/4-sample lines) → SDRAM burst — ICS `rom_cache.sv:159-232` | Engine **Stage-B serial sequencer** issues 3–4 word reads/slot, gated by a `mem_busy` handshake to the ch4 bridge; small per-slot decoded-sample cache — OPL4 `:481-621,510-529` |
| **Write/upload protocol** | none (chip never writes sample memory) — analysis §3.6 | reg 0x02/0x03-05/0x06 CPU mem port → low-priority requester on the **same** ch4 port — OPL4 `:1710-1860` |
| **Mixing** | 24-bit L/R accumulators, clamp to 16-bit — ICS `ics2115.sv:481-512` | 24-bit L/R accumulators, OSD shift + reg-0xF9 mix, saturate to 16-bit — OPL4 `:1278-1343` |
| **SDRAM arbiter** | 4-ch, **audio = highest priority**, 4-word burst — ICS `sdram.sv:239-246,73` | 4-ch, **ch4 = lowest** normally, raised by `CH4_HOLD` burst-priority window — OPL4 `sdram.sv:119-126,273-333` |

Two structural facts jump out of this table:

1. The ICS2115 puts the cache **outside** the engine and lets the engine be naive;
   the OPL4 puts the read *scheduler* **inside** the engine (Stage B) and bolts a
   tiny cache + an arbiter hack on afterward.
2. The ICS2115 sample memory is **read-only**; the OPL4's is **read/write on the
   same channel**, which is the root of the otir freeze.

---

## 2. ★ Memory-access philosophy — the core of the report

### 2.1 ICS2115: a stall-until-valid engine behind a private-per-voice cache

The ICS2115 oscillator treats sample memory as a **single-word, variable-latency
synchronous ROM**. It drives `rom_addr`/`rom_rd`, then *parks* in a wait state
until `rom_data_valid` (ICS `ics2115_osc.sv:239,241`). There is no DMA, no
engine-side burst, no deadline — the FSM simply does not advance until the data
arrives.

The magic is the module it talks to: `audio_rom_cache`
(ICS `rom_cache.sv:159-232`), a **direct-mapped 64-slot cache of 64-bit
(4-sample) SDRAM lines**, with the slot index:

```
wire [5:0] slot_idx = { channel, addr[3] };   // rom_cache.sv:184
```

This single line is the whole contention story. The slot is keyed by
**`channel`** (the voice id), so:

- **Each voice owns 2 private cache slots (32 voices × 2 = 64).** A read is a hit
  when `cache_tag == addr[26:3]` *and* the slot matches
  (`data_valid`, ICS `rom_cache.sv:198`), and the data is available
  **combinationally the same cycle** — 0 stall.
- **Voices cannot evict each other.** Voice N's reads land only in slots
  `{N, 0/1}`. No matter how many voices stream simultaneously, voice N's working
  set is never displaced by voice M. This is the property our engine does not
  have and the reason 32 streaming voices generate a *bounded, well-behaved*
  SDRAM load.
- **Each line is a 4-word burst** (ICS `sdram.sv:73` `BURST_LENGTH=4`,
  filled at `rom_cache.sv:215-224`). Linear interp needs `cur` and `cur+1`, which
  are almost always in the same line → the 2nd read is a guaranteed hit; and
  forward playback consumes 4 samples per line → only ~**1 SDRAM burst per voice
  per ~4 output samples** actually reaches SDRAM.
- **Audio is the highest-priority SDRAM channel** (ICS `sdram.sv:239-246`,
  checked right after emergency refresh), so even those rare misses win
  arbitration immediately.

Net effect: per output sample the engine issues 2×32 = 64 reads, but the vast
majority are 0-stall hits, and the few misses stall the *engine* (which has
generous slack — ~1024 `clk` per sample tick vs. a ~14-state FSM, analysis §2)
rather than dropping a voice. **There is no read budget. There is no deadline.
There is nothing to overflow.**

### 2.2 OPL4 (ours): a fixed read-budget scheduler

Our engine inverts every one of those properties.

- **There is a hard frame budget.** `CYCLES_PER_FRAME = 1948`, divided into 24
  slots × 64-cycle windows + a 3-window pipeline drain
  (OPL4 `:125-130`). Stage B has exactly one 64-cycle window to land its 3–4 word
  reads for a slot (`:357-362`).
- **The "cache" is shared by being indexed, but is really a per-slot scratch,**
  not a contention-isolated working set. We do have a per-slot decoded-sample
  cache keyed by `(startAddr, pos)` (OPL4 `:510-529`), but it only helps when a
  *low-pitched* slot re-reads the **same** window frame-after-frame. As soon as
  every voice is actually advancing through memory (the busy case), the cache
  misses and all 24 slots compete for ch4 inside the budget.
- **A miss DROPS, it doesn't stall.** `MAX_STALL = 0` (OPL4 `:174`) — the
  scheduler is deliberately set to **never** stall, because a stalled slot would
  never advance its key-on/envelope and would go silent on the overlay
  (`:169-176`). So when reads don't finish, Stage C falls back to the slot's
  **last interpolated sample** (`:767,789-792`). That is graceful degradation,
  but it is still a *voice drop* relative to correct audio — the "read budget"
  symptom.
- **ch4 is the LOWEST-priority channel**, and we compensate with the
  **`CH4_HOLD` hack**: after a ch4 grant, ch4 keeps priority over ch1/2/3 for 24
  cycles so a multi-word burst "pays the arbiter queue once instead of per word"
  (OPL4 `sdram.sv:119-126`, granted at `:325`). The comment itself records the
  measured effect (read latency 29→11, sustain restored) — i.e. without the hack
  the latency blows the per-slot window.

### 2.3 Why the ICS2115 is immune to exactly our two problems

**Read-budget voice-drop:** The ICS2115 has no per-slot deadline. A slow read
stalls the (slack-rich) engine instead of consuming a fixed window; and because
slots are per-voice and lines are bursted, the *aggregate* SDRAM traffic is
bounded (~1 burst/voice/4-samples) regardless of how many voices are active.
Our engine, by contrast, must fit **all** active slots' reads into 1948 cycles,
and a couple of row-misses or arbiter losses push a slot past its 64-cycle window
→ last-sample hold → drop. The ICS design converts "too many reads this frame"
(a hard failure for us) into "the engine waits a bit longer" (a non-event for it),
*and* keeps the read count low in the first place via the per-voice burst cache.

**Sustained traffic:** With private per-voice slots, a 32-voice fortissimo passage
is just 32 independent ~1-burst-per-4-samples streams — no thrash, no eviction
storm. Our shared, budgeted ch4 has no such isolation: heavy playback already
saturates the budget, which is why `CH4_HOLD` exists at all.

---

## 3. Lessons for our YMF278B engine

Distinguishing **applicable** ideas from ones blocked by the OPL4's spec.

### 3.1 (i) Read-budget voice drops — *highly applicable*

**Steal the per-voice private cache + burst line.** This is the single highest-
value port. Replace the current `(startAddr, pos)` scratch cache
(OPL4 `:510-529`) with an ICS-style **per-slot cache keyed by slot id**, holding
the **aligned multi-sample SDRAM line** (the ch4 bridge already exposes a 16-bit
`mem_rd_data16` word, OPL4 `msx.sv:716` — extend the bridge to return a 4-word /
64-bit line like `ch2_dout[63:0]` in ICS `sdram.sv`). Then:

- Voice N's reads never evict voice M's working set → no cross-slot thrash, which
  is the dynamic that makes the budget overflow under load.
- Forward playback drops from ~3–4 reads/slot/frame to ~1 line fetch every few
  frames, slashing aggregate ch4 traffic — exactly the lever that pulls us back
  under budget. (Our own cache comment already names this intent at `:510-517`;
  the ICS keying makes it robust under *simultaneous* voice activity, which the
  current pos-keyed version is not.)

**Make Stage B stall-tolerant instead of budget-bounded.** The scheduler already
has the machinery — `pipe_advance`, `b_busy`, `stall_cnt`, `MAX_STALL`
(OPL4 `:167-176,202-216`) — but `MAX_STALL=0` disables it because a stalled slot
stops advancing its envelope/key-on. The ICS shows the clean version: the *engine*
stalls on a read miss, but the **per-slot scheduling and the envelope/key-on
update are decoupled from the read** (ICS runs env update in `ST_VOL_ENV_UPDATE`
*after* the stall resolves, analysis §4). If we (a) add the per-voice cache so
stalls become rare, and (b) ensure a stalled slot's key-on edge/envelope still
advances (it already runs in Stage D, separate from Stage B's reads), we could
raise `MAX_STALL` and let slow slots borrow slack — the comment at `:159-166`
shows this was the original intent before it was disabled.

**Could we then drop `CH4_HOLD`?** Plausibly, *if* the per-voice burst cache lands.
`CH4_HOLD` exists because today every slot independently round-trips ch4 inside
its window and the arbiter queue per-word is too slow (OPL4 `sdram.sv:119-126`).
With a burst-line cache, ch4 traffic drops by ~4× **and** each fetch is already a
single aligned line — the same amortization `CH4_HOLD` is faking. Better still,
**make ch4 read the top arbiter priority like ICS ch2** (ICS `sdram.sv:239`):
that is the structural version of `CH4_HOLD` and would let us delete the
`ch4_hold_cnt` window entirely. (Caveat: ICS audio-priority works because nothing
else is latency-critical on its bus; on MSX, ch1-3 carry CPU/VDP — raising ch4 to
top priority needs a check that VDP/CPU latency stays acceptable. A bounded burst
hold like the current one may remain the safer middle ground.)

### 3.2 (ii) Sustained-upload (otir) freeze — *partially applicable; needs a different fix*

This is **not** a cache problem, and the ICS2115 has no direct analog (it never
writes sample memory — analysis §3.6). But the ICS register-write FIFO points at
the right shape of fix.

Today the CPU sample-write path is a **low-priority requester sharing the ch4
port** (OPL4 `:1737-1742,1851-1854`), issued only when HF and Stage B are both
idle (`cpu_issue_ok`). Under an unpaced `otir` of reg-0x06 writes:

- Each write must (a) cross the clk21m→clk_sdram CDC, (b) win a frame-tail / idle
  ch4 window, (c) round-trip the bridge. WAIT_n (OPL4 `msx.sv:596-641`) holds the
  Z80 per-write so a single write isn't lost — that fixed the **small**-upload
  race. But for a **sustained** burst the problem is throughput, not a single
  race: hundreds of writes each serialized through one idle window, contending
  with the same engine reads, with `cpu_mem_active` halting dispatch
  (OPL4 `:226,1804-1805`) — which can starve the reads/HF that are supposed to
  free the window, the classic deadlock-y stall the freeze looks like.

**Applicable ICS idea — decouple the write stream with a FIFO.** The ICS commits
host register writes through a **16-entry FIFO** drained when the target isn't
busy (ICS `ics2115.sv:822-839`), so the asynchronous Z80 stream never blocks the
synchronous engine. The OPL4 analog:

- Add a **sample-write FIFO** between the reg-0x06 decoder and the ch4 port. The
  CPU write enqueues (cheap, never blocks the engine); a drainer issues to ch4 in
  the slack windows. WAIT_n then only needs to assert on **FIFO-full**, not on
  every write — turning per-write stall into back-pressure only when actually
  saturated.
- Even better and **strictly applicable**: give sample writes their **own SDRAM
  channel** (e.g. reuse a spare arbiter channel for ch4-writes) so the upload
  stream stops contending with engine reads on the same channel. Reads stay
  latency-sensitive; writes become a separate bursted, back-pressured stream.
  This directly removes the "writes starve the reads that free the write window"
  coupling that the current single-ch4-port design creates.

Either of these is the real fix for the otir freeze; the read-side cache work in
§3.1 does **not** address it.

---

## 4. Honest constraints — where the chips genuinely differ

A fair comparison has to flag the spec differences so we don't over-port.

- **OPL4 has a host-writable 2 MB sample RAM with a reg-0x06 access port; the
  ICS2115 does not.** The ICS sample ROM is uploaded once at load via the MiSTer
  `ioctl` path and is **read-only at runtime** (analysis §3.6). So the entire
  otir-freeze class of bug is *structurally absent* on the ICS2115 — its
  contention-immunity is partly because it only ever reads. Any "the ICS doesn't
  have this problem" claim about writes is therefore not a design win to copy;
  it's a spec the OPL4 can't adopt. The write path needs its own engineering
  (§3.2).

- **OPL4 is FM + PCM; the ICS2115 is PCM-only.** The OPL4 also runs an OPL3 FM
  core (`clk_opl3`, OPL4 `msx.sv:573-582,733-736`) and the MoonSound detection /
  IRQ / timer logic. The ICS2115 has timers/IRQ for the PGM Z80 but no FM. This
  doesn't affect the memory comparison directly but means the OPL4 has more
  on-chip pressure (BRAM, DSP, timing) competing with any cache we add — and the
  MEMORY notes already record that a large combinational cloud in the engine
  broke SDRAM IOB packing and destabilized the 2 MB RAM. A burst cache must be
  added as **BRAM + a clean FSM**, not combinational logic, to avoid repeating
  that.

- **Clocking / multiplexing differ but are equivalent for this purpose.** ICS is
  single-domain with clock-enables and a time-multiplexed single datapath;
  ours is a true 4-stage pipeline at ~85.9 MHz with a CPU CDC. The ICS's "stall
  is free" property partly relies on its huge per-sample slack (1024 clk/sample).
  Our 64-cycle windows are tighter, so a naive "just stall forever" port is not
  safe — which is exactly why §3.1 pairs the stall-tolerant FSM **with** the
  cache (to make stalls rare) rather than relying on stalling alone.

- **Arbiter priority is not free to flip.** Making ch4 top-priority (§3.1) is the
  clean ICS-style fix, but ICS's bus only carries video + CPU, none latency-
  critical the way MSX VDP can be. Validate VDP/CPU latency before promoting ch4;
  the bounded `CH4_HOLD` burst window may stay the pragmatic choice.

---

## 5. Prioritized "what we should steal from the ICS2115"

1. **Per-voice (per-slot) burst-line cache, keyed by slot id** (model:
   ICS `rom_cache.sv:184,198,215-224`). Highest leverage for the read-budget
   drops: isolates voices from each other and cuts ch4 read traffic ~4×. Needs a
   ch4 bridge that returns an aligned multi-word line (extend
   OPL4 `msx.sv:716`). Implement as BRAM + FSM (not combinational — see §4).
2. **Stall-tolerant Stage B** (model: ICS stall-until-`rom_data_valid`,
   `ics2115_osc.sv:239,241`). Re-enable the already-present `MAX_STALL`/`stall_cnt`
   path (OPL4 `:167-176`) once the cache makes stalls rare and the
   key-on/envelope advance is confirmed decoupled from the read.
3. **Promote ch4 read to top arbiter priority** (model: ICS `sdram.sv:239`),
   potentially retiring the `CH4_HOLD` hack — gated on a VDP/CPU latency check.
4. **Decouple the host sample-WRITE path** (model: ICS host-write FIFO
   `ics2115.sv:822-839`): a sample-write FIFO and/or a separate SDRAM channel for
   reg-0x06 uploads, with WAIT_n asserting only on FIFO-full. This — not the
   cache — is the fix for the otir-burst freeze.

Items 1–3 attack the read-budget voice drops; item 4 attacks the sustained-upload
freeze. They are independent and can land separately.
