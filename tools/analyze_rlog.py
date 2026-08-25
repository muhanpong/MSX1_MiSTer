#!/usr/bin/env python3
# Ordering-agnostic analysis of the RLOG ch4 read-address trace.
import sys
words = [int(l.strip(),16) for l in open("/tmp/rlog_dump.txt") if l.strip()]
even, odd = words[0::2], words[1::2]
odd_is_hi = max(odd) <= 0x3F
addrs = []
for k in range(0, len(words)-1, 2):
    a,b = words[k], words[k+1]
    hi,lo = (b&0x3F,a) if odd_is_hi else (a&0x3F,b)
    addrs.append((hi<<16)|lo)

HDR_LO,HDR_HI = 0x5C4,0x5CE
def is_hdr(a): return HDR_LO<=a<=HDR_HI
def is_low(a): return a < 0x600

hdr_idx = [i for i,a in enumerate(addrs) if is_hdr(a)]
low_idx = [i for i,a in enumerate(addrs) if is_low(a)]
smp = [a for a in addrs if a>=0x600]
print(f"pairs={len(addrs)}  header(0x5C4..CE) reads at file idx: {hdr_idx}")
print(f"all low(<0x600) reads at file idx: {low_idx}")
if smp:
    print(f"sample region: min=0x{min(smp):06X} max=0x{max(smp):06X} span={max(smp)-min(smp)} bytes")
    print(f"  wave-123 sample START = 0x0CBC46 ; wave-123 header @0x5C4")

# Is the sample stream monotonic in FILE order? (tells us if file == time or reversed)
s = [a for a in addrs if a>=0x600]
inc = sum(1 for i in range(1,len(s)) if s[i]>s[i-1])
dec = sum(1 for i in range(1,len(s)) if s[i]<s[i-1])
print(f"\nsample monotonicity in FILE order: inc-steps={inc} dec-steps={dec}")
print("  (PCM plays ASCENDING in time; if file is mostly DEC, file == reverse-time)")
file_is_reverse = dec > inc
print(f"  => file order is {'REVERSE-time (line0 = newest)' if file_is_reverse else 'FORWARD-time (line0 = oldest)'}")

# Put header position in TIME order
n=len(addrs)
def to_time(i): return (n-1-i) if file_is_reverse else i
hdr_time = sorted(to_time(i) for i in hdr_idx)
print(f"\nheader reads in TIME order at idx: {hdr_time}")
if hdr_time:
    first_h = hdr_time[0]
    print(f"first header fetch at TIME idx {first_h}/{n}  ({'EARLY/onset' if first_h < n*0.1 else 'LATE — '+str(round(100*first_h/n))+'% into window'})")

# show the transition zone in TIME order around the header
print("\n# TIME-ordered trace around the header cluster (idx : addr):")
order = list(range(n-1,-1,-1)) if file_is_reverse else list(range(n))
tlist = [addrs[i] for i in order]
hpos = [ti for ti,a in enumerate(tlist) if is_hdr(a)]
if hpos:
    lo = max(0, hpos[0]-8); hi = min(n, hpos[-1]+12)
    for ti in range(lo,hi):
        a=tlist[ti]; m="<-- HEADER" if is_hdr(a) else ("<-- low" if is_low(a) else "")
        print(f"  t{ti:4d}  0x{a:06X} {m}")
