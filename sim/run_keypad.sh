#!/usr/bin/env bash
# MSX numeric keypad, matrix rows 9/10 (see the header of sim/tb_keypad.sv).
# NEGCTL=1 forces rows 9/10 back to 0xFF (the pre-fix table); every keypad
# check MUST then fail.
set -u
cd "$(dirname "$0")/.."
OUT=${OUT:-/tmp/keypad_sim}; mkdir -p "$OUT"

# kbd.mif -> $readmemh, honouring NEGCTL
NEGCTL=${NEGCTL:-0} python3 - "$OUT/kbd.hex" <<'PY'
import os, re, sys
data = bytearray(512)
for m in re.finditer(r'^\s*([0-9A-Fa-f]+)\s*:\s*([0-9A-Fa-f ]+);',
                     open('rtl/peripheral/kbd.mif').read(), re.M):
    a = int(m.group(1), 16)
    for i, v in enumerate(m.group(2).split()):
        data[a + i] = int(v, 16)
if os.environ.get('NEGCTL') == '1':                 # unmap rows 9 and 10 again
    data = bytearray(0xFF if (b >> 4) in (9, 10) else b for b in data)
open(sys.argv[1], 'w').write('\n'.join(f'{b:02X}' for b in data) + '\n')
PY

verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-DECLFILENAME \
   --top-module tb_keypad -o tbkeypad -Mdir "$OUT/v" \
   sim/tb_keypad.sv rtl/peripheral/keyboard.sv > "$OUT/build.log" 2>&1 \
   || { echo "COMPILE FAILED"; tail -20 "$OUT/build.log"; exit 2; }

( cd "$OUT" && ln -sf kbd.hex kbd.mif && "$OUT/v/tbkeypad" ) 2>&1 | grep -vE '^- '
rc=${PIPESTATUS[0]}; echo "rc=$rc"; exit $rc
