#!/usr/bin/env python3
"""The keypad map exists in two places that must never drift apart.

  1. rtl/peripheral/kbd.mif                     -- the bitstream default
  2. kbd_keypad() in memory_upload.sv           -- the fill applied while a
                                                   machine pack overwrites (1)

If (2) ever disagrees with (1), the keypad silently changes behaviour the
moment a ROM PACK is loaded, which is exactly the failure this fix exists to
prevent.  This checker also re-derives the 15 shipped entries from
releases/CreateMSXpack/MSX/Sony/Sony_HB-F1XV_128KB.MSX when that pack is
present locally, so the values stay anchored to a real artifact rather than to
a transcription.

Run:  python3 sim/check_keypad_consts.py
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MIF = os.path.join(ROOT, "rtl/peripheral/kbd.mif")
UPLOAD = os.path.join(ROOT, "rtl/peripheral/slots/memory_upload.sv")
PACK = os.path.join(ROOT, "releases/CreateMSXpack/MSX/Sony/Sony_HB-F1XV_128KB.MSX")

KEYPAD_ROWS = (9, 10)


def read_mif(path):
    data = bytearray(512)
    seen = set()
    for m in re.finditer(r"^\s*([0-9A-Fa-f]+)\s*:\s*([0-9A-Fa-f ]+);",
                         open(path).read(), re.M):
        addr = int(m.group(1), 16)
        for i, v in enumerate(m.group(2).split()):
            data[addr + i] = int(v, 16)
            seen.add(addr + i)
    if len(seen) != 512:
        raise SystemExit(f"{path}: covers {len(seen)} of 512 entries")
    return bytes(data)


def read_rtl_case(path):
    """Pull the address -> value pairs out of the kbd_keypad() case."""
    src = open(path).read()
    m = re.search(r"function\s+\[7:0\]\s+kbd_keypad\b.*?endfunction", src, re.S)
    if not m:
        raise SystemExit(f"{path}: kbd_keypad() not found")
    body = m.group(0)
    out = {}
    for a, v in re.findall(r"9'h([0-9A-Fa-f]{3})\s*:\s*kbd_keypad\s*=\s*8'h([0-9A-Fa-f]{2})",
                           body):
        out[int(a, 16)] = int(v, 16)
    if "default: kbd_keypad = 8'hFF" not in body.replace("default : ", "default: "):
        raise SystemExit(f"{path}: kbd_keypad() default must be 8'hFF")
    return out


def read_pack_keymap(path):
    """Locate the 512-byte KBD_LAYOUT block in a built .MSX pack."""
    blob = open(path, "rb").read()
    for m in re.finditer(b"MSX", blob):
        o = m.start()
        if blob[o + 3] == 0x50 and o + 16 + 512 <= len(blob):
            return blob[o + 16:o + 16 + 512]
    return None


def main():
    errors = []
    mif = read_mif(MIF)
    rtl = read_rtl_case(UPLOAD)

    # 1. every keypad entry in the mif must be reproduced by the RTL fill
    mif_keypad = {a: b for a, b in enumerate(mif) if (b >> 4) in KEYPAD_ROWS}
    for a, b in sorted(mif_keypad.items()):
        if rtl.get(a) != b:
            errors.append(f"0x{a:03X}: mif has {b:02X}, kbd_keypad() has "
                          f"{'absent' if a not in rtl else f'{rtl[a]:02X}'}")

    # 2. and the RTL must not invent entries the mif does not have
    for a, b in sorted(rtl.items()):
        if mif[a] != b:
            errors.append(f"0x{a:03X}: kbd_keypad() has {b:02X}, mif has {mif[a]:02X}")

    # 3. both keypad rows must be complete -- all 8 columns reachable
    for row in KEYPAD_ROWS:
        bits = sorted(b & 0x0F for b in mif if (b >> 4) == row)
        if bits != list(range(8)):
            errors.append(f"row {row} incomplete: columns {bits}")

    # 4. anchor against the shipped pack, when it is available locally
    if os.path.exists(PACK):
        packmap = read_pack_keymap(PACK)
        if packmap is None:
            errors.append(f"{PACK}: no KBD_LAYOUT block found")
        else:
            n = 0
            for a, b in enumerate(packmap):
                if (b >> 4) in KEYPAD_ROWS:
                    n += 1
                    if mif[a] != b:
                        errors.append(f"0x{a:03X}: shipped pack has {b:02X}, "
                                      f"mif has {mif[a]:02X}")
            print(f"anchored against {os.path.relpath(PACK, ROOT)}: {n} keypad entries")
    else:
        print("note: reference pack not present locally, skipping the anchor check")

    if errors:
        print("FAIL")
        for e in errors:
            print("  " + e)
        return 1
    print(f"PASS: {len(mif_keypad)} keypad entries agree across kbd.mif and "
          f"kbd_keypad(); rows 9 and 10 complete")
    return 0


if __name__ == "__main__":
    sys.exit(main())
