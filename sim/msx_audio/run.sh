#!/usr/bin/env bash
#  y8950_addon against the golden model (y8950_model.py, transcribed from openMSX).
#    sim/msx_audio/run.sh            OUT=<dir>  SEEDS="1 2 3 ..."
#  PASS needs: every seed's log equals the model's, at two sample-RAM latencies, AND every
#  mutant of the RTL differs from the model on at least one seed (the bench can fail).
set -u
export PATH=/home/linuxbrew/.linuxbrew/bin:$PATH
HERE=$(cd "$(dirname "$0")" && pwd); R=$HERE/../..
SRC=$R/rtl/peripheral/SOUND/msx_audio/y8950_addon.sv
O=${OUT:-/data/_claude/tmp/msx_audio.$$}; rm -rf "$O"; mkdir -p "$O"
SEEDS=${SEEDS:-"1 2 3 4 5 6 7 8"}

build() {  # name source
    verilator --binary --timing -j 8 -Wno-fatal -Wno-WIDTH -Wno-UNUSED -Wno-CASEINCOMPLETE \
        --top-module tb -Mdir "$O/$1" -o tb "$2" "$HERE/tb_y8950.sv" > "$O/$1.build.log" 2>&1
    [ -x "$O/$1/tb" ] || { echo "RESULT FAIL: build $1: $(grep -m1 %Error "$O/$1.build.log")"; exit 1; }
}
runall() {  # name -> number of seeds that differ
    local bad=0
    for s in $SEEDS; do
        for lat in 3 11; do
            "$O/$1/tb" +script="$O/s$s.txt" +log="$O/$1.s$s.l$lat.log" +memlat=$lat > /dev/null 2>&1
            cmp -s "$O/s$s.exp" "$O/$1.s$s.l$lat.log" || { bad=$((bad + 1)); break; }
        done
    done
    echo $bad
}

lines=0
for s in $SEEDS; do
    python3 "$HERE/y8950_model.py" gen "$s" "$O/s$s.txt"
    python3 "$HERE/y8950_model.py" run "$O/s$s.txt" "$O/s$s.exp"
    lines=$((lines + $(wc -l < "$O/s$s.exp")))
done

build rtl "$SRC"
bad=$(runall rtl)
echo "rtl: $bad seed(s) differ of $(echo $SEEDS | wc -w), $lines log lines"
fail=0; [ "$bad" = 0 ] || fail=1
[ "$bad" = 0 ] || { s=$(for s in $SEEDS; do cmp -s "$O/s$s.exp" "$O/rtl.s$s.l3.log" || { echo $s; break; }; done)
                    diff "$O/s$s.exp" "$O/rtl.s$s.l3.log" | head -6; }

#  mutants: each must be caught
mut() {  # name  old  new
    python3 - "$SRC" "$O/$1.sv" "$2" "$3" <<'P'
import sys
s = open(sys.argv[1]).read()
if s.count(sys.argv[3]) != 1: sys.exit("mutant anchor not found once: " + sys.argv[3])
open(sys.argv[2], "w").write(s.replace(sys.argv[3], sys.argv[4]))
P
    [ $? -eq 0 ] || { echo "RESULT FAIL: mutant $1 could not be built"; exit 1; }
    build "$1" "$O/$1.sv"
    local b; b=$(runall "$1")
    if [ "$b" = 0 ]; then echo "mutant $1: NOT caught"; fail=1; else echo "mutant $1: caught ($b seeds)"; fi
}
mut m_f2     "3'd5:    f2 = 8'd102;"                 "3'd5:    f2 = 8'd101;"
mut m_trunc  "sum_lev + \$signed({17'd0, sum_lev[17]})" "sum_lev"
mut m_delay  "read_delay <= 2'd2;"                    "read_delay <= 2'd1;"
mut m_eos    "st[4]   <= 1'b1;                             // last byte: EOS, pointer wraps" ""
mut m_brdy   "st[3]      <= 1'b1;                      // ready for the next byte" ""
mut m_mask   "st      <= st & (8'h87 | (~c_data & 8'h78));" ""
mut m_t2     "t2_run && t_pre == 4'd15"               "t2_run && t_pre[2:0] == 3'd7"
mut m_c0     "((c_data & 8'h0F) | 8'h30)"             "c_data"

[ $fail = 0 ] && echo "RESULT PASS" || echo "RESULT FAIL"
exit $fail
