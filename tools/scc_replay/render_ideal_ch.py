#!/usr/bin/env python3
import numpy as np, sys
sys.argv=['x']
exec(open("/home/muhanpong/.claude/jobs/e9af5670/tmp/render_ideal.py").read().split("ch=[Ch() for _ in range(5)]")[0].replace("out = np.zeros(TOTAL, dtype=np.int32)","out = np.zeros(TOTAL, dtype=np.int32); outc = np.zeros((TOTAL,5), dtype=np.int16)"))
# re-define render to also write per-channel
class Ch2(Ch):
    def __init__(s, i): super().__init__(); s.i=i
    def render(s, upto):
        n = upto - s.seg
        if n<=0: return
        seg0=s.seg
        before = out[seg0:upto].copy()
        super().render(upto)
        outc[seg0:upto, s.i] = (out[seg0:upto]-before)
ch=[Ch2(i) for i in range(5)]
deform=0
for t,a,v in evs:
    if t>=TOTAL: break
    if a < 0xA0:
        c=ch[a>>5]; c.render(t); c.wave[a&0x1F] = v-256 if v>127 else v
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
            for i in range(5): ch[i].render(t); ch[i].en=(v>>i)&1
    elif a < 0xE0:
        for c_ in ch: c_.render(t)
        deform=v
for c in ch: c.render(TOTAL)
outc.tofile("/home/muhanpong/.claude/jobs/e9af5670/tmp/ideal_ch.raw")
print("per-channel ideal written")
