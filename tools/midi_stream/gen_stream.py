#!/usr/bin/env python3
"""Make the byte stream an MSX MIDI player would push at port E8h.

This is the wire stream, not a Standard MIDI File: no header, no delta times,
just the status and data bytes in the order they are transmitted.  Running
status is used where a real player would use it, because that is the case most
likely to expose a transmitter that drops or duplicates a byte.

    gen_stream.py out.bin [--notes N] [--no-running-status]
"""
import argparse
import random
import sys

CH = 0            # channel 1


def build(n_notes, running_status):
    out = bytearray()
    out += bytes([0xC0 | CH, 0x50])                    # program change
    out += bytes([0xB0 | CH, 0x07, 0x64])              # channel volume
    rnd = random.Random(20260925)
    last_status = None
    for i in range(n_notes):
        note = 36 + (i * 7) % 49                       # a wide, non-musical spread
        vel = 64 + rnd.randrange(0, 40)
        for status, d1, d2 in ((0x90 | CH, note, vel), (0x80 | CH, note, 0x40)):
            if running_status and status == last_status:
                out += bytes([d1, d2])
            else:
                out += bytes([status, d1, d2])
                last_status = status
        if i % 8 == 7:
            out += bytes([0xF8])                       # timing clock, a realtime byte
            last_status = last_status                  # realtime does not clear it
    out += bytes([0xB0 | CH, 0x7B, 0x00])              # all notes off
    return bytes(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("out")
    ap.add_argument("--notes", type=int, default=24)
    ap.add_argument("--no-running-status", action="store_true")
    a = ap.parse_args()
    data = build(a.notes, not a.no_running_status)
    open(a.out, "wb").write(data)
    print(f"{len(data)} bytes -> {a.out}")


if __name__ == "__main__":
    main()
