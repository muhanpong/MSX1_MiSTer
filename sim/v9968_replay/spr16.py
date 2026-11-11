#  spr16.py OUT N a : trace for sim/v9968_replay with N sprite-mode-3 sprites on one line
#  (X = 8+14*i, palette set i, solid colour 1); see run_spr16.sh
import sys
#  VDP registers 0-63 of WBML V9968 v0.9.41 in a scrolling scene (sprite mode 3, R#20=1F)
regs=bytes.fromhex('1e601f8000f300002880000700000f02cfac00571f00052800021900000000004800100540000801080000003f00000000000000000000ff01ff07ffffffffff')
N=int(sys.argv[2]); V=sys.argv[3]; out=[]; t=1_000_000
def e_(s):
    global t; out.append(f"{t} {s}"); t+=1000
def w(p,v): e_(f"W {p:02X} {v:02X}")
def reg(r,v): w(0x99,v); w(0x99,0x80|r)
def setw(a): reg(14,a>>14); w(0x99,a&0xFF); w(0x99,((a>>8)&0x3F)|0x40)
w(0x9C,0); reg(21,0); reg(1,0); reg(0,0); reg(25,0); reg(20,0); reg(8,8)
setw(0x10000)
for i in range(0x10000): w(0x98,0x11)
sat=bytearray()
for i in range(N):
    x=8+14*i; sat+=(bytes([40,0,16,i&15,x&255,(x>>8)|0x20,16,0x00]) if V=='a' else bytes([40,0xc0,128,8,x&255,(x>>8)|0x20,16,0x30]) if V=='b' else bytes([40,0,16,8,x&255,(x>>8)|0x20,16,0x30]))
sat+=bytes([216,0,0,0,0,0,0,0])
for base in (0x3F800,0x3FA00):
    setw(base)
    for b in sat: w(0x98,b)
skip=set(range(32,48))|{1,14,15,16,17,21,26,27}
for r in range(64):
    if r not in skip: reg(r,regs[r])
reg(26,0); reg(27,0); reg(16,0)
for i in range(256):
    for v in ((i*7+3)%32,(i>>4)*2+1,(i*5)%32) if i&15 else (0,0,0): w(0x9A,v)
reg(1,regs[1]&~0x20)
t+=40_000_000; reg(2,regs[2]); t+=20_000_000; reg(2,regs[2])
open(sys.argv[1],'w').write('\n'.join(out)+'\n')
