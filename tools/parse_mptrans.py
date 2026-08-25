#!/usr/bin/env python3
# Decode the per-output-sample transition capture (/tmp/mprobe_dump.txt, 96-bit).
# Circular buffer frozen 512 samples after the wave-123 write → spans 122 tail ->
# gap -> 123 onset.  Find the transition (hdr/pos change) and show the output
# waveform + sample-to-sample deltas (a click = a big delta) around it.
import re
words=[int(l.strip(),16) for l in open("/tmp/mprobe_dump.txt") if l.strip()]
def fld(w,lo,n): return (w>>lo)&((1<<n)-1)
def s16(v): return v-0x10000 if v>=0x8000 else v
rows=[dict(addr=fld(w,0,22),hdr=fld(w,22,22),pos=fld(w,44,16),
           out=s16(fld(w,60,16)),envv=fld(w,76,10),envs=fld(w,86,3)) for w in words]
rows=rows[::-1]  # read_content reverse → BRAM/time order (modulo circular wrap)

EG={0:"OFF",1:"REL",2:"SUS",3:"DEC",4:"ATT"}
def tag(h):
    if 0x0C6A00<=h<=0x0C6B00: return "122"
    if 0x0CBC00<=h<=0x0CBD00: return "123"
    if 0x0CC700<=h<=0x0CC800: return "124"
    return f"{h:#08x}"

# locate transition: hdr_start switches 122->123 (or any -> 123)
trans=[i for i in range(1,len(rows)) if rows[i]['hdr']!=rows[i-1]['hdr']]
print(f"entries={len(rows)}  hdr transitions at idx: {trans[:8]}")
# pick the ->123 transition
t123=[i for i in trans if 0x0CBC00<=rows[i]['hdr']<=0x0CBD00]
c = t123[0] if t123 else (trans[0] if trans else len(rows)//2)
print(f"transition (->123) at idx {c}: hdr {rows[c-1]['hdr']:#08x}({tag(rows[c-1]['hdr'])}) -> {rows[c]['hdr']:#08x}({tag(rows[c]['hdr'])})")

lo=max(0,c-24); hi=min(len(rows),c+40)
print(f"\n# idx  hdr        pos    output  Δout   env_vol envs   (transition at idx {c})")
for i in range(lo,hi):
    r=rows[i]; d = r['out']-rows[i-1]['out'] if i>lo else 0
    mark=" <<< wave->123" if i==c else (" <<click?" if abs(d)>2000 else "")
    print(f"{i:4d}  {r['hdr']:#08x}{tag(r['hdr']):>4s} {r['pos']:5d}  {r['out']:+6d}  {d:+6d}  {r['envv']:5d}  {EG.get(r['envs'],r['envs'])}{mark}")

# biggest output jumps overall (clicks)
deltas=sorted(((abs(rows[i]['out']-rows[i-1]['out']),i) for i in range(1,len(rows))),reverse=True)
print("\nlargest output jumps (|Δ|, idx, out):")
for d,i in deltas[:8]:
    print(f"  Δ{d:5d} at idx{i:4d}: {rows[i-1]['out']:+6d} -> {rows[i]['out']:+6d}  hdr{tag(rows[i]['hdr'])} pos{rows[i]['pos']}")
print(f"\noutput abs-peak: ±{max(abs(r['out']) for r in rows)}")
