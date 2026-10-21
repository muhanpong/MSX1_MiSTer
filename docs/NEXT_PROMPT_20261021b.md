Continue MiSTer MSX1 core work on branch `sdram128-study` (worktree
`/home/sysop/data/MiSTer_build/sdram128`, never push).  Report in Korean.

Read first: `docs/handoff_20261021b_v9968_board.md`, then `docs/handoff_20261021_v9968_s5.md`
and `docs/plan_v9968_integration.md`.

First thing: check `output_files/compile_MSX1_V9968.log` (the 84c1b19 scanline build was
running at handoff).  If TIMING PASS, name the rbf by the rule
(`MSX1_20261021b_sdram128v9968_84c1b19.rbf`) and tell the user; send it only when asked.
If Quartus left `MSX1.qpf` / `MSX1_V9968.qsf` modified, `git checkout --` them.

Rules (unchanged):
- Builds, pushes, rbf delivery only on the user's explicit word.  One Quartus job at a
  time; after any `project_open` run `git checkout -- MSX1.qsf` (and MSX1_V9968.qsf,
  MSX1.qpf).  Only Quartus 17.0 on this machine.  V9968 build:
  `REV=MSX1_V9968 [ASM=1] tools/sdram128/compile.sh`.
- rbf name: `MSX1_<YYYYMMDD><a|b|c>_<topic>_<commit>.rbf`; rename before sending.
- After editing controller RTL, regenerate `sim/fullsys/gen/` copies (`tb/mkshim*.py`);
  after editing msx.sv ports, `python3 sim/fullsys/mkports.py > sim/fullsys/gen/msx_ports.svh`.
- Every number with its negative control; check each probe right after adding it.
- A sim PASS does not clear a register race: STA, then the board.  Board runs only when
  decisive.
- Benches: `PATH=/home/linuxbrew/.linuxbrew/bin:$PATH`.  No `pgrep -f`.
- Write "터보", or better the CPU and clock ("T80s 21.48 MHz").  If a user question about my
  wording seems odd, check my own spelling first.

Open with the user: does the Knightmare 224 HUD row flicker on the board (handoff section 4)?
Then propose the km224 fullsys line-timing sim (V9968 vs V9958 control).
