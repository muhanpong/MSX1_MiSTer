#!/usr/bin/env bash
#  A bench result is not a measurement until the bench has been shown to be capable of
#  failing.  Every mistake this guard exists for was made in one day, 2026-09-26:
#
#    - a runner copied to /tmp whose `cd "$(dirname $0)/.."` resolved to /, so the
#      build never happened and "0 warnings" was read off a log that did not exist;
#    - cases that passed because a value left over from the previous case happened to
#      match, in two different benches;
#    - a FIX env var shared by two benches, which rewrote the RTL under one of them and
#      turned every case green for the wrong reason;
#    - a 64-run matrix reported clean that contained zero instances of the race it was
#      written to cover.
#
#  So: run the bench, prove it ran, and prove it can go red.
#
#    sim/checkrun.sh <runner> --cases N --negative "ENV=VAL"
#
#  --cases N    the run must report exactly N ok/FAIL lines.  A case that stops
#               reporting is the failure this catches; a silent skip reads as a pass.
#  --negative   the same runner under that environment must report a DIFFERENT number
#               of failures.  If nothing can change the outcome, the bench is not
#               measuring anything -- whichever direction the difference goes.
set -u
cd "$(dirname "$0")/.."

runner=${1:?usage: sim/checkrun.sh <runner> [--cases N] [--negative ENV=VAL]}; shift
cases=""; neg=""
while [ $# -gt 0 ]; do
   case "$1" in
      --cases)    cases=$2; shift 2 ;;
      --negative) neg=$2;   shift 2 ;;
      *) echo "checkrun: unknown argument $1"; exit 2 ;;
   esac
done
[ -x "$runner" ] || { echo "checkrun: $runner is not executable here"; exit 2; }

run() {  # $1 = env assignment or empty; echoes "<n_ok> <n_fail>", or dies
   local out rc
   out=$(env ${1:+"$1"} OUT="/tmp/checkrun_$$" "$runner" 2>&1); rc=$?
   printf '%s\n' "$out" > "/tmp/checkrun_$$.log"
   #  a runner that did not run is the failure mode that started this
   if [ $rc -ne 0 ]; then
      echo "checkrun: FAIL  $runner exited $rc${1:+ (with $1)}" >&2
      printf '%s\n' "$out" | tail -5 >&2; return 1
   fi
   if ! printf '%s\n' "$out" | grep -q 'RESULT'; then
      echo "checkrun: FAIL  no RESULT line${1:+ (with $1)} -- the bench did not report" >&2
      printf '%s\n' "$out" | tail -5 >&2; return 1
   fi
   echo "$(printf '%s\n' "$out" | grep -c '^ok ') $(printf '%s\n' "$out" | grep -c '^FAIL')"
}

base=$(run "") || exit 1
b_ok=${base% *}; b_fail=${base#* }
echo "checkrun: $runner -> $b_ok ok, $b_fail FAIL"

rc=0
if [ -n "$cases" ]; then
   if [ $((b_ok + b_fail)) -ne "$cases" ]; then
      echo "checkrun: FAIL  expected $cases cases, saw $((b_ok + b_fail)) -- a case stopped reporting"
      rc=1
   else
      echo "checkrun: ok    all $cases cases reported"
   fi
fi

if [ -n "$neg" ]; then
   n=$(run "$neg") || exit 1
   n_fail=${n#* }
   if [ "$n_fail" = "$b_fail" ]; then
      echo "checkrun: FAIL  $neg changes nothing ($b_fail FAIL either way) -- this bench cannot go red"
      rc=1
   else
      echo "checkrun: ok    $neg moves failures $b_fail -> $n_fail, so the bench is sensitive"
   fi
fi

rm -f "/tmp/checkrun_$$.log"; rm -rf "/tmp/checkrun_$$"
exit $rc
