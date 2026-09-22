import hashlib, json, sys
st = open('bank0.bin','rb').read(), open('bank1.bin','rb').read(), open('bank2.bin','rb').read(), open('bank3.bin','rb').read()
hb = open('hb.bin','rb').read()
banks=[bytearray(b) for b in st]
log=[]
def put(bk, addr, new, expect=None, why=''):
    o=addr-0x4000; old=bytes(banks[bk][o:o+len(new)])
    if expect is not None: assert old==bytes(expect), f"bank{bk} {addr:04X}: have {old.hex()} expected {bytes(expect).hex()} ({why})"
    banks[bk][o:o+len(new)]=new; log.append((bk,addr,old.hex(),bytes(new).hex(),why))
w=lambda v: bytes([v&0xFF, v>>8])
# ---------- driver region: hb 7405-7FCF into banks 0 and 1 ----------
drv=bytearray(hb[0x7405-0x4000:0x7FD0-0x4000])
def dpatch(addr, new, expect, why):
    o=addr-0x7405; assert bytes(drv[o:o+len(new)])==bytes(expect), f"hb {addr:04X}: {bytes(drv[o:o+len(new)]).hex()} != {bytes(expect).hex()} ({why})"
    drv[o:o+len(new)]=new; log.append(('drv',addr,bytes(expect).hex(),bytes(new).hex(),why))
for a in (0x7694,0x7869,0x78A7,0x78BD,0x7B62,0x7B95):
    dpatch(a,b'\xCD'+w(0x4DCD),b'\xCD'+w(0x5FC2),'GETWRK DOS1 5FC2 -> DOS2 4DCD')
dpatch(0x78B4,b'\xC3'+w(0x4DFE),b'\xC3'+w(0x5FF6),'SETINT DOS1 5FF6 -> DOS2 4DFE')
dpatch(0x776C,b'\xCD'+w(0x4D4F),b'\xCD'+w(0x625A),'PROMPT DOS1 625A -> DOS2 4D4F')
dpatch(0x76CD,b'\xCD'+w(0x4E67),b'\xCD'+w(0x492F),'DIV DOS1 492F -> DOS2 4E67')
dpatch(0x78B1,b'\x21'+w(0x7FD4),b'\x21'+w(0x78B7),'INIENV handler 78B7 -> bank trampoline 7FD4 (as TC DOS2 build)')
dpatch(0x78B7,b'\xC3'+w(0x4E14),b'\xC3'+w(0x6027),'timer handler DOS1 6027 -> DOS2 4E14')
for bk in (0,1):
    o=0x7405-0x4000; old=bytes(banks[bk][o:o+len(drv)]); banks[bk][o:o+len(drv)]=drv
    log.append((bk,0x7405,f"<TC8566AF driver {len(drv)}B sha1 {hashlib.sha1(old).hexdigest()[:8]}>",f"<hb driver patched sha1 {hashlib.sha1(drv).hexdigest()[:8]}>",'driver swap 7405-7FCF'))
# ---------- DOS2 kernel side ----------
jt=[(0x4010,0x7495,0x751E,'DSKIO'),(0x4013,0x77CA,0x78BA,'DSKCHG'),(0x4016,0x7820,0x7943,'GETDPB'),(0x4019,0x783B,0x795D,'CHOICE'),(0x401C,0x7C6D,0x79A0,'DSKFMT'),(0x401F,0x7746,0x7DE2,'MTOFF')]
for bk in (0,1):
    for a,o,n,nm in jt: put(bk,a,b'\xC3'+w(n),b'\xC3'+w(o),f'jump table {nm}')
put(0,0x47D6,b'\xCD'+w(0x7827),b'\xCD'+w(0x7724),'CALL INIHRD')
put(0,0x48C6,b'\xCD'+w(0x7867),b'\xCD'+w(0x777A),'CALL DRIVES')
put(0,0x48F8,b'\x21'+w(0x74E7),b'\x21'+w(0x7416),'LD HL,DEFDPB')
put(0,0x4904,b'\xCD'+w(0x78A7),b'\xCD'+w(0x77A1),'CALL INIENV')
put(0,0x5796,b'\xC3'+w(0x7DE0),b'\xC3'+w(0x7878),'JP OEMSTA')
assert banks[0][0x489A-0x4000:0x489D-0x4000]==b'\x21\x1A\x00'   # MYSIZE kept at 1Ah (>= hb 09h, keeps stock RAM layout)
for bk in (0,1,2):
    put(bk,0x7FDE,b'\xCD'+w(0x78B7),b'\xCD'+w(0x77B6),'trampoline CALL timer handler')
# ---------- bank 3 = hb verbatim + stub + JP handler ----------
b3=bytearray(hb); assert b3[0x3FC0:]==bytes(64)
b3[0x3FD0:0x3FD7]=bytes.fromhex('32f07fc9c3b778')
banks[3]=b3; log.append((3,0x4000,'<Panasonic DOS1 kernel+TC8566AF>','<hb-f1xd 12f2cc79 + 7FD0 32F07FC9 + 7FD4 C3B778>','bank3 = hb DOS1 system'))
out=b''.join(bytes(b) for b in banks); assert len(out)==0x10000
open('synth_st.rom','wb').write(out)
for i in range(4): open(f'synth_bank{i}.bin','wb').write(bytes(banks[i]))
print("synth_st.rom sha1", hashlib.sha1(out).hexdigest())
for i in range(4): print(f"  bank{i} sha1 {hashlib.sha1(bytes(banks[i])).hexdigest()[:8]}  40FF={banks[i][0xFF]:02X}  7FD0-7FE7={bytes(banks[i][0x3FD0:0x3FE8]).hex()}")
print(f"\n패치 {len(log)}건:")
for l in log: print("  ", l)
json.dump(log,open('synth_patches.json','w'),indent=1)
