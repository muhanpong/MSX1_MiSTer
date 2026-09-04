#!/usr/bin/env python3
"""openMSX-algorithm SCC+ renderer at 1-tick (3.58 MHz) resolution, driven by the
captured register stream.  Output: summed 5ch (each (wav*vol)>>4) as int16 LE."""
import numpy as np
J="/home/muhanpong/.claude/jobs/e9af5670/tmp"
FS=3579545
TOTAL=17897700

evs=[]
for line in open(f"{J}/replay_events.txt"):
    t,a,v=line.split(); evs.append((int(t),int(a,16),int(v,16)))

out = np.zeros(TOTAL, dtype=np.int32)

class Ch:
    def __init__(s):
        s.wave=np.zeros(32,np.int32); s.vol=0; s.period=0; s.count=0; s.pos=0
        s.out=0; s.en=0; s.seg=0
    def table(s): return (s.wave*s.vol)>>4
    def render(s, upto):
        n = upto - s.seg
        if n<=0: return
        P = s.period+1
        tbl = s.table()
        active = s.en and (s.vol!=0 or s.out!=0)
        # step schedule
        first = P - s.count            # ticks until first step (count reaches P)
        if first > n:
            if active: out[s.seg:upto] += s.out
            s.count += n
        else:
            k = 1 + (n - first)//P     # number of steps within n
            # values: out for 'first' ticks, then tbl[pos+1..pos+k]
            idx = (s.pos + 1 + np.arange(k)) % 32
            vals = np.concatenate(([s.out], tbl[idx]))
            lens = np.concatenate(([first], np.full(k, P)))
            lens[-1] = n - first - (k-1)*P
            if active:
                out[s.seg:upto] += np.repeat(vals, lens)
            s.pos = int(idx[-1]); s.out = int(tbl[s.pos]) if active else 0
            s.count = lens[-1] % P if True else 0
            s.count = n - first - (k-1)*P   # ticks since last step
        if not active: s.out = 0
        s.seg = upto

ch=[Ch() for _ in range(5)]
deform=0
enable=0
for t,a,v in evs:
    if t>=TOTAL: break
    if a < 0xA0:                      # wave ch1-5
        c=ch[a>>5]; c.render(t)
        c.wave[a&0x1F] = v-256 if v>127 else v
    elif a < 0xC0:
        o=a&0x0F
        if o < 0x0A:
            c=ch[o//2]; c.render(t)
            per = c.period
            per = ((v&0xF)<<8)|(per&0xFF) if (o&1) else (per&0xF00)|v
            if deform & 2: per &= 0xFF
            elif deform & 1: per >>= 8
            c.period=per; c.count=0
            if deform & 0x20: c.pos=0
            c.out = int(c.table()[c.pos])
        elif o < 0x0F:
            c=ch[o-0xA]; c.render(t); c.vol=v&0xF
        else:
            for i in range(5):
                ch[i].render(t); ch[i].en=(v>>i)&1
    elif a < 0xE0:
        for c_ in ch: c_.render(t)
        deform=v
for c in ch: c.render(TOTAL)
np.clip(out, -32768, 32767).astype('<i2').tofile(f"{J}/ideal_samples.s16")
print("rendered", TOTAL, "ticks; peak", out.max(), out.min())
