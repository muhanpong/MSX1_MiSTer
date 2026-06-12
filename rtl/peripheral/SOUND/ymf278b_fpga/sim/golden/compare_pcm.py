#!/usr/bin/env python3
"""Compare RTL vs golden PCM streams.  Exact-match goal with a tiny rounding
allowance (|d|<=1 LSB counted separately); prints first hard mismatches."""
import sys

def load(p):
    out = []
    for ln in open(p):
        a = ln.split()
        if len(a) == 2:
            out.append((int(a[0]), int(a[1])))
    return out

rtl, gold, name = load(sys.argv[1]), load(sys.argv[2]), sys.argv[3]

# auto-detect a small frame lag (alignment artifact of TB write timing)
def badness(lag):
    n = min(len(rtl), len(gold)) - abs(lag)
    b = 0
    for i in range(n):
        r = rtl[i + max(lag, 0)]
        g = gold[i + max(-lag, 0)]
        b += (abs(r[0]-g[0]) > 1) + (abs(r[1]-g[1]) > 1)
    return b
lags = {l: badness(l) for l in (-2, -1, 0, 1, 2)}
lag = min(lags, key=lags.get)
if lag:
    rtl  = rtl[max(lag, 0):]
    gold = gold[max(-lag, 0):]
n = min(len(rtl), len(gold))
exact = off1 = bad = 0
firstbad = []
maxd = 0
for i in range(n):
    for c in range(2):
        d = abs(rtl[i][c] - gold[i][c])
        maxd = max(maxd, d)
        if d == 0: exact += 1
        elif d <= 1: off1 += 1
        else:
            bad += 1
            if len(firstbad) < 5:
                firstbad.append((i, 'LR'[c], rtl[i][c], gold[i][c]))
print(f"[{name}] {n} frames (lag={lag}): exact={exact} off-by-1={off1} bad={bad} maxd={maxd}"
      + (f" len(rtl)={len(rtl)} len(gold)={len(gold)}" if len(rtl) != len(gold) else ""))
for i, c, r, g in firstbad:
    print(f"   frame {i} {c}: rtl={r} gold={g}")
sys.exit(0 if bad == 0 else 1)
