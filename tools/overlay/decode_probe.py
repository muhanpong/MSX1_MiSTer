#!/usr/bin/env python3
"""Read the VDP register probes out of a MiSTer screenshot.

The debug overlay draws the last write to R#2, R#23, R#0 and R#1 as a 24-bit
bar -- 8 bits of value, then the 16-bit frame number it happened on -- and the
current frame as a 16-bit bar.  Getting one of those bits wrong by eye is easy,
so this reads them off the PNG instead.

    python3 tools/overlay/decode_probe.py shot.png

Take the shot with Debug Overlay on.  The panel sits at the top left; its scale
is measured from the image rather than assumed, because MiSTer scales the two
axes by different amounts and the horizontal one also moves with the screen
mode.  That measurement needs the game area beside the panel to be dark, which
is true of the case this exists for (a black screen that never came back).
"""
import sys
from PIL import Image

PW, ROWH, NBANDS = 66, 6, 37          # must match rtl/debug_overlay.sv
PH = 1 + NBANDS * ROWH + 1
BANDS = {30: ("R#2", 24), 31: ("R#23", 24), 32: ("R#0", 24), 33: ("R#1", 24),
         34: ("R#9", 24), 35: ("R#19", 24), 36: ("frame", 16)}


def panel_box(im):
    """Bounding box of the overlay panel, in image pixels."""
    W, H = im.size
    px = im.load()
    lit = lambda x, y: sum(px[x, y]) > 60
    right = 0
    for x in range(W // 2):
        if any(lit(x, y) for y in range(0, H, 3)):
            right = x
    bottom = 0
    for y in range(H):
        if any(lit(x, y) for x in range(0, min(right + 1, W), 3)):
            bottom = y
    return right + 1, bottom + 1


def main(path):
    im = Image.open(path).convert("RGB")
    W, H = im.size
    pw, ph = panel_box(im)
    if pw < PW or ph < PH:
        print(f"panel measured {pw}x{ph} px, too small to hold a {PW}x{PH} overlay -- "
              f"is Debug Overlay on, and is this from the r1probe build or later?")
        return 1
    sx, sy = pw / PW, ph / PH
    print(f"{W}x{H}, panel {pw}x{ph} px, scale x{sx:.3f} y{sy:.3f}\n")

    px = im.load()
    for band, (name, nbits) in sorted(BANDS.items()):
        y = int((1 + band * ROWH + ROWH / 2) * sy)
        bits = ""
        for b in range(nbits):
            x = int((b * 2 + 1) * sx)
            bits += "1" if (x < W and y < H and sum(px[x, y]) > 300) else "0"
        v = int(bits, 2)
        if nbits == 24:
            val, frm = v >> 16, v & 0xFFFF
            note = ""
            if name == "R#1":
                note = f"   display {'ON' if val & 0x40 else 'OFF'}, IE0 {'on' if val & 0x20 else 'off'}"
            elif name == "R#9":
                note = f"   {212 if val & 0x80 else 192} lines"
            elif name == "R#0":
                note = f"   IE1 {'on' if val & 0x10 else 'off'}"
            elif name == "R#19":
                note = f"   line {val}"
            print(f"  {name:<6} value={val:02X}  written on frame {frm}{note}")
        else:
            print(f"  {name:<6} = {v}   (current)")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
