import sys; sys.path.insert(0,'.')
from z80d import dec, w
def img(f): m=bytearray(0x10000); m[0x4000:0x8000]=open(f,'rb').read(); return m
OPS3={0xCD:'CALL',0xC3:'JP',0x21:'LD HL',0x11:'LD DE',0x01:'LD BC',0x31:'LD SP',0x22:'LD (nn),HL',0x2A:'LD HL,(nn)',0x32:'LD (nn),A',0x3A:'LD A,(nn)'}
for c in (0xC2,0xCA,0xD2,0xDA,0xE2,0xEA,0xF2,0xFA): OPS3[c]='JPcc'
for c in (0xC4,0xCC,0xD4,0xDC,0xE4,0xEC,0xF4,0xFC): OPS3[c]='CALLcc'
def scan(m, lo, hi, tlo=0x7400, thi=0x7FD0):
    hits=[]
    for a in range(lo,hi):
        op=m[a]
        if op in OPS3 and tlo<=w(m,a+1)<thi: hits.append((a,OPS3[op],w(m,a+1),'op'))
        if op==0xED and m[a+1] in (0x43,0x53,0x63,0x73,0x4B,0x5B,0x6B,0x7B) and tlo<=w(m,a+2)<thi: hits.append((a,'ED-LD16',w(m,a+2),'op'))
        if op in (0xDD,0xFD) and m[a+1] in (0x21,0x22,0x2A) and tlo<=w(m,a+2)<thi: hits.append((a,'IXIY-16',w(m,a+2),'op'))
    return hits
if __name__=='__main__':
    f=sys.argv[1]; lo=int(sys.argv[2],16); hi=int(sys.argv[3],16)
    m=img(f)
    for a,k,t,_ in scan(m,lo,hi): print(f"  {a:04X} {k:10s} -> {t:04X}   [{m[a:a+3].hex()}]")
