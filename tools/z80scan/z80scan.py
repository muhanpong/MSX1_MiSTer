#!/usr/bin/env python3
"""Walk a Z80 binary from its entry point and report what is reachable.

Written to answer one question about a file someone handed you: is there code in
here that nothing calls?  A program that has been tampered with usually grows a
region the original entry point never reaches, and the appended part is what
runs the payload.  So this follows every call and jump it can resolve, marks the
bytes it lands on, and prints whatever is left over.

It also lists the BDOS calls it saw, because on MSX-DOS the interesting
capabilities -- absolute sector read/write in particular -- all go through
CALL 0005 with the function in C.
"""
import sys
from collections import defaultdict

# instruction length tables, indexed by opcode
L1 = [1,3,1,1,1,1,2,1,1,1,1,1,1,1,2,1]*1
def base_len(op):
    # main page
    t = {
        0x01:3,0x11:3,0x21:3,0x31:3, 0x22:3,0x2A:3,0x32:3,0x3A:3,
        0x06:2,0x0E:2,0x16:2,0x1E:2,0x26:2,0x2E:2,0x36:2,0x3E:2,
        0x10:2,0x18:2,0x20:2,0x28:2,0x30:2,0x38:2,
        0xC3:3,0xC2:3,0xCA:3,0xD2:3,0xDA:3,0xE2:3,0xEA:3,0xF2:3,0xFA:3,
        0xCD:3,0xC4:3,0xCC:3,0xD4:3,0xDC:3,0xE4:3,0xEC:3,0xF4:3,0xFC:3,
        0xC6:2,0xCE:2,0xD6:2,0xDE:2,0xE6:2,0xEE:2,0xF6:2,0xFE:2,
        0xD3:2,0xDB:2,
    }
    return t.get(op,1)

def ins_len(d,i):
    op=d[i]
    if op==0xCB: return 2
    if op==0xED:
        sub=d[i+1] if i+1<len(d) else 0
        return 4 if sub in (0x43,0x4B,0x53,0x5B,0x63,0x6B,0x73,0x7B) else 2
    if op in (0xDD,0xFD):
        if i+1>=len(d): return 1
        sub=d[i+1]
        if sub==0xCB: return 4
        n=base_len(sub)
        # indexed forms add a displacement byte
        if sub in (0x34,0x35,0x36) or (0x46<=sub<=0x7E and sub&7==6) or (sub&0xC7)==0x86:
            n=max(n,2)+ (1 if sub!=0x36 else 1)
            if sub==0x36: n=4
        return 1+n
    return base_len(op)

FLOW_ABS_JP = {0xC3,0xC2,0xCA,0xD2,0xDA,0xE2,0xEA,0xF2,0xFA}
FLOW_CALL   = {0xCD,0xC4,0xCC,0xD4,0xDC,0xE4,0xEC,0xF4,0xFC}
UNCOND_END  = {0xC3,0xC9,0x76}           # JP nn, RET, HALT

def scan(data, base, entry):
    n=len(data)
    seen=bytearray(n)
    calls=defaultdict(int)
    bdos=defaultdict(int)
    todo=[entry]
    starts=set()
    while todo:
        a=todo.pop()
        while True:
            i=a-base
            if i<0 or i>=n or seen[i]: break
            starts.add(a)
            ln=ins_len(data,i)
            if i+ln>n: break
            for k in range(ln): seen[i+k]=1
            op=data[i]
            nxt=a+ln
            if op in FLOW_CALL or op in FLOW_ABS_JP:
                tgt=data[i+1]|(data[i+2]<<8)
                if op in FLOW_CALL:
                    calls[tgt]+=1
                    # BDOS: track the C value if the preceding op was LD C,n
                    if tgt==0x0005:
                        for back in range(i-2, max(i-8,-1), -1):
                            if data[back]==0x0E:
                                bdos[data[back+1]]+=1; break
                if base<=tgt<base+n: todo.append(tgt)
            elif op in (0x18,0x20,0x28,0x30,0x38):     # JR
                tgt=a+2+((data[i+1]^0x80)-0x80)
                if base<=tgt<base+n: todo.append(tgt)
            elif op==0x10:                              # DJNZ
                tgt=a+2+((data[i+1]^0x80)-0x80)
                if base<=tgt<base+n: todo.append(tgt)
            elif (op&0xC7)==0xC7:                       # RST
                calls[op&0x38]+=1
            if op in UNCOND_END or (op&0xC7)==0xC7 and op==0xC7: break
            if op in (0xC9,0xE9): break                 # RET, JP (HL)
            a=nxt
    return seen, calls, bdos

def main(path, base, entry):
    d=open(path,'rb').read()
    seen,calls,bdos=scan(d,base,entry)
    cov=sum(seen)
    print(f"{path}  {len(d)} bytes, entry {entry:#06x}")
    print(f"  reached by walking from entry: {cov} bytes ({100*cov//len(d)}%)")
    # unreached runs
    runs=[]; i=0
    while i<len(d):
        if not seen[i]:
            j=i
            while j<len(d) and not seen[j]: j+=1
            if j-i>=16: runs.append((i,j-i))
            i=j
        else: i+=1
    print(f"  unreached runs >=16B: {len(runs)}")
    for off,ln in runs[:12]:
        chunk=d[off:off+ln]
        printable=sum(1 for c in chunk if 32<=c<127 or c in (13,10,9))
        kind="text" if printable*100//ln>70 else "data/code"
        print(f"    +{off:#06x} len {ln:5d}  {kind}")
    if len(runs)>12: print(f"    ... {len(runs)-12} more")
    print("  BDOS functions called (C value -> count):")
    names={0x0F:"open",0x10:"close",0x11:"find first",0x13:"delete",0x14:"seq read",
           0x15:"seq write",0x16:"create",0x1A:"set DTA",0x26:"abs sector WRITE",
           0x2F:"abs sector READ",0x30:"abs sector WRITE",0x40:"ramdisk",0x62:"terminate"}
    for c,k in sorted(bdos.items()):
        flag=" <== 직접 섹터 접근" if c in (0x2F,0x30,0x26) else ""
        print(f"    C={c:#04x} x{k}  {names.get(c,'')}{flag}")

if __name__=="__main__":
    p=sys.argv[1]; base=int(sys.argv[2],0); entry=int(sys.argv[3],0)
    main(p,base,entry)
