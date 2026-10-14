#!/usr/bin/env bash
#  Compare two +iolog files (tb_msx.sv) by VALUE ORDER, not by time: two runs whose
#  timing differs (a MoonSound wait that depends on clk_sdram) must still send the
#  VDP the same bytes in the same order.  Only VDP writes (98h-9Bh) by default;
#  ALL=1 compares every line (MoonSound too).  Up to the shorter file.
#
#    sim/fullsys/cmp_io.sh <ref.io> <cand.io>
#
#  S#2 polling (R#15=2 / R#15=0 pairs) is collapsed first: how many times a game
#  polls is timing, not picture.  Prints the first difference with its times.
#  Controls: a file against itself PASS; against a different machine's FAIL.
set -eu
REF=${1:?ref.io}; CAND=${2:?cand.io}
python3 - "$REF" "$CAND" "${ALL:-0}" <<'EOF'
import sys
def ev(fn, every):
    out = []; latch = None
    for ln in open(fn, errors='replace'):
        if not ln.endswith('\n'):
            break                         # a live file's half-written last line
        p = ln.split()
        if len(p) < 4 or p[1] not in ('W', 'R'):
            continue                      # a line cut by a stopped run
        if not every and not (p[1] == 'W' and p[2] in ('98', '99', '9a', '9b')):
            continue
        try: v = int(p[3], 16)
        except ValueError: continue
        if p[1] == 'W' and p[2] == '99':
            if latch is None: latch = (p[0], v); continue
            e = ('R%d=%02x' % (v & 0x3f, latch[1])) if (v & 0xc0) == 0x80 else ('A%02x%02x' % (v, latch[1]))
            out.append((latch[0], e)); latch = None
        else:
            out.append((p[0], '%s%s:%02x' % (p[1], p[2], v)))
    y = []                                # collapse S#2 polling
    for t, e in out:
        if e in ('R15=02', 'R15=00') and len(y) >= 1 and y[-1][1] in ('R15=02', 'R15=00'):
            y[-1] = (t, e); continue
        y.append((t, e))
    return y
every = sys.argv[3] == '1'
a, b = ev(sys.argv[1], every), ev(sys.argv[2], every)
n = min(len(a), len(b))
print('events: ref %d, cand %d (after S#2 collapse); compared %d' % (len(a), len(b), n))
if n == 0:
    print('RESULT NO VERDICT: an empty side'); sys.exit(2)
for i in range(n):
    if a[i][1] != b[i][1]:
        print('first difference at event %d (ref t=%s ms, cand t=%s ms)' % (i, a[i][0], b[i][0]))
        for j in range(max(0, i - 5), min(n, i + 8)):
            print('  %6d  ref %10s %-10s  cand %10s %-10s%s' % (j, a[j][0], a[j][1], b[j][0], b[j][1],
                  '  <==' if a[j][1] != b[j][1] else ''))
        print('RESULT FAIL'); sys.exit(1)
print('RESULT PASS: same %d events (ref to %s ms, cand to %s ms)' % (n, a[n-1][0], b[n-1][0]))
EOF
