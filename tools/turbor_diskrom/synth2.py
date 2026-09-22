import hashlib, json, sys
w=lambda v: bytes([v&0xFF, v>>8])
HBSYM=dict(DSKIO=0x751E,DSKCHG=0x78BA,GETDPB=0x7943,CHOICE=0x795D,DSKFMT=0x79A0,MTOFF=0x7DE2,INIHRD=0x7827,DRIVES=0x7867,DEFDPB=0x74E7,INIENV=0x78A7,OEMSTA=0x7DE0)
CFG={
 'st':dict(src='bank_st.rom', jt=dict(DSKIO=0x7495,DSKCHG=0x77CA,GETDPB=0x7820,CHOICE=0x783B,DSKFMT=0x7C6D,MTOFF=0x7746),
           k=dict(INIHRD=(0x47D6,0x7724),DRIVES=(0x48C6,0x777A),DEFDPB=(0x48F8,0x7416),INIENV=(0x4904,0x77A1),OEMSTA=(0x5796,0x7878)),
           mysize=(0x489A,0x1A), handler=0x77B6, kmap=dict(GETWRK=0x4DCD,SETINT=0x4DFE,PROMPT=0x4D4F,DIV=0x4E67,TIMER=0x4E14)),
 'gt':dict(src='bank_gt.rom', jt=dict(DSKIO=0x7459,DSKCHG=0x779D,GETDPB=0x77F9,CHOICE=0x781A,DSKFMT=0x7C52,MTOFF=0x7713),
           k=dict(INIHRD=(0x47D6,0x76F1),DRIVES=(0x48C6,0x7747),DEFDPB=(0x48F8,0x73DA),INIENV=(0x4904,0x7771),OEMSTA=(0x5796,0x785D)),
           mysize=(0x489A,0x1F), handler=0x7789, kmap=dict(GETWRK=0x4DD8,SETINT=0x4E09,PROMPT=0x4D5A,DIV=0x4E72,TIMER=0x4E1F)),
}
def build(key):
    c=CFG[key]; blk=open(c['src'],'rb').read(); hb=open('hb.bin','rb').read()
    banks=[bytearray(blk[i*0x4000:(i+1)*0x4000]) for i in range(4)]; log=[]
    def put(bk,a,new,old,why):
        o=a-0x4000; assert bytes(banks[bk][o:o+len(new)])==old, f"{key} bank{bk} {a:04X}: {bytes(banks[bk][o:o+len(new)]).hex()}!={old.hex()} {why}"
        banks[bk][o:o+len(new)]=new; log.append([bk,f"{a:04X}",old.hex(),new.hex(),why])
    drv=bytearray(hb[0x7405-0x4000:0x7FD0-0x4000]); km=c['kmap']
    def dp(a,new,old,why):
        o=a-0x7405; assert bytes(drv[o:o+len(new)])==old, f"hb {a:04X} {why}"; drv[o:o+len(new)]=new; log.append(['drv',f"{a:04X}",old.hex(),new.hex(),why])
    for a in (0x7694,0x7869,0x78A7,0x78BD,0x7B62,0x7B95): dp(a,b'\xCD'+w(km['GETWRK']),b'\xCD'+w(0x5FC2),'GETWRK')
    dp(0x78B4,b'\xC3'+w(km['SETINT']),b'\xC3'+w(0x5FF6),'SETINT')
    dp(0x776C,b'\xCD'+w(km['PROMPT']),b'\xCD'+w(0x625A),'PROMPT')
    dp(0x76CD,b'\xCD'+w(km['DIV']),b'\xCD'+w(0x492F),'DIV')
    dp(0x78B1,b'\x21'+w(0x7FD4),b'\x21'+w(0x78B7),'INIENV handler -> trampoline 7FD4')
    dp(0x78B7,b'\xC3'+w(km['TIMER']),b'\xC3'+w(0x6027),'timer handler -> DOS2 generic')
    for bk in (0,1):
        banks[bk][0x7405-0x4000:0x7FD0-0x4000]=drv; log.append([bk,'7405-7FCF','<TC8566AF driver>',f'<hb driver patched {hashlib.sha1(drv).hexdigest()[:8]}>','driver swap'])
        for i,nm in enumerate(['DSKIO','DSKCHG','GETDPB','CHOICE','DSKFMT','MTOFF']):
            put(bk,0x4010+3*i,b'\xC3'+w(HBSYM[nm]),b'\xC3'+w(c['jt'][nm]),f'jump table {nm}')
    for nm,(site,old) in c['k'].items():
        op=0x21 if nm=='DEFDPB' else (0xC3 if nm=='OEMSTA' else 0xCD)
        put(0,site,bytes([op])+w(HBSYM[nm]),bytes([op])+w(old),nm)
    ms,mv=c['mysize']; assert banks[0][ms-0x4000:ms-0x4000+3]==b'\x21'+w(mv), 'MYSIZE site'
    for bk in (0,1,2): put(bk,0x7FDE,b'\xCD'+w(0x78B7),b'\xCD'+w(c['handler']),'trampoline CALL handler')
    b3=bytearray(hb); assert b3[0x3FC0:]==bytes(64); b3[0x3FD0:0x3FD7]=bytes.fromhex('32f07fc9c3b778'); banks[3]=b3
    log.append([3,'4000-7FFF','<vendor DOS1 kernel+TC8566AF>','<hb-f1xd 12f2cc79 + 7FD0 32F07FC9 + 7FD4 C3B778>','bank3'])
    out=b''.join(bytes(b) for b in banks); open(f'synth_{key}.rom','wb').write(out)
    for i in range(4): open(f'synth_{key}_bank{i}.bin','wb').write(bytes(banks[i]))
    json.dump(log,open(f'synth_{key}_patches.json','w'),indent=1)
    return hashlib.sha1(out).hexdigest(), len(log)
for k in ('st','gt'):
    sha,n=build(k); print(f"synth_{k}.rom  sha1 {sha}   patches {n}")
