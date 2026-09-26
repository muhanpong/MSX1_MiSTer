#!/usr/bin/env bash
# Verified Quartus build.  Every lesson from docs/az80_migration_20260913.md §6
# that can be checked by a script is checked here, so a build cannot "pass" by
# not running.
#
#   tools/buildgate/build.sh [--stages map,fit,asm] [--expect <substr>]... [--signoff-only]
#
#   --expect X     X must appear in fit.rpt (an instance you just added; catches
#                  "synthesised away" and "never compiled").  Repeatable.
#   --signoff-only skip map/fit/asm, just re-run timing on the existing fit.
#
# Refuses to run if the Quartus volume is not mounted (a reboot unmounts it and
# "command not found" then hides inside any piped/tail'ed log).  Prints rc,
# elapsed and artifact timestamps per stage; a fit under 3 minutes is flagged
# as a probable smart-recompile skip.  Ends with the 8-figure two-corner signoff
# (read_sdc per model), the clock-pair relationship assertions, and the list of
# SDC lines the analyser ignored.
set -u
cd "$(dirname "$0")/../.."
Q=/run/media/muhanpong/0eb4bebc-0644-4c2f-9a97-ddca5afcd8f3/intelFPGA_lite/17.1/quartus/bin
STAGES="map,fit,asm"; EXPECT=(); SIGNOFF_ONLY=0
while [ $# -gt 0 ]; do case "$1" in
  --stages) STAGES="$2"; shift 2;; --expect) EXPECT+=("$2"); shift 2;; --signoff-only) SIGNOFF_ONLY=1; shift;;
  *) echo "unknown arg $1"; exit 2;; esac; done
LOG=${BUILDGATE_LOG:-/tmp/buildgate}; mkdir -p "$LOG"; rm -f "$LOG/buildgate.out"
fail=0
if [ ! -x "$Q/quartus_map" ]; then
  echo "GATE-FAIL: Quartus volume not mounted at $Q"
  echo "           try: udisksctl mount -b /dev/disk/by-uuid/0eb4bebc-0644-4c2f-9a97-ddca5afcd8f3"; exit 3
fi
#  Before any Quartus stage: let the diff trip the records (landmines.tsv) and run
#  the benches it is answerable to.  A failing bench refuses the build.
if [ "$SIGNOFF_ONLY" = 0 ] && [ "${BUILDGATE_SKIP_PRECHECK:-0}" != 1 ]; then
  tools/buildgate/precheck.sh || { echo "GATE-FAIL: precheck refused the build (rc=$?)"; exit 4; }
fi
if [ "$SIGNOFF_ONLY" = 0 ]; then
  for st in ${STAGES//,/ }; do
    t0=$(date +%s)
    case $st in
      fit) "$Q/quartus_fit" MSX1 -c MSX1 --read_settings_files=on > "$LOG/$st.log" 2>&1;;
      *)   "$Q/quartus_$st" MSX1 -c MSX1 > "$LOG/$st.log" 2>&1;;
    esac
    rc=$?; el=$(( $(date +%s)-t0 ))
    echo "stage $st rc=$rc elapsed=${el}s errors=$(grep -c '^Error' "$LOG/$st.log")"
    [ $rc -ne 0 ] && { grep -E '^Error|Critical Warning \((140003|16618|188026)' "$LOG/$st.log" | head -8; exit 1; }
    #  Right after map, before the 15-minute fit: Quartus had already printed
    #  every defect that shipped this week (10030 midi_int_n, 10034 midi_tx,
    #  10999 the PCM MLAB that never inferred) and no gate read it.  New ones
    #  against a hand-checked baseline stop the build here, ~5 min in.
    [ $st = map ] && { tools/buildgate/quartus_warnings.py output_files/MSX1.map.rpt \
        || { echo "GATE-FAIL: new Quartus warning(s) after map -- see above"; exit 1; }; }
    [ $st = fit ] && [ $el -lt 180 ] && { echo "GATE-WARN: fit took ${el}s -- smart recompile probably skipped it; results may be stale"; fail=1; }
    [ $st = fit ] && grep -q 'Critical Warning (140003)' "$LOG/$st.log" && echo "GATE-WARN: LogicLock assignments present but unlicensed (silently dropped)"
  done
  echo "artifacts: fit.rpt $(stat -c %y output_files/MSX1.fit.rpt | cut -c1-19)  rbf $(stat -c %y output_files/MSX1.rbf 2>/dev/null | cut -c1-19)"
fi
for e in "${EXPECT[@]:-}"; do
  [ -z "$e" ] && continue
  n=$(grep -c -- "$e" output_files/MSX1.fit.rpt)
  if [ "$n" = 0 ]; then echo "GATE-FAIL: '$e' not in fit.rpt (pruned or never compiled)"; fail=1; else echo "expect '$e': $n mentions"; fi
done
"$Q/quartus_sta" -t report_paths.tcl > "$LOG/sta.log" 2>&1; echo "sta rc=$?"
"$Q/quartus_sta" -t tools/buildgate/signoff.tcl 2>/dev/null | grep '^WORST' | tee "$LOG/signoff.txt"
awk '$2<0{f=1} END{exit f}' "$LOG/signoff.txt" || { echo "GATE-FAIL: negative slack in signoff"; fail=1; }
"$Q/quartus_sta" -t tools/buildgate/relations.tcl 2>/dev/null | grep -E '^(REL|GATE)' | tee "$LOG/relations.txt"
grep -q '^GATE-FAIL' "$LOG/relations.txt" && fail=1
tools/buildgate/sdc_ignored.sh "$LOG/sta.log" || fail=1
grep -E 'M10K blocks|Logic utilization \(in ALMs\)' output_files/MSX1.fit.rpt | head -2 | sed 's/  */ /g'
#  A passing build becomes the base the next precheck diffs against.  (A dirty
#  tree still records HEAD: precheck also diffs the working tree against it.)
if [ $fail = 0 ]; then git rev-parse HEAD > output_files/.buildgate_last_pass 2>/dev/null || true; fi
if [ $fail = 0 ]; then echo "BUILDGATE: PASS" | tee "$LOG/buildgate.out"; else echo "BUILDGATE: FAIL" | tee "$LOG/buildgate.out"; exit 1; fi
