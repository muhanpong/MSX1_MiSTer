#!/usr/bin/env bash
#  VDP sprites in overscan frames (R#9 LN switched past the end line, display
#  never ends) and the unchanged normal frame.  GHDL, VDP alone.
#      sim/run_vdp_overscan_sprite.sh
#  rtl/video/VDP/sim/tb_vdp_ovs.vhd / tb_vdp_norm.vhd drive the VDP; this script
#  scores their VCDs:
#    OVS  every top-border line a sprite covers is drawn from the first one, and
#         a sprite across the LN switch keeps all 16 lines (openMSX 21.0-545;
#         km224.rom's top rows were empty before 2026-10-07)
#    NORM normal frames draw exactly the visible sprite lines and nothing on a
#         border line (the 2026-08-17 ghost-collision window stays closed)
#  PASS needs both clean AND each mutant to fail OVS:
#    nowin     W_ACTIVE without the SPWINDOW_Y (display-not-ended) term
#    plusone   the Y-test target back to DOTCOUNTERYP + 1 (no SP_TARGET_Y)
#  A run takes several minutes (three VDP builds, GHDL mcode).
set -u
cd "$(dirname "$0")/.."
OUT=${OUT:-/tmp/vdp_overscan_sprite}
rm -rf "$OUT"; mkdir -p "$OUT"
RTL=rtl/video/VDP
FLAGS="--std=93c -fsynopsys -fexplicit -frelaxed-rules"
mk() {   # name, sed expression on vdp_sprite.vhd ("" = source)
   mkdir -p "$OUT/$1/src"
   cp "$RTL/vdp_sprite.vhd" "$OUT/$1/src/vdp_sprite.vhd"
   if [ -n "$2" ]; then
      sed -i -e "$2" "$OUT/$1/src/vdp_sprite.vhd"
      cmp -s "$RTL/vdp_sprite.vhd" "$OUT/$1/src/vdp_sprite.vhd" && { echo "RESULT FAIL: mutant $1 identical to source"; exit 1; }
   fi
   local W="$OUT/$1/w"; mkdir -p "$W"
   local SRC="$RTL/vdp_package.vhd $RTL/vdp_slot_pack.vhd $(ls $RTL/*.vhd | grep -v -e vdp_graphic4567.vhd -e vdp_linebuf.vhd -e vdp_package.vhd -e vdp_slot_pack.vhd -e vdp_sprite.vhd) $OUT/$1/src/vdp_sprite.vhd rtl/peripheral/ram.vhd $RTL/sim/g4567_sim.vhd $RTL/sim/linebuf_sim.vhd $RTL/sim/tb_vdp_ovs.vhd $RTL/sim/tb_vdp_norm.vhd"
   ghdl -a --workdir="$W" $FLAGS -Wno-hide $SRC > "$OUT/$1/analyse.log" 2>&1 \
      || { echo "RESULT FAIL: ghdl analyse $1"; grep -i error "$OUT/$1/analyse.log" | head -5; exit 1; }
   for t in TB_VDP_OVS TB_VDP_NORM; do ghdl -e --workdir="$W" $FLAGS $t >> "$OUT/$1/analyse.log" 2>&1 || { echo "RESULT FAIL: elaborate $1 $t"; exit 1; }; done
}
run() {  # name tb stoptime
   local tb=$2 lc; lc=$(echo "$tb" | tr 'A-Z' 'a-z')
   printf '/%s/dut/spritecolorout\n/%s/dut/predotcounter_yp\n/%s/dval\n/%s/phase\n' $lc $lc $lc $lc > "$OUT/$1/$lc.opt"
   ( cd "$OUT/$1" && ghdl -r --workdir=w $FLAGS $tb --ieee-asserts=disable --stop-time=$3 \
       --read-wave-opt=$lc.opt --vcd=$lc.vcd > $lc.log 2>&1 ) || true
}
mk eng ""
mk nowin   "s/(DOTCOUNTERYP(8) = '0' AND SPWINDOW_Y = '1' AND/(DOTCOUNTERYP(8) = '0' AND SPWINDOW_Y = 'Z' AND/"
mk plusone "s/FF_CUR_Y <= SP_TARGET_Y + ('0' \& REG_R23_VSTART_LINE);/FF_CUR_Y <= DOTCOUNTERYP + ('0' \& REG_R23_VSTART_LINE) + 1;/"
run eng TB_VDP_OVS 900ms & run eng TB_VDP_NORM 400ms & run nowin TB_VDP_OVS 900ms & run plusone TB_VDP_OVS 900ms & wait
python3 - "$OUT" <<'PY'
import sys, collections
out = sys.argv[1]
def lines_of(path):
    f = open(path); ids = {}
    for line in f:
        t = line.split()
        if t and t[0] == '$var': ids[t[3]] = t[4].lower().split('[')[0]
        if t and t[0] == '$enddefinitions': break
    frames = collections.defaultdict(list); cur = []; yp = None; seen = 0; phase = 0; dval = 0
    for line in f:
        line = line.strip()
        if not line or line[0] == '#': continue
        if line[0] in 'bB': v, i = line.split(); v = v[1:]
        else: v, i = line[0], line[1:]
        n = ids.get(i); x = int(v, 2) if set(v) <= set('01') else None
        if n == 'predotcounter_yp':
            if yp is not None and phase == 2: cur.append((yp, seen))
            yp = None if x is None else (x - 512 if x >= 256 else x); seen = 0
        elif n == 'spritecolorout':
            if x == 1: seen = 1
        elif n == 'phase':
            if phase == 2 and x != 2: frames[dval].append(cur); cur = []
            phase = x or 0
        elif n == 'dval': dval = x
    if phase == 2 and cur: frames[dval].append(cur)   # a segment still open at EOF
    return frames
def s8(v): return v - 256 if v >= 128 else v
def score_ovs(path):
    fr = lines_of(path); bad = []
    if len(fr) < 5: return ['only %d D values reached the scored phase' % len(fr)]
    for d, frames in fr.items():
        L = frames[-1]
        ks = [i for i in range(1, len(L)) if L[i][0] < 0 and L[i - 1][0] >= 0]
        if not ks: bad.append('D=%02X no top border' % d); continue
        k = ks[-1]; first = L[k][0]
        exp = set(y for y in range(s8(d) + 1, s8(d) + 17) if first <= y <= 20)
        got = set(y for y, s in L[k:k + 40] if s and first <= y <= 20)
        mid = set(y for y, s in L if s and 190 <= y <= 230)
        if exp != got: bad.append('D=%02X top border: want %s got %s' % (d, sorted(exp), sorted(got)))
        if not set(range(196, 212)) <= mid: bad.append('D=%02X LN-switch sprite: %d/16 lines' % (d, len(set(range(196, 212)) & mid)))
    return bad
def score_norm(path):
    fr = lines_of(path); bad = []
    want = {0x20: set(range(33, 49)) | set(range(101, 117)), 0x00: set(range(1, 17)) | set(range(101, 117))}
    if set(fr) != set(want): return ['D values reached: %s' % sorted(fr)]
    for d, frames in fr.items():
        for L in frames:
            got = set(y for y, s in L if s)
            if got != want[d]: bad.append('D=%02X sprite lines %s' % (d, sorted(got - want[d]) or ('missing', sorted(want[d] - got))))
    return bad
fail = 0
for name, fn, path in (('OVS ', score_ovs, 'eng/tb_vdp_ovs.vcd'), ('NORM', score_norm, 'eng/tb_vdp_norm.vcd')):
    b = fn(out + '/' + path)
    print(('PASS: ' if not b else 'FAIL: ') + name + ('' if not b else '  ' + '; '.join(b[:4])))
    fail += bool(b)
for m in ('nowin', 'plusone'):
    b = score_ovs(out + '/' + m + '/tb_vdp_ovs.vcd')
    if b: print('ok    mutant %s fails OVS (%d) e.g. %s' % (m, len(b), b[0]))
    else: print('FAIL  mutant %s passes OVS -- the bench cannot see it' % m); fail += 1
print('════════════════════════════════')
print('VDP OVERSCAN SPRITE: PASS' if fail == 0 else 'RESULT FAIL: VDP OVERSCAN SPRITE')
sys.exit(1 if fail else 0)
PY
