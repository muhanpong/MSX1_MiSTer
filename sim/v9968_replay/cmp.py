#!/usr/bin/env python3
"""cmp.py <rtl.ppm> <oracle.png> [--shift N]: compare an RTL frame dump (320x240 PPM,
sim/v9968_replay) with an openMSX `screenshot -raw` PNG (320x240).  The RTL dump is
indexed by the VDP's screen position and lags by a fixed few pixels, so the best
horizontal/vertical shift within +-16/+-8 is searched first (reported), then the
mean absolute RGB difference and the share of exactly equal pixels at that shift.
Pure python (no PIL): PNG filters 0-4, 8-bit RGB/RGBA, non-interlaced."""
import sys, zlib, struct

def read_png(p):
    d = open(p, 'rb').read(); i = 8; idat = b''
    while i < len(d):
        n = struct.unpack('>I', d[i:i+4])[0]; t = d[i+4:i+8]; c = d[i+8:i+8+n]
        if t == b'IHDR': w, h, depth, ctype = struct.unpack('>IIBB', c[:10])
        if t == b'IDAT': idat += c
        i += 12 + n
    assert depth == 8 and ctype in (2, 6), (depth, ctype)
    bpp = 3 if ctype == 2 else 4
    raw = zlib.decompress(idat); stride = w * bpp
    out = bytearray(); prev = bytearray(stride); pos = 0
    for y in range(h):
        f = raw[pos]; line = bytearray(raw[pos+1:pos+1+stride]); pos += 1 + stride
        for x in range(stride):
            a = line[x-bpp] if x >= bpp else 0; b = prev[x]; c = prev[x-bpp] if x >= bpp else 0
            if f == 1: line[x] = (line[x] + a) & 255
            elif f == 2: line[x] = (line[x] + b) & 255
            elif f == 3: line[x] = (line[x] + ((a + b) >> 1)) & 255
            elif f == 4:
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[x] = (line[x] + pr) & 255
        out += line; prev = line
    px = [[tuple(out[(y*w+x)*bpp:(y*w+x)*bpp+3]) for x in range(w)] for y in range(h)]
    return w, h, px

def read_ppm(p):
    d = open(p, 'rb').read()
    parts = d.split(b'\n', 3); assert parts[0] == b'P6'
    w, h = map(int, parts[1].split()); body = parts[3]
    px = [[tuple(body[(y*w+x)*3:(y*w+x)*3+3]) for x in range(w)] for y in range(h)]
    return w, h, px

def diff(a, b, dx, dy, w, h, step=1):
    n = 0; s = 0; eq = 0
    for y in range(8, h - 8, step):
        ra = a[y]; rb = b[y + dy]
        for x in range(16, w - 16, step):
            pa = ra[x]; pb = rb[x + dx]
            d = abs(pa[0]-pb[0]) + abs(pa[1]-pb[1]) + abs(pa[2]-pb[2])
            s += d; n += 1
            if d <= 6: eq += 1         # the V9968 palette's 5-bit DAC vs openMSX's 8-bit
    return s / (3 * n), eq / n

if __name__ == '__main__':
    rtl = sys.argv[1]; orc = sys.argv[2]
    w, h, a = read_ppm(rtl); w2, h2, b = read_png(orc)
    assert (w, h) == (w2, h2), ((w, h), (w2, h2))
    best = None
    for dy in range(-8, 9):
        for dx in range(-16, 17):
            m, e = diff(a, b, dx, dy, w, h, step=3)
            if best is None or m < best[0]: best = (m, e, dx, dy)
    m, e, dx, dy = best
    m, e = diff(a, b, dx, dy, w, h, step=1)
    print(f"{rtl} vs {orc}: shift dx={dx} dy={dy}  mean|diff| {m:.2f}/255  equal(<=6) {100*e:.1f}%")
