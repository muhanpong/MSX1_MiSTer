Continue MiSTer MSX1 core work on branch `sdram128-study` (worktree
`/home/sysop/data/MiSTer_build/sdram128`, never push).  Report in Korean.

Read first: `docs/handoff_20261021_v9968_s5.md`, then `docs/plan_v9968_integration.md`
(S5 paragraph, S6–S8).

Rules (unchanged):
- Builds, pushes, rbf delivery only on the user's explicit word.  One Quartus job at a
  time; after any `project_open` (incl. `quartus_sta -t`) run `git checkout -- MSX1.qsf`.
  Only Quartus 17.0 (`/home/sysop/data/intelFPGA_lite/17.0`) on this machine.
- After editing controller RTL, regenerate `sim/fullsys/gen/` copies with `tb/mkshim*.py`.
- A sim PASS does not clear a register-to-register race: STA (field_race.tcl,
  relations.tcl), board run to decide.  Board runs only when decisive; the board is the
  mister-super-expert session's job.
- Every number with its negative control; check each injection/probe right after
  adding it.
- Benches: `PATH=/home/linuxbrew/.linuxbrew/bin:$PATH` (Verilator 5).  No `pgrep -f`.
- Write "터보" (turbo), not "턴보"; better, name the CPU and clock ("T80s 21.48 MHz").

Ask the user which to do first:
1. Quartus build + STA of `MSX1_V9968` (S7 part).
2. Stronger WAIT negative control (spacing pacer off) and a NextZ80 VPROBE run.
3. The open user decisions in handoff section 5.
