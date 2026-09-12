#!/usr/bin/env bash
# VDP command-timing regression gate.
#
# Runs all seven throttled commands through the RTL and compares each duration
# against the openMSX 21.0-245 reference for the same workload.  Those
# references were taken by driving tools/vdpprobe/CMDCMP.COM under the emulator
# and reading emulated time across each command with breakpoints, so both sides
# measure the same thing in the same unit (scanlines).
#
# It then runs a COPY-INTEGRITY check, because timing alone is blind to a
# broken read path: a command that fetches the wrong byte still takes the right
# number of cycles, so every timing row stays green while the copied pixels are
# garbage.  That is exactly how the "01"-phase read latch failed.
#
# Run this after ANY change under rtl/video/VDP/.  The command engine has a
# history of silent timing regressions that only surfaced as corrupted raster
# splits in one game, months later.
#
# usage:  sim/check_vdpcmd.sh
# env:    TOL=<fraction>   allowed deviation, default 0.05 (5%)
#
# 5% is the measurement floor, not a guess.  Running the same CMDCMP.DSK on the
# board and under openMSX and normalising both by D7 (the poll-loop reference)
# gives board/sim ratios of 1.049 1.029 1.003 1.010 0.978 1.030 0.957 across the
# seven commands -- mean +0.8%, spread -4.3%..+4.9%, no systematic bias.  A 3%
# gate would fire on a correct build.
#         OUT=<dir>        default /tmp/vdpcmd_check
#
# Exit 0 = every command inside tolerance.
set -u
TOL=${TOL:-0.05}
OUT=${OUT:-/tmp/vdpcmd_check}

OUT="$OUT" bash "$(dirname "$0")/run_vdpcmd7.sh" > "$OUT.raw" 2>&1
RC=$?
if [ $RC -ne 0 ] || ! grep -q "lines" "$OUT.raw"; then
    echo "FAIL: simulation produced no results (see $OUT.raw)"; exit 1
fi

DATACHECK=1 OUT="$OUT.dc" bash "$(dirname "$0")/run_vdpcmd7.sh" > "$OUT.dc.raw" 2>&1
DC=$(grep -o "DATACHECK.*" "$OUT.dc.raw" | head -1)
[ -z "$DC" ] && DC="DATACHECK: no result (see $OUT.dc.raw)  FAIL"

python3 - "$OUT.raw" "$TOL" "$DC" <<'PY'
import sys, re
raw, tol, dc = open(sys.argv[1]).read(), float(sys.argv[2]), sys.argv[3]
worst, bad = 0.0, 0
print(f"{'command':14s} {'RTL':>10s} {'openMSX':>10s} {'ratio':>8s}   verdict")
for line in raw.splitlines():
    m = re.match(r'\s*(\S+ \S+)\s+([0-9.eE+-]+) lines\s+\(openMSX\s+([0-9.]+)\)', line)
    if not m:
        continue
    name, got, ref = m.group(1), float(m.group(2)), float(m.group(3))
    r = got / ref
    ok = abs(r - 1.0) <= tol
    bad += 0 if ok else 1
    worst = max(worst, abs(r - 1.0))
    print(f"{name:14s} {got:10.2f} {ref:10.2f} {r:8.4f}   {'ok' if ok else 'OUT OF TOLERANCE'}")
print(f"\n{dc}")
dc_ok = "PASS" in dc
if bad == 0 and dc_ok:
    print(f"PASS  worst timing deviation {worst*100:.2f}% (tolerance {tol*100:.1f}%), copy intact")
    sys.exit(0)
if bad:
    print(f"FAIL  {bad} command(s) outside {tol*100:.1f}%; worst {worst*100:.2f}%")
if not dc_ok:
    print("FAIL  copy integrity")
sys.exit(1)
PY
