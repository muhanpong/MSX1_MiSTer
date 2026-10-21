# Handoff 2026-10-21 (b) — V9968 build on the board; the 224-line question

Branch `sdram128-study` (worktree `~/data/MiSTer_build/sdram128`), never pushed.
Earlier today: `docs/handoff_20261021_v9968_s5.md` (S5 structure, VPROBE, decisions) — still valid;
this file adds what happened after it.

## 1. Commits after f284c4e

| Commit | What |
|---|---|
| `75c48e2` | `pll_v9968` inner instance renamed `pll_inst` (MSX1.sdc names `emu|pll|pll_inst|...`); `compile.sh` / `check_timing.sh` / `sta_paths.tcl` take `REV=MSX1_V9968`; `ASM=1` makes the rbf only after TIMING PASS; the timing verdict now covers **every clock, setup and hold** (it judged clk_sdram setup alone). Negative control: the 20261019b report with one hold slack made negative -> FAIL. |
| `18e0496` | `v9968_bus`: CPU-side inputs registered on clk21m first (75c48e2 failed STA: clk21m -> clk_vdp -3.83 ns, T80 FETCH -> port decode -> clk_vdp registers). `MSX1.sdc`: false path to `debug_overlay` synchroniser first stages (CLK_VIDEO = clk_vdp shares the PLL; -0.01 ns). |
| `84c1b19` | V9968 scanlines from OSD "Scandoubler Fx": None/HQ2x -> off, CRT 25/50/75% -> dim-line gain 96/64/32 of 128. Upstream tied `has_scanline` to 1; **two upstream files modified** (`vdp.v`, `vdp_video_out.v`), listed in `rtl/video/v9968/ORIGIN.md`; `md5sum -c ORIGIN.md5` flags exactly those two. |

Evidence: `docs/evidence_20261020/v9968_s5c_board_build.txt`, `compile_MSX1_V9968_18e0496.txt`.

## 2. Builds

| rbf | Commit | Timing | Status |
|---|---|---|---|
| `output_files/MSX1_20261021a_sdram128v9968_18e0496.rbf` (md5 30feef79c44275cbd25f124888732013) | 18e0496 | PASS all clocks: clk_vdp setup **+0.029**, clk_sdram +0.052, clk21m +0.502, hold min +0.246; ALM 31,148 (74 %), RAM blocks 289 | **sent to the user, on the board** |
| `84c1b19` (scanlines) | 84c1b19 | build was running at handoff (tmux `msx1:q9968c`, map PASS) | **check `output_files/compile_MSX1_V9968.log`**; if TIMING PASS, copy `output_files/MSX1_V9968.rbf` to `MSX1_20261021b_sdram128v9968_84c1b19.rbf` and send only when the user asks |

Slack is thin (+0.029 / +0.052): small RTL edits can fail timing again; Geo3D will need seeds or path work.
rbf naming rule: `MSX1_<YYYYMMDD><a|b|c>_<topic>_<commit>.rbf` (memory: build-delivery).

## 3. Sim state

- VPROBE suite on 18e0496: **RESULT PASS** (stock PASS, T80s 21.48 MHz PASS, RELEASE_PH 6 / NOWAIT / NOINT all FAIL as wanted). Late stock reads 0 after the clk21m stage.
- Scanline levels (sim/v9968_vram `+scan=N`): dim/bright 1.000 / 0.748 / 0.498 / 0.246 for 0..3.
- 84c1b19 not run through VPROBE (video-only change; `sim/fullsys/tb_msx.sv` drives `v99_scanline = 0`).

## 4. Open: the 224-line overscan on the board (Knightmare 224)

User board captures of `km224.rom` (~/data/knightmare), V9968 rbf 18e0496:
- MiSTer framework screenshot (1440x1080): picture only VDP lines ~0–210, black above and below, **no HUD row** (SCORE / HISCORE / REST / STAGE).
- OBS capture of HDMI (1920x1080): same scale and positions (checked: "?" block and "CHANGE: 01" at the same y; 5 px per dot, 4.5 px per VDP line), but the **HUD row is there** (to ~line 228, cut by the 1080 edge) and the top border area is filled with picture.

Reading: both come from the same ascal buffer and the V9968 build's DE is the same 480-line window every frame, so the two captures are **different frames** — the overscan appears to work in some frames and not others. KM224 switches LN=0 on a line IRQ at 194 (end line 211 must be skipped), and BL off at 224 / on at 0. In V9968 (`vdp_timing_control_ssg.v`) the active area ends on `screen_pos_y == (212 mode ? 211 : 191)` (equality), so the trick is supported in principle — a late write would end the display at 211.

Asked the user, no answer yet: **does the HUD row flicker on the board?**

Next (decisive sim): fullsys V9968 build with km224.rom, per frame log the line-IRQ line, the line each R#9/R#23/R#1 write reaches the V9968, and the line the V9968 ends the display; same run on the V9958 build as control. Problem: the boot to the game screen is long in fullsys — find a shortcut (preload a save state? start the probe at the game's engine?) before running.

Also from the code reading, unverified: at 50 Hz the fixed 480-line output window (`v_en_start` 14) with `c_top_50hz_pos212` = 52 may cut the bottom of a 212-line screen. Measure before believing it.

## 5. Other open items (unchanged from handoff_20261021_v9968_s5.md)

NOWAIT control is thin; NextZ80 not run through VPROBE; ESE build only compiled + 1 ms after the msx.sv edits;
`sim/sdram_tdm` regression not re-run after `tdm_run`; `field_race.tcl` / `relations.tcl` still open MSX1 only
(add a revision argument and run them on MSX1_V9968 — sim cannot clear register races); BIOS logo boot and openMSX
VRAM comparison (S6); Geo3D (sources in upstream 7820668, ~3.1k ALM standalone, PLL 42.95 MHz or clk_vdp/2 enable);
user decisions: MSX1 colours = MSX2 standard palette, OSD items without effect (border, VDP ID), 32 MB upload limit.
