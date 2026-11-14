#!/usr/bin/env python3
"""Compare the per-enable chip outputs of two clockings of y8960_cart.

SSG, OPL2/ADPCM and OPM must be identical.  The OPLL and SCC wrappers pass a write
to the chip through a handshake that takes a few master clocks, so a write may land
one chip clock (279 ns) earlier or later.  The chip takes a register up when it next
serves that channel, so the slip can move the effect by one output sample (72 chip
clocks for the OPLL).  For those two a difference is accepted when the other stream
has the same value within the slip window.
"""
import sys
NAMES = ['ssg_l', 'ssg_r', 'opll_l', 'opll_r', 'opl2_l', 'opl2_r', 'scc_l', 'scc_r', 'opm_l', 'opm_r']
SLIP = {'opll_l': 74, 'opll_r': 74, 'scc_l': 2, 'scc_r': 2}
a = [l.split() for l in open(sys.argv[1])]
b = [l.split() for l in open(sys.argv[2])]
ok = len(a) == len(b)
if not ok:
    print('length %d != %d' % (len(a), len(b)))
n = min(len(a), len(b))
for c, name in enumerate(NAMES):
    diff = bad = 0
    for i in range(n):
        if a[i][c] != b[i][c]:
            diff += 1
            v = b[i][c]
            k = SLIP.get(name, -1)
            if not any(0 <= j < n and a[j][c] == v for j in range(i - k, i + k + 1)):
                bad += 1
    state = 'identical' if diff == 0 else ('%d samples differ, all within %d chip clocks' % (diff, SLIP[name]) if bad == 0
                                           else '%d samples differ, %d NOT explained by a slip' % (diff, bad))
    print('%-7s %s' % (name, state))
    ok = ok and bad == 0
print('CLOCKING PASS (%d samples)' % n if ok else 'CLOCKING FAIL')
sys.exit(0 if ok else 1)
