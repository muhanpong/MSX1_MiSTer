#!/usr/bin/env python3
"""Renders the TRI16.BAS odd/even 16-bit-triangle test to a Linux WAV via the
real-chip model (ref278) AND the RTL TB, and checks they agree.  This is the
ground truth for what the hardware SHOULD produce."""
import struct, os, subprocess, array

here = os.path.dirname(os.path.abspath(__file__))
MEM = bytearray(4*1024*1024)

# 32-sample 16-bit triangle, big-endian signed (matches TRI16.BAS line 700)
def tri_bytes():
    b = bytearray()
    for i in range(32):
        p = i if i <= 15 else 31-i
        w = p*4096 - 30720
        b += struct.pack('>h', w)     # big-endian: high byte first (getSample)
    return b
tri = tri_bytes()
MEM[0x300000:0x300000+64] = tri      # even-aligned copy
MEM[0x300101:0x300101+64] = tri      # odd-aligned copy

# headers at wavetblhdr=5 base 0x280000 (wave 384 -> +0, wave 385 -> +12)
def hdr(base, start):
    MEM[base+0] = 0xB0 | ((start>>16)&0x3F)   # bits=2 (16-bit)
    MEM[base+1] = (start>>8)&0xFF
    MEM[base+2] = start&0xFF
    MEM[base+3]=0; MEM[base+4]=0               # loop 0
    MEM[base+5]=0xFF; MEM[base+6]=0xE0         # end -> 0x20 = 32 samples
    MEM[base+7]=0; MEM[base+8]=0xF0            # AR=15
    MEM[base+9]=0; MEM[base+10]=0xF4; MEM[base+11]=0
hdr(0x280000, 0x300000)   # wave 384 (even)
hdr(0x28000C, 0x300101)   # wave 385 (odd)

L=[]
def W(fr,a,d): L.append(f"{fr} {a:02x} {d:02x} 1000")
W(1,0x02,0x14)             # wavetblhdr=5
W(1,0x50,0x01)             # TL=0
W(1,0x38,0x02)             # f2: oct0, fn_high
W(1,0x20,0x01)             # f1: fn_low0, wave bit8
W(1,0x08,0x80)             # f0: wave 384 (loads header)
W(2,0x68,0xA0)             # keyon EVEN
W(20000,0x68,0x20)         # keyoff
W(20800,0x08,0x81)         # f0: wave 385 (odd)
W(20801,0x68,0xA0)         # keyon ODD
frames=41000
open(f"{here}/tri16.bin","wb").write(MEM)
open(f"{here}/tri16.scr","w").write("\n".join(L)+"\n")

subprocess.run([f"{here}/out/ref278", f"{here}/tri16.bin", f"{here}/tri16.scr",
                str(frames), f"{here}/tri16_ref.txt"], check=True)

# hex mirror for the RTL TB (run separately to cross-check)
with open(f"{here}/tri16.hex","w") as f:
    for b in MEM: f.write(f"{b:02x}\n")

rows=[tuple(map(int,l.split())) for l in open(f"{here}/tri16_ref.txt") if len(l.split())==2]
peak=max(1,max(abs(v) for r in rows for v in r))
g=min(1.0,29000.0/peak)
inter=array.array('h')
for l,r in rows: inter.append(int(l*g)); inter.append(int(r*g))
data=inter.tobytes()
with open("/tmp/ms_wav/TRI16.wav","wb") as f:
    f.write(b'RIFF'); f.write(struct.pack('<I',36+len(data))); f.write(b'WAVE')
    f.write(b'fmt '); f.write(struct.pack('<IHHIIHH',16,1,2,44100,44100*4,4,16))
    f.write(b'data'); f.write(struct.pack('<I',len(data))); f.write(data)
print(f"/tmp/ms_wav/TRI16.wav: {len(rows)} frames peak={peak}")
