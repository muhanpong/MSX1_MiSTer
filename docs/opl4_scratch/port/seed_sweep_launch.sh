#!/usr/bin/env bash
# engine3 seed sweep: sdram128 HEAD + opl4_scratch's PCM port patch, one full copy per seed,
# all started together (user decision 2026-10-29: B); seeds as msx1-handoff's 9b1cea1 sweep
set -u
B=/data/_claude/tmp/opl4-scratch/p4/seeds6; W=/home/sysop/data/MiSTer_build/sdram128
H=$(git -C $W log -1 --format=%h)
for s in 18 22 23 24 25 26; do
  d=$B/s$s; rm -rf $d; mkdir -p $d
  rsync -a --exclude .git --exclude db --exclude incremental_db --exclude output_files --exclude sim/fullsys/gen --exclude releases $W/ $d/
  ( cd $d && git init -q && git add -A >/dev/null 2>&1 && git -c user.name=muhanpong -c user.email=muhanpong@naver.com commit -qm "$H base" \
    && git apply $B/port.patch && sed -i '/^echo "MSX1_V9968.qsf written/e cat '"$B"'/mk_v9968_qsf.add' tools/sdram128/mk_v9968_qsf.sh \
    && sed -i "/^pgrep -x/d" tools/sdram128/compile.sh \
    && git add -A >/dev/null 2>&1 && git -c user.name=muhanpong -c user.email=muhanpong@naver.com commit -qm "$H + opl4_scratch engine3 port, seed $s" ) || { echo "prep s$s FAILED"; exit 1; }
done
for s in 18 22 23 24 25 26; do
  ( cd $B/s$s && PCM_ENGINE3=1 REV=MSX1_V9968 SEED=$s ASM=1 tools/sdram128/compile.sh > $B/s$s.log 2>&1 ) &
done
wait
REV=MSX1_V9968 $W/tools/sdram128/seed_table.sh $B/s* > $B/table.txt 2>&1
echo done
