# Handoff 2026-10-22 — V9968: three upstream bugs fixed, Geo3D, DEBUG macro

Branch **`v9968_v9990`** (renamed from `sdram128-study`), worktree
`~/data/MiSTer_build/sdram128`. Never pushed. Report to the user in Korean.
The previous handoff, `docs/handoff_20261021b_v9968_board.md`, is still valid. This file adds
what came after it.

## 1. Commits after d79a212

| Commit | What |
|---|---|
| `2e640b1` | **Sprite-hold freeze** (SUPER CAT first LRMM): `vdp_sprite_select_visible_planes.v` hold branch now clears `ff_vram_valid`. Also adds a **V9938 command-speed** OSD option (`status[127]`, "VDP command speed V9968/V9938"; `rtl/video/v9968_cmdwait.sv`; `vdp_command.v` waits from a `cmd_wait[95:0]` port). This option is for local use only and not for upstream. |
| `71cd817` | `sim/v9968_replay`: trace-time pacing (`+pace=1`) and VRAM dumps at page flips. SUPER CAT VRAM matches the oracle byte for byte. |
| `a66666e` | **km224 HUD 10-line shift**: `vdp_timing_control_ssg.v` `ff_top_line` now updates only at the frame end. Debug overlay works at 31 kHz (`V2X`). R800 VPROBE added. |
| `f8fb45d` | `compile.sh` writes `build_id.v` with today's date (OSD About "MSX1 v261022"). VPROBE OTIR phase 5. LRMM bench. |
| `7b2be1f` | `compile.sh SEED=N`. |
| `7fcf4fe` | **ASO 224 black screen**: `vdp_cpu_interface.v` interrupt flags now apply clears first and events last. Before this, a line/frame/CE event on the clock of a status read was lost. **Geo3D v2.0** on ports 9Dh/9Fh, run by a new PLL output `clk_geo` 42.954540 MHz (outclk_3). **sdram_tdm V-slot address path** shortened, after timing failures of −0.16 / −0.14 ns. |
| `2a25e51` | `MOONSOUND_DIAG` → **`DEBUG`**, which now also gates `evt_trace` and `vdp_regprobe` (their probe outputs tie to 0 when it is off). Also: upstream issue drafts. |

Six upstream V9968 files are modified, all listed in `rtl/video/v9968/ORIGIN.md`: vdp.v,
vdp_video_out.v, vdp_sprite_select_visible_planes.v, vdp_command.v,
vdp_timing_control_ssg.v, vdp_cpu_interface.v.

## 2. Builds

| rbf | Status |
|---|---|
| `MSX1_20261022a_sdram128v9968_2e640b1.rbf` (md5 040534bd…) | Board-tested by the user: Go Figure runs with the V9938 option (with V9968 a dotted pattern appears mid-screen, which is the expected fast-VDP behaviour); SUPER CAT OK; scanlines 25/50/75 OK. |
| **7fcf4fe, SEED 11** | Was in `quartus_fit` at handoff (background task, log `output_files/compile_MSX1_V9968.log`). The map step read the sources at 21:52, before the DEBUG edit (21:58), so this build is clean 7fcf4fe with MOONSOUND_DIAG; evt_trace is present in the map report. **If TIMING PASS:** copy `output_files/MSX1_V9968.rbf` to `MSX1_20261022b_sdram128v9968_7fcf4fe.rbf`, run `git checkout -- MSX1.qpf MSX1_V9968.qsf MSX1.qsf`, report, and send only when the user asks. **If it fails:** try another seed, or build with DEBUG off. DEBUG off removes evt_trace (327 ALM / 80 M10K) and regprobe (171 / 10). |

After that build: run `tools/sdram128/mk_v9968_qsf.sh` (or the next compile.sh). This
regenerates `MSX1_V9968.qsf` from `MSX1.qsf`, which now has `DEBUG=1`, and the result should
be committed. The tracked MSX1_V9968.qsf still says MOONSOUND_DIAG. That is harmless, but
it means the DEBUG code is off in a V9968 build until the qsf is regenerated.

Board checks wanted from the next rbf (only when decisive; hardware runs are expensive):
1. ASO 224: press SPACE and the game starts (it was a black screen before).
2. km224 HUD sits at the right height.
3. Debug overlay appears once at normal size at 31 kHz.
4. About shows "MSX1 v261022".
5. Geo3D demo, if the user has one.

## 3. Sim state

- **VPROBE on 7fcf4fe**: was running at handoff (`/data/_claude/tmp/msx1-handoff/vp_7fcf4fe.log`; it is written at the end). Variants: stock, turbo, mut_relph, mut_nowait, mut_noint, mut_nogeo. Expected result: stock and turbo PASS, all mutants FAIL. A pre-fix Geo3D run is in `docs/evidence_20261022/vprobe_geo3d_pre_irqfix.txt`.
- **DEBUG on/off**: fullsys compiles and runs with 0 errors both ways (`dbg_on.log`, `dbg_off.log` in the same dir).
- Standalone bench `sim/v9968_vram/tb_v9968_vram.sv`:
  - `+aso=30`: 11 of 30 FH lost unfixed, 0 fixed.
  - `+offat=N` sweep: unfixed hangs only at 29 and 125 of 128 offsets; fixed, none hang.
  - `+lnsw=207`: jump unfixed, none fixed.
- The **oracle** is buppu3 openMSX **msx2pp** (`~/data/openmsx_v9968`), harness `~/data/v9968_oracle` (see memory `v9968-oracle`).

## 4. Open

- **Upstream report**: `docs/upstream_issues_v9968_20261022.md` has 3 drafts in JP and EN against upstream 31d82b8. The user posts them; we do not post to GitHub.
- **Replay video dark frames 510–528** (10 s SUPER CAT video from sim/v9968_replay). The board video is clean. VRAM at flip 508 is byte-identical, but page 1 differs (212 rows). This is suspected to be a replay artifact. Next step: load the oracle atlas into the standalone bench and run flip 508's LRMM there.
- **mfrsd VHD tool**: made by another session in the MSX1_MiSTer checkout (`tools/mkvhd/`, `docs/mfrsd_vhd.html`, untracked). Whether to commit it is the user's call.
- **ASO 224 fix is not board-verified.**

## 5. Rules (this branch)

- Builds only on the user's word, and one Quartus job at a time.
- After a build, run `git checkout -- MSX1.qpf MSX1_V9968.qsf MSX1.qsf`. This would also revert uncommitted MSX1.qsf edits, so commit those first.
- rbf names follow `MSX1_<date><a|b|c>_<topic>_<commit>.rbf`.
- After editing ports in msx.sv: `python3 sim/fullsys/mkports.py > sim/fullsys/gen/msx_ports.svh`.
- Put large scratch output under `/data/_claude/tmp/<session>/`, never at the top of /data (it is the Silo S3 root).
- `PATH=/home/linuxbrew/.linuxbrew/bin:$PATH`.
- Never use `pkill -f` or `pgrep -f`; kill by PID.
- Every number needs a negative control.
