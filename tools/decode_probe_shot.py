#!/usr/bin/env python3
# Decode the on-screen reg-probe panel from a screenshot.
# Panel: overlay window rows 120..151 (4 rows x 8px), 24 bits x 2px from x=0, MSB left.
#   row0 probe_r2  {val8, frame16}  red
#   row1 probe_r23 {val8, frame16}  green
#   row2 probe_r0  {val8, frame16}  amber
#   row3 {0, frame_now16}           cyan
# Usage: decode_probe_shot.py <shot.png> [x0 y0 xscale yscale]  (defaults: auto-ish for 1613x1080)
import sys
from PIL import Image

img = Image.open(sys.argv[1]).convert('RGB')
w, h = img.size
px = img.load()
# scale: overlay native window ≈ h/216 rows tall (VDP window 240 vis? use 216 layout like prior shots)
ys = h / 216.0
xs = None
# find content left edge (first nonblack column)
for x in range(w):
    if any(px[x, int(80*ys)] != (0,0,0) for _ in [0]):
        x0 = x; break
else:
    x0 = 0
# native h_cnt 2px/bit → screen px per native: assume same as pause work: content 1419px/256 ≈ 5.54
xs = float(sys.argv[4]) if len(sys.argv) > 4 else (w - 2*x0) / 256.0

def read_row(row_idx):
    yc = int((120 + row_idx*8 + 4) * ys)
    bits = 0
    for b in range(24):
        xc = x0 + int((b*2 + 1) * xs)
        r, g, bl = px[xc, yc]
        lit = (r > 100 or g > 100 or bl > 100)
        bits = (bits << 1) | (1 if lit else 0)
    return bits

names = ["R#2 ", "R#23", "R#0 ", "FRAME"]
vals = []
for i in range(4):
    v = read_row(i)
    vals.append(v)
    if i < 3:
        print(f"{names[i]}: val={v>>16:3d} (0x{v>>16:02X})  frame={v & 0xFFFF}")
    else:
        print(f"{names[i]}: now={v & 0xFFFF}")
print("\nInterpretation:")
r2f, r23f, r0f = vals[0] & 0xFFFF, vals[1] & 0xFFFF, vals[2] & 0xFFFF
print(f"  R#2 last write {'AFTER' if r2f > r23f else 'before'} R#23 setup (Δ={r2f - r23f} frames)")
print(f"  R#2 last write {'AFTER' if r2f > r0f else 'before'} R#0/IE1-off (Δ={r2f - r0f} frames)")
