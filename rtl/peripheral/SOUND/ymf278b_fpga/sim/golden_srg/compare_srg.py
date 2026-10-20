#!/usr/bin/env python3
"""Compare a test PCM stream ("L R" per line) against a reference stream.

  compare_srg.py <test.txt> <ref.txt> <name> [--maxlag N] [--shifted out.txt]

Prints one line per stage, each with exact / off-by-1 / bad(|d|>1) / maxd /
rms (absolute LSB) / nrms (rms error / rms of ref, %) / corr (Pearson, L and R
concatenated):

  raw     lag 0, gain 1: the streams exactly as produced
  lag     best integer lag in [-maxlag, maxlag] (test[i+lag] vs ref[i]),
          chosen by minimum rms error; gain 1
  lag+g   same lag, test divided by the least-squares gain g (test ~= g*ref);
          shows how much of the error is a constant level difference
  seg     each 100-sample window aligned on its own (best lag within +-48):
          the residual left when phase/latency differences between note
          events are forgiven (e.g. a pitch change applied one sample apart
          leaves the square waves out of phase for the rest of the note)
  onset   first non-zero sample in test and in ref (the start latency)
  env     phase-insensitive: 64-sample block RMS envelopes at that lag --
          their correlation, the overall level ratio in dB, and the largest
          per-block level difference (blocks where ref > -40 dBFS)

--shifted writes the lag-aligned test stream (no gain change) so that the
unchanged ../golden/compare_pcm.py can be run on it too.
Exit status is always 0: this is a measurement, not a gate.
"""
import sys, math, argparse

BLK = 64


def load(p):
    out = []
    for ln in open(p):
        f = ln.split()
        if len(f) == 2:
            out.append((int(f[0]), int(f[1])))
    return out


def pair(T, R, lag):
    n = min(len(T) - max(lag, 0), len(R) - max(-lag, 0))
    return [T[i + max(lag, 0)] for i in range(n)], [R[i + max(-lag, 0)] for i in range(n)]


def flat(x):
    return [v for p in x for v in p]


def stats(t, r, g=1.0):
    tv, rv = flat(t), flat(r)
    if g != 1.0:
        tv = [v / g for v in tv]
    n = len(rv)
    di = [round(abs(x - y)) for x, y in zip(tv, rv)]
    exact = sum(1 for v in di if v == 0)
    off1 = sum(1 for v in di if v == 1)
    se = sum((x - y) ** 2 for x, y in zip(tv, rv))
    rms = math.sqrt(se / n) if n else 0.0
    rr = math.sqrt(sum(y * y for y in rv) / n) if n else 0.0
    mt, mr = sum(tv) / n, sum(rv) / n
    ct = [x - mt for x in tv]; cr = [y - mr for y in rv]
    den = math.sqrt(sum(x * x for x in ct) * sum(y * y for y in cr))
    corr = sum(x * y for x, y in zip(ct, cr)) / den if den else float('nan')
    return dict(n=n, exact=exact, off1=off1, bad=n - exact - off1, maxd=max(di) if di else 0,
                rms=rms, nrms=100.0 * rms / rr if rr else float('nan'), corr=corr)


def envelope(t, r):
    def env(x):
        return [math.sqrt(sum(v * v for p in x[b:b + BLK] for v in p) / (2 * BLK))
                for b in range(0, len(x) - BLK + 1, BLK)]
    et, er = env(t), env(r)
    if not et or len(et) != len(er):
        return dict(ecorr=float('nan'), level=float('nan'), maxdb=float('nan'))
    mt, mr = sum(et) / len(et), sum(er) / len(er)
    num = sum((x - mt) * (y - mr) for x, y in zip(et, er))
    den = math.sqrt(sum((x - mt) ** 2 for x in et) * sum((y - mr) ** 2 for y in er))
    st, sr = math.sqrt(sum(x * x for x in et)), math.sqrt(sum(y * y for y in er))
    lvl = 20 * math.log10(st / sr) if st and sr else float('nan')
    dd = [abs(20 * math.log10(max(x, 1) / max(y, 1)))
          for x, y in zip(et, er) if y > 32768 * 10 ** (-40 / 20)]
    return dict(ecorr=num / den if den else float('nan'), level=lvl, maxdb=max(dd) if dd else 0.0)


def segmented(T, R, lag0, win=100, slack=48):
    se = ee = 0.0
    for b in range(0, len(R) - win + 1, win):
        if b + lag0 < 0 or b + lag0 + win > len(T):
            continue                 # only windows the global alignment covers
        rv = flat(R[b:b + win])
        best = None
        for l in range(lag0 - slack, lag0 + slack + 1):
            if b + l < 0 or b + l + win > len(T):
                continue
            tv = flat(T[b + l:b + l + win])
            e = sum((x - y) ** 2 for x, y in zip(tv, rv))
            if best is None or e < best:
                best = e
        if best is not None:
            se += best
            ee += sum(y * y for y in rv)
    return 100.0 * math.sqrt(se / ee) if ee else float('nan')


def onset(X):
    for i, (l, r) in enumerate(X):
        if l or r:
            return i
    return -1


def measure(T, R, maxlag=40, minlag=-2):
    res = {'raw': stats(*pair(T, R, 0))}
    best = None
    for lag in range(minlag, maxlag + 1):
        t, r = pair(T, R, lag)
        if len(r) < 0.8 * len(R):
            continue
        tv, rv = flat(t), flat(r)
        se = sum((x - y) ** 2 for x, y in zip(tv, rv)) / len(rv)
        if best is None or se < best[0]:
            best = (se, lag)
    lag = best[1]
    t, r = pair(T, R, lag)
    res['lagv'] = lag
    res['lag'] = stats(t, r)
    tv, rv = flat(t), flat(r)
    ryy = sum(y * y for y in rv)
    g = sum(x * y for x, y in zip(tv, rv)) / ryy if ryy else 1.0
    if abs(g) < 1e-3:          # silent / uncorrelated test stream: no gain to fit
        g = 1.0
    res['gain'] = g
    res['lagg'] = stats(t, r, g)
    res['env'] = envelope(t, r)
    res['seg'] = segmented(T, R, lag)
    res['onset'] = (onset(T), onset(R))
    return res


def fmt(name, tag, s, extra=''):
    return (f"[{name}] {tag:6s}{extra} n={s['n']} exact={s['exact']} off-by-1={s['off1']} "
            f"bad={s['bad']} maxd={s['maxd']} rms={s['rms']:.1f} nrms={s['nrms']:.2f}% "
            f"corr={s['corr']:.5f}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('test'); ap.add_argument('ref'); ap.add_argument('name')
    ap.add_argument('--maxlag', type=int, default=40)
    ap.add_argument('--minlag', type=int, default=-2,
                    help='a test engine cannot answer a write before it is made; '
                         'small negative lags cover the golden models applying a '
                         'pitch change one sample earlier than openMSX')
    ap.add_argument('--shifted')
    a = ap.parse_args()
    T, R = load(a.test), load(a.ref)
    m = measure(T, R, a.maxlag, min(a.minlag, a.maxlag))
    lag, g, e = m['lagv'], m['gain'], m['env']
    print(fmt(a.name, 'raw', m['raw']))
    print(fmt(a.name, 'lag', m['lag'], f" lag={lag:+d}"))
    print(fmt(a.name, 'lag+g', m['lagg'], f" lag={lag:+d} gain={g:.4f} ({20*math.log10(abs(g)):+.3f} dB)"))
    print(f"[{a.name}] env    lag={lag:+d} env_corr={e['ecorr']:.5f} level={e['level']:+.3f} dB "
          f"max_block_dB_diff(ref>-40dBFS)={e['maxdb']:.2f}")
    print(f"[{a.name}] seg    window-aligned nrms={m['seg']:.2f}%  onset test={m['onset'][0]} ref={m['onset'][1]}")
    if a.shifted:
        with open(a.shifted, 'w') as f:
            if lag < 0:                      # pad so line i still pairs with ref[i]
                f.write("0 0\n" * (-lag))
            for (l, r) in T[max(lag, 0):]:
                f.write(f"{l} {r}\n")


if __name__ == "__main__":
    main()
