# MSX1_MiSTer Cheat Work — Master TODO + Risk Register + Verification Plan

Consolidated handoff for the next session. Sources: `/tmp/cheat_handoff_snapshot.txt`,
memory `project_cheat_engine.md`, memory `project_msx1_rom_load_menus.md`.

## Context Snapshot (state at handoff)

- **Two cheat systems exist:**
  1. **Custom engine (MERGED, working on hardware):** register/BRAM 4-way set-assoc lookup,
     `d_to_cpu` mux injection, loader at ioctl index **9** (`F6,CHT,Load Cheats`) +
     master `O[51]` (`Cheats,Off,On`). Verified on real MFRSD boot. This is on `moonsound`
     @ `102c6c1` (main repo). M10K 335/553 (61%).
  2. **Standard MiSTer cheat (UNMERGED, in worktree `cheat-standard` @ `102c6c1`):** uses
     `C,Cheats;` CONF_STR token + ioctl index **255** + 16-byte `.gg` records from HPS,
     so the **HPS draws the OSD Cheats menu natively** (descriptions + per-cheat on/off).
     This is what the user actually wants visually (like the NES core screenshot).
- **The blocker for the standard path** was diagnosed across the team:
  - `C,Cheats;` token (with the label) sets `use_cheats=1` (user_io.cpp:907). Required.
  - **Root cause the menu was grayed/absent (per cheat-engine memory):** the `FC1` load
    option's `C` = `store_name` flag → `cheats_init` never called → entries gray.
  - **CORRECTION from `project_msx1_rom_load_menus.md` (user, 20260626):** `FC1`/`FC2` =
    machine/firmware load (`Load ROM PACK`/`Load FW PACK`), **NOT games, DO NOT TOUCH.**
    The earlier "change FC1→F1" plan was declared a **misjudgment** — it breaks machine
    ROM autoload. Games load via **Slot A `H3FS3,ROM,Load` (store_name=0)** and that is the
    path where standard `cheats_init` fires. So T1 must test the Slot A game-load path, not FC1.
- **Deployed RBFs on the board (newest last):** `MSX1_20260626b_cheatF1s2.rbf` is the most
  recent, but the `F1` builds reportedly broke boot-fit (CONF_STR 1-byte shift → SDRAM_DQ IOB
  roulette). Boot+menu status of each RBF is UNCONFIRMED — that is exactly T0.

---

## 1. TODO (ordered by dependency)

### T0 — Identify the actually-booting RBF that contains `C,Cheats`
- **Task:** Of the deployed RBFs (`MSX1_20260624_cheatSA`, `_20260625_cheatStd`,
  `_20260625b_cheatStd`, `_20260626_cheatStd3`, `_20260626a_revtest`,
  `_20260626b_cheatF1s2`), determine which one BOTH (a) boots MFRSD cleanly AND (b) has the
  standard `C,Cheats;` token. Record md5 of that RBF and map it back to its source
  commit/worktree state.
- **Why:** Every later test (T1) is meaningless on a non-booting or wrong-CONF_STR core.
  The `F1`/`cheatStd3`/`cheatF1s2` builds may be the boot-broken roulette variants.
- **How:** On board, for each candidate: power up, confirm MFRSD boots to menu. For
  CONF_STR, `strings <rbf> | grep -i cheats` won't work (RBF is compressed) — instead match
  md5 back to the build that produced it; grep the corresponding worktree `MSX1.sv` for the
  token. `cheat-standard` worktree has `"C,Cheats;"` (line 254 per snapshot); main has
  `F6,CHT`+`O[51]` (custom). Cross-check md5 with build logs/naming.
- **Done-criteria:** One named RBF identified that boots AND is confirmed (via its source) to
  carry `C,Cheats;`. If none qualifies → a clean rebuild from `cheat-standard` worktree
  (with a Quartus SEED change to dodge the fit roulette, see RISK R1) is the prerequisite,
  and T1 waits on it.

### T1 — (#1 PRIORITY) On a booting `C,Cheats` build, load twinbee in Slot A and capture serial
- **Task:** On the T0-confirmed RBF, use **Slot A `Load` (H3FS3, store_name=0)** — NOT
  "Load ROM PACK" — to load `twinbee`. Capture HPS serial with line-buffering and observe
  the OSD Cheats menu state.
- **Why:** This is the single decisive experiment. The standard path's `cheats_init` only
  fires on a store_name=0 game load; we need to see whether it runs and what it reports.
- **How:**
  - Serial: USB **Mini-B** built-in port = FT232R `0403:6001` → `/dev/ttyUSB0` (the
    micro-USB `09fb` is JTAG, not serial). Run:
    `stdbuf -oL -eL cat /dev/ttyUSB0 | tee /tmp/handoff/t1_twinbee.log` (or
    `stdbuf -oL screen /dev/ttyUSB0 115200`).
  - Place the cheat zip at `cheats/MSX1/<romname>.zip` (filename exact-match OR 8-hex CRC),
    STORED compression, 16-byte `.gg` records. CoreName2 = first CONF_STR token = `MSX1`.
  - After Slot A load, open OSD and look for the **Cheats** menu entry; note **grayed vs
    absent vs present-and-toggleable**.
- **Done-criteria:** Captured: (a) the serial log around load, grepped for the strings in the
  Verification Plan; (b) a clear OSD observation (gray / absent / present). NOTE per memory:
  MiSTer 260611 **suppresses console printf while a core is running (incl. ROM load)**, so
  the serial line may be silent even on success — the **OSD screen observation is the
  authoritative signal**; JTAG (R6) is the fallback if serial is mute.

### T2 — Branch the fix on the T1 result
- **Task:** Decide and act based on T1's three possible outcomes.
- **Why:** Each outcome points at a different layer; do not fix blindly.
- **How / branches:**
  - **Outcome A — log says "no cheat file found" / cheats:0:** zip/CRC/path problem. Fix
    filename exact-match or CRC8 hex; confirm STORED (not Deflate); confirm `cheats/MSX1/`
    dir and CoreName2=`MSX1`. Re-run T1.
  - **Outcome B — `cheats:N>0` but OSD menu absent/gray:** menu-render / `use_cheats`
    issue. Re-verify `C,Cheats;` token has the label and is reached; check `store_name`
    on the Slot A path is 0; compare against the NES core's working CONF_STR ordering.
  - **Outcome C — no `cheats_init` printf at all:** either printf-suppression (expected; use
    OSD/JTAG) OR `use_cheats=0` / `store_name=1` on the load path. Confirm the game was
    loaded via Slot A (store_name=0), NOT FC1/FC2.
- **Done-criteria:** Root cause for THIS build named with evidence, and the corresponding
  one-layer fix applied + re-tested through T1.

### T3 — Resolve the `.gg` record layout decision (APPLICATION-layer only)
- **Task:** Choose the loader's byte mapping and lock it in: either keep the current
  **self-consistent `{addr,0,value,0}`** interpretation, or switch to the **NES-standard
  `{flags,addr,compare,replace}`** 16-byte layout with loader offsets **addr @ bytes 4–5**
  and **value(replace) @ byte 12** (vs the current addr@0,1 / replace@8 per memory).
- **Why:** This affects whether a freeze actually writes the right value at the right
  address. It does **NOT** affect whether the menu renders (that is T1/T2). Get the menu
  working first, then make the data correct.
- **How:** Diff the HPS `cheats.cpp` 16-byte concat order against the worktree loader
  (`msx.sv` ioctl-255 case, `ioctl_addr[3:0]` switch ~line 337 per snapshot). Pick the
  layout that matches what HPS actually emits; document it in code comments + memory.
- **Done-criteria:** Loader byte offsets match the HPS wire format; a known cheat
  (e.g. twinbee lives) freezes the correct address/value in-game.

### T4 — Fallback if standard OSD proves infeasible without HPS changes
- **Task:** If the standard path cannot render the menu without modifying HPS firmware
  (out of scope), fall back to the **already-working merged custom `.CHT` engine** + the
  **web editor** (`tools/msx1_cheat_editor.html` / `mcf2mister.py`) and document the decision.
- **Why:** Preserve a shipping, hardware-verified cheat capability rather than block on the
  cosmetic OSD.
- **How:** Confirm the merged custom engine (index 9, `O[51]`) still works on the current
  `moonsound` build; document the web-editor workflow (`.mcf` → per-cheat toggle → `.cht`,
  4-way collision warning, ~2048 capacity) as the supported UX.
- **Done-criteria:** A written decision (in memory + repo doc) on standard-vs-custom, and the
  chosen path confirmed working on hardware.

### T5 — (HELD, pre-existing) ROM-change cheat reset for the custom engine
- **Task:** Bump `cur_gen` (invalidate the cheat table) on ROM load (ioctl idx 1/2) and/or
  reset, not only on `.cht` download (idx 9). From `project_cheat_engine.md` Q1 TODO.
- **Why:** Today, loading game B after enabling game A's cheats leaves stale cheats applied
  (and `O[51]` stays ON). Wrong-game freezes are a real hazard.
- **How:** Detect ROM download (ioctl index 1/2) in `clk21m` domain → bump `cur_gen` to
  invalidate the 4-way table. Small RTL change in `msx.sv`. (User decision 20260624: held,
  list-only — do not implement until prioritized.)
- **Done-criteria:** Loading a new ROM clears prior cheats; verified in Verilator + on
  hardware (game A cheat does not apply after loading game B).

### H — Housekeeping
- **H1 — Memory corrections (per audit):** Update `project_cheat_engine.md` to record that
  the **"FC1→F1" fix was retracted** (FC1/FC2 = machine/FW, must not touch per
  `project_msx1_rom_load_menus.md`); the standard-cheats path is **Slot A game load
  (store_name=0)**, not FC1. The memory currently still presents F1 as "the answer" —
  flag/annotate it as superseded.
  - **Done:** memory reflects the Slot A path and the FC1 retraction explicitly.
- **H2 — Worktree cleanup decision:** Decide the fate of the **unmerged `cheat-standard`
  worktree** (`.claude/worktrees/cheat-standard` @ `102c6c1`): merge to `moonsound`,
  keep parked, or delete. Tied to T1/T4 outcome — do not delete until the standard path is
  proven or abandoned.
  - **Done:** explicit keep/merge/delete decision recorded.
- **H3 — Build/deploy naming:** RBF names are ambiguous (`cheatSA`, `cheatStd`, `cheatStd3`,
  `revtest`, `cheatF1s2`). Establish a naming convention that encodes
  source-commit + token-variant + boot-status, and maintain an md5→commit map so T0 never
  has to be repeated.
  - **Done:** an md5→commit→token table exists in the repo/handoff; future builds follow the
    convention.

---

## 2. RISK REGISTER

| ID | Risk | Why it bites | Mitigation |
|----|------|--------------|------------|
| **R1** | **Fit fragility — CONF_STR 1-byte shift breaks boot.** Adding/altering a CONF_STR token (e.g. `F1` vs `FC1`, adding `C,Cheats;`) shifts placement and perturbs **SDRAM_DQ IOB packing** (BRAM/fit is tight) → core boots to garbage / 2MB RAM flaky. The `cheatStd3`/`F1` builds reportedly hit this. | A "good" RTL change can still produce a non-booting RBF purely from fit roulette. | Rebuild with a **changed Quartus SEED** and re-verify boot every time CONF_STR changes; keep the last known-good seed/RBF. Treat every CONF_STR edit as boot-risky, not cosmetic. |
| **R2** | **`FC1`/`FC2` must NOT be touched.** They are machine/FW load (`Load ROM PACK`/`Load FW PACK`), store_name=1. Editing them (the retracted F1 plan) breaks machine-ROM autoload → "manual machine ROM load" / boot failure. | Easy to "fix cheats" by editing the wrong option; cost days (already did). | Cheats work happens ONLY on the **Slot A `H3FS3,ROM,Load`** path. Leave FC1/FC2 alone. Encode in memory (H1). |
| **R3** | **Two-source confusion (main `moonsound` vs `cheat-standard` worktree).** Main has custom engine (idx 9, `O[51]`, `F6,CHT`); worktree has standard (`C,Cheats;`, idx 255, FC1/H3FS3 lines). Editing/building the wrong tree wastes a build cycle. | Both are @ `102c6c1`; identical hash, different working trees. | Always confirm `pwd` and `git -C <path> diff`/grep the cheat token before building. Use the H3 md5→source map. |
| **R4** | **Uninitialized `cheat_ram` false-positive.** BRAM way-RAM power-on contents could spuriously match an address (hit) before any `.cht`/255 load. | Phantom freeze on a value the user never set. | Rely on `gen`/`cur_gen` invalidation (bumped on load); confirm power-on `gen` mismatches so no stale slot hits. Verify a fresh-boot, no-cheat-loaded run applies nothing. |
| **R5** | **MFRSD boot regression on ANY rebuild.** The core is fit-tight; any rebuild (even unrelated) can regress MFRSD boot via R1-style packing churn. | A cheat change could silently break the user's primary boot path. | Every candidate RBF must pass an MFRSD cold-boot smoke test BEFORE cheat testing (part of T0/Verification). Keep last-known-good RBF for rollback. |
| **R6** | **Console-printf suppression blocks serial diagnosis.** MiSTer 260611 suppresses console printf while a core runs (incl. ROM load); `cheats_init`/`cheats_available` prints may never reach `/dev/ttyUSB0`. (NES behaves the same.) | T1 serial log can be silent on BOTH success and failure → false "no init" conclusion. | Treat OSD screen state (gray/absent/present) as the authoritative signal. Use **JTAG (micro-USB `09fb`)** for live HPS introspection if serial is mute. Do not conclude "cheats_init not called" from serial silence alone. |

---

## 3. VERIFICATION PLAN

### Success definition per path
- **Standard OSD path (T1–T3):** After Slot A load of a game with a matching cheat zip, the
  OSD shows a **`Cheats` menu like the NES screenshot** — entries present and **NOT grayed**,
  each with a description and an on/off toggle. Toggling a cheat **freezes a value in twinbee**
  (the targeted address reads the frozen value in-game; visible effect such as locked
  lives/score).
- **Custom fallback path (T4):** `.cht` loaded via `F6,CHT` / `O[51]` ON freezes the known
  address (regression: `NeonHorizon_fuel.cht = 78 DC 80 01` → `0xDC78`→`0x80` still works).
- **Always (every RBF, R5):** **MFRSD still cold-boots** to its menu.
- **Always (resource, R1):** **M10K unchanged** at the expected count (custom build = 335/553
  ≈ 61%; the merged engine added 0 M10K over baseline). Check the Quartus fit report.

### Serial-log strings to grep (T1, from HPS stdout if not suppressed)
Grep the captured `/tmp/handoff/t1_twinbee.log` for (case-insensitive):
- `cheats_init` — proves the init path ran.
- `cheats_available` / `cheats:` followed by a count — `>0` means HPS parsed records.
- `use_cheats` — should be `1` if `C,Cheats;` token took effect.
- `no cheat` / `not found` / `cheat file` — indicates zip/CRC/path failure (T2 Outcome A).
- `store_name` — confirm the load path is store_name=0 (Slot A), not 1 (FC1).
- `CRC` / the romname — confirm the cheat zip filename/CRC matched.

Suggested capture command:
`stdbuf -oL -eL cat /dev/ttyUSB0 | tee /tmp/handoff/t1_twinbee.log`
(FT232R `0403:6001` = Mini-B port = `/dev/ttyUSB0`).

### JTAG option (R6 fallback when serial is mute)
- The **micro-USB** port (`09fb...`, Blaster) is JTAG. Use it for live HPS/core introspection
  when console printf is suppressed and the OSD observation is ambiguous. This is the
  authoritative fallback to distinguish "cheats_init not called" from "printf suppressed."

### Per-task acceptance checklist
- [ ] **T0:** named RBF boots MFRSD AND its source carries `C,Cheats;` (md5 recorded).
- [ ] **T1:** twinbee loaded via Slot A; serial log captured; OSD state (gray/absent/present)
      recorded; outcome classified A/B/C.
- [ ] **T2:** single-layer root cause named with evidence; fix applied; T1 re-passes.
- [ ] **T3:** loader byte offsets match HPS wire format; a real freeze hits the right
      addr/value in twinbee.
- [ ] **T4 (if taken):** standard-vs-custom decision documented; chosen path HW-verified.
- [ ] **T5 (if taken):** new-ROM load clears prior cheats (Verilator + HW).
- [ ] **R5/R1 gates (every build):** MFRSD cold-boot OK; M10K count unchanged in fit report.
