#!/usr/bin/env python3
"""
golden_pcm.py + CPU wave-RAM access + ONE behaviour restored from YMF278.cc,
isolated so any difference has a single cause.

YMF278.cc writeRegDirect case 0 (wave-number write), lines 594-622:

        if (slot.keyon) {
                keyOnHelper(slot);          // env restart + stepPtr=0 + pos=0
        } else {
                slot.stepPtr = 0;           // <-- POSITION IS RESET EVEN WHEN
                slot.pos     = 0;           //     THE SLOT IS *NOT* KEYED ON
        }

golden_pcm.py implements only the keyon branch (it sets self.retrig[n]); the
else branch is missing.  ymf278_pcm_engine2.sv has the same gap: key_retrig is
set by `(wr_field == 4'd0) && cur_r.keyon` only, and ram_dyn[n].pos is written
nowhere else.  So the RTL and the golden model agree with each other while both
differ from openMSX/hardware for "wave number written while the slot is
releasing or silent" — i.e. exactly the mass-key-off-then-re-program sequence
of a song change.

Because generateChannels() emits the sample BEFORE advancing pos, the frame
that follows the write is rendered at pos == 0 (no advance), the same way a
key-on edge is handled.  That is modelled here by reusing golden_pcm's edge
path for the position only, leaving the envelope alone — done by rewriting two
lines of golden_pcm.py's gen_frame at import time so the rest of the model
stays byte-identical (no forked copy that can drift).

Usage: golden_pcm_omsx.py <script.txt> <mem.bin> <frames> <out.txt>
"""
import sys, os, types

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

_SRC = open(os.path.join(HERE, 'golden_pcm.py')).read()

_A_OLD = "            edge = self.retrig[n]      # RTL: write-time retrig latch covers all edges"
_A_NEW = ("            edge = self.retrig[n]\n"
          "            pclr = self.posclr[n]      # openMSX case-0 else-branch")
_B_OLD = """            if edge:
                s.pos = 0
                s.stepPtr = 0
            else:"""
_B_NEW = """            if edge or pclr:
                s.pos = 0
                s.stepPtr = 0
                self.posclr[n] = False
            else:"""
assert _A_OLD in _SRC and _B_OLD in _SRC, "golden_pcm.py changed — re-check the patch anchors"
_SRC = _SRC.replace(_A_OLD, _A_NEW).replace(_B_OLD, _B_NEW)

_mod = types.ModuleType('golden_pcm_patched')
_mod.__file__ = os.path.join(HERE, 'golden_pcm.py')
exec(compile(_SRC, _mod.__file__, 'exec'), _mod.__dict__)


class OpenMsxEngine(_mod.Engine):
    def __init__(self, memory):
        super().__init__(memory)
        self.posclr = [False] * 24
        self.cpu_adr = 0

    def write(self, addr, data):
        # CPU wave-RAM port (engine2.sv:1114-1128) — golden_pcm.py ignores it
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
        if 0x08 <= addr <= 0x1F:                       # field 0 = wave LSB
            n = addr - 0x08
            if not self.slots[n].keyon:
                self.posclr[n] = True                  # YMF278.cc case 0 else
        super().write(addr, data)


def main():
    script_f, mem_f, frames, out_f = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
    eng = OpenMsxEngine(list(open(mem_f, 'rb').read()))
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
    print(f"golden(openMSX case0): {frames} frames -> {out_f}")


if __name__ == "__main__":
    main()
