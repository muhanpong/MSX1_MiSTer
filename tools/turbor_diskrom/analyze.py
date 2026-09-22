import sys, difflib, hashlib; sys.path.insert(0,'.')
from z80d import dec, w, explore
from scanref import scan
def img(b): m=bytearray(0x10000); m[0x4000:0x8000]=b; return m
HB=img(open('hb.bin','rb').read())
HBSYM={'DSKIO':0x751E,'DSKCHG':0x78BA,'GETDPB':0x7943,'CHOICE':0x795D,'DSKFMT':0x79A0,'MTOFF':0x7DE2,
       'INIHRD':0x7827,'DRIVES':0x7867,'DEFDPB':0x74E7,'INIENV':0x78A7,'OEMSTA':0x7DE0}
KSITES={'INIHRD':0x576F,'DRIVES':0x5850,'DEFDPB':0x5883,'INIENV':0x588F,'OEMSTA':0x65AE}   # DOS1 kernel sites (hb numbering)
def analyze(name, blk):
    B=[img(blk[i*0x4000:(i+1)*0x4000]) for i in range(4)]
    r={'name':name,'sha1':hashlib.sha1(blk).hexdigest()[:8]}
    # 1) DOS1 bank3 vs hb kernel: must be near-identical, gives bank3 driver symbols
    diff=sum(1 for a in range(0x4000,0x7400) if B[3][a]!=HB[a]); r['b3_vs_hb_kernel_diffbytes']=diff
    s3={nm:w(B[3],0x4010+3*i+1) for i,nm in enumerate(['DSKIO','DSKCHG','GETDPB','CHOICE','DSKFMT','MTOFF'])}
    for nm,site in KSITES.items(): s3[nm]=w(B[3],site+1)
    # 2) bank0 jump table + alignment bank3-driver -> bank0-driver
    s0={nm:w(B[0],0x4010+3*i+1) for i,nm in enumerate(['DSKIO','DSKCHG','GETDPB','CHOICE','DSKFMT','MTOFF'])}
    lo=min(v for v in s3.values())&0xFF00
    d3=bytes(B[3][lo:0x7FD0]); d0=bytes(B[0][lo:0x7FD0])
    blocks=[b for b in difflib.SequenceMatcher(None,d3,d0,autojunk=False).get_matching_blocks() if b.size>0]
    def m30(x):
        o=x-lo
        for b in blocks:
            if b.a<=o<b.a+b.size: return x+(b.b-b.a)
    for nm in ('INIHRD','DRIVES','DEFDPB','INIENV','OEMSTA'):
        s0[nm]=m30(s3[nm])
    r['sym3']=s3; r['sym0']=s0; r['drvlo']=lo
    inv={v:k for k,v in s0.items() if v}
    # 3) kernel(bank0/1) -> driver references hitting known symbols
    refs=[]
    for bi in (0,1,2):
        for a,k,t,_ in scan(B[bi],0x4000,lo,tlo=lo,thi=0x7FD0):
            if t in inv: refs.append((bi,a,k,t,inv[t]))
    r['k2d']=refs
    # MYSIZE literal near DRIVES call in bank0
    r['mysize']=[ (a,w(B[0],a+1)) for a in range(0x4000,lo) if B[0][a]==0x21 and B[0][a+3]==0xCD and 0x08<=w(B[0],a+1)<=0x40 and any(abs(a-x[1])<0x60 for x in refs if x[4]=='DRIVES' and x[0]==0)]
    # 4) driver->kernel: bank3 driver call targets (DOS1 kernel), mapped to bank0's aligned site
    def k_refs(m,ents):
        code=explore(m,ents,lo=lo,hi=0x7FD0)
        return {pc:(t,a) for pc,(n,t,k,a) in code.items() if a is not None and 0x4000<=a<lo and k in ('call','jp','callc','jpc')}
    e3=[v for k,v in s3.items() if k!='DEFDPB']; e0=[v for k,v in s0.items() if k!='DEFDPB' and v]
    kr3=k_refs(B[3],e3); kr0=k_refs(B[0],e0)
    # include timer handler reached via SETINT: find "LD HL,x / JP setint" in INIENV of each
    pairs={}
    for pc,(t,a) in kr3.items():
        p0=m30(pc)
        if p0 in kr0: pairs.setdefault(a,set()).add(kr0[p0][1])
    r['kmap']={f"{a:04X}":sorted('%04X'%x for x in v) for a,v in sorted(pairs.items())}
    # handler: bank3 7FD4 and bank0 7FD4-7FE7
    r['b0_7FD0']=bytes(B[0][0x7FD0:0x7FE8]).hex(); r['b3_7FD0']=bytes(B[3][0x7FD0:0x7FD8]).hex()
    r['bankid40FF']=[f"{B[i][0x40FF]:02X}" for i in range(4)]
    return r
if __name__=='__main__':
    import json
    for nm,path,off in [('ST 2.30','bank_st.rom',0),('GT 2.31','bank_gt.rom',0),('MMCSD 2.31','mmcsd231.rom',0)]:
        blk=open(path,'rb').read()[off:off+0x10000]
        r=analyze(nm,blk)
        print(f"\n######## {nm}  sha1 {r['sha1']}   drv region from {r['drvlo']:04X}   bank3-vs-hb kernel diff bytes={r['b3_vs_hb_kernel_diffbytes']}   40FF={r['bankid40FF']}")
        print("  sym bank3:", {k:'%04X'%v for k,v in r['sym3'].items()})
        print("  sym bank0:", {k:('%04X'%v if v else '??') for k,v in r['sym0'].items()})
        print("  kernel->driver refs:"); [print(f"     bank{bi} {a:04X} {k:10s}->{t:04X} {nm2}") for bi,a,k,t,nm2 in r['k2d']]
        print("  MYSIZE candidates (bank0):", [('%04X'%a,'%04X'%v) for a,v in r['mysize']])
        print("  driver->kernel map DOS1->DOS2:", r['kmap'])
        print("  bank0 7FD0:", r['b0_7FD0'], "  bank3 7FD0:", r['b3_7FD0'])
