#!/usr/bin/env python3
# Reconstruct the ch4 read-address trace from /tmp/rlog_dump.txt.
# Encoding: even idx (2k)=  {6'd0,addr[21:16]},  odd idx (2k+1)= addr[15:0]
#   -> addr = (w[2k]<<16) | w[2k+1]   (22-bit ms_mem_addr, byte address)
import sys

words = []
with open("/tmp/rlog_dump.txt") as f:
    for ln in f:
        ln = ln.strip()
        if ln:
            words.append(int(ln, 16))

# Robust hi/lo orientation: the {6'd0,addr[21:16]} stream is always <=0x3F.
# Detect which interleaved phase holds it (don't assume write/read order).
even = words[0::2]
odd  = words[1::2]
even_is_hi = max(even) <= 0x3F
odd_is_hi  = max(odd)  <= 0x3F
addrs = []
for k in range(0, len(words) - 1, 2):
    a, b = words[k], words[k + 1]
    if odd_is_hi and not even_is_hi:
        hi, lo = b & 0x3F, a          # even=addr[15:0], odd={..,addr[21:16]}
    else:
        hi, lo = a & 0x3F, b          # even={..,addr[21:16]}, odd=addr[15:0]
    addrs.append((hi << 16) | lo)
print(f"orientation: even_is_hi={even_is_hi} odd_is_hi={odd_is_hi}")

nz = [a for a in addrs if a != 0]
print(f"total pairs: {len(addrs)}   non-zero: {len(nz)}")
if not nz:
    print("ALL-ZERO → buffer not filled. Play 122->123 (key-on slot 0) first, then re-dump.")
    sys.exit(0)

# yrw801 wave-123 landmarks (from msx.sv checkers)
HDR_LO, HDR_HI = 0x5C4, 0x5CE        # wave-123 header words
SMP123 = 0x0CBC46                    # wave-123 sample start

def tag(a):
    if HDR_LO <= a <= HDR_HI: return "HDR123"
    if 0x0CBC46 <= a <= 0x0CBD00: return "SMP123"
    if a < 0x600: return "hdr?"
    return ""

# find the LAST contiguous filled run (the captured onset)
print("\n# idx  addr      tag        (first 60 reads)")
for i, a in enumerate(addrs[:60]):
    print(f"{i:4d}  0x{a:06X}  {tag(a)}")

# locate where header-123 reads and sample-123 reads first appear
def first_idx(pred):
    for i, a in enumerate(addrs):
        if pred(a): return i
    return None

hdr_i = first_idx(lambda a: HDR_LO <= a <= HDR_HI)
smp_i = first_idx(lambda a: 0x0CBC46 <= a <= 0x0CBD00)
print(f"\nfirst HDR123 read at pair idx: {hdr_i}")
print(f"first SMP123 read at pair idx: {smp_i}")
if hdr_i is not None and smp_i is not None:
    if hdr_i < smp_i:
        print(f"=> header fetched BEFORE new-wave samples (Δ={smp_i-hdr_i} reads) — stall-then-play OK")
    else:
        print(f"=> NEW-WAVE SAMPLES read BEFORE header (Δ={hdr_i-smp_i} reads) — STALE-HEADER onset = direction glitch")

# address span / histogram of high bytes to see region transitions
from collections import Counter
hi_hist = Counter(a >> 12 for a in nz)
print("\nhigh-nibble[21:12] histogram (region):")
for k in sorted(hi_hist):
    print(f"  0x{k:03X}xxx : {hi_hist[k]}")
