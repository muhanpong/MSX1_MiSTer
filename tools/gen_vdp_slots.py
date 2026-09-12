#!/usr/bin/env python3
"""Regenerate rtl/video/VDP/vdp_slot_pack.vhd from openMSX's measured tables.

The slot positions are logic-analyser measurements of a real V9938 (openMSX
team, 2013).  We copy them rather than deriving them: the pattern is what is
left over after the chip's hard-wired display fetches, sprite fetches and DRAM
refresh have taken their cycles, so there is no closed form to derive.

usage: tools/gen_vdp_slots.py [path/to/openMSX/src/video/VDPAccessSlots.cc]
"""
import re, sys, pathlib

SRC = sys.argv[1] if len(sys.argv) > 1 else \
    str(pathlib.Path.home() / "Documents/github/openMSX/src/video/VDPAccessSlots.cc")
OUT = "rtl/video/VDP/vdp_slot_pack.vhd"

# bit order must match the RTL: 0 = screen off, 1 = sprites on, 2 = sprites off
TABLES = [("SCREENOFF", "slotsScreenOff"),
          ("SPRITESON", "slotsSpritesOn"),
          ("SPRITESOFF", "slotsSpritesOff")]

def parse(src, name):
    # each array carries cyclic duplicates past 1368; only the first N are real
    m = re.search(r'std::array<int16_t,\s*(\d+)\s*\+\s*\d+>\s*' + name +
                  r'\s*=\s*\{(.*?)\};', src, re.S)
    if not m:
        sys.exit(f"{name} not found in {SRC}")
    n, body = int(m.group(1)), re.sub(r'1368\s*\+\s*', '1368+', m.group(2))
    vals = [1368 + int(t[5:]) if t.startswith('1368+') else int(t)
            for t in (x.strip() for x in body.split(',')) if t]
    real = vals[:n]
    assert all(real[i] < real[i + 1] for i in range(len(real) - 1)), name
    assert 0 <= real[0] and real[-1] < 1368, name
    return real

def main():
    src = open(SRC).read()
    slots = {k: parse(src, v) for k, v in TABLES}
    mask = [0] * 1368
    for bit, (k, _) in enumerate(TABLES):
        for p in slots[k]:
            mask[p] |= 1 << bit
    for bit, (k, _) in enumerate(TABLES):          # round-trip
        assert [p for p in range(1368) if mask[p] >> bit & 1] == slots[k], k
        print(f"  {k:11s} {len(slots[k]):4d} slots/line  round-trip OK")

    rows = []
    for r in range(0, 1368, 12):
        cells = ', '.join(f'"{mask[p]:03b}"' for p in range(r, min(r + 12, 1368)))
        rows.append(f"        {cells}{',' if r + 12 < 1368 else ''}   -- {r}")
    hdr = open(OUT).read().split("PACKAGE")[0] if pathlib.Path(OUT).exists() else ""
    if not hdr:
        sys.exit(f"{OUT} missing: keep its header, this script only refills the table")
    open(OUT, "w").write(hdr + "PACKAGE VDP_SLOT_PACK IS\n"
        "    TYPE SLOT_MAP_T IS ARRAY(0 TO 1367) OF STD_LOGIC_VECTOR(2 DOWNTO 0);\n"
        "    CONSTANT SLOT_MAP : SLOT_MAP_T := (\n" + "\n".join(rows) +
        "\n    );\nEND PACKAGE;\n")
    print(f"  -> {OUT}")

main()
