#!/usr/bin/env python3
"""Turn a Standard MIDI File into the byte stream a player puts on the wire.

A .mid is not what travels down the cable.  Delta times, the track structure and
every meta event (FF ..) exist only in the file; what a player transmits is the
channel and system messages, in time order, merged across tracks.  SysEx is
transmitted, and its length byte in the file is replaced by the bytes themselves.

    smf2wire.py song.mid out.bin [--max N] [--no-running-status]

Running status is on by default because that is what a player does, and because
a transmitter that loses or repeats a byte shows up soonest in a stream that
depends on the previous status byte still being right.
"""
import argparse
import struct
import sys


def varlen(b, i):
    n = 0
    while True:
        c = b[i]
        i += 1
        n = (n << 7) | (c & 0x7F)
        if not c & 0x80:
            return n, i


def parse_track(b):
    """[(tick, bytes-for-the-wire)] for one MTrk chunk body."""
    out, t, i, status = [], 0, 0, None
    n = len(b)
    while i < n:
        dt, i = varlen(b, i)
        t += dt
        if i >= n:
            break
        c = b[i]
        if c == 0xFF:                              # meta: file only
            i += 2
            ln, i = varlen(b, i)
            i += ln
            continue
        if c in (0xF0, 0xF7):                      # sysex, or a raw escape
            i += 1
            ln, i = varlen(b, i)
            data = b[i:i + ln]
            i += ln
            out.append((t, bytes([0xF0]) + data if c == 0xF0 else data))
            status = None                          # sysex clears running status
            continue
        if c & 0x80:
            status = c
            i += 1
        elif status is None:
            raise ValueError(f"running status with no status byte at {i}")
        nd = 1 if (status & 0xF0) in (0xC0, 0xD0) else 2
        out.append((t, bytes([status]) + b[i:i + nd]))
        i += nd
    return out


def convert(path, running_status=True):
    b = open(path, "rb").read()
    if b[:4] != b"MThd":
        raise ValueError("not a Standard MIDI File")
    hlen = struct.unpack(">I", b[4:8])[0]
    fmt, ntrks, div = struct.unpack(">HHH", b[8:14])
    i = 8 + hlen
    events = []
    for _ in range(ntrks):
        if b[i:i + 4] != b"MTrk":
            break
        tlen = struct.unpack(">I", b[i + 4:i + 8])[0]
        events += parse_track(b[i + 8:i + 8 + tlen])
        i += 8 + tlen
    events.sort(key=lambda e: e[0])                # stable: keeps track order at a tie

    wire, last = bytearray(), None
    for _, msg in events:
        s = msg[0]
        if running_status and 0x80 <= s < 0xF0 and s == last:
            wire += msg[1:]
        else:
            wire += msg
            last = s if 0x80 <= s < 0xF0 else None
    return wire, fmt, ntrks, div, len(events)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("mid")
    ap.add_argument("out")
    ap.add_argument("--max", type=int, default=0, help="keep only the first N bytes")
    ap.add_argument("--no-running-status", action="store_true")
    a = ap.parse_args()
    wire, fmt, ntrks, div, nev = convert(a.mid, not a.no_running_status)
    if a.max and len(wire) > a.max:
        wire = wire[:a.max]
    open(a.out, "wb").write(wire)
    print(f"format {fmt}, {ntrks} tracks, division {div}, {nev} transmitted events"
          f" -> {len(wire)} wire bytes")


if __name__ == "__main__":
    main()
