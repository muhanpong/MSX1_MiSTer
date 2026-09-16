# PCM engine lockstep (20260917)

`ymf278_pcm_engine2_ref.sv` is the engine as it was before the MLAB change (flop arrays).
`tb_lockstep_pcm.sv` drives it and the current engine with identical stimulus and compares
all 39 outputs every cycle (golden only checks samples +-1 LSB, +-2 frames).
`+reset_at=<cycle>` inserts a warm reset mid-run.

Build: from this dir
  R=../..; iverilog -g2012 -o ls.vvp $R/rtl/pcm/ymf278_pcm_alu.sv $R/rtl/pcm/ymf278_pcm_eg_step.sv \
     $R/rtl/pcm/ymf278_pcm_engine2.sv ymf278_pcm_engine2_ref.sv tb_lockstep_pcm.sv
  (cd ../golden && python3 gen_pcm_testdata.py)
Run: ./run_lockstep.sh ls.vvp out        # 16 scenarios x lat {1,6,20,40}
     ./run_neg.sh                        # needs mut_*.vvp built the same way from mut_*.sv; all mutants must FAIL

Result 20260917: 64/64 mismatches=0, header store->stall-read path hit 248x; 4 warm-reset runs 0;
mutants m1 (header write 1 cycle late) 11497/1, m2 (no warm-reset mask) 670112/602247, m3 (dbg shadow late) 1.
