#!/usr/bin/env python3
"""Tie sim/tb_audio_trim.sv to the SHIPPED RTL.

tb_audio_trim REIMPLEMENTS the mix datapath instead of instantiating msx_slots,
so on its own it proves only that a copy of the arithmetic is self-consistent.
This project has been bitten by exactly that before -- check_opl4_gain_consts.py
exists for the same reason. This script parses the real RTL and fails if the
constants or the widths the TB assumes have drifted.
"""
import re, sys, math

FAIL = []
def need(cond, msg):
    if not cond: FAIL.append(msg)

slots = open("rtl/peripheral/slots/msx_slots.sv").read()
msx   = open("rtl/msx.sv").read()

# ---- 1. vol_mul table -------------------------------------------------------
m = re.search(r"function automatic signed \[(\d+):0\] vol_mul.*?endfunction", slots, re.S)
need(m, "vol_mul function not found in msx_slots.sv")
if m:
    width = int(m.group(1)) + 1
    tbl = [int(x) for x in re.findall(r"\d+'sd(\d+)", m.group(0))]
    need(tbl == [128, 203, 81, 51], f"vol_mul table drifted: {tbl} (expected [128,203,81,51])")
    # a signed field must hold the largest entry as a POSITIVE number
    need(max(tbl) <= 2**(width-1) - 1,
         f"vol_mul is signed [{width-1}:0] (max {2**(width-1)-1}) but table holds {max(tbl)} -- would read negative")
    for v, want in zip(tbl, [0.0, 4.0, -4.0, -8.0]):
        got = 20 * math.log10(v / 128)
        need(abs(got - want) < 0.1, f"x{v}/128 = {got:+.3f}dB, menu says {want:+.1f}dB")
    need(tbl[0] == 128, "entry 0 must be exactly 128 (unity) or the untouched-menu claim breaks")

# ---- 2. sum width and clamp -------------------------------------------------
m = re.search(r"wire signed \[(\d+):0\] snd_sum", slots)
need(m, "snd_sum not found")
if m:
    w = int(m.group(1)) + 1
    # Worst case with the loudest table entry.  Use Python's >> , which floors for
    # negatives exactly like Verilog's arithmetic >>> -- an approximation here would
    # give the wrong bound in one direction and this check exists to catch exactly
    # that class of error.
    mul = max(tbl) if tbl else 203
    hi = ((32767 * mul) >> 7) * 2 + 32767
    lo = ((-32768 * mul) >> 7) * 2 + (-32768)
    need(hi <= 2**(w-1) - 1 and lo >= -2**(w-1),
         f"snd_sum is {w} bits (range {-2**(w-1)}..{2**(w-1)-1}) but the sum reaches {lo}..{hi} "
         f"-- it wraps BEFORE the clamp can see it")
need(re.search(r"snd_sum > \d+'sd32767", slots), "positive clamp bound is not 32767")
need(re.search(r"snd_sum < -\d+'sd32768", slots), "negative clamp bound is not -32768")

# ---- 3. internal PSG trim in msx.sv -----------------------------------------
m = re.search(r"wire \[8:0\]\s+psg_mul\s*=(.*?);", msx, re.S)
need(m, "psg_mul not found in msx.sv")
if m:
    tbl = [int(x) for x in re.findall(r"9'd(\d+)", m.group(1))]
    need(tbl == [128, 203, 81, 51], f"psg_mul table drifted: {tbl}")
    need(tbl[0] == 128, "psg entry 0 must be exactly 128")

m = re.search(r"wire \[(\d+):0\]\s+psg_scl\s*=", msx)
need(m, "psg_scl not found")
if m:
    w = int(m.group(1)) + 1
    need(1023 * 203 < 2**w, f"psg_scl is {w} bits but audioPSG*203 reaches {1023*203}")

m = re.search(r"psg_trim\s*=\s*\|psg_scl\[(\d+):(\d+)\]\s*\?\s*10'h3FF\s*:\s*psg_scl\[(\d+):(\d+)\]", msx)
need(m, "psg_trim clamp shape changed -- re-verify the boundary by exhaustion")
if m:
    chi, clo, shi, slo = (int(g) for g in m.groups())
    bad = 0
    for a in range(1024):
        for mul in (128, 203, 81, 51):
            s = a * mul
            clamped = 1 if (s >> clo) & ((1 << (chi - clo + 1)) - 1) else 0
            got = 1023 if clamped else (s >> slo) & ((1 << (shi - slo + 1)) - 1)
            if got != min(s >> slo, 1023): bad += 1
    need(bad == 0, f"psg_trim clamp wrong on {bad} of 4096 (audioPSG, setting) combinations")

if FAIL:
    print("check_audio_trim_consts: FAIL")
    for f in FAIL: print("  -", f)
    sys.exit(1)
print("check_audio_trim_consts: RTL matches what tb_audio_trim assumes")
