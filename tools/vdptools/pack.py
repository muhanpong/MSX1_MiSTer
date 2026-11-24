#!/usr/bin/env python3
"""Pack vdptools.rom: bank 0 = bank0.bin (sjasmplus), then each .COM from a bank start.
Writes banks.inc first (run, assemble, run again with --rom)."""
import sys, os
H = os.path.dirname(os.path.abspath(__file__))
PROGS = [("CHK", "VDPCHK.COM"), ("REG", "VDPREG.COM"), ("VIEW", "VDPVIEW.COM"), ("INT", "VDPINT.COM"),
         ("DIAG", "VDPDIAG.COM"), ("STRS", "VRAMSTRS.COM"), ("TEST", "VDPTEST.COM"), ("RW", "VRAMRW.COM")]
BANK = 0x4000
PATCH = {"VIEW": 2, "INT": 2, "DIAG": 2, "STRS": 1}
bank = 1
layout = []
for name, fn in PROGS:
    data = bytearray(open(os.path.join(H, "com", fn), "rb").read())
    # OUT (0AAh),A / IN A,(0A9h) -> OUT (0AAh),A / RST 30h / NOP (pad on the keyboard)
    hits = [i for i in range(2, len(data) - 1) if data[i:i+2] == b"\xDB\xA9" and data[i-2:i] == b"\xD3\xAA"]
    assert len(hits) == PATCH.get(name, 0), (fn, [hex(0x100 + i) for i in hits])
    for i in hits:
        data[i:i+2] = b"\xF7\x00"
    data = bytes(data)
    assert 0x100 + len(data) < 0xE000, fn
    layout.append((name, bank, data))
    bank += (len(data) + BANK - 1) // BANK
with open(os.path.join(H, "banks.inc"), "w") as f:
    for name, b, data in layout:
        f.write(f"B_{name}\t= {b}\nL_{name}\t= {len(data)}\n")
if "--rom" in sys.argv:
    rom = bytearray(b"\xFF" * 0x80000)
    b0 = open(os.path.join(H, "bank0.bin"), "rb").read()
    assert len(b0) == BANK, len(b0)
    rom[0:BANK] = b0
    for name, b, data in layout:
        rom[b * BANK: b * BANK + len(data)] = data
    open(os.path.join(H, "vdptools.rom"), "wb").write(rom)
    print(f"vdptools.rom: {bank} banks used of 32")
