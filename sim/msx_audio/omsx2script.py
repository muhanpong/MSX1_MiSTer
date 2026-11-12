#!/usr/bin/env python3
"""openMSX port log -> y8950 bench script, and the comparison of a bench log with
openMSX's own per-channel recording.

  omsx2script.py conv <io.log> <script> [seconds]
  omsx2script.py cmp  <bench.log> <ch15.wav>

io.log lines: "<time> W|R <0|1> [hex]" (ports C0h/C1h, a watchpoint each; see
replay_omsx.sh).  openMSX brings the device up to the time of an access before
applying it, so an access at time t lands in front of sample
    floor(t * RATE + OFFSET)
of the recording.  RATE is what openMSX's clock really runs at for a device
declared as 49716 Hz: its period is a whole number of master ticks (69120 of
3436363200 per second = 49715.903 Hz, which is also 3579545 / 72).  OFFSET is
where the device clock started relative to the recording's first sample; it was
measured (openMSX 21.0, FS-A1GT + audio, recording switched on from the start-up
script): -78.46 is the one value in a 0.01 scan at which all five Psycho Soldier
ADPCM tracks compare with zero mismatches; 0.03 either side already fails.

cmp: openMSX records a channel at the chip rate as sample x 16 (volume 75 on a
float path, rounded to 16 bits).  Every sample must equal the bench's x 16, at
the same index: no fitting, no alignment search."""
import sys, wave, struct, math
RATE = 3436363200 / 69120
OFFSET = -78.46
GAIN = 16
def conv(src, dst, secs=None):
    o = []; cur = 0; latch = 0; last = 0.0
    for l in open(src):
        t = l.split()
        if not t or t[0] == '#': continue
        tm = float(t[0]); n = int(math.floor(tm * RATE + OFFSET)); last = tm
        if n > cur: o.append("T %d" % (n - cur)); cur = n
        if t[1] == 'W':
            if t[2] == '0': latch = int(t[3], 16)
            else: o.append("W %02X %s" % (latch, t[3].upper()))
        elif t[2] == '0': o.append("S")
        else: o.append("R %02X" % latch)
    end = int((secs if secs else last + 1.0) * RATE)
    if end > cur: o.append("T %d" % (end - cur))
    open(dst, "w").write("\n".join(o) + "\n")
def cmp_(logf, wavf):
    a = [int(l.split()[1]) for l in open(logf) if l.startswith("A ")]
    w = wave.open(wavf); n = w.getnframes()
    assert w.getframerate() == 49716 and w.getnchannels() == 1, (w.getframerate(), w.getnchannels())
    d = struct.unpack("<%dh" % n, w.readframes(n))
    m = min(len(a), n)
    bad = [i for i in range(m) if a[i] * GAIN != d[i]]
    nz = sum(1 for i in range(m) if a[i]); nzd = sum(1 for i in range(m) if d[i])
    print("samples %d, nonzero: bench %d, openMSX %d, mismatches %d" % (m, nz, nzd, len(bad)))
    if bad: print("first mismatch at sample %d: bench %d, openMSX %d/16" % (bad[0], a[bad[0]], d[bad[0]]))
    print("CMP " + ("PASS" if not bad else "FAIL") + ("" if nz else " (no ADPCM in this file: nothing was compared)"))
def top(src, dst, secs):
    """the same log for tb_top_replay.sv: absolute times in ns from 2 ms before the first
    write, status reads dropped (the core serves them without the bridge and they have
    no side effect); ends with a dummy status-port access at +secs after the last one"""
    ev = [l.split() for l in open(src) if l[0] != '#']
    ev = [t for t in ev if t[1] == 'W' or t[2] == '1']
    t0 = float(next(t for t in ev if t[1] == 'W')[0]) - 0.002
    o = ["%d %s %02X %s" % (round((float(t[0]) - t0) * 1e9), t[1], 0xC0 + int(t[2]), t[3] if t[1] == 'W' else "00")
         for t in ev if float(t[0]) >= t0]
    o.append("%d W C0 00" % round((float(ev[-1][0]) - t0 + secs) * 1e9))
    open(dst, "w").write("\n".join(o) + "\n")
if sys.argv[1] == "top": top(sys.argv[2], sys.argv[3], float(sys.argv[4]) if len(sys.argv) > 4 else 0.5)
elif sys.argv[1] == "conv": conv(sys.argv[2], sys.argv[3], float(sys.argv[4]) if len(sys.argv) > 4 else None)
else: cmp_(sys.argv[2], sys.argv[3])
