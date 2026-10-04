# Handoff 2026-10-04 -- SRAM order fixes building, README refreshed, SRAM design open

From the session in tmux `stable_Turbo-R-0927:2` (session 7026ec2d). Worktree
`.claude/worktrees/readcache`, detached HEAD = **`71de899` = origin/nextz80** (pushed).
Previous handoff: `docs/handoff_20260927_mupack.md` §10.

## 0. Do this first: a build is running -- you own its deploy

* `tools/buildgate/build.sh` was started on commit **`770879f`** (SRAM order fixes) as a
  background task of the old session. The later commit `71de899` is README only, so the
  bitstream is the same.
* Log: `/tmp/claude-1000/-home-muhanpong-Documents-github-MSX1-MiSTer--claude-worktrees-readcache/7026ec2d-78db-4728-82cb-c21f9d8b0871/scratchpad/build_770879f.log`
  (stage logs in `/tmp/buildgate/`). Verdict = the last line `BUILDGATE: PASS|FAIL`.
  At 10:21 it was still in precheck, running `sim/fullsys/run_packver.sh` (the last PASS
  was `d8d36d6`, so many landmine rows fire). Map ~5 min + fit ~15-17 min after that.
* Build start epoch (for deploy.sh): **`1791076110`**.
* **If PASS:** deploy at once (deploy needs no confirmation; name rule
  `MSX1_<YYYYMMDD><letter>_<desc>.rbf`; no 20261004 RBF is on the board yet):
  `tools/buildgate/deploy.sh MSX1_20261004a_sramorder.rbf 1791076110`
  then tell the user the name and the test list in §2.
* **If FAIL:** do not deploy. Read which stage failed; a precheck bench FAIL means a bench
  regressed -- find out why before anything else (`feedback-buildgate-harness`).
* The old session will NOT deploy. Do not start a second build while this one runs.

## 1. What this build contains (all on origin/nextz80)

| commit | what | verified |
|---|---|---|
| `29a829b` | MoonSound variant packs `Panasonic FS-A1F basic MoonSound`, `Sony_HB-F1XDmk2_MoonSound` (stock + one MOONSOUND device record). Packs only, no RTL. Both are on the board (`games/MSX1/MSX/Panasonic|Sony/`) | FS-A1F one: user heard Neon Horizon PCM fixed. Sony one untested |
| `0555cce` | ASCII16X recognised by its header at any size: OSD "ASCII16X" entry on a <=4MB cart was plain ASCII16; late 8MB padding; mapper_detect clears its stale signature on reset; padding no longer overwrites the last image byte | benches (`sim/run_x16_header.sh` + mutants). Never built before this build |
| `770879f` | nvram order fixes (below) | benches. Never built before this build |
| `71de899` | README: turbo R, MIDI/MT32-pi, Reset on ROM change, SRAM WIP; stale claims fixed | -- |

`770879f` in short (memory `project_sram_images_vd123.md`, "20261004 결함 1~4 수정"):
* slot B ROM carts get no SRAM (`msx_slots.sv` `sram_denied`) -- they inherited slot A
  FM-PAC's / machine SRAM's `ref_sram` and could write it
* nvram_backup: same bank load before save; nothing starts and saves are dropped while
  `upload_busy` (= memory_upload `reset_rq`); `img_mounted` raises a load (a mounted
  image is read); new output `guard` joins `saving` in MSX1.sv so save_guard finally
  covers SRAM saves (its `nvbak_dma_active` is the disabled flash path)
* benches `sim/run_nvram_order.sh` (O1-O4, four mutants), `sim/run_slotb_sram.sh`
  (msx_slots alone; needs `sim/fullsys/gen`), wired into landmines `saveload` + new `slotsram`

## 2. Hardware tests to give the user after deploy

Board CFG has `SRAM Autosave on OSD` = On (status[52]=1, checked in `config/MSX1.CFG`).
1. Core loads; OSD version date is 20261004.
2. Slot A SRAM cart (an ASCII8/16 game that saves to SRAM): save in game, open OSD (autosave)
   or SRAM Save, power cycle, load the same ROM -> save is there. (Mount-load + load-first.)
3. Illusion City `#01_ILLUCITY_EN/ICITY_A16X.rom` (4MB, has the ASCII16X header): set Slot A
   mapper to **ASCII16X by hand** -> must behave as ASCII16X (save works). Before 0555cce it
   became plain ASCII16. Also AUTO.
4. Flash save regression: an ASCII16X / Yamanooto game saves and reloads after power cycle.
5. Race check: save, open the OSD, and immediately load another ROM or switch Slot A's type;
   then go back -> the save is intact (not 0xFF).
6. Reset during a save: SRAM Save then OSD Reset at once -> save intact (reset waits).
7. Optional: ASCII16 SRAM game in **slot B** with FM-PAC in slot A -> the slot B game has no
   SRAM (cannot save); FM-PAC unaffected.
8. Optional: `Sony_HB-F1XDmk2_MoonSound` pack + Neon Horizon -> PCM effects audible
   (debug overlay row 0 green).

## 3. Open items (user decisions in **bold**)

1. **SRAM persistence design for FM-PAC / GM2 / machine SRAM / RTC.** Researched today by 3
   design agents + 3 cross-reviews + 4 user-simulation agents; reports were in the old
   session's scratchpad `scratchpad/sram/` (may vanish). Conclusion and verified facts are
   in memory `project_sram_images_vd123.md`. All 4 user simulations ranked B (one file
   `saves/MSX1/SRAM.NVR` via `SC1`, autosave on write, popups) > A (boot1..3.vhd, no code) > C
   (C withdrew and merged into B). Decisions pending: file layout now (no SRAM saves exist on
   the board yet -- the only migration-free moment), `SC1` vs `SC6`+VDNUM 7, FM-PAC save
   follows slot or cart, RTC settings memory yes/no, autosave scope (include VD0 + flash).
   The 2026-09-30 image format (64 kB entries, 4 kB header) is respected but not untouchable.
   Firmware facts (local `MiSTer_build/Main_MiSTer`, e48a278): three mount ways (FS's S =
   VD0 only, grows; `boot%d.vhd` i<4 fixed names, no grow; `SC<n>` remembered in
   `config/MSX1.s<n>`), boot vhd mounts after SC restore so it wins; OSD popups are not
   drawn while the menu is open; ext filter is 3-letter.
   Also found: FM-PAC 0x1FFE/F read = fm_pac_dout & BRAM (AND bus) -> importing openMSX's
   8190-byte .pac needs FF in the last two bytes.
2. **status bits 75-77 overlap**: R800 VDP access wait `O[77:75]` (MSX1.sv:469, 9/19) vs
   slot A Sub-slot 0/1 fields `[75:73]`/`[78:76]` (msx_config.sv, 8/26). Code-confirmed,
   hardware effect not seen. Free bits are only 11, 36, 37, 127 -- moving the dial needs a
   decision.
3. **Flash buffer program (25h..29h)** -- user: "구현 순위권", not started
   (`project_flash_buffer_program.md`).
4. boot1..3.vhd not on the board; MIDI IN cut; MT32-pi hot-plug looked fine to the user.
5. README pack builder URL: user said `muhanpong.github.io/packbuilder.html`, which is 404;
   `muhanpong.github.io/MiSTer/packbuilder.html` is 200 and is what the README uses. Ask if
   they want the other.
6. Untracked scratch at the worktree root (`holdfast.txt`, `rec.txt`, `research/` 4.3 GB, ...)
   still not reviewed.

## 4. Today's other changes outside the repo

* Branch cleanup (main checkout now on `nextz80`): local branches deleted -- az80_nextz80,
  moonsound_ascii16x, myMSX2-IKAOPLL, rz80 (+worktree), MSX2_Dev_IKASCC, myMSX2,
  myMSX2-ascii8_short, myMSX2-IKASCC, main. Bundles in `~/Documents/github/` and
  `/run/media/muhanpong/NewElements12TB/Backups/` (`MSX1_MiSTer_rz80_20261004.bundle`,
  `MSX1_MiSTer_oldbranches_20261004.bundle`). Left: `MSX2`, `nextz80`. Remotes untouched.
* Memory: a doc-extraction agent wrote 6 reference memories (`reference_build_deploy_howto`,
  `reference_bench_catalog`, `reference_code_map`, `reference_confstr_status_allocation`,
  `reference_local_sources_and_tools`, `project_user_decisions_closed_topics`) and rewrote
  the MEMORY.md index (pre-compaction copy next to the memory dir).
* A PreToolUse hook `~/.claude/hooks/memory-recall.py` (user settings) greps the memory
  before WebFetch / WebSearch / curl / wget / git clone / broad find and injects matches.
  A `[memory-recall]` block in your context means: read those files before going outside.
  Memory `reference_memory_recall_hook.md`.

## 5. Rules (memory index trigger table, the ones that bit today)

* Build only on the user's explicit "해"; deploy needs no confirmation; never delete an RBF.
* Read back every work request before doing it.
* Before saying something is "not local" or explaining firmware behaviour: grep memory, read
  `MiSTer_build/Main_MiSTer`. Before re-proposing a design: read the decision record.
* Kill only literal PIDs you started.
