# ASCII16X Permanent (Power-Off-Persistent) Flash Storage — Implementation Plan

Status: design / not yet implemented. Branch context: `moonsound`.
Goal: make ASCII16X (MegaFlashROM-style) in-game flash writes survive power-off,
e.g. Neon Horizon writing progress into its own ROM region.

---

## 1. Verified current state (code-confirmed, not memory)

- ASCII16X byte-program is **volatile**. `cart_ascii16x` runs its own JEDEC
  AA/55/A0 FSM and asserts `prog_we` for exactly one validated, in-bounds data
  write (`rtl/peripheral/slots/ascii16x.sv:95`, gated by `prog_arm <= ~mem_unmaped`
  at `:86`). The header comment "flash.sv NOT involved" is true for the *write*.
- That `prog_we` becomes an ordinary **CPU ch2 SDRAM write** into the ROM-image
  copy: `msx_slots.sv:148` folds `mapper_ascii16x_prog_we` into `sdram_ce`, and
  `:150` forces `ram_rnw` low. Target = `base_ram + mem_addr`. SDRAM is rebuilt
  from file on every reload / power cycle → writes lost.
- `flash.sv` is still wired to ASCII16X but only for **ident/status reads** and
  (potentially) **sector-erase via ch3**. Its own `bytePrgram` path is
  structurally dead (`flash.sv:134` chicken-and-egg on `write_cnt`). So the live
  write path for ASCII16X is the ch2 `prog_we` path only.
- A complete SDRAM↔SD DMA persistence FSM **already exists** in
  `rtl/nvram_backup.sv:196-283` (STATE_FLASH_PREFETCH/RD_WAIT/SD_WR save;
  STATE_FLASH_SD_RD/SDRAM_WR/WR_WAIT load), streaming 512 B sectors via the
  standard `hps_io` `sd_rd/sd_wr/sd_lba/sd_buff` block interface — the same proven
  mechanism the SRAM `.sav` save uses.
- That FSM is **hard-disabled** by `if (1'b0 & num==2'd0 & flash16x_active & ...)`
  at `nvram_backup.sv:150`. Comment `:148-149`: "ASCII16X flash save DISABLED:
  SDRAM ch1 DMA corrupts SDRAM controller after sustained read traffic. Requires
  future Flash FSM + BRAM mirror."
- Region descriptors are already plumbed end-to-end:
  `msx_slots.sv:476-484` (`flash16x_base=base_ram`, `flash16x_size=size` in 16 KB
  units, `flash16x_active`) → `msx.sv` → `MSX1.sv:869-871,896-898` into
  `nvram_backup`.
- Triggers already exist: `status[38]` "SRAM Save", `status[39]|load_sram`
  "SRAM Load" (`MSX1.sv:266-267,881-882`); CPU is frozen during DMA via
  `dma_active → nvbak_dma_active → msx_pause` (`MSX1.sv:443`).
- **Correction to prior analysis:** the OSD items are NOT masked off for
  ASCII16X. `status_menumask[6] = (sumSRAM==0) & (mapper != MAPPER_ASCII16X)`
  (`MSX1.sv:313`). For an ASCII16X cart with no SRAM this is `1 & 0 = 0`, so the
  "SRAM Save/Load" items are **already shown** for ASCII16X. The menu term
  *enables* the trigger; no menu edit is required. The sole RTL blocker is the
  `1'b0` guard.

Net: persistence is ~90% built and wired. The work is to **re-enable it safely**,
not to architect a new datapath.

---

## 2. Chosen approach (resolving the debate)

**Re-use the existing `nvram_backup` STATE_FLASH_* DMA FSM, gated by a small
COARSE (64 KB) register-based dirty bitmap, triggered manually with the CPU
paused, persisting to a sidecar `.sav`-style mounted image.**

All three lenses (Safety-first, MiSTer-idiomatic/reuse, Feasibility/MVP)
**converge** on: reuse the dead FSM + add a dirty-skip so the flush touches only
changed sectors. The only real disagreement is bitmap granularity. Resolution:

- **MVP granularity = 64 KB coarse bitmap in flip-flops (registers), zero M10K.**
  8 MB ROM = 128 bits. This is chosen over a fine 512 B BRAM bitmap (~2 M10K for
  8 MB) because the documented failure modes of this core are (a) sustained SDRAM
  ch1 traffic and (b) BRAM/IOB-packing pressure near the ~95% M10K cliff that
  corrupted `SDRAM_DQ` I/O timing (the `compute_vib` lesson). A register bitmap
  attacks (a) via dirty-skip while adding **zero** pressure to (b). The flush
  saving of a fine bitmap over a coarse one is irrelevant because the CPU is
  paused and Neon Horizon saves are tiny (~0xC008 region + scattered bytes), all
  landing in 1–2 64 KB blocks.
- 64 KB also aligns naturally with `flash.sv` erase-block size (`flash.sv:59`),
  so a future erase-capture sets the same coarse bit.

**Why not the alternatives** (per the lenses):
- *Just delete the `1'b0` guard* (minimal-change): reinstates the whole-image
  read storm — the exact cause of the seal. Rejected.
- *Custom BRAM mirror as primary store + DMA from BRAM* (heavy-RTL): duplicates
  state SDRAM already holds and pushes M10K back toward the flaky cliff —
  reintroducing root cause (b). Rejected for MVP.
- *Fine 512 B BRAM bitmap* (performance): trades the safe axis for the risky one
  for no practical benefit here. Deferred (only if a future game writes across
  many scattered 64 KB blocks).
- *`ioctl_upload` / FIO_FILE_TX write-back to the `.rom`* (framework-completeness):
  not wired in `MSX1.sv` (no `ioctl_din` net) AND semantically wrong — it reads
  HPS DDR3, where modifications never land (writes go to SDRAM). Would persist
  stale bytes. Rejected.
- *Autosave-on-eject + journaling/atomic commit* (robustness): genuinely better
  for power-loss but all-new logic with no scaffold; scope creep. Deferred to
  Phase 4.
- *In-place `.rom` rewrite*: needs bespoke HPS Main to mount the multi-MB ROM
  read-write; large write amplification. Sidecar `.sav` reuses proven plumbing.

---

## 3. Architecture & data flow

### Write capture (dirty tracking)
```
CPU JEDEC byte-program  ->  cart_ascii16x prog_we (ascii16x.sv:95)
                        ->  mem_addr (ROM-relative byte addr)
                        ->  set dirty64k[mem_addr[24:16]]   (NEW, registered)
```
The dirty bit set lives in `msx_slots` scope (where `mapper_ascii16x_prog_we`
and `mapper_ascii16x_addr`/`mem_addr` are visible) and is exported to
`nvram_backup`. It is a plain registered write — **no combinational fan-in to
`sdram.sv` ports**.

### Save flush (manual, CPU paused)
```
status[38] -> save_req -> nvram_backup STATE_SLEEP
  -> (guard now: flash16x_active & image_mounted[0] & ~readonly)
  -> walk sectors 0..flash_total_sectors:
        if dirty64k[sector >> 7] == 0  -> SKIP (advance flash_sector, no SDRAM read)
        else STATE_FLASH_PREFETCH: SDRAM ch1 read 512B -> sector_buf
             STATE_FLASH_SD_WR:    sd_wr[0] block -> HPS writes sidecar .sav
  -> on completion: clear dirty64k
```
(`sector >> 7` because 64 KB / 512 B = 128 sectors per coarse block.)

### Load restore (on mount / manual, AFTER ROM staged)
```
status[39] | load_sram  (must fire AFTER memory_upload finishes; upload_active low)
  -> STATE_FLASH_SD_RD: sd_rd[0] block -> sector_buf
  -> STATE_FLASH_SDRAM_WR: sector_buf -> SDRAM ch1 write (overlays saved bytes
     on top of the freshly-staged pristine ROM)
```
Load may walk all sectors (SD reads are cheap and the sidecar can be a sparse
file); or, to minimize, restore only sectors that read back non-pristine. MVP:
walk all (simplest, correctness-first); optimize later if load time is an issue.

### Non-volatile target
A sidecar block image (e.g. `<rom>.sav`-style) mounted by HPS/MiSTer-Main on the
VD0 index `nvram_backup` already drives (`sd_lba[0]/sd_wr[0]/sd_buff_din[0]`),
sized to the ROM, `sd_lba` mapped 1:1 from `flash16x_base` byte 0.

---

## 4. Exact files / edits (with anchors)

1. **`rtl/peripheral/slots/ascii16x.sv`** — no change needed; `prog_we`
   (`:95`) and `mem_addr` (`:54`) are the dirty source. (Optional: also expose an
   `erase_we`/`erase_block_num` if Phase 3 erase-capture is pursued.)

2. **`rtl/peripheral/slots/msx_slots.sv`** — add a registered 64 KB dirty
   bitmap. Set `dirty64k[mapper_ascii16x_addr[24:16]] <= 1` when
   `mapper_ascii16x_prog_we` fires (near the existing prog_we use at `:148-150`).
   Add an output port `output reg [127:0] flash16x_dirty` (or a clear-on-flush
   handshake). Reset/clear on a `flash16x_dirty_clr` input from `nvram_backup`.

3. **`rtl/msx.sv`** — thread the new `flash16x_dirty` / `flash16x_dirty_clr`
   ports through (alongside existing `flash16x_*` at `msx.sv:62-64`/`:87-89`).
   Also fix the pre-existing wiring quirk at `msx.sv:631-632`
   (`.flash_done(flash_ready)` should use the real ch3 `flash_done`) — verify
   before touching; out of MVP scope unless it affects erase.

4. **`MSX1.sv`** — connect `flash16x_dirty`/`flash16x_dirty_clr` between
   `msx`/`msx_slots` and `nvram_backup` (instantiation at `:876-906`). No CONF_STR
   / menumask change required (see §1 correction; `:313` already shows the items).

5. **`rtl/nvram_backup.sv`** — the core change:
   - Add input `flash16x_dirty[127:0]` and output `flash16x_dirty_clr`.
   - Replace `if (1'b0 & ...)` at `:150` with the real guard
     `if (num==2'd0 & flash16x_active & image_mounted[0] & (wr | (rd & image_size[0]>0)))`.
   - In `STATE_FLASH_PREFETCH` (`:196`): before issuing the SDRAM read, check
     `flash16x_dirty[flash_sector[15:7]]`; if 0, advance `flash_sector`
     (and `sd_lba[0]` if loading) and loop without an SDRAM access.
   - On save completion (`:236`), pulse `flash16x_dirty_clr`.
   - Keep `sdram_wait=68` read throttle (`:200`) and `=3` write (`:259`)
     untouched (CDC dead-reckoning).

No changes to `sdram.sv`, `flash.sv`, `memory_upload.sv`, or the SDRAM channel
map. ch2 absolute priority / no-handshake deadline (`sdram.sv:268-284`) is
untouched.

---

## 5. Safety guardrails (must respect the recorded lessons)

- **No sustained ch1 reads.** Dirty-skip collapses the ~16384-sector walk to the
  1–2 dirty 64 KB blocks Neon Horizon writes. This directly removes the
  documented seal cause.
- **CPU stays paused during DMA** (`dma_active → msx_pause`), so ch2/ch4 are
  idle — ch2's no-handshake deadline is never threatened.
- **Dirty logic is registers only**, zero M10K, NO combinational coupling to
  `sdram.sv`/`SDRAM_DQ`. Stay well under ~90% M10K (currently ~61% after the
  `systemRAM addr_width=16` reclaim) to avoid the IOB-packing flaky-RAM cliff.
- **Keep new logic off the SDRAM critical path.** clk_sdram margin is ~+0.065 ns
  with a wall of SDC multicycle waivers; put the bitmap on `clk21m`
  (`nvram_backup` domain) and away from `sdram.sv`.
- **Load-after-upload ordering.** `load_sram`/`status[39]` restore MUST run after
  `memory_upload` finishes staging the pristine ROM, else restored bytes are
  clobbered. Gate restore on `~upload_active`.
- **Address alignment.** Verify `flash16x_base` maps to ROM byte 0 so
  `mem_addr>>9 == flush sector index` and `sd_lba` is 1:1 with the sidecar file;
  guard the 32-bit `img_size` truncation edge for large ROMs.
- **Writable mount required.** `image_mounted[0] <= ~img_readonly`; if no writable
  sidecar is mounted, the flush must cleanly no-op (it already does via the guard).

---

## 6. Phased steps

**Phase 0 — Prerequisite verification (no RTL).**
- HW-verify the existing volatile `prog_we` byte-program actually lands correctly
  in SDRAM (currently sim-only, TB 5/5). Do NOT layer persistence on an unproven
  base.
- Confirm whether Neon Horizon issues a JEDEC sector-erase (AA/55/80/AA/55/30)
  before programming. If yes, erase routes through `flash.sv` ch3 and Phase 3 is
  required for full correctness.
- Confirm HPS/MiSTer-Main mounts a **writable** sidecar image at VD0 for the
  ASCII16X (Slot A "Load", H3FS3) path.
- HW smoke test: with current build (BRAM ~61%, `compute_vib` cloud removed),
  re-enable the dead flush with a SINGLE forced dirty block and check 2 MB RAM
  integrity — determines whether the bitmap is strictly necessary or pure
  insurance, and whether the ch1 root cause was traffic vs IOB/timing.

**Phase 1 — MVP (manual save/load, byte-program only).**
- Implement the 64 KB register dirty bitmap (§4.2–§4.4).
- Remove the `1'b0` guard + add dirty-skip in `STATE_FLASH_PREFETCH` (§4.5).
- Sidecar `.sav` target; manual `status[38]/[39]` triggers (already shown).
- Sim verify (extend the existing TB), then HW verify the full
  write→save→power-cycle→load→read-back loop on Neon Horizon.

**Phase 2 — Robustness hardening.**
- Atomicity: confirm/guard partial-flush on the ~6.3 s SD timeout
  (`nvram_backup.sv:225`); consider temp-file/journal commit (HPS-side policy).
- Load-after-upload ordering enforcement and auto-load on mount.

**Phase 3 — Erase capture (only if Phase 0 shows erase is used).**
- Export `flash.sv` erase_block events; set the same coarse dirty bit on
  `erase_block_num`. Persist erased (0xFF) regions too.

**Phase 4 — UX / autosave (optional).**
- Auto-save-on-dirty or save-on-eject hook (new logic); bound CPU-pause duration
  and SD write amplification.

---

## 7. Verification strategy

- **Sim:** extend the existing ASCII16X TB to drive a JEDEC byte-program, assert
  the dirty bit sets, run the flush FSM with a stubbed SD model, confirm only
  dirty sectors are read/written and the bitmap clears. Add a load test that
  overlays saved bytes after a simulated ROM restage.
- **HW (decisive):**
  1. 2 MB RAM integrity test with flush enabled (regression vs the original
     corruption).
  2. Neon Horizon: make progress → OSD "SRAM Save" → power-cycle → reload ROM →
     OSD "SRAM Load" (or auto-load) → confirm progress restored.
  3. Confirm no audio glitch / no excessive CPU freeze during flush (sparse
     saves should be sub-100 ms).
- **Gate rollout** behind the 2 MB integrity + boot-stability check before
  declaring safe.

---

## 8. Open risks

- **ch1 corruption root cause unconfirmed** (sustained-read vs arbitration vs
  IOB/timing). If partly arbitration/timing, even dirty-skip may not fully
  eliminate it. Mitigated by Phase 0 single-block HW smoke test.
- **Volatile base is HW-unverified** (sim 5/5 only). Persisting on an unproven
  write path risks persisting wrong bytes. Phase 0 blocker.
- **HPS dependency:** writable sidecar mount for the ASCII16X load path is
  bespoke and unconfirmed; without it nothing persists regardless of RTL.
- **Erase coverage gap:** if Neon Horizon erases via `flash.sv` ch3 and MVP only
  tracks ch2 `prog_we`, erased regions are missed (Phase 3).
- **Power-loss window:** manual-save-only model loses data between a write and an
  explicit save; no atomic commit in MVP.
- **Off-by-bank addressing:** `mem_addr>>16` must align to `flash16x_base` byte 0;
  misalignment flushes/restores the wrong region.
- **Timing:** any logic on clk_sdram/clk21m risks reopening the ~+0.065 ns
  margin; keep the bitmap registered and off the SDRAM datapath.
- **`img_size` 32-bit truncation** edge for large (>4 GB — non-issue here, but
  verify sizing) save images.
