#!/usr/bin/env python3
"""
Renders an OPL4 VGM to a 44.1 kHz stereo WAV using the faithful real-chip
model (ref278), reproducing exactly how vgmplay-sharksym's MoonSound driver
delivers it (ROM blocks +0x200000, wave 384+ remap, FixUp byte0|=0x20,
wavetblhdr=4).  This is the openMSX / real-YMF278 ground truth.

  render_wav.py in.vgm out_prefix
    -> out_prefix.bin  (4MB sample memory)
    -> out_prefix.scr  (full-timing register script for ref278)
    -> out_prefix.wav  (run separately: ./out/ref278 ... then txt2wav)
"""
import struct, sys, os, subprocess

vgm, prefix = sys.argv[1], sys.argv[2]
d = open(vgm, 'rb').read()
MEM = bytearray(4 * 1024 * 1024)
p = struct.unpack('<I', d[0x34:0x38])[0] + 0x34
frame = 1
lines = []
def W(addr, data): lines.append(f"{frame} {addr:02x} {data:02x}")
W(0x02, 0x10)
while p < len(d):
    c = d[p]
    if c == 0x67:
        sz = struct.unpack('<I', d[p+3:p+7])[0]
        ds = struct.unpack('<I', d[p+11:p+15])[0]
        MEM[ds|0x200000:(ds|0x200000)+sz-8] = d[p+15:p+7+sz]
        p += 7+sz
    elif c == 0xD0:
        port, aa, da = d[p+1], d[p+2], d[p+3]
        if port == 2 and aa >= 0x08:
            if 0x08 <= aa <= 0x1F:   da = 0x80 | (da & 0x7F)
            elif 0x20 <= aa <= 0x37: da |= 0x01
            W(aa, da)
        elif port in (0, 1):
            pass  # FM — not modelled by ref278 (these VGMs are PCM-only)
        p += 4
    elif c == 0x61: frame += struct.unpack('<H', d[p+1:p+3])[0]; p += 3
    elif c == 0x62: frame += 735; p += 1
    elif c == 0x63: frame += 882; p += 1
    elif 0x70 <= c <= 0x7F: frame += (c & 0xF) + 1; p += 1
    elif c == 0x66: break
    else: raise SystemExit(f"unknown {c:02x}")
for n in range(128):
    MEM[0x200000 + n*12] |= 0x20
frames = frame + 4410   # 0.1s tail
open(prefix + ".bin", "wb").write(MEM)
open(prefix + ".scr", "w").write("\n".join(lines) + "\n")
print(f"{prefix}: {len(lines)} writes, {frames} frames ({frames/44100:.1f}s)")

here = os.path.dirname(os.path.abspath(__file__))
ref = os.path.join(here, "out", "ref278")
txt = prefix + ".txt"
subprocess.run([ref, prefix + ".bin", prefix + ".scr", str(frames), txt], check=True)

# txt (L R per line) -> 16-bit stereo WAV, with peak normalisation to -1dBFS
import array
L = array.array('h'); R = array.array('h')
peak = 1
rows = []
for ln in open(txt):
    a = ln.split()
    if len(a) == 2:
        l, r = int(a[0]), int(a[1]); rows.append((l, r)); peak = max(peak, abs(l), abs(r))
g = min(1.0, 29000.0 / peak)
for l, r in rows:
    L.append(int(l*g)); R.append(int(r*g))
inter = array.array('h')
for i in range(len(L)):
    inter.append(L[i]); inter.append(R[i])
data = inter.tobytes()
wav = prefix + ".wav"
with open(wav, "wb") as f:
    f.write(b'RIFF'); f.write(struct.pack('<I', 36 + len(data))); f.write(b'WAVE')
    f.write(b'fmt '); f.write(struct.pack('<IHHIIHH', 16, 1, 2, 44100, 44100*4, 4, 16))
    f.write(b'data'); f.write(struct.pack('<I', len(data))); f.write(data)
print(f"{wav}: {len(L)} frames, peak={peak} gain={g:.3f}")
