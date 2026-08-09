#!/usr/bin/env python3
"""
golden_pcm.py + CPU wave-RAM access (regs 0x03/0x04/0x05/0x06).

The stock model ignores those registers, so any scenario that uploads sample
data cannot be compared with it.  This wrapper subclasses the model's Engine
and adds the 24-bit address latch + auto-incrementing data port, matching
ymf278_pcm_engine2.sv:1114-1128 (03=A[23:16], 04=A[15:8], 05=A[7:0],
06=data, address++ after each data write).  Everything else is inherited
unchanged, so the two models stay bit-identical for non-memory scenarios.

Usage: golden_pcm_memwr.py <script.txt> <mem.bin> <frames> <out.txt>
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import golden_pcm as G


class MemWrEngine(G.Engine):
    def __init__(self, memory):
        super().__init__(memory)
        self.cpu_adr = 0

    def write(self, addr, data):
        if addr == 0x03:
            self.cpu_adr = (self.cpu_adr & 0x00FFFF) | (data << 16); return
        if addr == 0x04:
            self.cpu_adr = (self.cpu_adr & 0xFF00FF) | (data << 8);  return
        if addr == 0x05:
            self.cpu_adr = (self.cpu_adr & 0xFFFF00) | data;         return
        if addr == 0x06:
            if self.cpu_adr < len(self.mem):
                self.mem[self.cpu_adr] = data
            self.cpu_adr = (self.cpu_adr + 1) & 0xFFFFFF
            return
        super().write(addr, data)


def main():
    script_f, mem_f, frames, out_f = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
    eng = MemWrEngine(list(open(mem_f, 'rb').read()))
    writes = {}
    for ln in open(script_f):
        ln = ln.split('#')[0].strip()
        if not ln:
            continue
        cols = ln.split()
        writes.setdefault(int(cols[0]), []).append((int(cols[1], 16), int(cols[2], 16)))
    with open(out_f, 'w') as out:
        for fr in range(frames):
            for ad, da in writes.get(fr, []):
                eng.write(ad, da)
            l, r = eng.gen_frame()
            out.write(f"{l} {r}\n")
    print(f"golden(memwr): {frames} frames -> {out_f}")


if __name__ == "__main__":
    main()
