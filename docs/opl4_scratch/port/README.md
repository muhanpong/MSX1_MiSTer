# engine3 port to the board tree (sdram128) -- what the board rbf was built from

`MSX1_20261029b_engine3_105dd00.rbf` (md5 50199067285cf00945b330d7a5f0ba98):

- sources: sdram128 **2a237cb** (= 9b1cea1 sources plus the 20261029a rbf) **+ the PCM
  port patch from opl4_scratch 105dd00** (`pcm_engine3_port.patch`, made with
  `git diff b90a9d49 -- <files>` in opl4_scratch; engine3 itself is unchanged since
  5dd75e8) **+ `mk_v9968_qsf_sdram128.patch`** (the PCM_ENGINE3 option, written against
  sdram128's mk_v9968_qsf.sh, which differs from opl4_scratch's).  The name's 105dd00 is the
  opl4_scratch commit the PCM patch came from, not a commit of the tree that was built.
- build: `PCM_ENGINE3=1 REV=MSX1_V9968 SEED=25 ASM=1 tools/sdram128/compile.sh` in an rsync
  copy (`seed_sweep_launch.sh`; the copies drop compile.sh's one-job pgrep guard because the
  six seeds ran side by side, user decision 2026-10-29).  `check_timing.sh` needs the engine3
  branch that `pcm_engine3_port.patch` carries, or the map check refuses the build.
- A/B partner: `MSX1_20261029a_sdram128v9968_9b1cea1.rbf` (sdram128 releases/, engine2):
  same sources and seed, only the PCM engine differs.
- timing (seed 25): worst setup +0.061 ns (hdmi), clk_sdram +0.212, hold min 0.215; engine3
  1,290.7 ALM, device 32,429 ALM.  Seed table: DESIGN.md "P4 결과".

To redo: rsync sdram128 2a237cb (without .git/db/output_files), `git apply
pcm_engine3_port.patch mk_v9968_qsf_sdram128.patch`, then the build line above.
