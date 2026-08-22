#!/usr/bin/env python3
"""Verify the OPL4 gain constants IN THE RTL match the measured calibration.

tb_opl4_gain.sv models the datapath rather than instantiating ymf278b_top, so
it cannot catch someone editing the RTL tables alone.  This does: it parses the
shipped case statements and checks the resulting net dB per OSD step.

Calibration source (2026-08-21, measured):
  target RMS -20.3 dBFS  = SCMD "Out Run" SCC -22.6 + openMSX MoonSound/SCC+
                           config weighting (17000/13000 = +2.3 dB)
  PCM net -12 dB puts both MoonSound music-disk tracks at 0.00% clipping;
  FM  net  -4 dB puts their median at -21.7 dBFS.
"""
import re, sys, math

RTL = "rtl/peripheral/SOUND/ymf278b_fpga/rtl/ymf278b_top.sv"

# menu order -> expected net dB
FM_WANT  = [-3.98, -8.00, -12.04,  0.00, +4.02]   # 0dB,-4dB,-8dB,+4dB,+8dB
PCM_WANT = [-12.00, -16.00, -8.00, -4.00, 0.00]   # -4dB,-8dB,0dB,+4dB,+8dB
TOL = 0.15

def parse_case(src, fname):
    """Return {sel: value} for a 5-entry function, expanding `default`."""
    m = re.search(r"function automatic .*?\b%s\s*\(.*?\);(.*?)endfunction" % fname,
                  src, re.S)
    if not m:
        sys.exit(f"FAIL: function {fname}() not found in {RTL}")
    body = m.group(1)
    out, dflt = {}, None
    for line in body.splitlines():
        mm = re.search(r"3'd(\d)\s*:\s*%s\s*=\s*\d+'d(\d+)" % fname, line)
        if mm:
            out[int(mm.group(1))] = int(mm.group(2)); continue
        mm = re.search(r"default\s*:\s*%s\s*=\s*\d+'d(\d+)" % fname, line)
        if mm:
            dflt = int(mm.group(1))
    if dflt is None:
        sys.exit(f"FAIL: {fname}() has no default branch")
    for s in range(5):
        out.setdefault(s, dflt)
    return out, dflt

src = open(RTL).read()
fm, _        = parse_case(src, "fm_gain")
pre, pre_d   = parse_case(src, "pcm_pre")
post, post_d = parse_case(src, "pcm_post")

bad = 0
print("  step  FM mul   FM net   want  |  sh  post   PCM net   want")
for s in range(5):
    fm_db  = 20*math.log10(fm[s]/128.0)
    sh     = 3 - pre[s]
    pcm_db = -6.0206*sh + 20*math.log10(post[s]/128.0)
    ok_fm  = abs(fm_db  - FM_WANT[s])  <= TOL
    ok_pc  = abs(pcm_db - PCM_WANT[s]) <= TOL
    if not (ok_fm and ok_pc): bad += 1
    print(f"  {s:4d} {fm[s]:6d} {fm_db:+8.2f} {FM_WANT[s]:+6.2f} {'' if ok_fm else '  <-- FM MISMATCH'}"
          f" | {sh:3d} {post[s]:5d} {pcm_db:+9.2f} {PCM_WANT[s]:+6.2f} {'' if ok_pc else '  <-- PCM MISMATCH'}")

# defaults (MiSTer status resets to 0 -> menu entry 0 must be the intended default)
if abs(20*math.log10(fm[0]/128.0) - (-3.98)) > TOL:
    print("FAIL: FM menu entry 0 is not the calibrated default (-4 dB net)"); bad += 1
if abs((-6.0206*(3-pre[0]) + 20*math.log10(post[0]/128.0)) - (-12.0)) > TOL:
    print("FAIL: PCM menu entry 0 is not the calibrated default (-12 dB net)"); bad += 1
# out-of-range (sel 5..7) must fall back to the default entry, not the loudest
if fm[0] != _ or pre[0] != pre_d or post[0] != post_d:
    print("FAIL: out-of-range selector does not fall back to the default step"); bad += 1

# the pre-saturation shift must carry the bulk of the attenuation, else the
# engine's internal clamp is hit before the trim can help (the 2026-08-21 fix)
if (3 - pre[0]) < 2:
    print("FAIL: default PCM step leaves <12 dB of pre-saturation headroom"); bad += 1

print(f"\ncheck_opl4_gain_consts: {'OK' if not bad else str(bad)+' MISMATCH'}")
sys.exit(1 if bad else 0)
