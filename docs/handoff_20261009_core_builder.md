# Handoff 2026-10-09 -- core_builder: SRAM file, OPL4 readback, OSD, overscan sprites

From the session **core_builder** (tmux `stable_Turbo-R-0927:2`, Claude session
978dfc9c / `claude --resume core_builder`). Worktree `.claude/worktrees/readcache`,
detached HEAD = **`cc1255e`**; `origin/nextz80` = `29a4303` (**`cc1255e` is not pushed**).
Previous handoff: `docs/handoff_20261004_sram.md` (all of its §0-§2 is done).

## 0. Do this first

* Nothing is building or pending. The board runs **`MSX1_20261008a_ovscansprite.rbf`**
  (= `cc1255e`), loaded 2026-10-08 02:34, boots to BASIC `Ok` on the FS-A1GT DOS2 pack.
* `cc1255e` (overscan sprites) is committed, built, deployed, **not pushed** -- push only on
  the user's word (`git push origin HEAD:nextz80`, it fast-forwards).
* Hardware checks still open are in §2. The user has not reported on `20261008a` yet.

## 1. What was done (commit, build, board)

| commit | what | verified |
|---|---|---|
| `6e893f3` | bench label "T5 bad magic" -> "wrong magic": precheck's BADLOG read "5 bad" as an error count and refused 770879f | bench PASS |
| `1a84d9f` | **SRAM file**: every SRAM but the slot A ROM `.sav` lives in ONE file on VD1, OSD `SC1` (remembered in `config/MSX1.s1`), one 64 kB entry per kind (entry = kind-1: FM-PAC, GM2, Halnote, Panasonic 16/32 kB, RTC); RTC settings memory got a 2nd port (`rtc.vhd`) and is bank 4 at 18'h20000; same-kind banks -> lower bank (slot A) owns the entry; **autosave on write** (quiet 0.78 s / age 12.5 s / flush on download or reset button), flash carts still save on OSD open | `run_nvram_layout` (T1-T14, A1-A7, 6 mutants), `run_rtc_nvport`; **hardware**: SC1 mount, FM-PAC/RTC saves, RTC restore after core reload (`SET PROMPT` test, prompt survived reload and applies before the BIOS reads it), SRAM Save button |
| `7d549a1` | blank `SRAM.NVR` is 2 MB (32 entries, 26 spare); `SRAM_KIND` append-only | board file padded to 2 MB in place (saves kept) |
| `37df809` | OSD label `SRAM(PAC/Turbo-R/...)` (no commas: substrcpy splits on ','; row holds 29 chars) | hardware |
| `50e246d`, `2ce73fc` | **OPL4 wave register readback** (was 0 for all but reg 2/6 since the first engine; Neon Horizon's stop routine at ROM 0x50D8 does RMW on 68h-7Fh and lost the pan). Third MLAB read port + 16-byte shadow; 2ce73fc registers the path (50e246d failed signoff -1.355 ns) | `run_pcm_regread` (3 mutants), PCM golden; built. Hardware: not specifically checked |
| `2c13ec0` | `deploy.sh` uploads the build's CONF_STR to `/media/fat/config/confstr/<rbf>.txt` for misterclaw (skipped, not failed, if it cannot prove it matches) | 4 deploys since; sidecars on the board |
| `f4240bd` | R800 VDP wait `O[77:75]` -> `O[38:36]` (it overlapped slot A sub-slot fields), SRAM Save `R[38]` -> `R[11]`; `tools/confstr/check_status_overlap.py` (confstr landmine) | board CFG bits 73-78 cleared (backup `MSX1.CFG.bak_20261005`); SRAM Save pressed on hardware via misterclaw: counters +1 |
| `a4f2b16` | SRAM file save writes data first, header last (power cut mid-save keeps the old header) | `run_nvram_layout` order checks + hdrfirst mutant |
| `45b1f1f` | OSD rows behind masks 5/6 (SRAM size, SRAM Save/Load/Autosave) are greyed (D) instead of hidden (H) -- the layout no longer depends on bits an OSD driver cannot see | hardware photo: SRAM size row greyed |
| `d0d6fc5`, `3016d6e`, `29a4303` | one "Video & Audio settings" page; audio grouped PSG/MSX-MUSIC, SCC (+SCC_DIAG channel mutes), MoonSound, mute above volume. Status bits unchanged | hardware photo |
| `cc1255e` | **VDP overscan sprites** (R#9 LN switched past the end line, display never ends -- km224.rom, ASO): W_ACTIVE gets a `SPWINDOW_Y` term (sprites no longer stop the line after an LN 1->0 switch); `vdp_ssg` outputs `SP_TARGET_Y` (two-line lookahead across the end-of-blanking jump) so the first top-border lines get the right sprites | `sim/run_vdp_overscan_sprite.sh` (new, ~13 min; openMSX table from the knightmare-v2 session; normal frames identical to before; mutants nowin/plusone), tb_zanac unchanged. Worst setup +0.025 ns in `ascal` (unrelated path). **Hardware: not yet** |

RBFs deployed this session: `20261004a_nvorder`, `b_sramfile`, `c_sramlabel`,
`d_opl4regrd`, `20261005a_vdpwbits`, `b_osdaudio`, `20261008a_ovscansprite`.

## 2. Hardware checks to ask the user for

1. **km224.rom** (`~/Downloads/km224.rom`, md5 da136038): sprites on the top 2-3 lines
   (the top border) now drawn -- the reason for `cc1255e`. knightmare-v2 is shipping a
   v1.1 ROM that also moves its LN switch to line 240.
2. **ASO** top band and ordinary sprite games (no stray sprites or ghost collisions on
   border lines) on `20261008a`.
3. **Neon Horizon** song change: pan of fading notes kept (OPL4 readback).
4. FM-PAC save restored into a game after a core reload (only the file counters and the
   RTC were proven); a real power-off was not tested (judged unnecessary: SC images are
   opened `O_SYNC`).
5. OSD: on a pack with no SRAM, the SRAM rows show greyed (only seen with Yamanooto).

## 3. Open items (user decisions in **bold**)

1. **Push `cc1255e`.**
2. **YMF278B follow-ups** from the MSXimus comparison (our engine matches openMSX far
   better; theirs has TL-interpolation, attack, DL, pan defects): F8 FM-mix reset 0 vs
   openMSX 0x1B (-9 dB) -- touches gain, ask first; LD/BUSY counts are openMSX master-clock
   values run on clk_sdram (2.54x shorter) -- comment only, by decision.
3. **VDP FH second defect** (memory `project_vdp_fh_vblank_clear`): with IE1 off openMSX
   returns FH for a short window, we return 0 -- our IE1 gate is a stopgap. MSXimus has no
   IE1 gate at all (would have the Zanac-EX title bug).
4. `reg 6` read with reg 2 bit0 = 0 returns data; openMSX returns 0xFF without increment.
5. Mask 5 still follows ROM size only; a <=4 MB ROM with an ASCII16X header runs as
   ASCII16X but shows the (now greyed-able) SRAM size row (harmless).
6. MoonSound yrw801 zero-fill has the same last-byte overwrite structure as the old
   ASCII16X padding; harmless for the known yrw801 (last byte is 0x00).
7. packbuilder published copy (github.io, other repo) lacks the SRAM.NVR button.

## 4. Cross-session facts

* **mister-super-expert** was handed over to **mister-super-expert-rc** (tmux
  `stable_Turbo-R-0927:0`, doc `docs/handoff_20261004_mister-super-expert.md` in the main
  checkout).
* **msx-machine-expert-rc** owns misterclaw (fork `muhanpong/misterclaw` branch
  `msx1-osd-support`): reads the confstr sidecars, infers the OSD mask from CFG + pack +
  ROM size (bit 15 MT32-pi runtime only). It measured the OPL4 reads in openMSX and pressed
  SRAM Save for us. It added `[MSX1] log_file_entry=1` to the board's MiSTer.ini
  (backup `MiSTer.ini.claw-20261005`).
* **knightmare-v2** / **rsrv** (Remote Control, other machine): km224 (Knightmare 224-line
  mod). They gave the openMSX top-border table; I sent rsrv a **correction** (our core did
  stop sprites after an LN 1->0 switch -- now fixed by cc1255e; they moved the switch to the
  HUD line anyway).

## 5. Rules that bit this session

* **Report to the user in Korean** even when the user writes English (memory
  `feedback_report_in_korean`) -- slipped several times.
* Build only on an explicit "빌드"; deploy needs no confirmation; never delete an RBF.
* A conclusion about display/sprite behaviour must follow the signal to its last consumer
  (I told rsrv "sprites continue" from PREWINDOW_Y_SP alone; W_ACTIVE said otherwise).
* A bench that scores a VCD must close its last segment before `done` (two bench runs were
  invalid; I first misdiagnosed it as stop-time).
* CONF_STR: no commas in a label, 29 chars a row, masks before `P`, `check_status_overlap.py`.
* Board CFG: change only the bits you mean; the firmware rewrites MSX1.CFG from memory only
  on OSD option changes, so edit the file and reload the core.
