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

missing = sorted(accum - cleared)
for s in sorted(accum):
    print(f"  {s:24s} {'cleared on load' if s in cleared else '*** NOT CLEARED ***'}")
if missing:
    sys.exit(f"\nFAIL: {', '.join(missing)} accumulate(s) across machine packs")
print(f"\nOK: all {len(accum)} accumulated signal(s) cleared on load")
