#!/usr/bin/env python3
"""Every OR-accumulated signal in memory_upload.sv must be cleared when a pack load starts.

The FSM builds `msx_device` and `cart_slot_expander_en` by OR-ing bits as it walks the
config records.  If such a signal is not reset in the `if (load)` block, its bits SURVIVE
into the next machine pack.  That is a silent, cross-machine bug: it only shows when a
device is present in one pack and absent in the next.

It actually happened.  msx_device was never cleared.  Nobody noticed while KANJI / OPL3 /
RESET_STATUS / MOONSOUND were in nearly every pack; DEV_MATSUSHITA (8 packs) exposed it --
loading FS-A1FX then Sony HB-F1XV left the Panasonic turbo port answering on the Sony.

Static check, no simulation needed.  Run from anywhere.
"""
import os, re, sys

SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   "..", "rtl", "peripheral", "slots", "memory_upload.sv")
src = open(SRC).read()

# signals built with `x <= x | ...`
accum = set(re.findall(r'^\s*([A-Za-z_]\w*)\s*<=\s*\1\s*\|', src, re.M))
if not accum:
    sys.exit("check_upload_accum_clear: found no OR-accumulated signals -- "
             "the pattern changed, update this checker")

# the load-time reset block: `if (load) begin ... end`
m = re.search(r'if \(load\) begin(.*?)\n      end', src, re.S)
if not m:
    sys.exit("check_upload_accum_clear: could not find the `if (load) begin` block")
cleared = set(re.findall(r'^\s*([A-Za-z_]\w*)\s*<=', m.group(1), re.M))

# msx_device is a KNOWN, DELIBERATE exception: clearing it here regressed
# Konami-mapper games on hardware (MSX1_20260830b vs 30a) because `load` also
# fires for a plain SLOT A/B ROM load.  See docs/TODO_msx_device_leak.md.
KNOWN = {"msx_device"}

missing = sorted(accum - cleared)
for s in sorted(accum):
    if s in cleared:      state = "cleared on load"
    elif s in KNOWN:      state = "NOT cleared -- known exception, see docs/TODO_msx_device_leak.md"
    else:                 state = "*** NOT CLEARED ***"
    print(f"  {s:24s} {state}")
unexpected = [m for m in missing if m not in KNOWN]
if unexpected:
    sys.exit(f"\nFAIL: {', '.join(unexpected)} accumulate(s) across machine packs")
if missing:
    print(f"\nOK (with {len(missing)} known exception): no NEW accumulate-without-clear")
else:
    print(f"\nOK: all {len(accum)} accumulated signal(s) cleared on load")
