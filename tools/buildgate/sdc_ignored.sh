#!/usr/bin/env bash
# Lists SDC constraints the analyser ignored (empty collections) and FAILS on any
# that is not allow-listed.  Allow-listing is by the constraint TEXT, not line
# number -- line numbers shift every time the SDC grows (a line-number list
# produced a false GATE-FAIL on build 725d49b).
log=${1:-/tmp/buildgate/sta.log}
sdc=${2:-MSX1.sdc}
ALLOW_TEXT='u_pcm'      # OPL4 PCM multicycles, empty since before 20260912 (tracked in the migration doc)
bad=""
for ln in $(grep -E '332049|332054' "$log" | grep -oE 'MSX1\.sdc\([0-9]+\)' | sed -E 's/.*\(([0-9]+)\)/\1/' | sort -un); do
  # the ignored command spans a few lines; look at it and the two after
  txt=$(sed -n "${ln},$((ln+2))p" "$sdc")
  echo "$txt" | grep -q "$ALLOW_TEXT" || bad="$bad $ln"
done
if [ -n "$bad" ]; then echo "GATE-FAIL: newly ignored SDC constraints at MSX1.sdc lines:$bad"; exit 1; fi
echo "sdc ignored: only allow-listed ($ALLOW_TEXT) constraints"; exit 0
