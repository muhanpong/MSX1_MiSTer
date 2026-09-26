#!/usr/bin/env python3
"""Fail a build on NEW Quartus warnings of the kinds that have cost this project.

    tools/buildgate/quartus_warnings.py [map.rpt]          # compare to the baseline
    BLESS=1 tools/buildgate/quartus_warnings.py [map.rpt]  # accept what is there now

Why this exists.  In one week three defects were printed by Quartus and read by
nobody, because every gate here looked at timing, benches and summary numbers:

  * Warning (10030)  midi_int_n has no driver -> tied to GND.  An active-low
    interrupt stuck asserted; 20260924c hung the GT at its first EI.
  * Warning (10034)  output port midi_tx has no driver.
  * Warning (10999)  "can't infer memory for variable 'ram_header_m'" -- the
    PCM header/dyn arrays requested MLAB and stayed in registers.  I measured
    that as "moving to MLAB saves nothing" and wrote it into memory as fact.
    msx1-audit read the warning and took 2,297 ALM out.

Plus the per-instance "Declared by entity but not connected by instance" rows in
the Port Connectivity Checks folder (Warning 12241 points at it).  Those are keyed
here by FULL hierarchy path + port, so two instances of the same module are two
entries -- the flaw in tools/check_pins.sh (keyed by file + pin, one baseline line
covered two instances) that msx1-audit pointed out.

A new entry fails the build.  An entry that has gone away is reported, not
failed; re-bless when convenient.  A report that could not be read, or that holds
none of these sections at all, FAILS -- an empty result has to be told apart from
"nothing ran" (a missing report reads exactly like a clean one).
"""
import os, re, sys

RPT  = sys.argv[1] if len(sys.argv) > 1 else "output_files/MSX1.map.rpt"
BASE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "quartus_warnings_baseline.txt")
IDS  = ("10030", "10034", "10999")

def collect(path):
    out = set(); sections = 0
    try:
        text = open(path, errors="ignore").read()
    except OSError as e:
        print(f"RESULT FAIL: cannot read {path}: {e}"); sys.exit(1)
    for ln in text.splitlines():
        m = re.match(r"Warning \((\d+)\): (.*)", ln.strip())
        if m and m.group(1) in IDS:
            # drop "File: ... Line: n" -- line numbers move on every edit
            msg = re.sub(r"\s*File: .*$", "", m.group(2))
            msg = re.sub(r"\(\d+\)", "", msg)
            out.add(f"W{m.group(1)} {msg}")
    hier = None
    for ln in text.splitlines():
        m = re.match(r'^; Port Connectivity Checks: "([^"]+)"', ln)
        if m:
            hier = m.group(1); sections += 1; continue
        if hier and ln.startswith(";") and "; Warning" in ln:
            c = [x.strip() for x in ln.strip().strip(";").split(";")]
            if c and "not connected by instance" in c[-1]:
                out.add(f"PORT {hier} :: {c[0]}")
    return out, sections

now, sections = collect(RPT)
if sections == 0:
    print(f"RESULT FAIL: {RPT} has no Port Connectivity Checks at all -- did Analysis & Synthesis run?")
    sys.exit(1)

if os.environ.get("BLESS") == "1":
    open(BASE, "w").write("\n".join(sorted(now)) + "\n")
    print(f"blessed {len(now)} entries from {RPT}")
    sys.exit(0)

if not os.path.exists(BASE):
    print(f"RESULT FAIL: no baseline {BASE} -- BLESS=1 once on a build you have checked by hand")
    sys.exit(1)
base = set(l for l in open(BASE).read().splitlines() if l)
new  = sorted(now - base)
gone = sorted(base - now)
if gone:
    print(f"note: {len(gone)} baseline entries no longer reported (re-bless when convenient):")
    for g in gone[:10]: print("   ", g)
if new:
    print(f"RESULT FAIL: {len(new)} new Quartus warning(s) of a kind that has shipped defects:")
    for n in new: print("   ", n)
    print("   (fix it, or BLESS=1 and say in the commit why it is meant)")
    sys.exit(1)
print(f"quartus warnings: no new ones ({len(now)} known, {sections} connectivity sections read)")
