#!/usr/bin/env python3
"""Decode a SignalTap CSV export of msx.sv's 48-bit stp_data bus.

Column i+1 of each data row is stp_data[i]; the layout is fixed by rtl/msx.sv:

    [15:0]  a            [23:16] d_from_cpu   [31:24] d_to_cpu
    [32] wr_n [33] rd_n [34] iorq_n [35] mreq_n [36] m1_n [37] wait_n
    [45:38] ppi_out_a    [47:46] spare

Emits one record per *bus cycle* (a run of identical strobe+address samples),
which is what you want to read -- the raw stream is 6 clk21m samples per T-state.
"""
import csv, sys
from dataclasses import dataclass

@dataclass
class Cyc:
    first: int          # first sample index of the run
    n: int              # samples held
    a: int
    d_from: int
    d_to: int
    wr_n: int; rd_n: int; iorq_n: int; mreq_n: int; m1_n: int; wait_n: int
    slot: int

    @property
    def kind(self):
        if not self.mreq_n and not self.m1_n: return 'M1'
        if not self.mreq_n and not self.rd_n:  return 'MR'
        if not self.mreq_n and not self.wr_n:  return 'MW'
        if not self.iorq_n and not self.m1_n:  return 'INTACK'
        if not self.iorq_n and not self.rd_n:  return 'IOR'
        if not self.iorq_n and not self.wr_n:  return 'IOW'
        return '--'

    @property
    def data(self):
        return self.d_from if self.kind in ('MW','IOW') else self.d_to

    def __str__(self):
        k = self.kind
        d = f"{self.data:02X}" if k != '--' else '..'
        return (f"{self.first:6d} {k:6s} a={self.a:04X} d={d} "
                f"slot={self.slot:02X} n={self.n}")

def load(path):
    rows, hdr = [], None
    with open(path) as f:
        started = False
        for line in f:
            line = line.strip()
            if line.startswith('time unit'):
                hdr = line; started = True; continue
            if not started or not line: continue
            parts = [p.strip() for p in line.split(',')]
            if len(parts) < 49: continue
            bits = parts[1:49]
            if any(b not in ('0','1') for b in bits):
                continue                      # leading all-X sample
            v = 0
            for i, b in enumerate(bits):
                if b == '1': v |= (1 << i)
            rows.append((int(parts[0]), v))
    return rows

def field(v, hi, lo):
    return (v >> lo) & ((1 << (hi - lo + 1)) - 1)

def cycles(rows):
    out, prev, run_start, run_n = [], None, None, 0
    def mk(v, first, n):
        return Cyc(first, n, field(v,15,0), field(v,23,16), field(v,31,24),
                   (v>>32)&1, (v>>33)&1, (v>>34)&1, (v>>35)&1, (v>>36)&1, (v>>37)&1,
                   field(v,45,38))
    for idx, v in rows:
        # strobes (bits 36:32) + address only; wait_n (37) is EXCLUDED --  Data must NOT be part of the key:
        # it toggles mid-cycle and split every fetch.  Data must not be in the
        # key either: d_to_cpu settles a sample or two in, and splitting on it
        # chopped every fetch into three bogus records.
        key = (((v >> 32) & 0x1F) << 16) | (v & 0xFFFF)   # wr/rd/iorq/mreq/m1
        if prev is not None and key == prev[0]:
            run_n += 1; prev = (key, v)     # keep the LAST value -> settled data
            continue
        if prev is not None:
            out.append(mk(prev[1], run_start, run_n))
        prev, run_start, run_n = (key, v), idx, 1
    if prev is not None:
        out.append(mk(prev[1], run_start, run_n))
    return out

if __name__ == '__main__':
    rows = load(sys.argv[1])
    cyc = [c for c in cycles(rows) if c.kind != '--']
    print(f"# {len(rows)} samples -> {len(cyc)} bus cycles", file=sys.stderr)
    for c in cyc:
        print(c)
