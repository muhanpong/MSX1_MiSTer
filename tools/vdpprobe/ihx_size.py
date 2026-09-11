#!/usr/bin/env python3
"""Length of the .COM image in an Intel hex file linked at 0x0100."""
import sys

hi = 0
for line in open(sys.argv[1]):
    if not line.startswith(':'):
        continue
    n, addr, rtype = int(line[1:3], 16), int(line[3:7], 16), int(line[7:9], 16)
    if rtype == 0 and n:
        hi = max(hi, addr + n)
print(hi - 0x100)
