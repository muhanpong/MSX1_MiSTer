#!/usr/bin/env python3
"""SignalTap CSV export (scc_stp[55:0] probe, 2026-09-05 layout) -> replay_events.txt.

Layout (rtl/peripheral/slots/scc_sound.sv, `ifdef SCC_STP`):
  [10:0] wave_A  [18:11] din  [26:19] addr[7:0]  [42:27] tick  [43] B8win  [44] 98win
  [46:45] mode_A [47] cs_A [48] wr_A [49] rd_A [50] wr_pulse [51] rd_pulse
  [52] wave_chg  [53] jump>=192  [54] cs raw  [55] cart_num

Accepts either one grouped bus column (hex/binary/decimal) or 56 single-bit columns.
Emits `<tick> <addr_lo_hex> <val_hex>` for every write (wr_pulse), tick unwrapped
from the 16-bit counter, plus an anomaly summary on stderr.
"""
import sys, re, csv

def parse(path):
    rows = []
    with open(path, newline='') as f:
        lines = [l for l in f if l.strip()]
    # find header line: the one mentioning scc_stp
    hi = next(i for i, l in enumerate(lines) if 'scc_stp' in l)
    rd = list(csv.reader(lines[hi:]))
    hdr = [h.strip() for h in rd[0]]
    bitcols = {}
    buscol = None
    for i, h in enumerate(hdr):
        m = re.search(r'scc_stp\[(\d+)\]$', h)
        if m: bitcols[int(m.group(1))] = i
        elif re.search(r'scc_stp(\[55\.\.0\]|\[55:0\])?$', h) or h.endswith('scc_stp'): buscol = i
    for r in rd[1:]:
        if len(r) < len(hdr) or any(c.strip() == 'X' for c in r[1:]): continue  # unfilled buffer
        try:
            if len(bitcols) >= 56:
                v = 0
                for b, c in bitcols.items():
                    if r[c].strip() in ('1', "1'b1", 'H'): v |= 1 << b
            else:
                s = r[buscol].strip().replace(' ', '')
                v = int(s, 16) if re.match(r'^[0-9A-Fa-f]+h?$', s) and not s.isdigit() else int(s, 0) if not s.isdigit() else int(s)
                if re.match(r'^[01]{56}$', s): v = int(s, 2)
        except Exception:
            continue
        rows.append(v)
    return rows

def field(v, lo, hi): return (v >> lo) & ((1 << (hi - lo + 1)) - 1)

def main():
    src, dst = sys.argv[1], sys.argv[2]
    rows = parse(src)
    out = open(dst, 'w')
    last_tick = None; base = 0; n_w = n_r = 0
    modes = set(); win = {'B8': 0, '98': 0, 'none': 0}; mode_flips = 0; prev_mode = None
    for v in rows:
        t16 = field(v, 27, 42)
        if last_tick is not None and t16 < last_tick: base += 1 << 16
        last_tick = t16
        tick = base + t16
        mode = field(v, 45, 46); modes.add(mode)
        if prev_mode is not None and mode != prev_mode: mode_flips += 1
        prev_mode = mode
        if v >> 50 & 1:
            n_w += 1
            out.write(f"{tick} {field(v,19,26):02x} {field(v,11,18):02x}\n")
            win['B8' if v >> 43 & 1 else '98' if v >> 44 & 1 else 'none'] += 1
        elif v >> 51 & 1:
            n_r += 1
    out.close()
    span = (base + (last_tick or 0)) / 3579545.0 if rows else 0
    print(f"samples={len(rows)} writes={n_w} reads={n_r} span={span*1e3:.1f}ms "
          f"modes={sorted(modes)} mode_flips={mode_flips} windows={win}", file=sys.stderr)

if __name__ == '__main__': main()
