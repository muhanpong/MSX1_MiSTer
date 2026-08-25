#!/usr/bin/env python3
"""
Replays ST02O.VGM (Strikers 1945 II, OPL4 arcade rip) through the PCM golden
harness exactly as vgmplay-sharksym's MoonSound driver would deliver it:

  - ROM data blocks relocated +0x200000 into SRAM (OPL4.asm `set 5,e`)
  - FixUpWaveHeaders: byte0 |= 0x20 on the 128 headers at 0x200000
  - wave-number mapping: f0 LSB -> 0x80|(w&0x7F), f1 bit0 forced 1
    (waveNumberMap: every wave becomes 384 + (w & 127))
  - wavetblhdr = 4 (reg2 = 0x10, left behind by WAVE_MEMORY_CONTROL writes)

Long waits are compressed (cap WAIT_CAP frames) so iverilog finishes; RTL and
golden see the identical compressed script, so the diff stays meaningful.

Outputs: mem2.bin / mem2.hex (4MB) and sc_st02.txt.
"""
import struct, os

VGM = "/home/muhanpong/Documents/github/MSX1_MiSTer/vgm_test/sdcard/ST02O.VGM"
WAIT_CAP = 100000

out = os.path.dirname(os.path.abspath(__file__))
d = open(VGM, 'rb').read()

MEM = bytearray(4 * 1024 * 1024)

p = struct.unpack('<I', d[0x34:0x38])[0] + 0x34
lines = []
frame = 1          # writes for frame N are applied during frame N-1
nmapped = 0

def W(addr, data):
    lines.append(f"{frame} {addr:02x} {data:02x} 1000")

W(0x02, 0x10)      # wavetblhdr=4 (vgmplay leaves this from memory-control writes)

while p < len(d):
    c = d[p]
    if c == 0x67:
        sz = struct.unpack('<I', d[p+3:p+7])[0]
        ds = struct.unpack('<I', d[p+11:p+15])[0]
        payload = d[p+15:p+7+sz]
        base = ds | 0x200000
        MEM[base:base+len(payload)] = payload
        p += 7 + sz
    elif c == 0xD0:
        port, aa, da = d[p+1], d[p+2], d[p+3]
        if port == 2 and aa >= 0x08:               # SafeWriteRegisterWave drops <8
            if 0x08 <= aa <= 0x1F:                 # f0: wave LSB -> map
                da = 0x80 | (da & 0x7F)
                nmapped += 1
            elif 0x20 <= aa <= 0x37:               # f1: wave bit8 forced 1
                da |= 0x01
            W(aa, da)
        p += 4
    elif c == 0x61:
        frame += min(struct.unpack('<H', d[p+1:p+3])[0], WAIT_CAP); p += 3
    elif c == 0x62: frame += min(735, WAIT_CAP); p += 1
    elif c == 0x63: frame += min(882, WAIT_CAP); p += 1
    elif 0x70 <= c <= 0x7F: frame += min((c & 0xF) + 1, WAIT_CAP); p += 1
    elif c == 0x66: break
    else: raise SystemExit(f"unknown cmd {c:02x} at 0x{p:x}")

# FixUpWaveHeaders: 128 headers at 0x200000, byte0 |= 0x20
for n in range(128):
    MEM[0x200000 + n*12] |= 0x20

frames = 13000    # tail room for release
open(f"{out}/mem2.bin", "wb").write(MEM)
with open(f"{out}/mem2.hex", "w") as f:
    for b in MEM:
        f.write(f"{b:02x}\n")
with open(f"{out}/sc_st02.txt", "w") as f:
    f.write("\n".join(lines) + "\n")
print(f"sc_st02.txt: {len(lines)} writes ({nmapped} wave-mapped), {frames} frames")
