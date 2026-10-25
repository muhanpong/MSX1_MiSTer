#!/usr/bin/env python3
"""Judge an LPROBE run (tb_msx.sv -DLPROBE, assets/lprobe.asm) before its latency
numbers are used: every phase must have run as lprobe.asm says, and the one-timestamp
latency counter must not have lost or merged a request.

    lprobe_check.py <run log> [cpf]

Prints each phase's latency lines and "VALID" or "INVALID: <reasons>", then
"LPROBE VALID" only if every phase is valid.  cpf = clk per 44.1 kHz frame
(default 2922, 128.86 MHz).
"""
import re, sys

log = open(sys.argv[1], errors='replace').read()
cpf = int(sys.argv[2]) if len(sys.argv) > 2 else 2922
MIN_FRAMES = 10                      # a phase shorter than this has too few frames to say much

# phase -> (keyed-on slots at its end, min MoonSound OUTs, min INs, min idle-loop M1s)
EXPECT = {
    1: dict(keyon=24),
    2: dict(keyon=24, m1=600),
    3: dict(keyon=24, m1=1200),
    4: dict(keyon=24, io_wr=1024),
    5: dict(keyon=24, io_rd=1024),
    6: dict(keyon=0, io_wr=1024, m1=600),
    7: dict(keyon=0, m1=600),
}

counts = {int(m.group(1)): dict(zip(m.group(2).split()[0::2], map(int, m.group(2).split()[1::2])))
          for m in re.finditer(r"^lprobe: phase (\d+) count (.*)$", log, re.M)}
lat = {}
for m in re.finditer(r"^lprobe: phase (\d+) (read|write) +(.*?)\s*$", log, re.M):
    lat.setdefault(int(m.group(1)), {})[m.group(2)] = m.group(3)

ok_all = True
for ph in sorted(EXPECT):
    c = counts.get(ph)
    if c is None:
        print(f"phase {ph}: INVALID: no count line"); ok_all = False; continue
    why = []
    e = EXPECT[ph]
    if c['keyon'] != e['keyon']:
        why.append(f"keyon {c['keyon']} (want {e['keyon']})")
    for k in ('io_wr', 'io_rd'):
        if k in e and c[k] < e[k]:
            why.append(f"{k} {c[k]} (want >= {e[k]})")
    if 'm1' in e and c['idle_m1'] < e['m1']:
        why.append(f"idle loop ran {c['idle_m1']}x (want >= {e['m1']})")
    if ph != 1 and c['clk'] < MIN_FRAMES * cpf:
        why.append(f"{c['clk']} clk = {c['clk'] / cpf:.1f} frames (want >= {MIN_FRAMES})")
    #  one request may straddle the phase boundary
    if abs(c['rd_rise'] - c['rd_valid']) > 1:
        why.append(f"read rises {c['rd_rise']} != valids {c['rd_valid']}")
    if abs(c['wr_rise'] - c['wr_done']) > 1:
        why.append(f"write rises {c['wr_rise']} != completions {c['wr_done']}")
    if c['rd_overwrite'] or c['wr_overwrite']:
        why.append(f"overwritten timestamps rd {c['rd_overwrite']} wr {c['wr_overwrite']}")
    l = lat.get(ph, {})
    print(f"phase {ph}: {c['clk'] / cpf:.1f} frames, read {l.get('read', '?')}, write {l.get('write', '?')}")
    print(f"  {'VALID' if not why else 'INVALID: ' + '; '.join(why)}")
    ok_all &= not why
print("LPROBE " + ("VALID" if ok_all else "INVALID"))
sys.exit(0 if ok_all else 1)
