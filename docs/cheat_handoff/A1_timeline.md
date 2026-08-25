# A1 — Chronological Timeline: MSX1_MiSTer Cheat Engine Saga

> **Purpose:** Resume-without-re-deriving handoff. This file records FACTS only — no judgments or decisions. Sources: `/tmp/cheat_handoff_snapshot.txt`, `project_cheat_engine.md`, `project_msx1_rom_load_menus.md`, `project_msx_vs_msx1_cores.md`.
>
> **Repo:** `/home/muhanpong/Documents/github/MSX1_MiSTer` (core CONF_STR first token = `MSX1`; cheats dir = `cheats/MSX1/`). We work on the **MSX1** core (Molekula-based, VG-8010), NOT the separate official **MSX** core.

---

## 0. Two-Source Confusion (READ FIRST — prevents re-deriving wrong context)

There are **two distinct cheat implementations** living in two different git locations. They use different mechanisms, tokens, and ioctl indices. Conflating them caused much of the wasted effort.

| | **MAIN REPO** (branch `moonsound`) | **WORKTREE** `cheat-standard` |
|---|---|---|
| Path | `/home/muhanpong/Documents/github/MSX1_MiSTer` | `.../.claude/worktrees/cheat-standard` |
| Mechanism | CUSTOM `.CHT` freeze/POKE engine | STANDARD MiSTer OSD cheats (`.gg`/zip) |
| CONF_STR tokens | `F6,CHT,Load Cheats;` + `O[51],Cheats,Off,On;` | `C,Cheats;` (label required) |
| ioctl index | 6 (was 9 in register version) | 255 |
| `use_cheats` (user_io.cpp:907) | **0** (no `C,Cheats` token present) | **1** (`C,Cheats;` present) |
| Status | **MERGED, WORKS ON HARDWARE** (102c6c1) | UNMERGED, cheat menu did NOT appear |

Snapshot `git log`: HEAD = `102c6c1`, worktree `cheat-standard` also checked out at `102c6c1`.

---

## 1. CONFIRMED — Custom `.CHT` Engine (MAIN REPO, working)

### [T1] 2026-06-21 — Register-based freeze/POKE engine (commit `c5dea71`)
- Action-Replay style memory freeze/POKE. Designed via 4-agent plan review.
- **Injection point:** `rtl/msx.sv` `d_to_cpu` priority mux (~line 276), added `cheat_act ? cheat_value :` above IO legs. `d_to_cpu` feeds t80pa `.DI` directly (line 183). Priority mux avoids wired-AND → can force arbitrary value (0xFF over 0x00). flash/msx_slots/SDRAM/BRAM untouched.
- **Storage:** register-based, BRAM 0. CHEAT_N=8, `{cheat_en, cheat_addr[15:0], cheat_val[7:0]}`. Build confirmed **M10K 530 unchanged** (no BRAM increase).
- **Loader:** ioctl **index 9** (CONF_STR `F9,CHT,Load Cheats`). On clk21m, `cheat_dl = download & index==9`. 4 bytes/entry `{addr_lo, addr_hi, value, flags(bit0=en)}`, max 8 entries.
- **Master enable:** `status[51]` (CONF_STR `O[51],Cheats,Off,On`). `.cheat_en_master(status[51])` explicitly wired to msx instance.
- **Compare:** combinational parallel `a==cheat_addr[i] & cheat_en[i]` on Z80 logical addr `a` (line 156). `cheat_act = master & hit & ~mreq_n & rfrsh_n` (memory reads only; IO/refresh excluded).
- **.CHT format:** 4 bytes LE/entry `{addr[7:0], addr[15:8], value, flags(bit0=enable)}`, max 8. e.g. 0xC050=99 → `50 C0 63 01`.
- **Verification:** Verilator 6/6 PASS (TB `/tmp/cheat_test/{cheat_test.sv,tb_cheat.sv}`). Build `20260621d_cheat`: 0 errors, M10K 530 unchanged, timing +0.537ns, md5 `52add70d`.
- ◆ **HARDWARE OK (2026-06-21):** `0xDC78→0x80` freeze (`games/MSX1/NeonHorizon_fuel.cht = 78 DC 80 01`) confirmed working on Neon Horizon.
- ◆ Merged to `moonsound` (`c5dea71`, FF). MFRSD active boot confirmed OK by user.

### [T2] 2026-06-24 — 4-way set-associative BRAM upgrade (commit `102c6c1`)
- Registers (8) → **512-set × 4-way BRAM (capacity 2048)**. index=a[8:0], tag=a[15:9], slot=`{gen[2:0], tag[6:0], value[7:0]}` = 18 bit. 1-cycle parallel 4-way compare, `d_to_cpu` injection.
- **gen (3-bit)** provides instant reload invalidation (no sweep/race).
- 4× 512×18 way-RAM = exactly **4 M10K** (parity ×20 packing).
- ioctl **index 9** (same `.CHT` format), next-way placement, master `O[51]`. Verilator 15/15.
- ◆ **HARDWARE OK (`20260624d_cheatSA`):** castlemore **222 cheats applied simultaneously**, boot normal (4-way 512-set distributes without collision). Build = 4-way + fallback reduction 335/553 (61%), timing +0.513.
- ◆ **Merged to `moonsound` (2026-06-25, `102c6c1` FF)** — replaces register engine. flash/msx_slots/SDRAM untouched.
- Web app `tools/msx1_cheat_editor.html`: per-cheat on/off editor (.mcf load → toggle → .cht, 4-way collision warning, ~2048).

> NOTE on ioctl index: snapshot main-repo tokens read `F6,CHT,Load Cheats;` (index 6) + `O[51]`. Memory text for the merged engine says index 9. The deployed/merged token in the snapshot is **F6** (index 6); earlier register design used **F9** (index 9). Both refer to the same custom `.CHT` loader at different points.

### [T2a] ☐ OPEN TODO (Q1, on hold per user 2026-06-24)
- `cur_gen` only bumps on `.cht` download (ioctl idx9), NOT on ROM load (idx1/2) or reset; `O[51]` stays ON. Game-A cheats → load Game-B = stale-apply risk. Proposed fix: bump `cur_gen` on ROM-download detect (invalidate table). HELD, list-only.

---

## 2. Standard MiSTer OSD Cheats Attempt (WORKTREE `cheat-standard`, UNMERGED)

User requirement: "OSD should show cheat description + per-cheat on/off." Core overlay/font NOT needed — **MiSTer standard cheat system draws everything in HPS**.

### Standard system facts (confirmed via 8 sub-agents + direct verification, 2026-06-25)
- **Enable:** CONF_STR `C,Cheats;` token (label REQUIRED — `C;` is WRONG) → `user_io.cpp:907` `use_cheats=1`. Position free.
- **Wire format:** ioctl index **255**, HPS gathers only enabled cheats, **16 bytes/.gg record** `{addr32, compare32, replace32, flag32}` LE, no header (`cheats.cpp:359` raw concat). Each toggle re-sends full set + gen invalidate.
- **Loader (msx.sv):** index 9→255, 4B→16B. addr=byte0,1 / value(replace)=byte8. `ld_set={hi[0],lo}=a[8:0]`, tag=hi[7:1]. No CDC (single clk21m). Verilator 7/7.
- **zip:** `cheats/MSX1/<romname>.zip` (exact filename match OR CRC[8hex]). CoreName2 = CONF_STR first token = `MSX1`. STORED compression, 16B, `.gg`. `cheats.cpp` counts every entry via `cheats_available()` (no extension filter; 16B check only at toggle).

### Build progression (deployed RBFs from snapshot)
| # | Build / RBF | Date | Change | Result |
|---|---|---|---|---|
| [T3] | `MSX1_20260624_cheatSA.rbf` | 06-24 | 4-way SA custom engine | HW OK (T2) |
| [T4] | `MSX1_20260625_cheatStd.rbf` | 06-25 | standard, **`C;` (WRONG token, no label)** | use_cheats path wrong |
| [T5] | `MSX1_20260625b_cheatStd.rbf` | 06-25 | **`C,Cheats;` + ioctl 255**, FC1 still present | **OPEN — menu did NOT appear** (see §4) |
| [T6] | `MSX1_20260626_cheatStd3.rbf` | 06-26 | **FC1→F1** (false-lead fix) | **BOOT BROKE** (machine ROM auto-load lost; also CONF_STR 1-byte shifted SDRAM_DQ IOB placement → fit broke) |
| [T7] | `MSX1_20260626a_revtest.rbf` | 06-26 | revert test | — |
| [T8] | `MSX1_20260626b_cheatF1s2.rbf` | 06-26 | **F1 + Quartus SEED2** (re-seed to fix fit roulette) | — |

Worktree CONF_STR (snapshot lines 14-19): `C,Cheats;`, `F1,MSX,Load ROM PACK,30000000;`, `H3FS3,ROM,Load,30C00000;`. Loader: `cheat_dl = ioctl_download & (ioctl_index[7:0]==8'd255)`, `case(ioctl_addr[3:0])` 16-byte record parsing.
- Converter `mcf2mister.py` → `msx_mister/752` zip. Web app gained `.zip` export/import. cheatStd builds 335 M10K (61%).

---

## 3. HYPOTHESES — Disproven / Corrected

### [H1] FALSE LEAD (later abandoned): "FC1's `C`=store_name blocks cheats; change FC1→F1"
- **Original (wrong) theory (2026-06-25/26):** `FC1,MSX,Load ROM PACK,30000000` — the **C after F = store_name flag** (`menu.cpp:2362`) → store_name=1 → `menu.cpp:2685 if(!store_name)` means `cheats_init` is never called → `cheats_available()=0` → cheat entry greyed out (`menu.cpp:2072` MenuWrite always draws; 4th arg = grey flag). Proposed fix: FC1→F1.
- **NES contrast used as "proof" (2026-06-26):** NES core + cheats game → OSD Cheats menu appears = board / Main260611 / standard cheats all fine. MSX doesn't → "our core." NES ROM load uses `FS` (store_name=0) → cheats_init; MSX `FC1` (store_name=1) → blocked. At the time "F1 is the answer" was declared confirmed.

### [H1-CORRECTION] ★ CRITICAL — FC1 is MACHINE/FW ONLY, NEVER game (user emphasized 2026-06-26)
This **overturns H1's fix**. Recorded in `project_msx1_rom_load_menus.md`:
- `FC1,MSX,Load ROM PACK,30000000;` = **MACHINE (BIOS/system ROM) ONLY**. store_name=1 (C flag). For remembering machine ROM auto-load.
- `FC2,MSX,Load FW PACK,32000000;` = **FIRMWARE ONLY**. store_name=1.
- `H3FS3,ROM,Load,30C00000;` = **GAME ROM (Slot A)**. store_name=0 (F+S+3). ← games go here.
- `H4F4,ROM,Load,31100000;` = Slot B game load.
- **Changing FC1→F1 was a complete misjudgment:** FC1 is machine-only, so editing it breaks machine ROM auto-load → "machine ROM manual load required" / boot failure (exactly what build T6 `cheatStd3` showed). **FC1 must NEVER be touched.**
- **Standard `cheats_init` is called only on the store_name=0 path = Slot A "Load" (H3FS3).** Cheats must be handled on the **game load (Slot A Load)** path, not on FC1.

### [H2] DISPROVEN: "NES works but MSX1 doesn't = our core has a bug"
- `project_msx_vs_msx1_cores.md`: This isolation is **wrong**. MSX-family cores never supported standard MiSTer OSD cheats (no precedent). Reason: MSX doesn't load ROM as a single-file ioctl stream — it uses ROM PACK (with mapper config) + direct DDR upload (load_addr `0x30C00000`). Standard `cheats_init` expects "single ROM ioctl stream + CRC" flow — structural mismatch. NES-type (single ROM) works; MSX doesn't.
- gamehacking.org has MSX cheat data, but it has never been integrated into a MiSTer core. Putting standard cheats on MSX1 = first attempt ever (user confirmed 2026-06-26).
- Stated conclusion there: standard OSD approach needs **HPS modification** (core RTL alone insufficient); practical solution = custom `.CHT` (already working, c5dea71/102c6c1 merged) + web app per-cheat.

### [H3] CONFIRMED diagnosis tooling fact: Main suppresses console printf during core run
- MiSTer Main 260611 suppresses console `printf` while a core runs (including ROM load) → cannot observe `cheats_init` via serial / HPS-stdout (NES behaves identically).
- **Serial = USB Mini-B built-in port** (`0403:6001` FT232R = `/dev/ttyUSB0`, 115200). **micro-USB = JTAG** (`09fb`).
- Therefore the only diagnostic = **check on-screen OSD after core load** (serial console is blind during run).

---

## 4. 6-Agent Deep-Dive Findings (record each verbatim-intent)

These examined why build T5 (`20260625b_cheatStd`, worktree, `C,Cheats;` + ioctl 255 + FC1) did not show a cheat menu.

- **(P1)** Our `.gg` layout `{addr, 0, value, 0}` differs from NES standard `{flags, addr, compare, replace}` — BUT our converter + loader are self-consistent (HPS raw passthrough), so apply works on our core.
- **(C2/C6)** Main repo has NO `C,Cheats` token (custom F6/O51) → `use_cheats=0` there. BUT the `cheat-standard` **worktree** has `C,Cheats;` → `use_cheats=1` for the `20260625b` build.
- **(C4)** Apply path correct.
- **(C5)** ioctl 255 receive correct in worktree.

---

## 5. OPEN QUESTION at session end (UNVERIFIED)

- **Build T5 `20260625b_cheatStd`** (worktree; `C,Cheats;` + ioctl 255; FC1 still present) — all conditions appear met:
  - `use_cheats=1` (token present)
  - Slot A Load store_name=0 → `cheats_init` called
  - filename match
  - apply path OK
  - …yet the **cheat menu did NOT appear.**
- **Unconfirmed:** whether T5 was tested correctly on a **booting build via Slot A Load** (the game-load path). Build T6 (`cheatStd3`, F1) broke boot, so the FC1-based T5 vs the F1-based T6 were never cleanly A/B-tested on a booting core loading a game through Slot A.
- Net: the standard-OSD-cheats attempt (worktree) is **unresolved**. The custom `.CHT` engine (main repo, §1) **works and is the deployed/merged solution**.

---

## 6. Quick Fact Reference (file:line index)

| Fact | Location |
|---|---|
| `d_to_cpu` priority mux (cheat injection) | `rtl/msx.sv` ~line 276 |
| `d_to_cpu` → t80pa `.DI` | `rtl/msx.sv` line 183 |
| Z80 logical addr `a` (compare input) | `rtl/msx.sv` line 156 |
| Main-repo cheat tokens (F6/O51) | `MSX1.sv` lines 294-295 |
| Worktree cheat tokens (`C,Cheats;`, F1, H3FS3) | worktree `MSX1.sv` lines 254/256/259 |
| Worktree loader `cheat_dl` (ioctl 255) | worktree `rtl/msx.sv` line 324; 16-byte case line 337 |
| `use_cheats=1` set | MiSTer `user_io.cpp:907` |
| `.gg` raw concat (no header) | MiSTer `cheats.cpp:359` |
| store_name flag parse | MiSTer `menu.cpp:2362` |
| `if(!store_name)` cheats_init gate | MiSTer `menu.cpp:2685` |
| MenuWrite grey flag | MiSTer `menu.cpp:2072` |

### Deployed RBFs (board), chronological
```
MSX1_20260621f_gapprobe.rbf      (pre-cheat probe)
MSX1_20260621g_causeprobe.rbf    (pre-cheat probe)
MSX1_20260624_cheatSA.rbf        (4-way SA custom .CHT — HW OK, 222 cheats)
MSX1_20260625_cheatStd.rbf       (standard, "C;" WRONG token)
MSX1_20260625b_cheatStd.rbf      (standard, "C,Cheats;"+255, FC1 — OPEN, no menu)
MSX1_20260626_cheatStd3.rbf      (F1 — BOOT BROKE)
MSX1_20260626a_revtest.rbf       (revert test)
MSX1_20260626b_cheatF1s2.rbf     (F1+SEED2)
```

### Git (snapshot)
```
102c6c1 cheat: 4-way set-associative BRAM lookup (1-cycle, ~2048 cheats, 4 M10K)   <- HEAD moonsound
c5dea71 cheat: register-based freeze/POKE engine (no BRAM, flash/slots untouched)
f94b2be ascii16x: volatile JEDEC byte-program into SDRAM (flash.sv untouched)
```
Worktree `cheat-standard` checked out at `102c6c1` (unmerged standard-cheats work lives there).
