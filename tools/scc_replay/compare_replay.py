#!/usr/bin/env python3
"""Band-energy comparison: RTL replay render vs openMSX same-run solo recording."""
import numpy as np, wave, sys

J = "/home/muhanpong/.claude/jobs/e9af5670/tmp"
T0, T1 = 0.2, 4.8          # analysis window (skip edges)
BANDS = [(30,200),(200,500),(500,1000),(1000,2000),(2000,4000),(4000,8000),(8000,16000)]

# RTL render: 16-bit LE @ 3579545 Hz
rtl = np.frombuffer(open(f"{J}/replay_samples.s16","rb").read(), dtype="<i2").astype(np.float64)
fs_r = 3579545.0
rtl = rtl[int(T0*fs_r):int(T1*fs_r)]

# openMSX recording
w = wave.open(f"{J}/omsx_home/soundlogs/sccrep0001.wav")
fs_o = w.getframerate()
om = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.float64)
if w.getnchannels() == 2: om = om[0::2]
om = om[int(T0*fs_o):int(T1*fs_o)]

def band_powers(x, fs):
    n = 1 << 16 if fs < 100000 else 1 << 21
    f = np.fft.rfftfreq(n, 1/fs)
    acc = np.zeros(len(f)); cnt = 0
    win = np.hanning(n)
    for s in range(0, len(x)-n, n//2):
        X = np.fft.rfft(x[s:s+n]*win)
        acc += np.abs(X)**2; cnt += 1
    acc /= cnt
    return [acc[(f>=lo)&(f<hi)].sum() for lo,hi in BANDS]

pr = band_powers(rtl, fs_r)
po = band_powers(om, fs_o)
# gain-match on total power over 30..8000 (skip top band: resampler rolloff differs)
g = sum(po[:6]) / sum(pr[:6])
print(f"{'band':>12} {'RTL-openMSX dB':>15}")
for (lo,hi), a, b in zip(BANDS, pr, po):
    d = 10*np.log10(a*g/b) if b > 0 else float('nan')
    print(f"{lo:>5}-{hi:<6} {d:>+14.2f}")
rms_r = np.sqrt((rtl**2).mean()); rms_o = np.sqrt((om**2).mean())
print(f"rms rtl={rms_r:.1f} omsx={rms_o:.1f} (gain factor sqrt={np.sqrt(g):.3f})")
