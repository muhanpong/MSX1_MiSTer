#!/usr/bin/env python3
"""Replica of rtl/peripheral/slots/mapper_detect.sv (bank-write histogram) for a ROM file."""
import sys
d = open(sys.argv[1], "rb").read()
asc16 = asc8 = kon4 = kon5 = 0
for i in range(len(d) - 2):
    if d[i] == 0x32 and d[i+1] == 0:
        a2 = d[i+2]
        if a2 in (0x60, 0x70): asc16 += 1; asc8 += 1
        if a2 in (0x68, 0x78): asc8 += 1; asc16 -= 1
        if a2 in (0x60, 0x80, 0xA0): kon4 += 1
        if a2 in (0x50, 0x70, 0x90, 0xB0): kon5 += 1
kon = max(kon4, kon5); ascii_ = max(asc8, asc16)
m = (("KONAMI_SCC" if kon5 > kon4 else "KONAMI") if kon >= ascii_ else ("ASCII8" if asc8 > asc16 else "ASCII16"))
print(f"asc16={asc16} asc8={asc8} kon4={kon4} kon5={kon5} -> {m}")
