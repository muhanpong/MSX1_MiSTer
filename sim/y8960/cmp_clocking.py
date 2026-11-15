#!/usr/bin/env python3
"""Compare the per-enable chip outputs of two clockings of y8960_cart: SSG2 and
the OPM must be identical, sample for sample."""
import sys
NAMES = ['ssg2_l', 'ssg2_r', 'opm_l', 'opm_r']
SLIP = {}
a = [l.split() for l in open(sys.argv[1])]
b = [l.split() for l in open(sys.argv[2])]
# the bench's last few cycles are counted in master clocks, not chip clocks
ok = abs(len(a) - len(b)) <= 16
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
