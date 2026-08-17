#!/usr/bin/env python3
# Parse the vdp_regprobe MPRB dump (/tmp/mprobe_dump.txt, 1024 x 24-hex-char lines).
# Layout: see rtl/vdp_regprobe.sv header.
import sys

path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/mprobe_dump.txt"
words = []
for ln in open(path):
    ln = ln.strip()
    if len(ln) == 24:
        words.append(int(ln, 16))
print(f"{len(words)} words")

def fields_a5(w):  # {A5, 2b0+reg6, val8, frame16, line9, 47'0}
    reg = (w >> 80) & 0x3F
    val = (w >> 72) & 0xFF
    frm = (w >> 56) & 0xFFFF
    lin = (w >> 47) & 0x1FF
    return reg, val, frm, lin

print("\n== last-write table (regs with activity) ==")
for i, w in enumerate(words[:64]):
    if (w >> 88) == 0xA5:
        reg, val, frm, lin = fields_a5(w)
        print(f"  R#{reg:2d} <- {val:3d} (0x{val:02X})  frame {frm:5d} line {lin:3d}")

print("\n== R#2 history (last 16, cyclic) ==")
hist = []
for i, w in enumerate(words[64:80]):
    if (w >> 88) == 0xB2:
        idx = (w >> 80) & 0x0F
        val = (w >> 72) & 0xFF
        frm = (w >> 56) & 0xFFFF
        lin = (w >> 47) & 0x1FF
        hist.append((frm, lin, val, idx))
for frm, lin, val, idx in sorted(hist):
    print(f"  [{idx:2d}] R#2 <- {val:3d} (0x{val:02X})  frame {frm:5d} line {lin:3d}")

print("\n== raw 0x99 ring (last events, sorted) ==")
evs = []
for w in words[80:]:
    t = (w >> 88) & 0xFF
    if (t & 0xFC) == 0xC0:
        data = (w >> 80) & 0xFF
        frm  = (w >> 64) & 0xFFFF
        lin  = (w >> 55) & 0x1FF
        evs.append((frm, lin, "RD" if (t & 2) else "WR", data))
evs.sort()
for frm, lin, typ, d in evs[-60:]:
    print(f"  f{frm:5d} l{lin:3d} {typ} {d:02X}")
