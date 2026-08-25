# NEW SESSION — MSX1_MiSTer Cheats (paste-ready)

You are resuming the MSX1_MiSTer cheats work. Read this, then CROSS-VERIFY every load-bearing
fact yourself (grep the real files / ssh the board) before acting — prior sessions were misled by
unverified claims. Quote file:line for anything you rely on.

## Situation (two tracks)
- **Track A — custom `.CHT` engine: WORKS and is MERGED** into `moonsound` HEAD `102c6c1`
  (4-way set-associative BRAM, 4 M10K, fit 335/553). Loader = ioctl **index 6** (`F6,CHT`),
  master enable = `status[51]` (`O[51]`), injected at the `rtl/msx.sv` `d_to_cpu` priority mux.
  Real-hardware verified. Limitation: no per-cheat OSD description/toggle (the web editor
  `tools/msx1_cheat_editor.html` does editing).
- **Track B — standard MiSTer OSD cheats** (`.gg`/zip, ioctl index 255, `"C,Cheats;"` token):
  **UNRESOLVED, UNMERGED.** Lives in worktree `.claude/worktrees/cheat-standard`. The HPS path
  looks correct, but the OSD Cheats menu has not been confirmed to appear. This is the open work.

## 5 HARD RULES (do not violate)
1. **FC1 = machine/BIOS only, NEVER a game, NEVER touch it.** `"FC1,MSX,Load ROM PACK,…"`
   (main `MSX1.sv:255`) is the machine slot, store_name=1. Changing FC1→F1 was a DISPROVEN
   misjudgment that breaks machine autoload/boot. It does NOT enable cheats.
2. **Game ROMs load via Slot A "Load"** (the `"H3FS3,ROM,Load,30C00000;"` entry, `MSX1.sv:259`,
   store_name=0). Standard `cheats_init` fires on THIS path regardless of FC1/F1. NOT via
   "Load ROM PACK".
3. **MSX != MSX1. We work on MSX1** (CoreName2 = `MSX1`, dir `cheats/MSX1/`,
   repo `/home/muhanpong/Documents/github/MSX1_MiSTer`). The separate official MSX core is a
   different project — do not assume its behavior.
4. **NES cheats work on this same board** — use NES as the known-good reference for what a
   working standard-OSD cheats flow looks like (but the "NES works ⇒ MSX1 is buggy" isolation is
   unproven; treat it as a lead, not a conclusion).
5. **The `cheat-standard` worktree HEAD (`102c6c1`) currently HAS the forbidden F1** at
   `MSX1.sv:256`. Do NOT "rebuild the worktree" as-is — revert `MSX1.sv:256` F1→FC1 first.
   The booting build that already has `C,Cheats;` is **`MSX1_20260625b_cheatStd.rbf`** (FC1) —
   test IT before any multi-hour Quartus rebuild.

## #1 EXPERIMENT (decisive, do this first)
On a BOOTING build that declares `"C,Cheats;"` — start with `20260625b` (board may currently be on
`20260626b_cheatF1s2`, so re-select 20260625b):
1. Pre-req: `ssh root@192.168.1.86 'ls -l "/media/fat/cheats/MSX1/"'` — confirm
   `Twinbee (1986) (Konami) (J).zip` exists; you must load the ROM matching that exact name/CRC,
   else an empty menu is a false negative.
2. Boot core → OSD → **Slot A → "Load"** (the `H3FS3` entry) → pick the matching twinbee ROM.
   Do NOT use "Load ROM PACK".
3. Observe the OSD **Cheats** item: **grayed** (= `cheats_init` ran, 0 usable entries → record
   format / miniz) vs **absent** (= `cheats_init` never reached → zip naming/CRC or path).
4. Secondary: capture serial with `stdbuf -oL` for `cheats_init` / `Using cheat file` / `cheats: N`.
   NOTE: console-printf-suppression-during-core-run is UNVERIFIED — **OSD screen observation is the
   authoritative signal**, serial is corroboration only.

If 20260625b fails to boot, it is not the right build → re-identify the booting `C,Cheats;` variant
(or reseed a FC1+`C,Cheats;` build) before drawing conclusions.

## Key paths
- Repo (main, Track A merged): `/home/muhanpong/Documents/github/MSX1_MiSTer`
- Worktree (Track B, HAS F1): `…/MSX1_MiSTer/.claude/worktrees/cheat-standard`
- HPS framework: `/run/media/muhanpong/0eb4bebc-0644-4c2f-9a97-ddca5afcd8f3/MiSTer_build/Main_MiSTer`
  (store_name gate `menu.cpp:2685`/`:2688`; set at `:2364`)
- NES reference: `/run/media/.../MiSTer_build/NES_MiSTer`
- Converter: `~/Downloads/blueMSXv282full/Tools/Cheats/mcf2mister.py` (EXISTS)
- Board: `ssh root@192.168.1.86` (passwordless). Serial = PC-side `/dev/ttyUSB0` (FT232R); board
  console = `ttyS0`; board-side log to `/tmp/mlog`. To read the running rbf:
  `tr '\0' '\n' < /proc/$(pidof MiSTer)/cmdline | sed -n 2p` (do NOT use `awk -v RS="\0"` — empty on
  the board's busybox).

## Memory + docs to read
- Memory (authoritative on the FC1 rule): `project_msx1_rom_load_menus.md`,
  `project_msx_vs_msx1_cores.md`, `project_cheat_engine.md`. Where they conflict,
  `project_msx1_rom_load_menus.md` wins.
- Final handoff docs: `/tmp/handoff/FINAL_consensus.md` (corrected facts + decision points),
  the B-references `/tmp/handoff/B1_hps_cheat_reference.md` / `B2_core_rtl_reference.md`
  (verified file:line on HPS and RTL sides), `A3_open_questions.md` (full experiment tree),
  `A4_diagnostic_playbook.md` (serial/JTAG procedures).

## Decision note (if the user has not chosen a direction)
Track A already satisfies "cheats work on hardware" (just no per-cheat OSD UI). Before grinding
Track B, confirm the user actually wants the standard OSD per-cheat menu vs accepting Track A.
If undecided, surface: A (works+merged, no OSD per-cheat) / B (standard OSD, blocked on the #1
experiment) / C (core-drawn overlay, unstarted, large RTL).

CROSS-VERIFY before acting: re-grep `MSX1.sv` line tokens, `rtl/msx.sv` ioctl index, and the
worktree `MSX1.sv:256` F1 state yourself; re-confirm the deployed RBF identity (md5) before
trusting any "no menu" result.
