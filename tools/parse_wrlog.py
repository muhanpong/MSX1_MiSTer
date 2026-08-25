#!/usr/bin/env python3
# Reconstruct the post-CDC MoonSound register-WRITE stream from /tmp/rlog_dump.txt.
# word = {port==0x7F (bit15), 7'd0, data[7:0]}.  Circular buffer frozen 32 writes
# after the wave-123 write (0x7E=0x08 then 0x7F=0x7B).
# Goal: does KEY-ON (0x68<-0x80) reach clk_sdram BEFORE the wave write (0x08<-0x7B)?
import sys
words = [int(l.strip(),16) for l in open("/tmp/rlog_dump.txt") if l.strip()]

def events(seq):
    """reconstruct (index,value) register writes from a 7E/7F port stream."""
    idx = None; out = []
    for w in seq:
        is_data = (w >> 15) & 1
        d = w & 0xFF
        if not is_data:        # 0x7E: register index
            idx = d
        else:                  # 0x7F: data write to current index
            out.append((idx, d))
    return out

def name(i, v):
    if i == 0x08: return f"WAVE_LSB <- 0x{v:02X}" + ("  <== 123" if v == 0x7B else "")
    if i == 0x20: return f"WAVE_MSB/FN <- 0x{v:02X}"
    if i == 0x68: return f"KEY {'ON' if v & 0x80 else 'OFF'} (0x68 <- 0x{v:02X})"
    if i is None: return f"data 0x{v:02X} (no index)"
    return f"reg0x{i:02X} <- 0x{v:02X}"

for tag, seq in (("FILE ORDER", words), ("REVERSED", words[::-1])):
    ev = events(seq)
    # locate the wave-123 write
    w123 = [k for k,(i,v) in enumerate(ev) if i == 0x08 and v == 0x7B]
    kon  = [k for k,(i,v) in enumerate(ev) if i == 0x68 and (v & 0x80)]
    print(f"\n===== {tag}: {len(ev)} reg-writes, wave123@{w123[:3]}, keyon@{kon[:5]} =====")
    if not w123:
        print("  (no wave-123 write found in this orientation)")
        continue
    # show a window around the LAST wave-123 write
    c = w123[-1]
    lo = max(0, c-14); hi = min(len(ev), c+6)
    for k in range(lo, hi):
        i, v = ev[k]
        mark = " <<< wave-123" if k == c else (" <<< KEY-ON" if (i==0x68 and v&0x80) else "")
        print(f"  [{k:3d}] {name(i,v)}{mark}")
    # verdict: nearest key-on before the wave-123 write?
    kb = [k for k in kon if k < c]
    print(f"  -> key-ON writes before wave-123: {kb[-3:] if kb else 'NONE'}"
          + (f" (gap {c-kb[-1]} writes)" if kb else "  *** NO KEY-ON BEFORE WAVE — delivery suspect ***"))
