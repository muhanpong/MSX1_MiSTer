#!/usr/bin/env bash
#  CPU 98h writes while a V9968 command runs (LRMMWR on the board, 2026-10-25): every byte
#  must land once.  Upstream vdp_cpu_interface latched a host request on ff_bus_ready alone,
#  so a write held during ff_busy ran on the edge busy fell and was taken again when the host
#  saw bus_ready: the byte written twice, every later address +1.  Board: LRMM 468, HMMM 2806
#  bad bytes per 22528 at R800 "None"; SUPER CAT / PRISM FLIGHT sprite and strip glitches.
#    sim/v9968_vram/run_mix.sh   OUT=<dir>
#  PASS needs: the current RTL 0 errors (during and after the command) at iogap 40 and 0, AND
#  the mutant with upstream's latch condition restored has errors (the test can fail).
set -u
export PATH=/home/linuxbrew/.linuxbrew/bin:$PATH
HERE=$(cd "$(dirname "$0")" && pwd); R=$HERE/../..
O=${OUT:-/tmp/v9968_mix.$$}; rm -rf "$O"; mkdir -p "$O/mut"
cp $R/rtl/video/v9968/*.v "$O/mut/"
python3 - "$O/mut/vdp_cpu_interface.v" <<'E'
import sys
p = sys.argv[1]; s = open(p).read()
old = "else if( bus_valid && ff_bus_ready && !ff_busy ) begin"
if old not in s: sys.exit("mutant: anchor not found in vdp_cpu_interface.v (the fix moved?)")
open(p, 'w').write(s.replace(old, "else if( bus_valid && ff_bus_ready ) begin"))
E
[ $? -eq 0 ] || { echo "RESULT FAIL: mutant"; exit 1; }
build() {  # name v9968-dir
    verilator --binary --timing -j 4 -Wno-fatal -Wno-WIDTH -Wno-UNUSED -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
        -Wno-CASEINCOMPLETE -Wno-PINCONNECTEMPTY -Wno-MULTIDRIVEN -Wno-BLKANDNBLK -Wno-UNOPTFLAT \
        -GRELEASE_PH=5 --top-module tb -Mdir "$O/$1" -o tb \
        $R/rtl/peripheral/sdram_tdm.sv $HERE/../sdram_tdm/sdram_chk.sv $R/rtl/video/v9968_link.sv \
        $2/*.v $R/rtl/video/v9968_cmdwait.sv $HERE/tb_v9968_vram.sv > "$O/$1.build.log" 2>&1
    [ -x "$O/$1/tb" ] || { echo "RESULT FAIL: build $1"; exit 1; }
}
build cur $R/rtl/video/v9968 & build mutb "$O/mut" & wait
ok=1
for b in cur mutb; do for g in 40 0; do
    "$O/$b/tb" +m128=1 +cmd=3 +demo=1 +mix=88 +mixrep=20 +iogap=$g > "$O/$b.g$g.log" 2>&1
    e1=$(grep -m1 '^MIX 88' "$O/$b.g$g.log" | sed -E 's/.*errors ([0-9]+).*/\1/')
    e2=$(grep -m1 '^MIX after' "$O/$b.g$g.log" | sed -E 's/.*errors ([0-9]+).*/\1/')
    echo "  $b iogap $g: errors during $e1, after $e2"
    [ -n "$e1" ] && [ -n "$e2" ] || { ok=0; continue; }
    if [ $b = cur ]; then [ "$e1" -eq 0 ] && [ "$e2" -eq 0 ] || ok=0
    else [ "$e1" -gt 0 ] || ok=0; fi
done; done
[ $ok -eq 1 ] && echo "RESULT PASS" || echo "RESULT FAIL"
