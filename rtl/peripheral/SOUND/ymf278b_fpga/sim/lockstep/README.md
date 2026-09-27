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

# Stress lockstep: the per-register-byte MLAB register file (20260926)

    ./run_stress.sh          # quick: 16 scenarios x lat {6,20} x seed 1, ~200 runs, a few minutes at P=64
    ./run_stress.sh full     # lat {1,6,20,40} x seeds {1,2,3}
    OUT=<dir> P=<jobs>       # output dir (default out_stress) and parallelism

The engine now keeps the slot registers in one 24x8 MLAB per register byte and
clears them WHILE held in reset.  The golden scenarios never write a register
near the moment that slot is read, so they cannot see a mistake there.  (The
matrix above had 11,180 slot writes: 0 on the edge of a dispatch read of that
slot, 2 within 4 cycles, 0 colliding with a header backfill.)  `+stress=1` adds
random writes aimed at exactly those moments:

  A  the edge on which dispatch reads cur_slot, same slot
  B  the next slot to dispatch, a few cycles ahead
  C  the cycle hf_store_now is high, fields 5..9, same slot / another slot
  E  (with +reset_every) the first 40 cycles after each warm reset, during playback
  plus wave + fast-attack + key-on writes so slots are playing and headers load

Other plusargs: `+seed=N`, `+reset_len=N` (default 256: hardware holds reset_ms
>= 252 clk), `+reset_every=N` (repeat the warm reset). Power-on reset is 300 cycles.
The comparison covers every output the build uses; the 19 `dbg_slot0_*`,
`dbg_slot5_wave` and `dbg_slot23_wave` ports are excluded because the engine ties
them off (they were unconnected in msx.sv, and reading them is what kept
ram_header/ram_dyn out of MLAB -- Quartus warning 10999).

PASS requires the engine clean in every run, every mutant failing in every run,
reset_len=8 failing, and every counted event > 0.  Mutants (generated from the
engine, one change each):

  mut_rd1     register-file read one cycle late
  mut_nopend  a CPU write that collides with a backfill to another slot is dropped
  mut_sw23    reset sweep wraps at 22, slot 23 never cleared
  mut_noclr   reset sweep writes nothing

Result 20260926 (quick): engine 32/32 stress + 32/32 stress-with-reset, 0 mismatches;
each mutant 32/32 fail; reset_len=8 fails.  Events: same-edge write 9,381;
dispatch of an ACTIVE slot 1-4 cycles after a write 10,751; deferred CPU write
15,959; same-slot backfill collision 16,680; other-slot 20,542; header
store->stall-read 15,098; resets with slots active 638; writes after release 6,452.
A run that shows 0 for any of these has stopped testing what it claims to.
