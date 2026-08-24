#!/usr/bin/env python3
"""Instrument SCMD's SC.COM / CORE2.SYS / CORE2.SY2 with an on-screen trace.

Why.  `SC.COM` runs and returns to DOS with no message at all on the MSX1 core,
while openMSX with the same MFRSD and the same flashed disk prints
"SCC cartridge is not mounted."  Every failure path inside SC.COM prints
something (its 431 bytes were disassembled exhaustively), so SC.COM completes and
jumps to CORE2.SYS at 0x0300 -- and CORE2.SYS's own message at 0x4060 is never
reached either.  Something in between dies silently.

Design, and why it is this and not something cheaper
----------------------------------------------------
Earlier rounds used the BORDER COLOUR (VDP R#7).  That was the wrong instrument:
only ONE value survives, so each run answered a single bit and the window had to
be bisected over several rounds -- and a round costs a rebuild, a file drop, a
re-flash, a reboot and a screenshot.  Two rounds were then lost to faults in the
colour scheme itself: colour 0 is transparent and so indistinguishable from an
untouched border, and two markers sat at different loop depths so the inner one
always overwrote the outer.  Marker count is nearly free; rounds are expensive.
That trade was got backwards.

This version writes CHARACTERS to the text screen, so every site that executes
leaves its own mark and the whole path is readable in one run.

Two constraints shape it:

  * The stub lives in CORE2.SY2 (loaded at 0xC000, page 3).  CORE2.SYS spans
    0x0300-0x8CBE -- pages 1 and 2 -- and the slot sweep pages candidate slots
    into exactly those pages, so code there is not there any more while sweeping.
    That is why SCMD ships as two files in the first place.

  * Output goes straight to VRAM, not through BDOS: the sweep runs with
    interrupts disabled (0xC000 and 0xC06E both start with DI), and a crash
    mid-sweep would never flush a buffer anyway.  The name table base is READ
    from NAMBAS (0xF3B3) rather than assumed -- guessing it is what made the
    first VRAM attempt write somewhere nobody was looking.

Nothing is inserted: each site has a 3-byte instruction overwritten with a CALL
(or JP) to a trampoline that re-executes the displaced instruction.  Absolute
addresses everywhere in a 35KB binary make anything else a relocation job.  An
earlier attempt at a CORE2.SYS stub failed purely on the load-address offset --
the file loads at 0x300, so file offset + 0x300 = execution address.

Room: SC.COM reads CORE2.SY2 with HL=0x1100 records of 1 byte (SC.COM:0x01EB
sets the FCB record size, 0x01FD the count), so 4352 bytes are loaded while the
file is 4138 -- 214 bytes for the stub.

Reading the trace
-----------------
    0        SC.COM about to JP 0x0300
    1        CORE2.SYS:0x0336, about to CALL 0x4000
    a b c    0x4013 / 0x401B (CALL 0xC000 #1) / 0x4028 (CALL 0xC000 #2)
    d e      0x4040 / 0x404A -- about to RDSLT / WRSLT 0x7FF6 (FM-PAC OPLL enable)
    f g      0x4052 / 0x4057 (CALL the SCC+ scan)
    E        inside 0xC000, past the DI/save preamble
    <digit>  0xC013 -- the PRIMARY slot about to be swept (0-3)
    <digit>  0xC01A -- the SUBSLOT about to be paged in by 0x0302 (0-3)
    .        0xC020 -- paging returned, about to compare 8 bytes at 0x4018

A healthy sweep reads "01aE3 3. 2. 1. 0. 2 3. ..." -- a primary digit, then four
<subslot><dot> pairs, then the next primary.  Where the trail stops is where it
died: a digit with no dot after it means CALL 0x0302 killed it on that slot; a
dot with nothing after means the compare did.

Known-good reference (openMSX, MFRSD alone): the sweep matches "APRLOPLL" on the
first probe and leaves the loop from there, so the trace is short and
"SCC cartridge is not mounted." prints.
"""
import argparse
import sys

COM_BASE = 0x0100
SYS_BASE = 0x0300
SY2_BASE = 0xC000
SY2_LOAD_MAX = 0x1100          # SC.COM:0x01FD -- records loaded, 1 byte each

RG2SAV = 0xF3E1                # BIOS shadow of VDP R#2 -- name table base / 0x400
                               # NAMBAS (0xF3B3) is NOT usable here: under MSX-DOS
                               # it reads 0 while R#2 says 6, so the first attempt
                               # wrote the trace into the pattern table at VRAM 0
                               # where nothing shows.  Verified with openMSX's
                               # debugger: VRAM 0x0000 held "01abE03.fgh".

PUTC = None
CUR = None


def lo(a):
    return a & 0xFF


def hi(a):
    return (a >> 8) & 0xFF


def putc_stub():
    """Print the character in C at the next screen cell.  Preserves everything."""
    return bytes([
        0xF5,                                  # push af
        0xE5,                                  # push hl
        0xD5,                                  # push de
        # R#14 holds VRAM address bits 16-14 on the MSX2 VDP; the ports only
        # carry the low 14.  Whatever DOS left in it would send these writes to
        # another 16KB bank -- which is exactly why the first VRAM attempt wrote
        # somewhere nobody was looking.  Force it to 0.
        0xAF,                                  # xor a
        0xD3, 0x99,                            # out (0x99),a
        0x3E, 0x8E,                            # ld a,0x8E     register 14
        0xD3, 0x99,                            # out (0x99),a
        0x3A, lo(RG2SAV), hi(RG2SAV),          # ld a,(RG2SAV)
        0xE6, 0x0F,                            # and 0x0F
        0x07, 0x07,                            # rlca ; rlca   -> high byte of base
        0x57,                                  # ld d,a
        0x1E, 0x00,                            # ld e,0        DE = R#2 * 0x400
        0x2A, lo(CUR), hi(CUR),                # ld hl,(CUR)
        0x23,                                  # inc hl
        0x22, lo(CUR), hi(CUR),                # ld (CUR),hl
        0x2B,                                  # dec hl        pre-increment value
        0x19,                                  # add hl,de
        0x7D,                                  # ld a,l
        0xD3, 0x99,                            # out (0x99),a  VRAM addr low
        0x7C,                                  # ld a,h
        0xF6, 0x40,                            # or 0x40       write mode
        0xD3, 0x99,                            # out (0x99),a  VRAM addr high
        0x79,                                  # ld a,c
        0xD3, 0x98,                            # out (0x98),a  the character
        0xD1,                                  # pop de
        0xE1,                                  # pop hl
        0xF1,                                  # pop af
        0xC9,                                  # ret
    ])


def tramp_fixed(ch, displaced, is_jump=False):
    assert len(displaced) == 3
    body = bytes([
        0xC5,                          # push bc
        0x0E, ord(ch),                 # ld c,<char>
        0xCD, lo(PUTC), hi(PUTC),      # call PUTC
        0xC1,                          # pop bc
    ]) + displaced
    return body if is_jump else body + bytes([0xC9])


def tramp_primary(displaced):
    """Print '0'+primary, taken from A.

    NOT from (0x2C46): the displaced instruction IS the store into it, so at this
    point the variable still holds the previous iteration's value -- which is how
    the first trace came out as "...E03." with a stale 0 where a 3 belonged.
    0xC012 has just done LD A,B, so A is the primary slot."""
    assert len(displaced) == 3
    return bytes([
        0xC5, 0xF5,                    # push bc ; push af
        0xC6, 0x30,                    # add a,'0'
        0x4F,                          # ld c,a
        0xCD, lo(PUTC), hi(PUTC),      # call PUTC
        0xF1, 0xC1,                    # pop af ; pop bc
    ]) + displaced + bytes([0xC9])


def tramp_subslot(displaced):
    """Print '0'+subslot from B, the inner loop counter live at 0xC01A."""
    assert len(displaced) == 3
    return bytes([
        0xC5, 0xF5,                    # push bc ; push af
        0x78,                          # ld a,b
        0xC6, 0x30,                    # add a,'0'
        0x4F,                          # ld c,a
        0xCD, lo(PUTC), hi(PUTC),      # call PUTC
        0xF1, 0xC1,                    # pop af ; pop bc
    ]) + displaced + bytes([0xC9])


# (file, execution address, expected bytes, kind, char)
SITES = [
    ("com", 0x0205, bytes([0xC3, 0x00, 0x03]), "jump",    "0"),
    ("sys", 0x0336, bytes([0xCD, 0x00, 0x40]), "fixed",   "1"),
    ("sys", 0x4013, bytes([0x21, 0xA3, 0xC1]), "fixed",   "a"),
    ("sys", 0x401B, bytes([0xCD, 0x00, 0xC0]), "fixed",   "b"),
    ("sys", 0x4028, bytes([0xCD, 0x00, 0xC0]), "fixed",   "c"),
    ("sys", 0x4040, bytes([0x21, 0xF6, 0x7F]), "fixed",   "d"),
    ("sys", 0x404A, bytes([0x21, 0xF6, 0x7F]), "fixed",   "e"),
    ("sys", 0x4052, bytes([0x32, 0x47, 0x2C]), "fixed",   "f"),
    ("sys", 0x4057, bytes([0xCD, 0x6E, 0xC0]), "fixed",   "g"),
    ("sy2", 0xC005, bytes([0x3A, 0xFF, 0xFF]), "fixed",   "E"),
    ("sy2", 0xC013, bytes([0x32, 0x46, 0x2C]), "primary", None),
    ("sy2", 0xC01A, bytes([0xCD, 0x02, 0x03]), "subslot", None),
    ("sy2", 0xC020, bytes([0xCD, 0x54, 0xC0]), "fixed",   "."),
]


def main():
    global PUTC, CUR
    ap = argparse.ArgumentParser()
    for a in ("com", "sys", "sy2", "out-com", "out-sys", "out-sy2"):
        ap.add_argument("--" + a, required=True)
    args = ap.parse_args()

    com_img = bytearray(open(args.com, "rb").read())
    sys_img = bytearray(open(args.sys, "rb").read())
    sy2_img = bytearray(open(args.sy2, "rb").read())

    PUTC = SY2_BASE + len(sy2_img)
    CUR = 0                                # placeholder: the stub's length is
    CUR = PUTC + len(putc_stub())          # fixed, so one dry run sizes it

    blob = bytearray(putc_stub())
    blob += b"\x00\x00"                                   # CUR

    for which, addr, expect, kind, ch in SITES:
        img, base = {"com": (com_img, COM_BASE), "sys": (sys_img, SYS_BASE),
                     "sy2": (sy2_img, SY2_BASE)}[which]
        off = addr - base
        got = bytes(img[off:off + 3])
        if got != expect:
            sys.exit("%s 0x%04X: expected %s, found %s -- wrong file or wrong build"
                     % (which, addr, expect.hex(" "), got.hex(" ")))
        t = PUTC + len(blob)
        if kind == "primary":
            blob += tramp_primary(expect); label = "'0'+primary"
        elif kind == "subslot":
            blob += tramp_subslot(expect); label = "'0'+subslot"
        else:
            blob += tramp_fixed(ch, expect, is_jump=(kind == "jump")); label = "'%s'" % ch
        img[off:off + 3] = bytes([0xC3 if kind == "jump" else 0xCD, lo(t), hi(t)])
        print("  %-3s 0x%04X  %s -> %-4s 0x%04X   %s"
              % (which, addr, expect.hex(" "), "JP" if kind == "jump" else "CALL", t, label))

    sy2_img += blob
    if len(sy2_img) > SY2_LOAD_MAX:
        sys.exit("CORE2.SY2 grew to %d bytes; SC.COM only loads %d"
                 % (len(sy2_img), SY2_LOAD_MAX))

    open(args.out_com, "wb").write(com_img)
    open(args.out_sys, "wb").write(sys_img)
    open(args.out_sy2, "wb").write(sy2_img)
    print("CORE2.SY2 %d -> %d bytes (ceiling %d, %d spare), stub at 0x%04X"
          % (len(sy2_img) - len(blob), len(sy2_img), SY2_LOAD_MAX,
             SY2_LOAD_MAX - len(sy2_img), PUTC))


if __name__ == "__main__":
    main()
