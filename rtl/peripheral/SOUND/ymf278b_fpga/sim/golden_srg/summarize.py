#!/usr/bin/env python3
"""Markdown result table from the streams run_srg_golden.sh leaves in $WORK/out.

  summarize.py <outdir> <test-tag>[,<test-tag>...] <ref-tag>[,...] <scenario>...

For each scenario/test/ref: compare_pcm.py-style counts after the best lag
(exact / off-by-1 / bad / maxd), rms and normalised rms, correlation, lag,
least-squares gain, and the envelope level / worst block level difference.
"""
import sys, os, math
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from compare_srg import load, measure

out, tests, refs, scen = sys.argv[1], sys.argv[2].split(','), sys.argv[3].split(','), sys.argv[4:]
print("| scenario | test | ref | lag | exact | off1 | bad | maxd | rms | nrms % | corr | gain dB | env level dB | worst block dB | seg nrms % | onset t/r |")
print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
for sc in scen:
    for t in tests:
        tp = f"{out}/{sc}_{t}.txt"
        if not os.path.exists(tp):
            continue
        T = load(tp)
        for r in refs:
            m = measure(T, load(f"{out}/{sc}_{r}.txt"))
            s, e = m['lag'], m['env']
            print(f"| {sc} | {t} | {r} | {m['lagv']:+d} | {s['exact']} | {s['off1']} | {s['bad']} | "
                  f"{s['maxd']} | {s['rms']:.0f} | {s['nrms']:.2f} | {s['corr']:.4f} | "
                  f"{20*math.log10(abs(m['gain'])):+.2f} | {e['level']:+.2f} | {e['maxdb']:.2f} | "
                  f"{m['seg']:.2f} | {m['onset'][0]}/{m['onset'][1]} |")
