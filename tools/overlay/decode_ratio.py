#!/usr/bin/env python3
"""Read the P5 WAIT-ratio and ch2 cache HIT-ratio bars out of a MiSTer screenshot.

The two bottom rows of the MOONSOUND_DIAG overlay are bars, not bit patterns:
64 panel pixels = 100%, value[15:10] of a per-65536 counter.  Reading them by
eye off a 2.4x-scaled screenshot is guesswork, so read them off the PNG.

    python3 tools/overlay/decode_ratio.py shot.png [more.png ...]

Differences from decode_probe.py, both needed here:

  * The panel width is found from the BLACK GAP between the panel and the game
    area, not from "the last lit column".  decode_probe's method only works
    when the game area is dark; the shots that matter for a ratio are of a
    running game, which is not.
  * The layout is detected rather than assumed.  A build without the ratio rows
    (37 rows, PH 224) ends in the cyan frame row; the ratio build (39 rows,
    PH 236) ends in the green HIT bar.  Told apart by the unlit colour of the
    bottom row: 0x202020 grey for a bar, 0x003030 for the cyan probe row.
"""
import sys
from PIL import Image

PW, ROWH = 66, 6
LAYOUTS = {39: 1 + 39 * ROWH + 1,      # with the P5 ratio rows
           37: 1 + 37 * ROWH + 1}      # r1probe/fhfix and earlier


def panel_geometry(im):
    """(x0, y0, width, height) of the overlay panel in image pixels.

    x0 is not always 0: a desktop capture of the MiSTer output carries black
    letterbox borders, so find the panel's left edge as well as its right.
    Columns are classified by the FRACTION of sampled rows that are dark, not
    by "is any row lit": the panel's grey background lights nearly its whole
    height, while a gap column stays dark even when a band of corrupted tiles
    crosses the top of the frame (which is exactly when a shot is worth
    reading)."""
    W, H = im.size
    px = im.load()
    ys = range(0, int(H * 0.85), 7)
    dark_frac = []
    for x in range(W // 2):
        d = sum(1 for y in ys if sum(px[x, y]) < 25)
        dark_frac.append(d / len(ys))
    x0 = next((x for x, f in enumerate(dark_frac) if f < 0.9), None)
    if x0 is None:
        raise SystemExit("no panel-like column in the left half -- is Debug Overlay on?")
    x1 = next((x for x in range(x0, W // 2) if dark_frac[x] >= 0.9), None)
    if x1 is None:
        raise SystemExit("no gap right of the panel -- is Debug Overlay on?")
    lit_row = lambda y: any(sum(px[x, y]) > 25 for x in range(x0, x1, 3))
    y0 = next(y for y in range(H) if lit_row(y))
    y1 = max(y for y in range(H) if lit_row(y))
    return x0, y0, x1 - x0, y1 - y0 + 1


def row_y(band, sy):
    return int((1 + band * ROWH + ROWH / 2) * sy)


def bar(px, W, x0, sx, y, kind):
    """Bar length in panel pixels (0..64)."""
    n = 0
    for b in range(64):
        x = x0 + int((b + 0.5) * sx)
        if x >= W:
            break
        r, g, bl = px[x, y]
        on = (r > 128 and g < 110 and bl < 110) if kind == "red" \
            else (g > 128 and r < 110 and bl < 110)
        if not on:
            break
        n += 1
    return n


def main(paths):
    for path in paths:
        im = Image.open(path).convert("RGB")
        W, H = im.size
        x0, y0, pw, ph = panel_geometry(im)
        px = im.load()

        sy39 = ph / LAYOUTS[39]
        sx = pw / PW
        # Sample the left half of where the HIT bar would be.  A bar row holds
        # only lit green or 0x202020 grey; the cyan frame row of the 37-row
        # layout lands here instead and shows 0x003030 / 0x00FFFF.  (Checking a
        # single far-right pixel does NOT work: past bit 32 the probe rows fall
        # through to the same grey background.)
        def barlike(c):
            return (c[1] > 128 and c[0] < 110 and c[2] < 110) or \
                   all(abs(v - 32) < 24 for v in c)
        y38 = y0 + row_y(38, sy39)
        bad = [px[x0 + int((b + 0.5) * sx), y38] for b in range(0, 32, 3)]
        bad = [c for c in bad if not barlike(c)]
        if bad:
            print(f"{path}: bottom row shows {bad[0]}, which is not a bar -- this "
                  f"core has no ratio rows (37-row overlay, r1probe/fhfix era).  "
                  f"Boot an RBF built from the read-cache branch.")
            continue

        w = bar(px, W, x0, sx, y0 + row_y(37, sy39), "red")
        h = bar(px, W, x0, sx, y38, "green")
        print(f"{path}  (panel {pw}x{ph}px at x={x0},y={y0})")
        print(f"   WAIT ratio  {w:2d}/64 = {100 * w / 64:5.1f}%   "
              f"(T-states the CPU spent stalled)")
        print(f"   HIT  ratio  {h:2d}/64 = {100 * h / 64:5.1f}%   "
              f"(ch2 reads answered from the cache)")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    main(sys.argv[1:])
