#!/usr/bin/env python3
"""Build the FS-A1ST / FS-A1GT packs that actually use the Panasonic 3-3 mapper.

The shipped packs leave slot 3-3 empty, so nothing in the tree exercises
MAPPER_PANASONIC or the SRAM allocation behind it.  This writes a copy of each
machine XML with 3-3 filled, into a scratch tree, and leaves the shipped packs
alone -- they are what hardware runs, and a pack nobody has booted does not
belong there yet.

    tools/panasonic33/make_packs.py <outdir>
    cd <outdir> && python3 createMSXpack.py

<outdir> gets Computer/, Extension/, ROM/ and a copy of createMSXpack.py, so the
builder runs there unchanged.  ROM/ is copied rather than linked: createMSXpack
walks it with os.walk, which does not follow symlinks.

Sizes come from docs/panasonic_mapper.md: the ST is 2 MB of firmware (128 blocks
of 16 kB) with 16 kB of SRAM, the GT 4 MB (256 blocks) with 32 kB.  The block
type carries the SRAM size, so PANASONIC16 and PANASONIC32 are what pick it.
"""
import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PACK = os.path.join(HERE, '..', 'CreateMSXpack')

JOBS = [
    ('Panasonic FS-A1ST.xml', 'PANASONIC16', 'fs-a1st_firmware.rom',
     'c212b11fda13f83dafed688c54d098e7e47ab225', 128),
    ('Panasonic FS-A1GT.xml', 'PANASONIC32', 'fs-a1gt_firmware.rom',
     'e779c338eb91a7dea3ff75f3fde76b8af22c4a3a', 256),
]


def fill_3_3(text, typ, rom, sha, count):
    """Add a secondary 3 under primary 3.  On a turbo R that slot is empty."""
    i = text.index('<primary slot="3">')
    j = text.index('  </primary>', i)
    block = (
        '    <!-- 3-3: the firmware behind the Panasonic mapper. Eight 8 kB regions\n'
        '         cover the whole address space, plus the machine battery SRAM.\n'
        '         Empty in the shipped pack; this is the verification copy. -->\n'
        '    <secondary slot="3">\n'
        '      <block start="0" id="firmware (Panasonic mapper)">\n'
        f'        <type>{typ}</type>\n'
        f'        <block_count>{count}</block_count>\n'
        f'        <filename>{rom}</filename>\n'
        f'        <SHA1>{sha}</SHA1>\n'
        '      </block>\n'
        '    </secondary>\n')
    return text[:j] + block + text[j:]


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__.splitlines()[0] + '\n\n  usage: make_packs.py <outdir>')
    out = os.path.abspath(sys.argv[1])
    for sub in ('Computer/Panasonic', 'Extension', 'MSX'):
        os.makedirs(os.path.join(out, sub), exist_ok=True)
    shutil.copy(os.path.join(PACK, 'createMSXpack.py'), out)
    rom_dst = os.path.join(out, 'ROM')
    if not os.path.isdir(rom_dst):
        shutil.copytree(os.path.join(PACK, 'ROM'), rom_dst)
        print(f'ROM store copied to {rom_dst}')
    for src, typ, rom, sha, count in JOBS:
        with open(os.path.join(PACK, 'Computer', 'Panasonic', src), encoding='utf-8') as f:
            text = f.read()
        name = src.replace('.xml', ' 3-3.xml')
        with open(os.path.join(out, 'Computer', 'Panasonic', name), 'w', encoding='utf-8') as f:
            f.write(fill_3_3(text, typ, rom, sha, count))
        print(f'  {name}: {typ}, {count} blocks')
    print(f'\nnow: cd {out} && python3 createMSXpack.py')


if __name__ == '__main__':
    main()
