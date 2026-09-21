#!/usr/bin/env bash
#  precheck -- make the change itself trip the record.
#
#      tools/buildgate/precheck.sh [--base <commit>] [--notes-only]
#
#  Called by build.sh before any Quartus stage.  It diffs the tree against the
#  last build that PASSED, matches that diff against tools/buildgate/landmines.tsv,
#  and for every record it trips:
#
#    * prints the note -- what this project already learned about that area, and
#      where the full write-up is;
#    * runs the bench the record names, and REFUSES the build if it fails.
#
#  Why it exists (2026-09-22): a 25-minute build and ten board boots went on
#  removing the turbo R CHGCPU stub, when the reason the stub exists was written
#  in the module header, a memory note said "read the reference to the end", and
#  the cpuswap bench would have failed in minutes -- it was run AFTER the build.
#  Every one of those records existed.  None was in mind at the decision.  A rule
#  that depends on being remembered is not a rule; this does not depend on it.
#
#  A bench PASS is stamped by the hash of the files it covers, so an unchanged
#  area is not re-benched on every build.
#
#  Exit: 0 clear, 4 a required bench failed (build refused), 2 usage.
set -u
cd "$(dirname "$0")/../.."
REG=tools/buildgate/landmines.tsv
STAMPS=${BUILDGATE_BENCH:-/tmp/buildgate_bench}; mkdir -p "$STAMPS"
LASTPASS=output_files/.buildgate_last_pass
BASE=""; NOTES_ONLY=0
while [ $# -gt 0 ]; do case "$1" in
   --base) BASE=$2; shift 2;; --notes-only) NOTES_ONLY=1; shift;;
   *) echo "precheck: unknown arg $1"; exit 2;; esac; done

if [ -z "$BASE" ]; then
   if [ -s "$LASTPASS" ] && git cat-file -e "$(cat "$LASTPASS")^{commit}" 2>/dev/null; then
      BASE=$(cat "$LASTPASS")
   else
      BASE=$(git rev-parse HEAD~1)
   fi
fi

#  The diff text: changed paths, plus every added and removed line, committed or not.
DIFF=$( { git diff --name-only "$BASE" -- . ; git diff "$BASE" -- . | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)'; } 2>/dev/null )
if [ -z "$DIFF" ]; then echo "precheck: nothing changed since $(git rev-parse --short "$BASE")"; exit 0; fi

echo "precheck: diff against $(git rev-parse --short "$BASE") ($(git log -1 --format=%s "$BASE" | cut -c1-60))"
fail=0; tripped=0
while IFS=$'\t' read -r id regex bench note; do
   case "$id" in ''|\#*) continue;; esac
   printf '%s' "$DIFF" | grep -Eq -- "$regex" || continue
   tripped=$((tripped+1))
   echo
   echo "  [$id] this change touches an area with a record:"
   echo "$note" | fold -s -w 96 | sed 's/^/      /'
   [ "$bench" = "-" ] && continue
   [ "$NOTES_ONLY" = 1 ] && { echo "      bench: $bench   (skipped, --notes-only)"; continue; }
   #  stamp = hash of the working tree state of everything the diff could reach
   h=$( { git rev-parse HEAD; git diff HEAD -- rtl sim tb tools MSX1.sv; } | sha1sum | cut -c1-12 )
   stamp="$STAMPS/$id.$h.pass"
   if [ -e "$stamp" ]; then echo "      bench: PASS (stamped for this tree)"; continue; fi
   echo "      bench: $bench"
   t0=$(date +%s)
   #  The exit status is NOT enough.  On this gate's first self-test the cpuswap
   #  bench printed RESULT FAIL and exited 0 (`a && echo || echo` ends in an echo),
   #  and the tb/ benches print "  FAIL ..." from a Verilator binary that always
   #  exits 0.  So the log is read for a verdict as well, and a bench that says
   #  FAIL anywhere fails, whatever it returned.
   BADLOG='^RESULT FAIL|^[[:space:]]*FAIL[[:space:]]|[^0-9][1-9][0-9]* bad|GEN-FAIL|BUILD FAIL|: FAIL$|^%Error'
   rc=0; ( eval "$bench" ) > "$STAMPS/$id.log" 2>&1 || rc=$?
   if [ $rc -eq 0 ] && grep -Eq -- "$BADLOG" "$STAMPS/$id.log"; then
      echo "      bench: exited 0 but its log says FAIL:"
      grep -E -- "$BADLOG" "$STAMPS/$id.log" | head -4 | sed 's/^/         /'
      rc=99
   fi
   if [ $rc -eq 0 ]; then
      echo "      bench: PASS in $(( $(date +%s)-t0 ))s"; : > "$stamp"
   else
      echo "      bench: FAIL in $(( $(date +%s)-t0 ))s -- last lines of $STAMPS/$id.log:"
      tail -6 "$STAMPS/$id.log" | sed 's/^/         /'
      fail=1
   fi
done < "$REG"

echo
if [ $tripped -eq 0 ]; then echo "precheck: no record tripped."; fi
if [ $fail -ne 0 ]; then
   echo "PRECHECK: REFUSED -- a bench this change is answerable to FAILS."
   echo "          If you are about to argue the bench is wrong, that is the moment to stop:"
   echo "          find out why the bench was written that way before building."
   exit 4
fi
echo "precheck: clear ($tripped record(s) tripped)"
exit 0
