#!/usr/bin/env bash
#  srg320 YMF278B PCM engine vs the openMSX oracle, on the ../golden scenarios.
#
#      ./run_srg_golden.sh            # srg320 + ours vs ref278 (pure openMSX)
#                                     #   and vs golden_pcm.py
#      SKIP_OURS=1 ./run_srg_golden.sh   # do not rerun our engine
#      SKIP_NEG=1  ./run_srg_golden.sh   # skip the negative controls
#
#  Build products go to $WORK (default: the session scratch dir below); the
#  only files written outside it are ../golden/out/<sc>_vl.txt and
#  ../golden/out/<sc>_gold.txt, which ../golden/run_pcm_golden_vl.sh writes
#  when it is run for our engine (and which it rewrites on every run anyway).
#  NOTE: that script also reruns gen_pcm_testdata.py, which rewrites
#  ../golden/mem.* and sc_*.txt with identical content.
#
#  Nothing in this script is a pass/fail gate: it prints measurements.
set -u
cd "$(dirname "$0")"
H=$(pwd)
G=$H/../golden
WORK=${WORK:-/tmp/claude-1000/-home-sysop-data-MiSTer-build-MSX1-MiSTer/ec0a1005-959c-4dce-b18e-143d394e77c6/scratchpad/golden_srg}
export PATH=/home/linuxbrew/.linuxbrew/bin:$PATH
export PYTHONDONTWRITEBYTECODE=1
mkdir -p "$WORK/src" "$WORK/out"
SCEN="sc_single8 sc_square16 sc_tri12_loop sc_multi sc_lfo sc_pitchbend sc_wavehi sc_odd16"
frames_of() { case $1 in sc_tri12_loop|sc_pitchbend) echo 1000;; sc_multi) echo 1200;; sc_lfo) echo 1500;; sc_wavehi) echo 800;; *) echo 900;; esac; }

#  YMF278B.sv defines SIM itself inside a synopsys translate_off comment.
#  Verilator ignores that pragma, so SIM gets defined and the file's own SIM
#  RAM branch is compiled -- which is illegal (procedural assignment to the
#  output net Q, PROCASSWIRE).  Build from a copy with that ONE line removed so
#  the altsyncram branch + altsyncram_sim.sv is used.  The diff is checked.
sed 's/^`define SIM$//' YMF278B.sv > "$WORK/src/YMF278B_nosim.sv"
nd=$(diff YMF278B.sv "$WORK/src/YMF278B_nosim.sv" | grep -c '^[<>]')
[ "$nd" = 2 ] || { echo "FATAL: SIM-strip changed $nd lines, expected 1"; exit 1; }

VLFLAGS="--binary --timing -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD --top-module tb_srg"
build() {   # build <name> <package> <YMF278B source> [extra flags]
    local name=$1 pkg=$2 src=$3; shift 3
    rm -rf "$WORK/vl_$name"
    verilator $VLFLAGS -o vsrg -Mdir "$WORK/vl_$name" "$@" \
        "$pkg" "$src" altsyncram_sim.sv tb_srg.sv > "$WORK/vl_$name.log" 2>&1
    [ -x "$WORK/vl_$name/vsrg" ] || { echo "FATAL: build $name failed"; grep %Error "$WORK/vl_$name.log" | head; exit 1; }
}
build srg YMF278B_pkg.sv "$WORK/src/YMF278B_nosim.sv"
build srg_rdwnew YMF278B_pkg.sv "$WORK/src/YMF278B_nosim.sv" +define+RDW_NEW

#  srg_fix: NOT the DUT.  A copy of the package with the four expression-
#  semantics bugs repaired: three signed*unsigned multiplications made signed
#  (tb_signedness.sv shows what they compute as written) and the right-pan
#  ~PAN[2:0] that is inverted after widening to 10 bits.  Separates "srg320 has a bug" from "srg320's
#  architecture differs from openMSX".  Nothing else is changed.
python3 - YMF278B_pkg.sv "$WORK/src/YMF278B_pkg_fix.sv" <<'PYEOF'
import sys
s = open(sys.argv[1]).read()
rep = [("TEMP = $signed(PLFO_WAVE) * F[10:4];", "TEMP = $signed(PLFO_WAVE) * $signed({1'b0,F[10:4]});"),
       ("TEMP0 = $signed(WAVE0) * PHASE_NEG;", "TEMP0 = $signed(WAVE0) * $signed({1'b0,PHASE_NEG});"),
       ("TEMP1 = $signed(WAVE1) * PHASE;", "TEMP1 = $signed(WAVE1) * $signed({1'b0,PHASE});"),
       ("MULT = $signed(WAVE) * ({2'b01,~LEVEL[5:0]});", "MULT = $signed(WAVE) * $signed({2'b01,~LEVEL[5:0]});"),
       # ~PAN[2:0] is widened to 10 bits BEFORE the inversion (context width)
       ("(10'h020 * ~PAN[2:0])", "(10'h020 * {7'b0000000,~PAN[2:0]})")]
for a, b in rep:
    assert s.count(a) == 1, a
    s = s.replace(a, b)
open(sys.argv[2], 'w').write(s)
PYEOF
build srg_fix "$WORK/src/YMF278B_pkg_fix.sv" "$WORK/src/YMF278B_nosim.sv"

#  the package functions as written vs as intended, in both simulators
rm -rf "$WORK/vl_sgn"
verilator --binary -Wno-fatal -Wno-lint -Wno-style --top-module tb_signedness -Mdir "$WORK/vl_sgn" -o v \
    YMF278B_pkg.sv tb_signedness.sv > "$WORK/vl_sgn.log" 2>&1
echo "=== signedness unit check (Verilator, package as written) ==="
"$WORK/vl_sgn/v" | grep -v '^-'
if command -v iverilog > /dev/null; then
    echo "=== signedness unit check (iverilog, verbatim function copies) ==="
    iverilog -g2012 -DCOPY -o "$WORK/sgn.vvp" tb_signedness.sv && vvp -n "$WORK/sgn.vvp" | grep -v finish
fi

g++ -O2 -std=c++17 -o "$WORK/ref278" "$G/ref278.cpp" 2> /dev/null || { echo "FATAL: ref278 build"; exit 1; }

cmp3() {   # cmp3 <test> <ref> <name>  -> compare_srg + compare_pcm on raw and shifted
    python3 compare_srg.py "$1" "$2" "$3" --shifted "$1.shift"
    python3 "$G/compare_pcm.py" "$1" "$2" "$3:cmp_pcm(raw)" | head -1
    python3 "$G/compare_pcm.py" "$1.shift" "$2" "$3:cmp_pcm(lag-aligned)" | head -1
}

echo "=== references ==="
for sc in $SCEN; do
    fr=$(frames_of $sc)
    "$WORK/ref278" "$G/mem.bin" "$G/$sc.txt" $fr "$WORK/out/${sc}_ref.txt" 2> /dev/null
    python3 "$G/golden_pcm.py" "$G/$sc.txt" "$G/mem.bin" $fr "$WORK/out/${sc}_gold.txt" > /dev/null
    python3 "$G/golden_pcm_omsx.py" "$G/$sc.txt" "$G/mem.bin" $fr "$WORK/out/${sc}_omsx.txt" > /dev/null
    python3 compare_srg.py "$WORK/out/${sc}_gold.txt" "$WORK/out/${sc}_ref.txt" "$sc gold_pcm.py vs ref278" --maxlag 2 | sed -n 2p
    python3 compare_srg.py "$WORK/out/${sc}_omsx.txt" "$WORK/out/${sc}_ref.txt" "$sc gold_pcm_omsx.py vs ref278" --maxlag 2 | sed -n 2p
done

echo "=== srg320 vs ref278 (pure openMSX) and vs golden_pcm.py ==="
for sc in $SCEN; do
    fr=$(frames_of $sc)
    run() { "$WORK/vl_$1/vsrg" +script="$G/$sc.txt" +mem="$G/mem.hex" +frames=$fr "${@:3}" \
                +out="$WORK/out/${sc}_$2.txt" > "$WORK/out/${sc}_$2.log" 2>&1; }
    run srg        srg
    run srg_rdwnew srg_rdwnew
    run srg        srg_memlat  +memlat=1
    run srg        srg_ld      +ldwait=1
    run srg_fix    srg_fix
    run srg_fix    srg_fix_ld  +ldwait=1
    echo "--- $sc ($fr frames)"
    cmp -s "$WORK/out/${sc}_srg.txt" "$WORK/out/${sc}_srg_rdwnew.txt" \
        && echo "[$sc] TB check: RAM read-during-write old/new data -> identical streams" \
        || echo "[$sc] TB check: RAM read-during-write old/new data -> STREAMS DIFFER"
    cmp -s "$WORK/out/${sc}_srg.txt" "$WORK/out/${sc}_srg_memlat.txt" \
        && echo "[$sc] TB check: wave memory latency 0/1 clk -> identical streams" \
        || echo "[$sc] TB check: wave memory latency 0/1 clk -> STREAMS DIFFER"
    grep -h "LD status polls" "$WORK/out/${sc}_srg_ld.log" | sed "s/^/[$sc] ldwait: /"
    cmp3 "$WORK/out/${sc}_srg.txt" "$WORK/out/${sc}_ref.txt" "$sc srg/ref278"
    python3 compare_srg.py "$WORK/out/${sc}_srg.txt"        "$WORK/out/${sc}_gold.txt" "$sc srg/gold_pcm"
    python3 compare_srg.py "$WORK/out/${sc}_srg_ld.txt"     "$WORK/out/${sc}_ref.txt"  "$sc srg+ldwait/ref278"
    python3 compare_srg.py "$WORK/out/${sc}_srg_fix.txt"    "$WORK/out/${sc}_ref.txt"  "$sc srg_fix/ref278"
    python3 compare_srg.py "$WORK/out/${sc}_srg_fix_ld.txt" "$WORK/out/${sc}_ref.txt"  "$sc srg_fix+ldwait/ref278"
done

if [ -z "${SKIP_OURS:-}" ]; then
    echo "=== our engine (ymf278_pcm_engine2) ==="
    OUT="$WORK/vgold" "$G/run_pcm_golden_vl.sh" | grep -E '^\[|RESULT|GOLDEN'
fi
echo "=== our engine vs ref278 ==="
for sc in $SCEN; do
    [ -f "$G/out/${sc}_vl.txt" ] || { echo "[$sc] no ../golden/out/${sc}_vl.txt"; continue; }
    cp "$G/out/${sc}_vl.txt" "$WORK/out/${sc}_ours.txt"
    cmp3 "$WORK/out/${sc}_ours.txt" "$WORK/out/${sc}_ref.txt" "$sc ours/ref278"
done

echo "=== EG counter phase (sc_wavehi, srg_fix) ==="
#  For effective rates below 0x30 srg320 indexes EncIncTbl with SCNT[14:12]
#  (EnvInc default branch, CNT[13:11] of SCNT[18:1]) whatever the rate, so the
#  increment pattern changes only every 4096 samples.  Wave 300's AR=10 row
#  starts with 0: whether the attack moves at all in the first 93 ms depends
#  on how long the chip has been running.  Same script, chip idle for 0 or
#  4096 samples first:
for idle in 0 4096; do
    "$WORK/vl_srg_fix/vsrg" +script="$G/sc_wavehi.txt" +mem="$G/mem.hex" +frames=800 +idle=$idle \
        +out="$WORK/out/sc_wavehi_srg_fix_idle$idle.txt" > /dev/null 2>&1
    python3 compare_srg.py "$WORK/out/sc_wavehi_srg_fix_idle$idle.txt" "$WORK/out/sc_wavehi_ref.txt" "sc_wavehi srg_fix idle=$idle" | sed -n 4p
done

echo "=== CPU wave-memory writes (sc_memhit) ==="
#  sc_memhit writes regs 03h-06h WITHOUT setting reg 02h bit0.  openMSX
#  (YMF278.cc writeReg case 0x06) and srg320 both ignore reg-06h writes unless
#  bit0 (memory access mode) is set; golden_pcm_omsx.py and our engine do not
#  check it.  So srg320 gets a copy with "02 01" before and "02 00" after each
#  burst.  ref278.cpp has no reg-06h support, so the reference here is
#  golden_pcm_omsx.py (flat writable memory).  srg320 stops fetching wave data
#  while bit0 is set (MEM_START && WD_READ && !MEMMODE[0]).
python3 - "$G/sc_memhit.txt" "$WORK/out/sc_memhit_mode.txt" "$WORK/out/memhit_expect.txt" <<'PYEOF'
import sys
lines = [l.split() for l in open(sys.argv[1]) if l.strip()]
out, exp, cur, adr = [], [], None, 0
for f in lines:
    fr, ad, da = int(f[0]), int(f[1], 16), int(f[2], 16)
    if ad in (3, 4, 5, 6):
        if cur != fr:
            if cur is not None:
                out.append(f"{cur} 02 00 1075")
            out.append(f"{fr} 02 01 990"); cur = fr
        if ad == 3: adr = (adr & 0xFFFF) | ((da & 0x3F) << 16)
        if ad == 4: adr = (adr & 0xFF00FF) | (da << 8)
        if ad == 5: adr = (adr & 0xFFFF00) | da
        if ad == 6: exp.append(f"{adr:06x} {da:02x}"); adr += 1
    out.append(' '.join(f))
if cur is not None:
    out.append(f"{cur} 02 00 1075")
open(sys.argv[2], 'w').write('\n'.join(out) + '\n')
open(sys.argv[3], 'w').write('\n'.join(exp) + '\n')
PYEOF
python3 "$G/golden_pcm_omsx.py" "$G/sc_memhit.txt" "$G/mem.bin" 400 "$WORK/out/sc_memhit_omsx.txt" > /dev/null
for v in srg srg_fix; do
    "$WORK/vl_$v/vsrg" +script="$WORK/out/sc_memhit_mode.txt" +mem="$G/mem.hex" +frames=400 \
        +out="$WORK/out/sc_memhit_$v.txt" > "$WORK/out/sc_memhit_$v.log" 2>&1
    grep '^MEMWR' "$WORK/out/sc_memhit_$v.log" | awk '{print $2, $3}' > "$WORK/out/memhit_$v.got"
    echo "[sc_memhit $v] memory writes: expected $(wc -l < "$WORK/out/memhit_expect.txt"), got $(wc -l < "$WORK/out/memhit_$v.got"), address/data mismatches: $(diff "$WORK/out/memhit_expect.txt" "$WORK/out/memhit_$v.got" | grep -c '^>')"
    diff "$WORK/out/memhit_expect.txt" "$WORK/out/memhit_$v.got" | head -6 | sed "s/^/[sc_memhit $v]   /"
    python3 compare_srg.py "$WORK/out/sc_memhit_$v.txt" "$WORK/out/sc_memhit_omsx.txt" "sc_memhit $v/omsx" | sed -n '2p;4p;5p'
done
if [ -x "$WORK/vgold/vgold" ]; then
    "$WORK/vgold/vgold" +script="$G/sc_memhit.txt" +mem="$G/mem.hex" +frames=400 \
        +out="$WORK/out/sc_memhit_ours.txt" > /dev/null 2>&1
    python3 compare_srg.py "$WORK/out/sc_memhit_ours.txt" "$WORK/out/sc_memhit_omsx.txt" "sc_memhit ours/omsx" | sed -n '2p;4p;5p'
fi

[ -n "${SKIP_NEG:-}" ] || {
echo "=== negative controls ==="
#  The mutants are made on top of srg_fix (the bug-patched copy), the
#  better-scoring baseline, and run with +ldwait=1 (without it srg320's
#  header load overwrites the LFO/AM writes of sc_lfo, so N3 would not be
#  exercised at all).  Each is compared with ref278 AND directly with the
#  srg_fix+ldwait stream; compare the ref278 numbers with srg_fix_ld's.
#  N1: interpolation disabled (OP5.WD takes the current word, no blend with
#      the previous one).
#  N2: one envelope-increment table row changed (EncIncTbl row for effective
#      rate 0x10 = RR 4 with RC 15, the release rate of every header in
#      mem.bin: 0,1,0,1,.. -> 4,4,..).
sed 's/OP5.WD <= Interpolate(PWD, OP4.WD, OP4.MODF);/OP5.WD <= OP4.WD;/' \
    "$WORK/src/YMF278B_nosim.sv" > "$WORK/src/YMF278B_mut_interp.sv"
cmp -s "$WORK/src/YMF278B_nosim.sv" "$WORK/src/YMF278B_mut_interp.sv" && { echo "FATAL: interp mutant unchanged"; exit 1; }
build mut_interp "$WORK/src/YMF278B_pkg_fix.sv" "$WORK/src/YMF278B_mut_interp.sv"
python3 - "$WORK/src/YMF278B_pkg_fix.sv" "$WORK/src/YMF278B_pkg_mut_env.sv" <<'PYEOF'
import sys
s = open(sys.argv[1]).read()
old = "4'h0,4'h1,4'h0,4'h1,4'h0,4'h1,4'h0,4'h1,//10"
new = "4'h4,4'h4,4'h4,4'h4,4'h4,4'h4,4'h4,4'h4,//10"
assert s.count(old) == 1, "anchor"
open(sys.argv[2], 'w').write(s.replace(old, new))
PYEOF
build mut_env "$WORK/src/YMF278B_pkg_mut_env.sv" "$WORK/src/YMF278B_nosim.sv"
#  N3: tremolo depth halved (AMCalc result >> 1) -- exercised by sc_lfo only.
python3 - "$WORK/src/YMF278B_pkg_fix.sv" "$WORK/src/YMF278B_pkg_mut_am.sv" <<'PYEOF'
import sys
s = open(sys.argv[1]).read()
old = "return AM ? ((DATA&8'hFE)>>(~AM)) : '0;"
assert s.count(old) == 1, "anchor"
open(sys.argv[2], 'w').write(s.replace(old, "return AM ? (((DATA&8'hFE)>>(~AM))>>1) : '0;"))
PYEOF
build mut_am "$WORK/src/YMF278B_pkg_mut_am.sv" "$WORK/src/YMF278B_nosim.sv"
for sc in $SCEN; do
    fr=$(frames_of $sc)
    for m in mut_interp mut_env mut_am; do
        "$WORK/vl_$m/vsrg" +script="$G/$sc.txt" +mem="$G/mem.hex" +frames=$fr +ldwait=1 \
            +out="$WORK/out/${sc}_$m.txt" > /dev/null 2>&1
        python3 compare_srg.py "$WORK/out/${sc}_$m.txt" "$WORK/out/${sc}_ref.txt" "$sc $m/ref278" | sed -n '2p;4p;5p'
        python3 compare_srg.py "$WORK/out/${sc}_$m.txt" "$WORK/out/${sc}_srg_fix_ld.txt" "$sc $m/srg_fix_ld" --minlag 0 --maxlag 0 | sed -n 1p
    done
done
#  N4: garbage / misaligned streams through compare_pcm.py and compare_srg.py
sc=sc_square16
python3 - "$WORK/out/${sc}_ref.txt" "$WORK/out/neg_" <<'EOF'
import sys, random
ref = [l.split() for l in open(sys.argv[1]) if l.strip()]
p = sys.argv[2]
random.seed(1)
open(p+'shift7.txt','w').write("0 0\n" * 7 + ''.join(f"{a} {b}\n" for a,b in ref[:-7]))  # 7-sample delay > compare_pcm's +-2 window
open(p+'noise.txt','w').write(''.join(f"{random.randint(-20000,20000)} {random.randint(-20000,20000)}\n" for _ in ref))
open(p+'halfgain.txt','w').write(''.join(f"{int(a)//2} {int(b)//2}\n" for a,b in ref))
open(p+'self.txt','w').write(''.join(f"{a} {b}\n" for a,b in ref))
EOF
for n in self shift7 noise halfgain; do
    python3 "$G/compare_pcm.py" "$WORK/out/neg_$n.txt" "$WORK/out/${sc}_ref.txt" "neg_$n cmp_pcm" | head -1
    python3 compare_srg.py "$WORK/out/neg_$n.txt" "$WORK/out/${sc}_ref.txt" "neg_$n" | sed -n 2,3p
done
}

echo "=== summary table (lag-aligned) ==="
python3 summarize.py "$WORK/out" srg,srg_ld,srg_fix,srg_fix_ld,ours ref,gold $SCEN | tee "$WORK/summary.md"
