#!/usr/bin/env python3
"""Replay the V9938's VRAM access-slot rule, but prove the model works first.

WHY THIS EXISTS
---------------
A throwaway version of this model was written on 2026-09-13 to judge whether
the RTL or the slot rule was responsible for a timing divergence.  It omitted
one thing: during the vertical border the chip uses the display-OFF slot
column (154 slots per line), not the sprites-on column (31).  Every number it
produced was therefore too slow, the rule looked 8-24% wrong against openMSX,
and that wrong conclusion was reported before the omission was found.

The failure was not the missing line of code.  It was that a brand-new,
unvalidated model disagreed with a documented measurement and the DOCUMENT was
suspected first.  An instrument has to demonstrate it can measure a known
quantity before its reading of an unknown one means anything.

So this script will not answer a question until it has reproduced the openMSX
reference for all seven throttled commands.  If the self-check fails it prints
the failures and exits non-zero, and you should fix the model, not the RTL.

It also reads the slot table and the DELTA tables out of the RTL rather than
carrying its own copies, so the model cannot silently drift away from the
hardware it is supposed to predict.

usage
  tools/vdpslotmodel/slotmodel.py                 self-check only
  tools/vdpslotmodel/slotmodel.py --bias N        self-check, then re-run every
                                                  command with N cycles added to
                                                  each DELTA.  bias=1 is what a
                                                  one-register-too-few counter
                                                  does; it is how the FF_SINCE
                                                  off-by-one was identified.
  tools/vdpslotmodel/slotmodel.py --no-line-minor  drop LINE's minor-axis +32
  tools/vdpslotmodel/slotmodel.py --tol 0.03       self-check tolerance (default 5%)
"""
import argparse, re, sys, pathlib

RTL = pathlib.Path(__file__).resolve().parents[2] / "rtl/video/VDP"

# openMSX references, measured by running tools/vdpprobe/cmdcmp.s under the
# emulator and timing each command with Tcl breakpoints.  GRAPHIC4, display on,
# sprites on, NTSC 192 lines.  Durations in scanlines.
REFERENCE = {
    "HMMV":  722.18, "HMMM": 1466.82, "LMMV": 1476.01, "LMMM": 1744.90,
    "YMMM": 1204.82, "LINE":  897.35, "SRCH":  670.97,
}

# Which delta applies at each step of a command's inner loop, in order, and
# which table it comes from.  Transcribed from the calculator.next(Delta::Dxx)
# calls in openMSX src/video/VDPCmdEngine.cc: the delta named by a next() call
# is the wait before the FOLLOWING access, so a loop is read as a cycle.
#   "wr"    -> WR_DELTA            (the wait before a write)
#   "rd_aw" -> RD_DELTA_AFTER_WR   (before a read that follows a write)
#   "rd_ar" -> RD_DELTA_AFTER_RD   (before a read that follows a read)
STEPS = {
    "HMMV": ["wr"],                    # write only
    "HMMM": ["wr", "rd_aw"],           # src read, write
    "LMMV": ["wr", "rd_aw"],           # dst read, write
    "YMMM": ["wr", "rd_aw"],           # src read, write
    "LMMM": ["wr", "rd_aw", "rd_ar"],  # src read, dst read, write
    "LINE": ["wr", "rd_aw"],           # dst read, write (+32 on a minor step)
    "SRCH": ["rd_ar"],                 # read only
}

def read(name):
    return (RTL / name).read_text()

def slot_tables():
    """SLOT_MAP from the RTL, re-indexed to our H_CNT via SLOT_OFFSET."""
    off = int(re.search(r"CONSTANT SLOT_OFFSET\s*:\s*INTEGER\s*:=\s*(\d+)",
                        read("vdp_access_slots.vhd")).group(1))
    bits = re.findall(r'"([01]{3})"', read("vdp_slot_pack.vhd"))
    if len(bits) != 1368:
        sys.exit(f"slot table has {len(bits)} entries, expected 1368")
    # VHDL "abc": a is bit 2 (sprites off), b is bit 1 (sprites on),
    # c is bit 0 (display off / vertical border).
    on, off_spr, blank = [[False]*1368 for _ in range(3)]
    for i, v in enumerate(bits):
        h = (i - off) % 1368
        blank[h], on[h], off_spr[h] = v[2] == "1", v[1] == "1", v[0] == "1"
    return on, off_spr, blank

def delta_tables():
    """The three DELTA arrays, parsed out of vdp_access_slots.vhd."""
    src, out = read("vdp_access_slots.vhd"), {}
    for key, const in (("wr", "WR_DELTA"), ("rd_aw", "RD_DELTA_AFTER_WR"),
                       ("rd_ar", "RD_DELTA_AFTER_RD")):
        body = re.search(rf"CONSTANT {const}\s*:\s*DELTA_T\s*:=\s*\((.*?)\);",
                         src, re.S).group(1)
        body = re.sub(r"--[^\n]*", "", body)
        vals = [int(x) for x in re.findall(r"\d+", body)]
        if len(vals) != 16:
            sys.exit(f"{const} parsed to {len(vals)} entries, expected 16")
        out[key] = vals
    return out

OPCODE = {"STOP":0, "POINT":4, "PSET":5, "SRCH":6, "LINE":7, "LMMV":8,
          "LMMM":9, "LMCM":10, "LMMC":11, "HMMV":12, "HMMM":13, "YMMM":14,
          "HMMC":15}

class Frame:
    """NTSC: 262 lines, 192 of them inside the vertical display window."""
    def __init__(self, on, off_spr, blank, sprites=True, display=True):
        self.inside = on if sprites else off_spr
        self.outside = blank
        self.display = display
    def free(self, t):
        if not self.display:
            return self.outside[t % 1368]
        return (self.inside if (t // 1368) % 262 < 192 else self.outside)[t % 1368]

def replay(frame, deltas, seq):
    """seq is a list of cycle counts; take the next free slot at or after each."""
    t = last = 0
    for d in seq:
        t = last + d
        while not frame.free(t):
            t += 1
        last = t
    return t / 1368.0

def sequence(cmd, dt, bias, line_minor):
    """Expand a command into its list of per-access deltas."""
    op = OPCODE[cmd]
    if cmd == "LINE":
        #  The benchmark draws 32 lines of DX=0 DY=200 NX=255 NY=100, X major.
        #  openMSX charges D120 rather than D88 whenever the Bresenham
        #  accumulator steps onto the next minor-axis position.
        seq = []
        for _ in range(32):
            asx, adx, anx = (255 - 1) >> 1, 0, 0
            while True:
                seq.append(dt["wr"][op] + bias)
                adx += 1
                if anx == 255 or (adx & 256):
                    break
                anx += 1
                d = dt["rd_aw"][op]
                if asx < 100:
                    asx += 255
                    if line_minor:
                        d += 32
                asx -= 100
                seq.append(d + bias)
        return seq
    units = 32 * 256 if cmd == "SRCH" else 16384
    return [dt[s][op] + bias for _ in range(units) for s in STEPS[cmd]]

def run_all(frame, dt, bias, line_minor):
    return {c: replay(frame, dt, sequence(c, dt, bias, line_minor)) for c in REFERENCE}

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bias", type=int, default=0)
    ap.add_argument("--no-line-minor", action="store_true")
    ap.add_argument("--tol", type=float, default=0.05)
    ap.add_argument("--drop-slots", default="",
                    help="comma-separated openMSX slot indices to remove from the "
                         "sprites-on column, e.g. 162,1330 -- for asking what a "
                         "slot our arbiter fails to deliver would have been worth")
    a = ap.parse_args()

    on, off_spr, blank = slot_tables()
    dt = delta_tables()
    frame = Frame(on, off_spr, blank)
    dropped = [int(x) for x in a.drop_slots.split(",") if x.strip()]

    print(f"model reads: {RTL}/vdp_slot_pack.vhd, {RTL}/vdp_access_slots.vhd")
    print(f"SELF-CHECK  bias=0, LINE minor step on, tolerance {a.tol*100:.0f}%\n")
    print(f"{'cmd':6}{'model':>9}{'openMSX':>9}{'ratio':>8}")
    base, bad = run_all(frame, dt, 0, True), []
    for c, r in REFERENCE.items():
        m = base[c]
        ok = abs(m / r - 1) <= a.tol
        if not ok:
            bad.append(c)
        print(f"{c:6}{m:9.1f}{r:9.1f}{m/r:8.3f}  {'ok' if ok else 'FAIL'}")

    if bad:
        print(f"\nSELF-CHECK FAILED: {', '.join(bad)}")
        print("The model does not reproduce a measurement that is known to be")
        print("correct, so it cannot be used to judge anything else.  Fix the")
        print("model.  Do NOT conclude from this that the RTL or the reference")
        print("is wrong -- that is the exact error this gate exists to prevent.")
        return 1
    print("\nSELF-CHECK PASSED -- the model may now be used to predict.")

    if dropped:
        #  Deleting slots must happen AFTER the self-check: the check proves the
        #  unmodified model is sound, and only then does a modified one mean
        #  anything.  Indices are openMSX's; SLOT_OFFSET maps them to our H_CNT.
        off = int(re.search(r"CONSTANT SLOT_OFFSET\s*:\s*INTEGER\s*:=\s*(\d+)",
                            read("vdp_access_slots.vhd")).group(1))
        on2 = list(on)
        for idx in dropped:
            h = (idx - off) % 1368
            if not on2[h]:
                sys.exit(f"slot {idx} (H_CNT {h}) is not a sprites-on slot")
            on2[h] = False
        f2 = Frame(on2, off_spr, blank)
        alt = run_all(f2, dt, 0, True)
        print(f"\nPREDICTION with slots {dropped} never delivered "
              f"(H_CNT {[(i-off)%1368 for i in dropped]}):\n")
        print(f"{'cmd':6}{'base':>9}{'dropped':>9}{'openMSX':>9}{'drop/ref':>10}")
        for c, r in REFERENCE.items():
            print(f"{c:6}{base[c]:9.1f}{alt[c]:9.1f}{r:9.1f}{alt[c]/r:10.3f}")

    if a.bias or a.no_line_minor:
        what = []
        if a.bias:
            what.append(f"bias +{a.bias} on every DELTA")
        if a.no_line_minor:
            what.append("LINE minor-axis +32 removed")
        print(f"\nPREDICTION with {' and '.join(what)}:\n")
        alt = run_all(frame, dt, a.bias, not a.no_line_minor)
        print(f"{'cmd':6}{'base':>9}{'altered':>9}{'openMSX':>9}{'alt/ref':>9}")
        for c, r in REFERENCE.items():
            print(f"{c:6}{base[c]:9.1f}{alt[c]:9.1f}{r:9.1f}{alt[c]/r:9.3f}")
    return 0

if __name__ == "__main__":
    sys.exit(main())
