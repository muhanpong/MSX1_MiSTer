#!/usr/bin/env python3
"""Build a 720KB MSX FAT12 floppy image that boots MSX-DOS 1 and MSX-DOS 2.

Usage:
    mkmsxdsk.py OUT.DSK [options] FILE [FILE ...]

Options:
    --label NAME       volume label (<=11 chars)
    --autoexec "CMD"   create AUTOEXEC.BAT with these lines (use ';' to separate)
    --dos1-only        omit MSXDOS2.SYS / COMMAND2.COM
    --dos2-only        omit MSXDOS.SYS / COMMAND.COM (required to boot DOS 2)
    --no-sys           data-only disk (not bootable)

The system files come from tools/mkdsk/sys/.  MSXDOS.SYS is always written
first so it occupies cluster 2 contiguously, which the MSX disk ROM's boot
loader assumes.
"""
import sys, os, struct

HERE   = os.path.dirname(os.path.abspath(__file__))
SYSDIR = os.path.join(HERE, 'sys')

# --- 720KB 2DD geometry -------------------------------------------------
BPS, SPC, RES, NFAT, NROOT, TOTSEC, SPF, SPT, HEADS = 512, 2, 1, 2, 112, 1440, 3, 9, 2
FAT_OFF   = RES * BPS
ROOT_OFF  = FAT_OFF + NFAT * SPF * BPS
DATA_OFF  = ROOT_OFF + NROOT * 32
NCLUST    = (TOTSEC - RES - NFAT * SPF - NROOT * 32 // BPS) // SPC  # 713
CLSZ      = SPC * BPS

def fat_set(fat, n, v):
    o = n + n // 2
    if n & 1:
        fat[o]   = (fat[o] & 0x0F) | ((v & 0x0F) << 4)
        fat[o+1] = (v >> 4) & 0xFF
    else:
        fat[o]   = v & 0xFF
        fat[o+1] = (fat[o+1] & 0xF0) | ((v >> 8) & 0x0F)

def msxname(fn):
    fn = os.path.basename(fn).upper()
    name, _, ext = fn.partition('.')
    if len(name) > 8 or len(ext) > 3:
        raise SystemExit(f"'{fn}' is not a valid 8.3 name")
    return name.ljust(8)[:8].encode('ascii') + ext.ljust(3)[:3].encode('ascii')

def main():
    a = sys.argv[1:]
    if not a or a[0] in ('-h', '--help'):
        print(__doc__); return 0
    out, a = a[0], a[1:]
    label, autoexec, dos1_only, dos2_only, no_sys, files = 'MSXDISK', None, False, False, False, []
    i = 0
    while i < len(a):
        if   a[i] == '--label':    label = a[i+1]; i += 2
        elif a[i] == '--autoexec': autoexec = a[i+1]; i += 2
        elif a[i] == '--dos1-only': dos1_only = True; i += 1
        elif a[i] == '--dos2-only': dos2_only = True; i += 1
        elif a[i] == '--no-sys':    no_sys = True; i += 1
        else: files.append(a[i]); i += 1

    # (source_path_or_bytes, on_disk_name) -- order matters
    entries = []
    if not no_sys:
        if not dos2_only:
            entries.append((os.path.join(SYSDIR, 'MSXDOS.SYS'),  'MSXDOS.SYS'))
            entries.append((os.path.join(SYSDIR, 'COMMAND.COM'), 'COMMAND.COM'))
        if not dos1_only:
            entries.append((os.path.join(SYSDIR, 'NEXTOR.SYS'),   'NEXTOR.SYS'))
            entries.append((os.path.join(SYSDIR, 'MSXDOS2.SYS'),  'MSXDOS2.SYS'))
            entries.append((os.path.join(SYSDIR, 'COMMAND2.COM'), 'COMMAND2.COM'))
    if autoexec is not None:
        body = ''.join(l + '\r\n' for l in autoexec.split(';'))
        entries.append((body.encode('ascii'), 'AUTOEXEC.BAT'))
    for f in files:
        entries.append((f, os.path.basename(f)))

    img = bytearray(b'\x00' * (TOTSEC * BPS))
    boot = open(os.path.join(SYSDIR, 'boot720.bin'), 'rb').read()
    img[0:BPS] = boot                                   # proven-good MSX boot sector
    fat = bytearray(b'\x00' * (SPF * BPS))
    fat[0], fat[1], fat[2] = 0xF9, 0xFF, 0xFF           # media F9 = 720KB 2DD

    dirent, free = bytearray(), NCLUST
    nextc = 2
    # volume label first (does not consume a cluster)
    e = bytearray(32); e[0:11] = label.upper().ljust(11)[:11].encode('ascii'); e[11] = 0x08
    dirent += e

    for src, name in entries:
        data = src if isinstance(src, bytes) else open(src, 'rb').read()
        need = (len(data) + CLSZ - 1) // CLSZ or 1
        if need > free:
            raise SystemExit(f"out of space: {name} needs {need}KB, {free}KB free")
        start = nextc
        for k in range(need):
            c = nextc + k
            fat_set(fat, c, 0xFFF if k == need - 1 else c + 1)
            off = DATA_OFF + (c - 2) * CLSZ
            img[off:off + CLSZ] = data[k*CLSZ:(k+1)*CLSZ].ljust(CLSZ, b'\x00')
        nextc += need; free -= need
        e = bytearray(32)
        e[0:11] = msxname(name)
        e[11] = 0x20                                    # archive
        e[22:24] = struct.pack('<H', 0x6000)            # time 12:00
        e[24:26] = struct.pack('<H', 0x5AF7)            # date 2025-07-23
        e[26:28] = struct.pack('<H', start)
        e[28:32] = struct.pack('<I', len(data))
        dirent += e
        print(f"  {name:14s} {len(data):7d} B  clu {start}..{nextc-1}")

    if len(dirent) > NROOT * 32:
        raise SystemExit(f"too many root entries ({len(dirent)//32} > {NROOT})")
    img[ROOT_OFF:ROOT_OFF + len(dirent)] = dirent
    for n in range(NFAT):
        o = FAT_OFF + n * SPF * BPS
        img[o:o + SPF * BPS] = fat
    open(out, 'wb').write(img)
    print(f"{out}: {TOTSEC*BPS} B, {len(dirent)//32 - 1} files, {free} KB free of {NCLUST} KB")
    return 0

sys.exit(main())
