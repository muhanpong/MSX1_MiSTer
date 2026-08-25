#!/usr/bin/env python3
# CAUSE probe decoder (96-bit, per ch4 read, circular, frozen after wave-123).
# Packing: [21:0]addr [37:22]DATA [53:38]out [69:54]pos [79:70]envv [82:80]envs
# Usage:
#   parse_mpcause.py            -> decode /tmp/mprobe_dump.txt, show 123-onset reads
#   parse_mpcause.py <a> <b>    -> diff DATA per-addr between two saved dumps
import sys
def load(f):
    rows=[]
    for l in open(f):
        l=l.strip()
        if not l: continue
        w=int(l,16)
        g=lambda lo,n:(w>>lo)&((1<<n)-1)
        s16=lambda v:v-0x10000 if v>=0x8000 else v
        rows.append(dict(addr=g(0,22),data=g(22,16),out=s16(g(38,16)),
                         pos=g(54,16),envv=g(70,10),envs=g(80,3)))
    return rows[::-1]  # read_content reverse → time order (modulo circular wrap)

def tag(a):
    if 0x0C6A00<=a<=0x0CA200: return "122"
    if 0x0CBC00<=a<=0x0CC100: return "123"
    if 0x0CC700<=a<=0x0CCB00: return "124"
    return ""

if len(sys.argv)==3:
    a=load(sys.argv[1]); b=load(sys.argv[2])
    # addr -> data (first occurrence) for each
    def amap(rows):
        m={}
        for r in rows:
            if r['addr'] not in m: m[r['addr']]=r['data']
        return m
    ma,mb=amap(a),amap(b)
    common=sorted(set(ma)&set(mb))
    diff=[x for x in common if ma[x]!=mb[x]]
    print(f"{sys.argv[1]}={len(a)} {sys.argv[2]}={len(b)}  common addr={len(common)}")
    print(f"★ SAME ADDR, DIFFERENT DATA: {len(diff)} / {len(common)}")
    for x in diff[:30]:
        print(f"  addr0x{x:06X}({tag(x)}): A=0x{ma[x]:04X}  B=0x{mb[x]:04X}")
    if not diff:
        print("  → 모든 공통 addr에서 DATA 동일 → SDRAM 읽기 손상 아님; 원인은 엔진처리/타이밍")
    sys.exit(0)

rows=load("/tmp/mprobe_dump.txt")
while rows and rows[-1]['addr']==0 and rows[-1]['data']==0 and rows[-1]['out']==0: rows.pop()
# find ->123 transition by addr region
c=None
for i in range(1,len(rows)):
    if tag(rows[i]['addr'])=="123" and tag(rows[i-1]['addr'])!="123": c=i; break
print(f"entries={len(rows)}  ->123 transition at idx {c}")
lo=max(0,(c or 0)-16); hi=min(len(rows),(c or 0)+48)
print("# idx  addr        data   output  pos   envv envs")
for i in range(lo,hi):
    r=rows[i]
    mk=" <<<123" if i==c else ""
    print(f"{i:4d} 0x{r['addr']:06X}{tag(r['addr']):>4s} 0x{r['data']:04X} {r['out']:+6d} {r['pos']:5d} {r['envv']:4d} {r['envs']}{mk}")
print(f"\noutput peak ±{max(abs(r['out']) for r in rows)}")
# known yrw801 wave-123 sample-start values (from msx.sv smpchk): 0xCBC46=32FE ...
exp={0x0CBC46:0x32FE,0x0CBC48:0xFE02,0x0CBC4A:0xFC04,0x0CBC4C:0xDAFF,0x0CBC4E:0x0303,0x0CBC50:0xFD11}
bad=[(r['addr'],r['data']) for r in rows if r['addr'] in exp and r['data']!=exp[r['addr']]]
print(f"123-start reads mismatching known yrw801: {len(bad)}")
for a,d in bad[:10]: print(f"  addr0x{a:06X}: got0x{d:04X} exp0x{exp[a]:04X}")
