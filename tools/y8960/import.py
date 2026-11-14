#!/usr/bin/env python3
"""Import the Y8960 Cartridge RTL (github.com/hra1129/Y8960_Cartridge) into the core tree.

usage: import.py <upstream checkout> <core root>

Copies the synthesizable sources the Gowin project lists, minus the board parts
(PLL, slot pins, serial SRAM / flash, I2S, system controller), into
rtl/peripheral/SOUND/y8960/upstream/ and gives every module that also exists in
this core (IKAOPLL, IKASCC, jtopl: Y8960 carries patched copies) a Y89_ prefix.
Nothing else is changed; re-run after pulling upstream.
"""
import os, re, shutil, subprocess, sys

SKIP = ('gowin_', 'i2s_audio', 'msx_slot', 'pll_init', 'sfrom', 'spi_rom', 'ssram/',
        'system_controller', 'y8960_cartridge', 'scc_bank')
PREFIX = 'Y89_'

def main():
    up, core = sys.argv[1], sys.argv[2]
    proj = os.path.join(up, 'fpga', 'Y8960_Cartridge_TangPrimer25K')
    dst = os.path.join(core, 'rtl', 'peripheral', 'SOUND', 'y8960', 'upstream')
    gprj = open(os.path.join(proj, 'Y8960_Cartridge_TangPrimer25K.gprj')).read()
    files = [f for f in re.findall(r'path="(src/[^"]*\.v)"', gprj) if not any(s in f for s in SKIP)]
    texts = {f: open(os.path.join(proj, f), encoding='utf-8', errors='surrogateescape').read() for f in files}
    mods = set()
    for t in texts.values():
        mods.update(re.findall(r'^\s*module\s+(\w+)', t, re.M))
    # modules of this core (outside the import directory)
    have = set()
    for root in ('rtl', 'sys'):
        for dp, dn, fn in os.walk(os.path.join(core, root)):
            if os.path.join('SOUND', 'y8960') in dp:
                continue
            for n in fn:
                if n.endswith(('.v', '.sv')):
                    t = open(os.path.join(dp, n), encoding='utf-8', errors='replace').read()
                    have.update(re.findall(r'^\s*module\s+(\w+)', t, re.M))
    # the whole family is renamed as soon as one member clashes, so that a later
    # core-side addition of another member cannot collide
    fam = ('IKAOPLL', 'IKASCC', 'jtopl', 'BUFG')
    clash = sorted(m for m in mods if m in have or m.startswith(fam))
    pat = re.compile(r'\b(' + '|'.join(re.escape(m) for m in sorted(clash, key=len, reverse=True)) + r')\b')
    if os.path.isdir(dst):
        shutil.rmtree(dst)
    out = []
    for f, t in texts.items():
        t2 = pat.sub(lambda m: PREFIX + m.group(1), t)
        rel = f[len('src/'):]
        p = os.path.join(dst, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        open(p, 'w', encoding='utf-8', errors='surrogateescape').write(t2)
        out.append(rel)
    for ip in ('adpcm', 'ikaopll', 'ikaopm', 'ikascc', 'opl2'):
        for n in ('LICENSE', 'README.txt'):
            s = os.path.join(proj, 'src', ip, n)
            if os.path.exists(s):
                os.makedirs(os.path.join(dst, ip), exist_ok=True)
                shutil.copy(s, os.path.join(dst, ip, n))
    shutil.copy(os.path.join(proj, 'LICENSE'), os.path.join(dst, 'LICENSE'))
    rev = subprocess.check_output(['git', '-C', up, 'rev-parse', 'HEAD']).decode().strip()
    with open(os.path.join(dst, 'UPSTREAM.md'), 'w') as u:
        u.write('# Y8960 Cartridge RTL\n\n'
                'Source: https://github.com/hra1129/Y8960_Cartridge  \n'
                'Commit: %s  \n'
                'Imported by tools/y8960/import.py -- do not edit here.\n\n'
                'Licences: see the header of each file and the LICENSE / README.txt in each\n'
                'directory (IKAOPLL, IKAOPM, IKASCC: BSD 2-Clause; jtopl, jt12 ADPCM: GPL-3;\n'
                'the remaining files: the terms in their headers, (C) Takayuki Hara).\n\n'
                'Modules renamed with the %s prefix (the core has its own copies):\n\n%s\n'
                % (rev, PREFIX, '\n'.join('- ' + m for m in clash)))
    qip = os.path.join(os.path.dirname(dst), 'y8960.qip')
    with open(qip, 'w') as q:
        for rel in sorted(out):
            q.write('set_global_assignment -name VERILOG_FILE [file join $::quartus(qip_path) upstream/%s ]\n' % rel)
        q.write('set_global_assignment -name SEARCH_PATH [file join $::quartus(qip_path) upstream/opl2/src ]\n')
        q.write('set_global_assignment -name SEARCH_PATH [file join $::quartus(qip_path) upstream/adpcm/src ]\n')
    print('%d files, %d modules, %d renamed, upstream %s' % (len(out), len(mods), len(clash), rev[:7]))

main()
