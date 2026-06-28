# ASCII16X flash CHANGE-LOG persistence design (8 design + 3 review agents, consolidated)
# Worktree: ascii16x-flash. Status: design only, not implemented.

# ASCII16X flash CHANGE-LOG persistence — consolidated implementable design

This resolves the 6 designs + 3 reviews into one buildable plan. Where designs disagreed, the reviews' adversarial findings decide (see §5). Headline resolutions: **linear append journal** (not 4-way set-assoc), **new `flash_changelog.sv` module** (sealed nvram FSM untouched), **ch1-write replay** (not ch2), **header-written-last + CRC** format, **fail-loud** on every fallback/mount gap.

---

## 1. Architecture overview

Data flow:

```
 WRITE-TIME (live, CPU running)            SAVE (status[38], CPU paused)      LOAD (load_sram/[39], CPU paused)
 ┌──────────────┐  prog_we rise           ┌─────────────────────┐            ┌──────────────────────┐
 │ cart_ascii16x│──{addr,val}──► JOURNAL   │ JOURNAL BRAM ──────► │ VD0 .sav   │ VD0 .sav ──► sector  │
 │ prog_we      │   linear append          │  STATE_PROCESS-style │  (BRAM→SD, │  buf ──► ch1 single  │
 │ (ascii16x:95)│   wp++ (1 cyc)           │  stream, ZERO ch1    │  zero ch1) │  WRITES (proven half)│
 └──────┬───────┘                          └─────────────────────┘            │  onto pristine ROM   │
        │ (unchanged) folds to SDRAM ch2 write                                 └──────────────────────┘
        ▼ msx_slots:148-150  ── byte already lands in SDRAM; journal is a passive snoop
```

- **Capture** is a passive snoop on `mapper_ascii16x_prog_we` (`msx_slots.sv:350,360`). It adds **nothing** to `d_to_cpu`, `sdram_ce`, `ram_rnw`, `ram_addr`, `ram_din` (`msx_slots.sv:148-152`) — the written byte already reaches SDRAM via the existing `prog_we` fold. The journal only *reads* that strobe and writes private BRAM, all registered on `clk21m`. This is the key property that keeps it off the fit-fragile SDRAM_DQ path (compute_vib lesson).
- **SAVE** streams the journal BRAM to `<rom>.sav` over VD0 using the proven `STATE_PROCESS` BRAM→SD template (`nvram_backup.sv:180-192`) — **never touches ch1**.
- **LOAD** stages the pristine ROM normally, then replays records as **bounded single ch1 writes** (`STATE_FLASH_SDRAM_WR` idiom, `nvram_backup.sv:254-261`, `sdram_wait=3`) — the proven-safe half of ch1 (only sustained *reads* corrupt). CPU paused throughout.

### BRAM geometry (chosen: linear append journal)

```
(* ramstyle="M10K" *) logic [31:0] jrnl[8192];   // 8192 × 32b
logic [13:0] wp;                                   // write pointer == live entry count
// entry = { type(1), addr(23), value(8) }
//   type=0 BYTE  : addr = mem_addr[22:0], value = data byte
//   type=1 ERASE : addr = {sector_base[22:16],16'b0}, value = 0xFF (informational)
```

8192×32b → width-32 hits the ≤40-bit/256-deep M10K bucket → **8192/256 = 32 M10K**. Verified headroom: 339/553 M10K used (61%), ~214 free (feasibility review, `output_files/MSX1.fit.summary`). Fits with large margin. Tunable down to 4096 (~16 M10K) if desired; overflow is the safety net either way.

Why linear, not the 4-way set-assoc cheat clone (`msx.sv:288-347`): the set-assoc has no write ordering, so it **cannot represent erase** (erase-then-reprogram needs order) and the literal 512×4 clone overflows ~11% at K=256 / ~45% at K=512 scattered writes (overflow design §7 balls-in-bins). Linear gives **deterministic, measured** overflow (P≈0 for Neon Horizon's ~10²–10³ writes), erase = **one** record, and `wp<=0` on reload sidesteps the gen-3-bit-wrap false-hit hazard entirely. Capture is a 1-cycle registered append (single pointer) vs a 3-cycle RMW — less new RTL to get wrong.

---

## 2. Exact RTL plan

New file **`rtl/peripheral/flash_changelog.sv`** (capture + SAVE FSM + LOAD/replay FSM + overflow/erase flags), instantiated in `MSX1.sv` beside `flash_dump_test` (`MSX1.sv:941`). The sealed `nvram_backup` flash FSM (`nvram_backup.sv:150` `if(1'b0…)`) stays sealed; nvram SRAM path and cheat engine untouched.

### 2a. Bubble capture signals up (msx_slots → msx → MSX1)

`rtl/peripheral/slots/msx_slots.sv` — add outputs, drive from existing internal nets:
```
output        flash16x_prog_we;    assign = mapper_ascii16x_prog_we;   // :350,360
output [22:0] flash16x_prog_addr;  assign = mapper_ascii16x_addr[22:0]; // :357 (= mem_addr, ascii16x:54)
output  [7:0] flash16x_prog_data;  assign = cpu_dout;                   // :152 (= ram_din)
output        flash16x_erase;      // phase-2; tie 1'b0 until ascii16x erase-detect exists
output [22:0] flash16x_erase_addr; // phase-2; tie 0
```
`rtl/msx.sv` — re-export the same names (header near `:87-89`, connect on msx_slots instance near `:657-659`).
`MSX1.sv` — declare wires, connect on msx instance (near `:496-498`), feed `flash_changelog`.

### 2b. Capture FSM (in flash_changelog, clk21m)

```systemverilog
logic pw_q;  wire pw_rise = flash16x_prog_we & ~pw_q;   // count ONE per byte-program
logic erase_q; wire erase_rise = flash16x_erase & ~erase_q;
wire  in_bounds = flash16x_prog_addr < (flash16x_size<<14);   // region bound (24b safety)

always @(posedge clk21m) begin
  pw_q <= flash16x_prog_we;  erase_q <= flash16x_erase;
  if (log_clear) begin wp <= 0; overflow <= 1'b0; end          // see §2e for trigger
  else if (~overflow & flash16x_active) begin
    if (erase_rise)                overflow <= 1'b1;            // erase: until phase-2, force fulldump
    else if (pw_rise & ~in_bounds) overflow <= 1'b1;           // out-of-region (>8MB alias guard)
    else if (pw_rise) begin
      if (wp == 14'd8191)          overflow <= 1'b1;            // journal full -> fulldump
      else begin jrnl[wp] <= {1'b0, flash16x_prog_addr, flash16x_prog_data}; wp <= wp+1'b1; end
    end
  end
end
```
`pw_rise` (edge of the held `prog_we`, `ascii16x.sv:95`) fires once per program; JEDEC unlock writes put consecutive programs dozens of clk21m apart, so a 1-cycle append always completes (no stall needed). Dedup is intentionally dropped: byte-program workloads are naturally near-distinct, and ordering matters more than compaction once erase exists. (Optional compaction by address can be added later but is not needed for the real footprint.)

### 2c. SAVE FSM (BRAM→VD0, zero ch1)

Reuse the `STATE_PROCESS` block-write handshake (`nvram_backup.sv:180-192`, `flash_dump_test.sv:117-132`). `wp` is already the count, so no pre-pass. **Two-pass header** (atomicity, §3): stream payload to sectors 1..N first, then write the header sector 0 LAST with final count+CRC.
```
S_IDLE  : on save_req rising & flash16x_active & sav_writable & (wp!=0 | overflow):
             save_mode <= overflow ? FULLDUMP : CHANGELOG; lba<=1; go S_PAYLOAD
          else if (wp==0 & ~overflow): refuse (do NOT clear/overwrite prior .sav)  // C2
S_PAYLOAD: CHANGELOG: walk jrnl[0..wp-1], 128 entries/512B block, feed CRC32, sd_wr each block
           FULLDUMP : hand to flash_dump_test path (ch1 read), CRC over image
S_HEADER : assemble sector 0 {magic,ver,mode,flags,count=wp,image_bytes,rom_id,payload_crc32};
           sd_lba=0; sd_wr=1 (WRITTEN LAST)
S_DONE   : changelog_active drops
```
`sd_buff_din[0]` byte-slice driven by registering the 32-bit word per `sd_buff_addr[8:2]` (no async cloud, mirrors `nvram_backup.sv:118`).

### 2d. LOAD / replay FSM (SD→ch1 single writes)

```
R_IDLE      : on start_restore (§2e) -> sd_lba=0; sd_rd=1; go R_HDR
R_HDR       : capture sector 0 into hdr_buf
R_CLASSIFY  : (see §3 disambiguation) -> R_REPLAY (changelog) | R_IMAGE (fulldump/legacy) | R_DONE (ignore)
R_REPLAY    : for each record in order:
                type=0 BYTE : ch1 WRITE val @ flash16x_base + addr   (STATE_FLASH_SDRAM_WR, wait=3)
                type=1 ERASE: bounded 64KB 0xFF fill @ block base (ch1 writes, 16384 iters)
                bounds-gate addr < flash16x_size<<14 (skip if out of range)
                ** re-append each replayed record into jrnl so journal is authoritative ** (C2)
R_IMAGE     : SD->sector_buf->ch1 write loop (nvram_backup.sv:244-283 shape), ROM-relative
R_DONE      : restore_busy drops -> CPU resumes on restored image
```
Replay is **ch1 writes only** (bounded ≤8192 + erase fills), never sustained reads — categorically not the corrupting pattern. Reuse the existing ch1 write mux; do **not** add a ch2 mux (load-restore §0 rejected, §5).

### 2e. MSX1.sv wiring

- **Instance** `flash_changelog` next to `flash_dump_test` (`MSX1.sv:941`), on `clk21m`.
- **VD0 mux** — extend the 2-way (`MSX1.sv:893-904`) to put `changelog_active` highest (nvram is idle on VD0 for ASCII16X carts: they have no SRAM, `lookup_SRAM[0].size==0` → nvram `STATE_SLEEP` no-ops, `nvram_backup.sv:163`):
  ```
  sd_lba[0]/sd_rd[0]/sd_wr[0]/sd_buff_din[0] = changelog_active ? cl_* : dump_active ? dump_* : nv_*
  ```
- **ch1 mux** — extend (`MSX1.sv:825-828`) with `cl_replay_active` as a writer (after upload, reuse the proven `dump_active` priority idiom).
- **Pause** — `msx_pause = nvbak_dma_active | dump_active | cl_replay_active | …` (`MSX1.sv:449`). Replay/load pauses CPU; SAVE may also pause for absolute safety (no functional need — BRAM→SD only).
- **Triggers** — SAVE `status[38]`, LOAD `status[39] | load_sram` (already wired, `MSX1.sv:911`). `load_sram` pulses when staging completes (`memory_upload.sv:172`).
- **log_clear / start_restore** — derive ONE explicit "Slot-A ASCII16X ROM (re)staged" pulse (M2). Sequence is mandatory: **clear → restore-from-.sav → re-append**. Do not let the shared `load_sram` both clear and restore without this defined order. Gate start: `~upload_active & flash16x_active & image_mounted[0] & (image_size[0]>0) & sav_writable`.
- **Overflow fallback** — OR `cl_full_dump_req` into `flash_dump_test` trigger (`MSX1.sv:945`); reuse it as the 8MB fallback (do not unseal nvram).
- **OSD/CONF_STR** — none. opensave VD0 + status[38]/[39] + menumask[6] already present (`MSX1.sv:315,911`).

---

## 3. `.sav` on-disk format (one format, hybrid mode, legacy compat, atomic)

512-B sector granular, LE. **Header in sector 0, written LAST** (two-pass commit — defeats grow-only torn writes, H1).

**Header — sector 0**
| off | sz | field | notes |
|----|----|----|----|
| 0 | 8 | magic `"MFX16XSV"` | primary discriminator |
| 8 | 2 | format_version `0x0001` | accept equal major; unknown minor ignored |
| 10 | 1 | mode | 0=changelog, 1=fulldump |
| 11 | 1 | flags | bit0 erase_occurred, bit1 overflow |
| 12 | 4 | entry_count | changelog: #records; fulldump: image sectors |
| 16 | 4 | image_bytes | `flash16x_size<<14`; load-time sanity vs current cart |
| 20 | 4 | rom_id | size + cheap CRC/hash of staged ROM (M4 wrong-ROM guard) |
| 24 | 4 | payload_crc32 | CRC32 over all payload bytes streamed (torn-write detect, M5) |
| 28 | 484 | reserved=0 | |

**CHANGELOG body — sectors 1..N**: 128 records/512B, 4 bytes each: `addr[7:0], addr[15:8], {type, addr[22:16]}, value` (type in bit7 of byte2). Standardize 24-bit ROM-relative addr; bound-checked (L1).
**FULLDUMP body — sectors 1..N**: raw ROM image from `flash16x_base`, the proven `flash_dump_test` stream.

**LOAD disambiguation (normative classifier, resolves M3/M4):**
```
if magic == "MFX16XSV" && version major OK && rom_id matches && payload_crc32 verifies:
     mode==0 -> replay records ; mode==1 -> stream image
else if no magic && img_size == image_bytes(flash16x_size<<14):
     LEGACY raw 8MB dump (headerless flash_dump_test output) -> stream image
else: IGNORE -> boot pristine ROM (no silent misapply)
```
This is the only design (format-robustness) that handles the **legacy headerless raw `.sav`** that `flash_dump_test` already writes to the same VD0 file (`MSX1.sv:941`). The overflow fulldump now writes the **same magic'd header**, so both engines share one self-describing format.

**Atomicity / power-loss:** header-last + CRC means a crash mid-payload leaves sector 0 stale-or-absent → magic/CRC/count fails → IGNORE → pristine. Every corruption path (torn write, bad magic, wrong rom_id, unknown major, short file) lands on **boot pristine**. The only ways to *apply* data are a fully-committed header with matching CRC, or an exact-size legacy raw image.

---

## 4. Overflow + erase fail-safe (NON-NEGOTIABLE: no silent loss)

| event | detection | action |
|---|---|---|
| journal full (wp==8191) | counter compare (§2b) | sticky `overflow` → SAVE mode=fulldump |
| out-of-region addr (>8MB / aliasing) | `addr ≥ flash16x_size<<14` | sticky `overflow` |
| JEDEC sector-erase 0x30 | erase-detect in ascii16x (phase-2); until then `flash16x_erase` tied 0 | `overflow` → fulldump (phase-2: journal as type=1 record + ordered replay) |
| chip-erase 0x10 | erase-detect | `overflow` → fulldump |
| empty journal SAVE (wp==0 & ~overflow) | SAVE guard | **refuse** — never overwrite a good prior .sav with count=0 (C2) |
| .sav not writable (autoload) | `~(image_mounted[0] & ~img_readonly)` | **fail loud** — do NOT silently `done`; surface to user (C1/F) |
| SD ARM never acks | ~6.3s timeout | abort, leave file partial → bad-CRC-safe on load |
| partial/garbage .sav | magic/CRC/rom_id mismatch | IGNORE → pristine |

**Critical caveat on the fulldump fallback (H4 / feasibility-E):** the 8MB ch1→VD0 dump (`flash_dump_test.sv`) is the historical *corrupting* path (sealed at `nvram_backup.sv:150`; sustained ch1 reads corrupt the controller). It is **not yet proven safe at this fit** — that is exactly what `flash_dump_test` exists to determine. Therefore:
1. Size the journal so overflow is **unreachable** for the real footprint (8192 entries, ≥8× margin over Neon Horizon's ~10²–10³ writes → P(overflow)≈0). The fallback essentially never fires.
2. The fulldump branch is gated behind re-verification of `flash_dump_test` at the shipping fit. **Until verified, overflow/erase must fail LOUD** (do not mark `done`/`store_new_size`, keep prior `.sav` intact) rather than write garbage. "No new save" still honors no-silent-loss; silent garbage does not.

---

## 5. Reviewer disagreements — resolved

| # | Disagreement | Resolution | Rationale |
|---|---|---|---|
| D1 | Structure: 4-way set-assoc dedup (bram-structure, write-capture, save-path, integration, format-robustness) vs **linear append** (overflow, erase-handling) | **Linear append** | Set-assoc has no write order → cannot represent erase (H3); 512×4 clone overflows 11–45% on scattered writes (overflow §7); linear = deterministic overflow, erase=1 record, simpler 1-cycle append, no gen-wrap. Feasibility + idiomatic reviews both concur. |
| D2 | Replay channel: ch2 paused mux (load-restore, save-path) vs **ch1 single writes** (integration) | **ch1 writes** | ch2 perturbs the live CPU memory channel (`MSX1.sv:831-836`), the most DQ-fragile datapath; ch1-write mux already exists and is proven via `dump_active`. Writes are the proven-safe half (only reads corrupt). Idiomatic review rejects ch2 outright. |
| D3 | Module: extend nvram_backup (overflow, save-path, format-robustness) vs **new module** (integration, load-restore) | **New `flash_changelog.sv`** | Keeps proven SRAM path + sealed flash FSM untouched; capture port-pair running every CPU write is foreign to nvram. |
| D4 | Invalidation: gen-3bit (write-capture, integration) vs valid-bit sweep (bram-structure) | **Neither — `wp<=0`** | Linear journal needs no invalidation table; gen wraps after 7 reloads → false-live slot corrupts .sav (M1); valid-sweep reintroduces the race the gen trick avoided (idiomatic §6). |
| D5 | Format: header-first+count, no checksum (5 designs) vs **header-last+CRC+trailer** (format-robustness) | **Header-last + CRC, in header (not trailer)** | Trailer-at-EOF located via `img_size/512-1` breaks on grow-only files (H1). Put count+CRC+rom_id in header, write header LAST → self-detecting torn writes without trusting `img_size`. |
| D6 | Erase: ignore until implemented (most) vs **detect-and-flag now** (erase-handling) | **Detect-and-flag (phase-2 detect → overflow→fulldump); ordered-record replay later** | "Erase undetected" already violates no-silent-loss for real in-place re-saves (H2): NOR can only clear bits, so re-save *must* erase first. Until detect exists, scope is a hard precondition (byte-program-only carts, verified by capture). |
| D7 | Overflow fallback engine: unseal nvram `STATE_FLASH_*` vs **reuse `flash_dump_test`** | **Reuse flash_dump_test** | Already instantiated/muxed/HW-exercised (`MSX1.sv:941`); don't perturb sealed dead code. |
| D8 | Addr width 23/24/25 | **24-bit stored + region bound-check** | `mem_addr` is 25b (`ascii16x.sv:52`), truncated to 23 (`:56`, ≤8MB). 23b aliases on >8MB; store 24, assert `addr<flash16x_size<<14`→overflow (L1, load-restore §5). |

Two cross-cutting blockers all designs missed (now folded in): **C1/F** the `.sav` is writable only on a *fresh manual Slot A→Load* (`user_io.cpp` opensave `cangrow=pre!=0`), so SAVE silently no-ops on autoload → must fail loud + document the manual-load precondition; **C2** empty/short-journal SAVE clobbers a good prior save on the grow-only file → refuse `wp==0 & ~overflow` SAVE, and re-append replayed records on LOAD so the journal stays authoritative.

---

## 6. Effort vs proven full-dump, and incremental build/sim/HW plan

**Effort comparison.** The full 8MB dump (`flash_dump_test`) is *already written and HW-exercised*, so it is "less code." But its core mechanism (sustained ch1 read) is the unresolved corruption source — it **cannot ship as the primary path** with confidence, and yields an 8MB `.sav`. The change-log is more new RTL (~1 module: capture + 2 FSMs + format) but **structurally avoids** the failure (capture = zero SDRAM touch; replay = bounded writes = proven half), yields a few-KB `.sav`, and captures arbitrary addresses. Net: change-log is the only path that ships cleanly if ch1 reads remain broken; full-dump is retained solely as the rare overflow fallback (and only once re-verified). Resource/insert-timing are non-issues (214 M10K free; 6× clock headroom over the 3.58MHz CPU write rate).

**Recommended incremental plan:**
1. **Resolve `flash_dump_test` FIRST** — does ch1 sustained read still corrupt at this fit? Decides whether the fulldump fallback can ever write, or must fail-loud. (Gates the whole fail-safe story.)
2. **Capture only** — add bubbled ports + journal append FSM; TB: drive synthetic `prog_we` bursts, assert `jrnl`/`wp` contents and overflow latch. No SAVE/LOAD yet.
3. **SAVE (BRAM→VD0)** — clone `STATE_PROCESS` streamer; TB: golden-compare emitted `.sav` bytes (header-last, CRC, record packing) against a Python model. Verify two-pass header + empty-journal refuse + not-writable fail-loud.
4. **LOAD/replay (SD→ch1 writes)** — TB with a ROM hex + `.sav`: classify (changelog/fulldump/legacy/garbage), replay onto staged SDRAM, assert final image; verify bounds-skip, rom_id mismatch→ignore, re-append.
5. **Integrate muxes + pause** in MSX1.sv; **post-route timing check** of the added ch1-write mux term against the ~0.3ns DQ slack (do not assume).
6. **HW**: byte-program-only cart (Neon Horizon 16X), full round-trip in-game save → power-off → manual Slot-A reload → verify replay. Confirm `.sav` grows from 0.
7. **Phase-2**: add JEDEC erase-chain detect in `ascii16x.sv` (`AA/55/80/AA/55/30` tail, erase-handling §3) → type=1 records + ordered 0xFF-fill replay; lift the byte-program-only precondition.

---

## 7. Open risks / unknowns

- **R1 (HIGH):** fulldump fallback unproven — ch1 sustained read may still corrupt at this fit. Gates whether overflow/erase can write at all; until cleared, those corners must fail loud. (`flash_dump_test.sv:1-10`, `nvram_backup.sv:150`.)
- **R2 (MED-HIGH):** `.sav` writable only on manual Slot-A→Load — the natural autoload round-trip silently won't persist. Needs explicit fail-loud + user-facing documentation; no RTL fix makes autoload growable (it's an HPS opensave property, `user_io.cpp` `cangrow=pre!=0`).
- **R3 (MED):** added ch1-write mux term erodes the fragile ~0.3ns SDRAM_DQ slack — must be confirmed in post-route, not assumed.
- **R4 (MED):** erase is undetected today → no-silent-loss is only truly honored for byte-program-only carts until phase-2 ships. Whether Neon Horizon's save routine issues `0x30` is unconfirmed (this session's HW probe only exercised byte-program). If it does and we ship phase-1, in-place re-saves corrupt — hence the hard precondition.
- **R5 (LOW):** back-to-back same-address writes inside the (now 1-cycle) append are not a concern with linear; the JEDEC unlock cadence keeps programs dozens of clk21m apart. Stall-while-busy is unnecessary but cheap insurance.
- **R6 (LOW):** `log_clear` vs `start_restore` ordering on the shared `load_sram` pulse must be sequenced (clear→restore→re-append); a missed clear replays a previous game's journal → cross-game corruption (M2).

**Files to create/edit:** new `rtl/peripheral/flash_changelog.sv`; edit `rtl/peripheral/slots/msx_slots.sv` (export capture nets ~`:350,357,152`; phase-2 erase-detect in `rtl/peripheral/slots/ascii16x.sv:59-95`), `rtl/msx.sv` (pass-through ~`:87-89,657-659`), `MSX1.sv` (instance ~`:941`, VD0 mux `:893-904`, ch1 mux `:825-828`, pause `:449`, fulldump trigger OR `:945`, capture wire connect ~`:496-498`). No CONF_STR/OSD change (`MSX1.sv:315,911`).