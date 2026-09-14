#!/usr/bin/env bash
# Lists SDC constraints the analyser ignored (empty collections).  Pre-existing
# ones are allow-listed; anything new is a GATE-FAIL -- a constraint that
# silently stopped matching is how a real violation gets hidden.
log=${1:-/tmp/buildgate/sta.log}
ALLOW='MSX1\.sdc\((75|78|82|85|102|105|115|118|128|131)\)'   # u_pcm multicycles, dead since before 20260912
new=$(grep -E '332049|332054' "$log" | grep -oE 'MSX1\.sdc\([0-9]+\)' | sort -u | grep -vE "$ALLOW")
if [ -n "$new" ]; then echo "GATE-FAIL: newly ignored SDC lines: $(echo $new | tr '\n' ' ')"; exit 1; fi
echo "sdc ignored: only the allow-listed u_pcm lines"; exit 0
