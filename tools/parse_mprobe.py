#!/usr/bin/env python3
# Decode the slot-0 multi-probe trace from /tmp/mprobe_dump.txt (96-bit words).
# Packing (LSB-first):
#   [21:0]  mem_addr   [43:22] hdr_start  [59:44] pos
#   [75:60] pcm_level  [85:76] env_vol    [88:86] env_state
import sys
words = []
for l in open("/tmp/mprobe_dump.txt"):
    l = l.strip()
    if l: words.append(int(l, 16))

def fld(w, lo, n): return (w >> lo) & ((1 << n) - 1)
def s16(v): return v - 0x10000 if v >= 0x8000 else v

rows = []
for w in words:
    rows.append(dict(
        addr=fld(w,0,22), hdr=fld(w,22,22), pos=fld(w,44,16),
        out=s16(fld(w,60,16)), envv=fld(w,76,10), envs=fld(w,86,3)))

# read_content is reverse-time (line0 = newest); re-arm clears ptr to 0 so BRAM
# order is chronological → reverse the file to get time order.
rows = rows[::-1]
# drop trailing all-zero (unfilled) entries
while rows and rows[-1]['addr']==0 and rows[-1]['hdr']==0 and rows[-1]['out']==0:
    rows.pop()

EG = {0:"OFF",1:"REL",2:"SUS",3:"DEC",4:"ATT"}  # approximate; adjust to RTL enum
def tag(a):
    if 0x0C6A00<=a<=0x0CA200: return "122"
    if 0x0CBC00<=a<=0x0CC100: return "123"
    if 0x0CC700<=a<=0x0CCB00: return "124"
    if a<0x600: return "HDR"
    return ""

print(f"entries: {len(rows)}  (122 start=0x0C6AC5  123=0x0CBC46  124=0x0CC771)")
print(f"\n# t   read-addr  tag  hdr_start  pos    output  env_vol env_state")
for i,r in enumerate(rows[:40]):
    print(f"{i:3d}  0x{r['addr']:06X} {tag(r['addr']):3s}  0x{r['hdr']:06X}  {r['pos']:5d}  {r['out']:+6d}  {r['envv']:5d}  {EG.get(r['envs'],r['envs'])}")

if rows:
    outs=[r['out'] for r in rows]
    print(f"\nsummary: output peak=±{max(abs(o) for o in outs)}  "
          f"hdr_start(first)=0x{rows[0]['hdr']:06X}  pos(first)={rows[0]['pos']}  "
          f"env_vol range={min(r['envv'] for r in rows)}..{max(r['envv'] for r in rows)}")
    # verdict scaffolding
    h0=rows[0]['hdr']
    print("hdr_start at onset: " + ("123 (0x0CBC46) COMMITTED" if 0x0CBC00<=h0<=0x0CC100
          else ("122/stale (0x%06X)"%h0 if h0 else "0")))
