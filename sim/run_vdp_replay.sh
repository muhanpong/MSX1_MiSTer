#!/usr/bin/env bash
# Replay a recorded VDP I/O stream (openMSX) into the VDP RTL and compare VRAM
# with the recording machine's own VRAM at the same clocks.
#
#   sim/run_vdp_replay.sh <recdir>
#     <recdir>/io.txt     "cycle W|R pp vv"   (clk21m cycles from power-on, hex port/value)
#     <recdir>/snaps.txt  "k cycle regs..."   VRAM dump times
#     <recdir>/vKKK.bin   128 KB VRAM at snap k (openMSX "physical VRAM": the core's layout;
#                         "VRAM" is the CPU view and differs in SCREEN 7/8)
#   env: OUT=<dir>   MUT=<n>  negative control: flip bit 0 of the n-th 98h write of the window
#                    (MUT=-1: its last one -- an earlier one may be rewritten by a later frame:
#                    MUT=100 in w25 hit the SAT at 7600h, rewritten every frame, and read 0)
#        START=<k>   start from snapshot k: VRAM = vKKK.bin, VDP registers 0-45 from
#                    snaps.txt written through port 99h before the stream (default 1)
#        UPTO=<k>    stop after snapshot k (default: all)
#  Windows can run in parallel (one OUT each): the bench runs ~1 machine second per hour.
#
# The recording is made by the openMSX script in docs (handoff_20261016_neon.md):
# watchpoints on write_io/read_io 98h-9Bh, cycle = round(machine_info time * 21477270).
# VRAM starts from snapshot 1 (0.5 s: the A1FX BIOS has not touched the VDP yet).
set -eu
REC=${1:?recdir}
OUT=${OUT:-/tmp/vdp_replay}
RTL=rtl/video/VDP
mkdir -p "$OUT"
python3 - "$REC" "$OUT" "${MUT:-0}" "${UPTO:-999}" "${START:-1}" <<'EOF'
import sys
rec, out, mut, upto, start = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
snaps = [l.split() for l in open(rec + '/snaps.txt')]
c0 = int(snaps[start - 1][1])            # the window starts here
regs = bytes.fromhex(snaps[start - 1][2])
BASE = 4000                              # bench cycle of c0 (reset + register load before it)
n98 = 0
if mut < 0:                              # MUT=-1: the window's LAST 98h write (one that a
    c1 = int(snaps[min(upto, len(snaps)) - 1][1])   # later frame cannot overwrite)
    mut = sum(1 for l in open(rec + '/io.txt') if (lambda p: len(p) > 3 and c0 < int(p[0]) <= c1 and p[1] == 'W' and p[2] == '98')(l.split()))
with open(rec + '/io.txt') as f, open(out + '/replay.io', 'w') as o:
    if start > 1:
        t = 100
        # 0-31 and the command registers 32-45 (not 46, which starts a command): a
        # command in the window may reuse arguments set before it (w4: a DY high
        # byte from the previous window -> a 61-byte block 2400h away)
        for r in list(range(0, 46)):
            if r in (15, 17): continue   # status pointer / indirect pointer: last, below
            o.write('%d 1 1 %d\n%d 1 1 %d\n' % (t, regs[r], t + 40, 0x80 | r)); t += 80
        for r in (17, 15):
            o.write('%d 1 1 %d\n%d 1 1 %d\n' % (t, regs[r], t + 40, 0x80 | r)); t += 80
        # VRAM pointer (openMSX "VRAM pointer", 14 bits LE; R#14 restored above) in the
        # mode it was in ("VRAM access status" 1 = write), then the port-99h first-byte
        # latch ("VDP register latch status" 1 = a first byte is pending, value = "VDP
        # data latch value").  Without this a window that opens inside a 98h burst
        # sends the rest of the burst to the wrong place (w25, 2026-10-16).
        st = dict(x.split('=') for x in snaps[start - 1][3:])
        if 'ptr' in st:
            ptr = int(st['ptr'][2:4] + st['ptr'][0:2], 16) & 0x3FFF
            hi = (ptr >> 8) | (0x40 if st['acc'] == '01' else 0)
            o.write('%d 1 1 %d\n%d 1 1 %d\n' % (t, ptr & 0xFF, t + 40, hi)); t += 80
            if st['rl'] == '01':
                o.write('%d 1 1 %d\n' % (t, int(st['dl'], 16))); t += 80
            ce = int(st['st'][4:6], 16) & 1
            open(out + '/replay.ce', 'w').write('%d\n' % ce)
    for ln in f:
        p = ln.split()
        if len(p) < 4: continue
        c = int(p[0])
        if c <= c0: continue
        rw = 1 if p[1] == 'W' else 0; port = int(p[2], 16) - 0x98; v = int(p[3], 16)
        if rw and port == 0:
            n98 += 1
            if mut and n98 == mut: v ^= 1; print('MUT: 98h write #%d at cycle %d flipped' % (mut, c))
        o.write('%d %d %d %d\n' % (c - c0 + BASE, rw, port, v))
with open(out + '/replay.snap', 'w') as o:
    for sn in snaps:
        k, c = sn[0], sn[1]
        if start < int(k) <= upto: o.write('%s %d\n' % (k, int(c) - c0 + BASE))
open(out + '/replay.c0', 'w').write('%d %d\n' % (c0, BASE))
v = open(rec + '/v%03d.bin' % start, 'rb').read()
with open(out + '/replay.init', 'w') as o:
    for b in v: o.write('%02x\n' % b)
print('io events:', sum(1 for _ in open(out + '/replay.io')), ' snaps:', sum(1 for _ in open(out + '/replay.snap')))
EOF
FLAGS="--std=93c -fsynopsys -fexplicit -frelaxed-rules"
SRC="$RTL/vdp_package.vhd $RTL/vdp_slot_pack.vhd $(ls $RTL/*.vhd | grep -v -e vdp_graphic4567.vhd -e vdp_linebuf.vhd -e vdp_package.vhd -e vdp_slot_pack.vhd)"
SRC="$SRC rtl/peripheral/ram.vhd $RTL/sim/g4567_sim.vhd $RTL/sim/linebuf_sim.vhd $RTL/sim/tb_vdp_replay.vhd"
ghdl -a --workdir="$OUT" $FLAGS -Wno-hide $SRC > "$OUT/build.log" 2>&1 || { echo "BUILD FAIL"; tail -20 "$OUT/build.log"; exit 1; }
ghdl -e --workdir="$OUT" $FLAGS TB_VDP_REPLAY >> "$OUT/build.log" 2>&1 || { echo "ELAB FAIL"; tail -20 "$OUT/build.log"; exit 1; }
( cd "$OUT" && ghdl -r --workdir=. $FLAGS TB_VDP_REPLAY -gPFX=replay ${GENERICS:-} --ieee-asserts=disable > run.log 2>&1 ) || true
grep -E "snapshot|io stream done" "$OUT/run.log" | tail -3
python3 - "$REC" "$OUT" <<'EOF'
import sys, os
rec, out = sys.argv[1], sys.argv[2]
snaps = [l.split() for l in open(out + '/replay.snap')]
first = None
for k, c in snaps:
    fn = '%s/replay.v%s.hex' % (out, k)
    if not os.path.exists(fn): print('snap %s: no dump' % k); continue
    sim = bytes.fromhex(''.join(l.strip() for l in open(fn)))
    ref = open('%s/v%03d.bin' % (rec, int(k)), 'rb').read()
    d = [i for i in range(0x20000) if sim[i] != ref[i]]
    kb = sorted({i >> 10 for i in d})
    c0, base = map(int, open(out + '/replay.c0').read().split())
    print('snap %2s (%.2f s): %6d bytes differ%s' % (k, (int(c) - base + c0) / 21477270.0, len(d),
          ('  KB blocks ' + ' '.join('%03x' % x for x in kb[:12]) + (' ...' if len(kb) > 12 else '')) if d else ''))
    if d and first is None: first = (k, d[0])
ce = open(out + '/replay.ce').read().strip() if os.path.exists(out + '/replay.ce') else '?'
print('window start: VDP command executing (S#2 CE) = %s%s' % (ce, '  -- the bench cannot resume it: differences in its area are expected' if ce == '1' else ''))
print('RESULT %s' % ('PASS: VRAM equal at every snapshot' if first is None else 'FAIL: first difference at snap %s, address %05x' % first))
EOF
