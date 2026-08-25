# Cheat Engine — Full 64KB Address-Indexed BRAM Overlay (Design Document)

> **STATUS: NOT YET IMPLEMENTED — FUTURE WORK.**
> The currently shipping design is the **register-based** cheat engine
> (`localparam CHEAT_N` in `rtl/msx.sv`). This document specifies a future
> replacement that scales to the full 64KB Z80 logical address space using a
> dual-port BRAM overlay. No RTL has been changed for this proposal.

---

## 1. Motivation

### 1.1 The current (shipping) design

The cheat engine lives in `rtl/msx.sv` (merged commit `c5dea71`). It is a small
**register file with parallel comparators**:

- `rtl/msx.sv:283` — `localparam CHEAT_N = 8;`
- `rtl/msx.sv:284-286` — per-entry registers:
  `cheat_en[CHEAT_N]`, `cheat_addr[CHEAT_N][15:0]`, `cheat_val[CHEAT_N][7:0]`.
- `rtl/msx.sv:288-304` — the loader: `ioctl_index == 9` (`F9,CHT`),
  4 bytes/entry `{addr_lo, addr_hi, value, flags(bit0=enable)}`. On a new
  download (`cheat_dl & ~cheat_dl_q`) every `cheat_en` is cleared, then entries
  are written while `ioctl_addr < CHEAT_N*4`.
- `rtl/msx.sv:306-317` — the comparator cloud: a combinational `for` loop over
  all `CHEAT_N` entries comparing the live Z80 address `a` against each
  `cheat_addr[cj]`, producing `cheat_hit` / `cheat_value`.
- `rtl/msx.sv:318` — `cheat_act = cheat_en_master & cheat_hit & ~mreq_n & rfrsh_n`
  (memory reads only).
- `rtl/msx.sv:320-327` — injection at the `d_to_cpu` priority mux, *below* every
  IO leg:
  ```verilog
  assign d_to_cpu = rd_n ? 8'hFF :
                    ... IO legs ... :
                    cheat_act ? cheat_value :   // cheat freeze/POKE override
                                d_from_slots ;
  ```
- Master enable: `MSX1.sv:295` `"O[51],Cheats,Off,On;"`, wired at
  `MSX1.sv:511` `.cheat_en_master(status[51])`, consumed as
  `cheat_en_master` (`rtl/msx.sv:48`).

This is deliberately non-invasive: it forces an arbitrary byte onto CPU memory
reads only. `flash.sv`, `msx_slots`, and SDRAM are untouched.

### 1.2 The limit

`CHEAT_N` is bounded **not by memory** but by the **combinational comparator
cloud sitting on the `d_to_cpu` critical path**. Every entry adds a 16-bit
equality compare and a wide OR/priority into a mux that feeds the CPU data bus —
a fit- and timing-sensitive node in this already-tight core. Practical `CHEAT_N`
is roughly **16–32** before timing/fit regressions appear. (The shipping value
is a conservative 8.)

### 1.3 Why we want more

The blueMSX `.mcf` cheat database (752 games, 5908 cheats) shows real games far
exceed a handful of pokes:

| Game | Cheats |
|------|-------:|
| **castlemore** (max) | **222** |
| Montana John | 140 (page 0) |
| Crimson 1 | 80 (page 2) |
| Xak 1 | 57 (page 0) |

To hold a whole game's `.mcf` at once we need an engine whose capacity is
**independent** of the timing path. A 64KB address-indexed overlay makes
capacity = "however many distinct addresses you poke," up to all 65536 — and it
*removes* the comparator cloud rather than growing it.

### 1.4 When to switch register → overlay

- You want to load an entire game `.mcf` (tens to low hundreds of pokes).
- You are hitting/avoiding the `CHEAT_N` timing ceiling.
- You can afford ~72 M10K blocks (we can — see §2.3).

For 1–4 pokes the register design remains perfectly adequate and cheaper; this
overlay is the "scale up" path.

---

## 2. Architecture

### 2.1 The overlay BRAM

A single **64KB dual-port BRAM** indexed directly by the Z80 logical address:

```
overlay[a[15:0]] = { valid(1 bit), value(8 bits) }   // 9 bits × 65536
```

- **Width:** 9 bits (1 valid + 8 data).
- **Depth:** 65536 (one slot per logical address).
- **Raw size:** 9 × 65536 = **589,824 bits = 576 Kbit**.

### 2.2 Ports

- **Port A — read by the CPU.** Address = the live Z80 address `a[15:0]`.
  Returns `{valid, value}` for the address the CPU is reading. **Registered**
  (synchronous read, 1-cycle latency — see §3).
- **Port B — written by the ioctl loader** and by the clear-sweep FSM (§5).
  This is the only writer; the CPU never writes the overlay.

This mirrors the existing `systemRAM` dual-port usage in `MSX1.sv:854-865`
(port A = core, port B = ioctl/SD side), so the same `dpram` primitive style
applies.

### 2.3 M10K cost and headroom

Cyclone V M10K blocks pack **8192 usable bits** per block when used in the
**8/9-bit-wide** mode (this is exactly the packing the `systemRAM` dpram relies
on; verify against the fit report rather than the nominal 10240 raw bits).

```
576 Kbit / 8192 bits-per-M10K  ≈  72 M10K blocks
```

**Does it fit?** Current fit (`output_files/MSX1.fit.summary`):

- `Total RAM Blocks : 344 / 553 ( 62 % )`  → **~209 M10K free**.
- `Logic utilization (in ALMs) : 25,836 / 41,910 ( 62 % )`.
- Device: Cyclone V `5CSEBA6U23I7`.

This headroom exists because `systemRAM` was shrunk from `addr_width(18)` →
`addr_width(16)` (`MSX1.sv:849-854`), reclaiming ~190 M10K. **72 of the ~209
free blocks** comfortably accommodates the overlay (post-overlay ≈ 344 + 72 =
**~416 / 553 ≈ 75%**). Confirm the exact number in the post-build fit summary —
synthesis may round to 73–80 depending on packing and ECC settings.

> Cross-check note (per project memory): the design previously hit IOB-packing /
> M10K-pressure fragility at ~95% M10K (the 2MB-RAM flakiness episode). At ~75%
> we are well clear, but the overlay must use a clean inferred/`dpram`-style
> block — **no large combinational clouds** near it.

---

## 3. Injection & Timing

### 3.1 Same mux, different source

The injection point is **unchanged** — still the `d_to_cpu` priority mux at
`rtl/msx.sv:320-327`. The only difference: `cheat_value` and the hit signal now
come from the **overlay BRAM read** instead of the comparator loop.

Conceptually:

```verilog
// OLD (register):  cheat_hit/cheat_value from the for-loop comparator cloud
// NEW (overlay):   {ov_valid, ov_value} = overlay.q_a   (registered read of a)
wire cheat_act = cheat_en_master & ov_valid & ~mreq_n & rfrsh_n;
...
cheat_act ? ov_value : d_from_slots
```

The comparator `for` loop (`rtl/msx.sv:309-317`) and the per-entry register
arrays (`:284-286`) are **deleted**. This is strictly **fit-friendlier**: a wide
combinational equality/priority cloud on the CPU data path is replaced by a
single BRAM output register feeding the mux.

### 3.2 BRAM read latency vs. the combinational path

The register design's `cheat_value` is *combinational* in `a` (zero added
cycles). The overlay's port-A read is *synchronous* (1 cycle). We must align it.

**Why this is safe:**

- The CPU runs at 3.58 MHz (the T80 clock domain), while the BRAM/core fabric
  runs at `clk21m` (~21.48 MHz). A single CPU read cycle spans **many** fabric
  clocks.
- Z80 memory reads on this core carry large slack: `mreq_n`/`rd_n` assert and
  the data is sampled late in the cycle, and `WAIT_n` can stretch it further.
- The Z80 address `a[15:0]` is **valid at the very start** of the read cycle
  (during T1, well before data is sampled in T2/T3).

**Alignment strategy — "address-early registered read":**

1. Drive `overlay` port-A address from the live `a[15:0]` continuously
   (it is stable for the whole read).
2. The synchronous read produces `{ov_valid, ov_value}` one `clk21m` edge later.
   Because `a` is stable from T1, that registered output is valid **long before**
   the CPU samples `d_to_cpu` in T2/T3.
3. The mux at `:320-327` consumes the **registered** overlay output — so the
   data path into `d_to_cpu` is now register→mux, not cloud→mux.

In short: the 1-cycle BRAM latency is hidden entirely inside the multi-`clk21m`
Z80 read cycle. No extra `WAIT_n` is needed; verify in static timing that the
overlay `q_a`→`d_to_cpu` mux→T80 setup is met (it has the same generous slack the
old combinational path had, minus the comparator depth).

> If a paranoia margin is wanted: gate `cheat_act` on the read being a genuine
> CPU memory access (`~mreq_n & rfrsh_n` as today) and optionally on `~rd_n`, so
> a stale registered value can never leak onto a non-read cycle.

---

## 4. Loader

The ioctl loader stays almost identical to `rtl/msx.sv:288-304`, but instead of
indexing a small register file it **writes the overlay BRAM**:

- Trigger unchanged: `ioctl_download & (ioctl_index[5:0] == 6'd9)` (`F9,CHT`).
- `.CHT` format unchanged: 4 bytes/entry `{addr_lo, addr_hi, value, flags}`,
  `flags[0] = enable`.
- Assemble each entry's 16-bit address from the two address bytes, then on the
  value/flags byte issue **one port-B write**:
  ```
  overlay[cheat_addr] <= { flags[0], value };   // valid = enable bit
  ```
- The `ioctl_addr < CHEAT_N*4` bound (`:296`) is **removed** — capacity is no
  longer a fixed `CHEAT_N`; the file can contain effectively unlimited entries
  (up to 65536 distinct addresses).

A small loader FSM (or a 2-bit byte phase like the existing `ioctl_addr[1:0]`
case at `:297`) latches `addr_lo/addr_hi/value`, and on the flags byte performs
the BRAM write. Entries with `flags[0]==0` write `valid=0` (an explicit
disable), which is harmless.

---

## 5. The CLEAR problem

The register design clears all enables in a **single cycle** on a new download
(`rtl/msx.sv:294-295`, the `for` loop zeroing `cheat_en`). **A 64KB BRAM cannot
be cleared in one cycle** — there is only one write port and 65536 slots.

### 5.1 Chosen approach — clear-sweep FSM at download start

On the rising edge of a new cheat download (`cheat_dl & ~cheat_dl_q`, the same
edge used today at `:294`), run a sweep:

```
state CLEARING:
  overlay[sweep_ctr] <= {1'b0, 8'h00};   // valid = 0
  sweep_ctr <= sweep_ctr + 1
  when sweep_ctr wraps (== 16'hFFFF) → state LOADING
```

- **Cost:** 65536 writes ≈ **65536 `clk21m` cycles ≈ ~3.05 ms** at 21.48 MHz.
- **Frequency:** once per `.CHT` load. A 3 ms blank at load time is
  imperceptible and entirely acceptable.
- **Contention:** the sweep owns port B until done. Sequence it **before** the
  loader's entry writes (CLEARING → LOADING). Since ioctl bytes stream in over
  many ms anyway, an arbiter can also let the sweep finish first; simplest is a
  strict CLEAR-then-LOAD state machine triggered on the download edge. If ioctl
  bytes can arrive during the sweep, buffer/stall the first few entries or run
  the sweep on the leading edge before any data byte is consumed.

### 5.2 Alternative — epoch / generation bit (noted, not chosen)

Instead of clearing, store a small **epoch tag** alongside each slot
(`{epoch[k], valid, value}`) and keep a global `current_epoch`. A slot counts as
valid only if `valid & (slot_epoch == current_epoch)`. A new download just
**increments `current_epoch`** — O(1), no sweep. Costs:

- +`k` bits per slot (e.g. +2 bits → 11-bit width → more M10K).
- Stale slots are never reclaimed until their address is rewritten; after
  `2^k` loads the epoch wraps and a real sweep is still required.

Given the sweep is a one-time ~3 ms cost and BRAM width matters for M10K count,
**the clear-sweep FSM is preferred**. The epoch trick is documented only as a
fallback if load-time latency ever becomes a concern.

---

## 6. Enable semantics

- **Master enable** is unchanged: `status[51]` (`MSX1.sv:295`,
  `MSX1.sv:511`, `rtl/msx.sv:48`). `cheat_act` still ANDs in `cheat_en_master`,
  so OSD "Cheats Off" disables the whole overlay instantly without touching
  BRAM.
- **Per-address enable** is the overlay's `valid` bit. A poke is active iff
  `cheat_en_master & overlay[a].valid & ~mreq_n & rfrsh_n`. Loading an entry
  with `flags[0]==0` (or the clear-sweep) sets `valid=0`.

---

## 7. CAVEAT — logical-address aliasing

The overlay is indexed by the **Z80 logical address** `a[15:0]`. This is the
right granularity for `.mcf`/`.CHT` data (which is itself logical), but it
inherits a fundamental limitation:

- **Page 3 (0xC000–0xFFFF, ~74.6% of all DB cheats)** is on this core
  effectively always main work RAM — **alias-safe**. These pokes "just work."
- **Pages 0–2 (~25% combined: page0 7.1%, page1 6.9%, page2 11.3%)** are subject
  to **slot / mapper paging alias**: the same logical address maps to different
  physical RAM/ROM depending on the current slot and mapper segment. A poke
  keyed only on the logical address can fire when the "wrong" bank is paged in.

This is **inherent to logical-address cheats** — blueMSX has exactly the same
behavior, and the current **register design shares it** (it also compares only
`a[15:0]`). So the overlay does **not regress** anything; it just makes the
existing logical-address model bigger.

**Slot-aware option (low ROI, noted):** one could widen the key to include the
active slot/segment (`{slot, segment, a}`) so a poke only fires for the intended
bank. But `.mcf`/`.CHT` payloads are *logical*, with no slot info, so we'd have
nothing to populate the extra key bits from. Until a cheat format carries slot
metadata, this is not worth the BRAM-width and complexity cost.

---

## 8. Tradeoffs

| Dimension | Register (current, `CHEAT_N`) | Full-64KB overlay (this doc) |
|---|---|---|
| **Capacity** | ~8 shipped; ~16–32 ceiling | Up to 65536 distinct addresses (whole `.mcf`, max DB game = 222) |
| **Capacity limited by** | Comparator cloud on `d_to_cpu` timing/fit | M10K availability only |
| **M10K** | ~0 (uses LUT registers) | ~72 M10K (576 Kbit / 8192) |
| **ALM / comparators** | N×16-bit compares + priority OR on data path | None — comparator cloud **removed**; just a BRAM + mux |
| **Read timing** | Combinational in `a` (0 cycle), but grows with N | 1-cycle synchronous read, hidden in the 3.58 MHz read cycle; flat regardless of #pokes |
| **Clear** | 1-cycle (`for` loop zeroing enables) | ~3 ms sweep FSM once per load |
| **Loader** | Bounded `ioctl_addr < CHEAT_N*4` | Unbounded; one BRAM write per entry |
| **Aliasing (page0–2)** | Yes (logical) | Yes (logical) — same |
| **Complexity** | Very low | Moderate (BRAM + clear-sweep FSM + load FSM) |
| **Fit risk** | Grows with N on critical path | Lower critical-path risk; spends M10K headroom |

---

## 9. Migration / Implementation Checklist

**RTL (`rtl/msx.sv`):**

- [ ] Add a `dpram`-style 9×65536 dual-port `overlay` (model on
      `MSX1.sv:854-865` `systemRAM`).
- [ ] Port A: drive address from live `a[15:0]`; register `{ov_valid, ov_value}`.
- [ ] Port B: clear-sweep FSM + ioctl loader writes.
- [ ] Replace the comparator `for` loop (`:309-317`) and entry arrays
      (`:284-286`) with the registered overlay read.
- [ ] Rework `cheat_act` (`:318`) to use `ov_valid`; keep
      `cheat_en_master & ~mreq_n & rfrsh_n` gating.
- [ ] Mux at `:320-327` unchanged except `cheat_value → ov_value`.
- [ ] Loader (`:288-304`): drop the `CHEAT_N*4` bound; assemble addr; write BRAM.
- [ ] Clear-sweep FSM on the download edge (`cheat_dl & ~cheat_dl_q`):
      walk 0..0xFFFF writing `valid=0`, then enter LOADING.

**No changes needed:**

- [ ] `MSX1.sv` CONF_STR (`F9,CHT` line 294, `O[51]` line 295) — unchanged.
- [ ] `.cheat_en_master(status[51])` wiring (`MSX1.sv:511`) — unchanged.
- [ ] `flash.sv`, `msx_slots`, SDRAM — untouched (non-invasive injection
      preserved).

**Verification plan:**

1. **Simulation (unit TB):**
   - Drive port-B writes for a scattered set of `(addr, value)` pairs incl.
     page0–3 addresses; read back via port A at those addresses — expect
     `valid=1, value=v`.
   - Read an un-poked address — expect `valid=0` (no override).
   - Trigger the clear-sweep; confirm every slot reads `valid=0` afterward and
     that a fresh load repopulates correctly (no stale survivors from the prior
     load — the core correctness property vs. the register design).
   - Confirm `d_to_cpu` reflects `ov_value` only when
     `cheat_en_master & ov_valid & ~mreq_n & rfrsh_n`.

2. **Build:**
   - Fit: expect `Total RAM Blocks` ≈ `344 + ~72 = ~416 / 553 (~75%)`. Confirm
     actual packing (73–80 acceptable).
   - Static timing: overlay `q_a` → `d_to_cpu` mux → T80 setup met; no new
     failing paths on `clk21m`. Confirm comparator-cloud paths are gone.
   - Watch SDRAM_DQ IOB packing is still clean (we are far from the 95% M10K
     danger zone, but verify per prior fragility lessons).

3. **Hardware:**
   - Load a **100+ entry `.CHT`** (e.g. derived from castlemore's 222-cheat
     `.mcf`) and confirm all page-3 pokes take effect in-game.
   - Spot-check a page0/page2 game (Montana John / Crimson 1) — expect the known
     logical-aliasing caveat (§7) to behave the same as the register engine.
   - Toggle OSD `Cheats Off/On` (`status[51]`) and confirm instant global
     enable/disable with no BRAM reload.
   - Re-load a *different* `.CHT` and confirm none of the previous game's pokes
     persist (clear-sweep correctness on real hardware).

---

## 10. Summary

A 64KB address-indexed dual-port BRAM overlay replaces the register comparator
cloud with a single registered BRAM read at the **same** `d_to_cpu` injection
point. It (a) lifts capacity from ~8–32 to effectively the whole address space —
enough for any DB game including the 222-cheat max, (b) **removes** the
timing-/fit-sensitive comparator cloud, (c) costs ~72 of ~209 free M10K, and
(d) needs only a one-time ~3 ms clear-sweep at load. The single new constraint
(logical-address aliasing on pages 0–2) is inherent to logical cheats and is
already present in today's register design — so this is pure scale-up with no
behavioral regression.

**Again: NOT YET IMPLEMENTED. Shipping design remains the register-based
`CHEAT_N` engine in `rtl/msx.sv`.**
