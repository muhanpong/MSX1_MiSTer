# FINAL CONSENSUS — Standard-OSD-Cheats Handoff (Synthesis Lead, Round 2/3)

Reconciles R1 (consistency), R2 (continuity), R3 (durability). Every corrected fact below
was independently re-verified by the synthesis lead against the live trees; file:line quoted.

---

## 0. Verified ground truth (synthesis lead re-greps)

| Fact | Source | Verified value |
|------|--------|----------------|
| Worktree machine slot | `.claude/worktrees/cheat-standard/MSX1.sv:256` | `"F1,MSX,Load ROM PACK,30000000;"` — **forbidden F1 baked in HEAD** |
| Worktree cheats token | worktree `MSX1.sv:254` | `"C,Cheats;"` |
| Worktree Slot A game | worktree `MSX1.sv:259` | `"H3FS3,ROM,Load,30C00000;"` (store_name=0) |
| Main machine slot | main `MSX1.sv:255` | `"FC1,MSX,Load ROM PACK,30000000;"` |
| Main cheat loader token | main `MSX1.sv:294` / `:295` | `"F6,CHT,Load Cheats;"` + `"O[51],Cheats,Off,On;"` |
| Main RTL cheat ioctl | main `rtl/msx.sv:320` | `ioctl_index[5:0]==6'd6` — comment `// CHT moved F9→F6 (F9 entry didn't show in OSD)` |
| Worktree RTL cheat ioctl | worktree `rtl/msx.sv:324` | `ioctl_index[7:0]==8'd255` |
| HEAD (both trees) | `git log` | `102c6c1` = "4-way set-associative BRAM lookup (… 4 M10K)" |
| store_name gate | Main_MiSTer `menu.cpp:2685` / `:2688` | `if (!store_name) … if (user_io_use_cheats()) cheats_init(...)` |
| store_name set | `menu.cpp:2364` / `:2400` (set 1), `:2351`/`:2395` (set 0) | only `C` after F/S sets store_name=1 |
| Converter | `~/Downloads/blueMSXv282full/Tools/Cheats/mcf2mister.py` | EXISTS, 6520 B |
| Booting C,Cheats build | snapshot DEPLOYED RBFs | `MSX1_20260625b_cheatStd.rbf` (FC1) |
| Board currently running | R2 [CHECKED] | `MSX1_20260626b_cheatF1s2.rbf` (must re-select 20260625b) |

---

## 1. LOCKED decision points (consensus, all verified)

1. **FC1→F1 "fixes cheats" is WRONG and must never be repeated.** FC1 is the machine/BIOS
   "Load ROM PACK" slot (`MSX1.sv:255`), store_name=1. The store_name MECHANISM is real
   (`menu.cpp:2685` calls `cheats_init` only `if(!store_name)`; `:2364` sets store_name=1 when a
   `C` follows an F/S option) — but the REMEDY of touching FC1 is wrong. Cheats already fire on
   the **Slot A `H3FS3` Load** path (`MSX1.sv:259`/worktree `:259`), which is store_name=0,
   regardless of FC1 vs F1. F1 only breaks machine autoload/boot.
   **The worktree HEAD (`102c6c1`) still HAS F1 at `MSX1.sv:256`** → a naive "rebuild the worktree"
   re-breaks boot. The known build that BOTH boots AND declares `C,Cheats;` is **`20260625b`** (FC1).

2. **ioctl indices.** Main-repo custom engine = **index 6** (`F6,CHT`, `rtl/msx.sv:320` `==6'd6`).
   Worktree standard engine = **index 255** (`rtl/msx.sv:324` `==8'd255`). The "F9/index 9" in
   memory and some docs is stale.

3. **Merged custom engine HEAD = 4-way set-associative BRAM (`102c6c1`)**, NOT the register engine
   (`c5dea71`, which it superseded). 4 M10K, fit 335/553.

4. **`mcf2mister.py` EXISTS.** `.gg` layout `{addr32,0,value32,0}` is self-consistent with our
   loader (HPS does raw passthrough; `cheats_available()` counts by 16-byte stride). Field order
   affects cheat APPLICATION only, NOT OSD menu visibility.

5. **printf-suppression-during-core-run is UNVERIFIED.** Do not assert as fact. OSD screen
   observation (grayed vs absent) is the authoritative signal; serial `stdbuf -oL` is secondary.

6. **#1 decisive open experiment.** On a BOOTING build that declares `C,Cheats;` (`20260625b`,
   or a reseeded FC1+C,Cheats build), load **twinbee via Slot A "Load"** (the `H3FS3` entry — NOT
   "Load ROM PACK"), using the ROM matching the existing
   `cheats/MSX1/Twinbee (1986) (Konami) (J).zip`, and observe whether the OSD **Cheats** item
   appears **grayed** (cheats_init ran, 0 entries) vs **absent** (cheats_init never reached).
   Serial logging secondary.

---

## 2. How each R1/R2/R3 disagreement was resolved (with evidence)

| # | Disagreement | Resolution | Evidence |
|---|--------------|-----------|----------|
| D1 | A2 framed F1 as "the store_name fix / build the F1 worktree"; A1/R2-§7/R3 call F1 the disproven boot-breaker | **A2 is WRONG.** F1 is the disproven change; resume = revert worktree `MSX1.sv:256` F1→FC1, keep `C,Cheats;`+`H3FS3`, reseed, test on Slot A. | worktree `MSX1.sv:256`=F1 (verified); `H3FS3` `:259` store_name=0 already fires cheats; booting build `20260625b` had FC1 |
| D2 | C4 said ioctl index 9; R1/R3 said 6 | **6.** | main `rtl/msx.sv:320` `==6'd6` + comment "F9→F6" |
| D3 | A2 said `mcf2mister.py` absent; B3 said exists | **EXISTS.** A2 searched only repo `tools/`. | `~/Downloads/blueMSXv282full/Tools/Cheats/mcf2mister.py` 6520 B |
| D4 | B3 file count 753 vs task's 752 | **752** (R1 confirmed 752 `.cht`/`.zip`/`.mcf`). Cosmetic, no resume impact. | R1 §2.4 disk count |
| D5 | C1/C2 describe custom engine as register/M10K-530 | **HEAD = 4-way BRAM `102c6c1`, 335/553.** Register `c5dea71` is superseded. | `git log` both trees |
| D6 | A1 §6 line numbers stale (register-era) | Use B2's current numbers: d_to_cpu mux `:347`, `.DI` `:186`, addr `a` `:159`. | re-verified main `rtl/msx.sv` |
| D7 | C2 inverted MSX vs MSX1 ("we are not MSX1") | **We work on MSX1.** C2 is wrong. | `project_msx_vs_msx1_cores.md:15` (CoreName2=MSX1, `cheats/MSX1/`); main `MSX1.sv:253` first token `MSX1` |
| D8 | A4/A3 serial cmd: `awk -v RS="\0"` empty on busybox; A3 targets board `/dev/ttyUSB0` | Use `RBF=$(tr '\0' '\n' < /proc/$(pidof MiSTer)/cmdline \| sed -n 2p)`. `ttyUSB0` is the **PC-side** FT232R; board console = `ttyS0`; board-side log to `/tmp/mlog`. | R2 [CHECKED] on board |
| D9 | memory `project_cheat_engine.md:46-48` still says "F1이 정답 확정" (F1 confirmed) | **Must retract** — contradicts `project_msx1_rom_load_menus.md:23` ("완전 오판, FC1 절대 손대지 말 것", authoritative). | both memory files read |
| D10 | printf-suppression stated as fact in A4/C1/C3/C4/memory but A2 #9 hedged | **UNVERIFIED.** Downgrade everywhere; OSD observation authoritative. | A2 #9 hedge; no proof on disk |
| D11 | Repo path `/home/muhanpong/github/...` vs `/Documents/github/...` | Same inode (R2 [CHECKED]); standardize on **`/home/muhanpong/Documents/github/MSX1_MiSTer`**. | R2 §0 |

---

## 3. Resume-blocking adds (consensus)

1. **Worktree HEAD trap:** worktree `MSX1.sv:256` = F1. Revert F1→FC1 before any rebuild.
2. **Test `20260625b` FIRST** (boots + `C,Cheats;` + Slot A store_name=0). Only rebuild if it
   fails. Board is currently on `20260626b_cheatF1s2` → must re-select 20260625b.
3. **Exact ROM/zip precheck:** `cheats/MSX1/Twinbee (1986) (Konami) (J).zip` exists; load the
   matching ROM by name/CRC or "no menu" is a false negative.
4. **Shared dirty `rtl/msx.sv`:** main working tree has uncommitted PCM/moonsound WIP in the same
   `rtl/msx.sv` that holds cheat code (areas don't overlap, but a build from the dirty tree mixes
   both — commit cheat-only).

---

## 4. Two-track status (canonical)

- **Track A — custom `.CHT` engine: WORKS + MERGED.** 4-way BRAM `102c6c1`, ioctl **index 6**
  (`F6,CHT`), master `status[51]` (`O[51]`), d_to_cpu mux injection. Real-hardware verified.
  No per-cheat OSD description/toggle (web app `tools/msx1_cheat_editor.html` handles editing).
- **Track B — standard MiSTer OSD cheats (`.gg`/zip, ioctl 255, `C,Cheats;`): UNRESOLVED + UNMERGED.**
  HPS path looks correct; the single open question is whether the OSD Cheats menu appears on a
  booting `C,Cheats;` build with the game loaded via Slot A — see experiment #1 (§1.6).
