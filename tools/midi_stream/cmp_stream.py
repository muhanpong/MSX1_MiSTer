#!/usr/bin/env python3
"""Diff two MIDI wire streams and say where they first part company.

    cmp_stream.py sent.bin wire.bin [--label-a sent --label-b wire]

Byte streams, not files with structure, so the report is an index and the
surrounding bytes of each side.
"""
import argparse
import sys


def show(b, i, w=6):
    lo, hi = max(0, i - w), min(len(b), i + w + 1)
    return " ".join(("[%02X]" if j == i else " %02X ") % b[j] for j in range(lo, hi)).strip()


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("a")
    ap.add_argument("b")
    ap.add_argument("--label-a", default="A")
    ap.add_argument("--label-b", default="B")
    o = ap.parse_args()
    a = open(o.a, "rb").read()
    b = open(o.b, "rb").read()
    print(f"{o.label_a}: {len(a)} bytes    {o.label_b}: {len(b)} bytes")
    n = min(len(a), len(b))
    for i in range(n):
        if a[i] != b[i]:
            print(f"first difference at byte {i}: {a[i]:02X} vs {b[i]:02X}")
            print(f"  {o.label_a}: {show(a, i)}")
            print(f"  {o.label_b}: {show(b, i)}")
            return 1
    if len(a) != len(b):
        longer, name = (a, o.label_a) if len(a) > len(b) else (b, o.label_b)
        print(f"identical for {n} bytes, then {name} has {len(longer) - n} more")
        print(f"  extra: {' '.join('%02X' % x for x in longer[n:n + 12])}")
        return 1
    print(f"identical, {n} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
