#!/usr/bin/env python3
"""Build the turbo R disk ROM that runs on this core's WD2793.

The FS-A1ST / FS-A1GT disk ROM (64 KB inside the firmware at 0x60000) carries
MSX-DOS 2.30 / 2.31 and a TC8566AF driver.  This core has no TC8566AF, so the
driver is replaced with the WD2793 driver from the Sony HB-F1XD disk ROM and the
kernel is re-linked to it.  The result is what the TURBOR_FDC pack block loads
(fs-a1st_diskrom_wd2793.rom / fs-a1gt_diskrom_wd2793.rom).

No ROM bytes live in this file: only addresses and the few jump/call
instructions we write.  Both inputs are your own dumps, checked by sha1:

  fs-a1st_firmware.rom  c212b11f...  (disk ROM at 0x60000: 84a44ecf...)
  fs-a1gt_firmware.rom  e779c338...  (disk ROM at 0x60000: 0527fb75...)
  hb-f1xd_disk.rom      12f2cc79...

Usage:
  synth_diskrom.py [--store DIR] [--out DIR] [--patches] [st|gt ...]

--store is searched (recursively, by sha1) for the inputs; it defaults to the
pack builder's ROM store.  Outputs go to --out (default: the store's
machines/panasonic/), are verified against the known sha1, and an existing file
is only left alone if it is byte-identical.  Details: docs/turbor_diskrom_20260923.md.
"""
import argparse, hashlib, json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEF_STORE = os.path.join(HERE, '..', 'CreateMSXpack', 'ROM')

HB_SHA = '12f2cc79b3d09723840bae774be48c0d721ec1c6'
MODELS = {
    'st': dict(fw_sha='c212b11fda13f83dafed688c54d098e7e47ab225',
               disk_sha='84a44ecf6f2dcfc1102f43ec7f6ddf687a44aadf',
               out='fs-a1st_diskrom_wd2793.rom',
               out_sha='94f4587db749af02f82837b3dbad7fc6e55f15e9',
               # original driver entry points (bank 0/1 jump table at 4010)
               jt=dict(DSKIO=0x7495, DSKCHG=0x77CA, GETDPB=0x7820, CHOICE=0x783B, DSKFMT=0x7C6D, MTOFF=0x7746),
               # kernel call sites into the driver: site -> original target
               k=dict(INIHRD=(0x47D6, 0x7724), DRIVES=(0x48C6, 0x777A), DEFDPB=(0x48F8, 0x7416),
                      INIENV=(0x4904, 0x77A1), OEMSTA=(0x5796, 0x7878)),
               mysize=(0x489A, 0x1A), handler=0x77B6,
               # DOS2 kernel services the DOS1 driver has to call instead of its own
               kmap=dict(GETWRK=0x4DCD, SETINT=0x4DFE, PROMPT=0x4D4F, DIV=0x4E67, TIMER=0x4E14)),
    'gt': dict(fw_sha='e779c338eb91a7dea3ff75f3fde76b8af22c4a3a',
               disk_sha='0527fb75775caa76c7eca8d449938ace83d36e96',
               out='fs-a1gt_diskrom_wd2793.rom',
               out_sha='86f81c71c858d98e2d4031566efd3b5a3843e279',
               jt=dict(DSKIO=0x7459, DSKCHG=0x779D, GETDPB=0x77F9, CHOICE=0x781A, DSKFMT=0x7C52, MTOFF=0x7713),
               k=dict(INIHRD=(0x47D6, 0x76F1), DRIVES=(0x48C6, 0x7747), DEFDPB=(0x48F8, 0x73DA),
                      INIENV=(0x4904, 0x7771), OEMSTA=(0x5796, 0x785D)),
               mysize=(0x489A, 0x1F), handler=0x7789,
               kmap=dict(GETWRK=0x4DD8, SETINT=0x4E09, PROMPT=0x4D5A, DIV=0x4E72, TIMER=0x4E1F)),
}
# entry points in the HB-F1XD driver
HBSYM = dict(DSKIO=0x751E, DSKCHG=0x78BA, GETDPB=0x7943, CHOICE=0x795D, DSKFMT=0x79A0, MTOFF=0x7DE2,
             INIHRD=0x7827, DRIVES=0x7867, DEFDPB=0x74E7, INIENV=0x78A7, OEMSTA=0x7DE0)
DISK_OFF, DISK_LEN = 0x60000, 0x10000
DRV_LO, DRV_HI = 0x7405, 0x7FD0          # driver span copied into banks 0 and 1
BANK_STUB = bytes.fromhex('32f07fc9c3b778')  # 7FD0: LD (7FF0),A / RET / 7FD4: JP 78B7


def w(v): return bytes([v & 0xFF, v >> 8])
def sha1(b): return hashlib.sha1(b).hexdigest()


def find_by_sha(store, want):
    for dp, _, fs in os.walk(store, followlinks=True):
        for f in fs:
            p = os.path.join(dp, f)
            try:
                if os.path.getsize(p) in (0x4000, 0x10000, 0x400000) and sha1(open(p, 'rb').read()) == want:
                    return p
            except OSError:
                pass
    return None


def disk_rom(store, m):
    """64 KB disk ROM, from the firmware or from an already cut copy."""
    for want, cut in ((m['fw_sha'], True), (m['disk_sha'], False)):
        p = find_by_sha(store, want)
        if p:
            d = open(p, 'rb').read()
            d = d[DISK_OFF:DISK_OFF + DISK_LEN] if cut else d
            if sha1(d) != m['disk_sha']:
                sys.exit(f"{p}: disk ROM sha1 {sha1(d)} != {m['disk_sha']}")
            return d, p
    sys.exit(f"firmware (sha1 {m['fw_sha'][:8]}) or disk ROM (sha1 {m['disk_sha'][:8]}) not found under {store}")


def build(disk, hb, m):
    banks = [bytearray(disk[i * 0x4000:(i + 1) * 0x4000]) for i in range(4)]
    log = []

    def put(bk, a, new, old, why):
        o = a - 0x4000
        got = bytes(banks[bk][o:o + len(new)])
        assert got == old, f"bank{bk} {a:04X}: found {got.hex()}, expected {old.hex()} ({why})"
        banks[bk][o:o + len(new)] = new
        log.append([bk, f"{a:04X}", old.hex(), new.hex(), why])

    drv = bytearray(hb[DRV_LO - 0x4000:DRV_HI - 0x4000])
    km = m['kmap']

    def dp(a, new, old, why):
        o = a - DRV_LO
        assert bytes(drv[o:o + len(new)]) == old, f"hb {a:04X}: unexpected bytes ({why})"
        drv[o:o + len(new)] = new
        log.append(['drv', f"{a:04X}", old.hex(), new.hex(), why])

    # the DOS1 driver's calls into the DOS1 kernel -> the DOS2 kernel's equivalents
    for a in (0x7694, 0x7869, 0x78A7, 0x78BD, 0x7B62, 0x7B95):
        dp(a, b'\xCD' + w(km['GETWRK']), b'\xCD' + w(0x5FC2), 'GETWRK')
    dp(0x78B4, b'\xC3' + w(km['SETINT']), b'\xC3' + w(0x5FF6), 'SETINT')
    dp(0x776C, b'\xCD' + w(km['PROMPT']), b'\xCD' + w(0x625A), 'PROMPT')
    dp(0x76CD, b'\xCD' + w(km['DIV']), b'\xCD' + w(0x492F), 'DIV')
    dp(0x78B1, b'\x21' + w(0x7FD4), b'\x21' + w(0x78B7), 'INIENV handler -> trampoline 7FD4')
    dp(0x78B7, b'\xC3' + w(km['TIMER']), b'\xC3' + w(0x6027), 'timer handler -> DOS2 generic')

    for bk in (0, 1):
        banks[bk][DRV_LO - 0x4000:DRV_HI - 0x4000] = drv
        log.append([bk, f'{DRV_LO:04X}-{DRV_HI - 1:04X}', '<TC8566AF driver>', f'<hb driver patched {sha1(drv)[:8]}>', 'driver swap'])
        for i, nm in enumerate(['DSKIO', 'DSKCHG', 'GETDPB', 'CHOICE', 'DSKFMT', 'MTOFF']):
            put(bk, 0x4010 + 3 * i, b'\xC3' + w(HBSYM[nm]), b'\xC3' + w(m['jt'][nm]), f'jump table {nm}')
    for nm, (site, old) in m['k'].items():
        op = 0x21 if nm == 'DEFDPB' else (0xC3 if nm == 'OEMSTA' else 0xCD)
        put(0, site, bytes([op]) + w(HBSYM[nm]), bytes([op]) + w(old), nm)
    ms, mv = m['mysize']
    assert banks[0][ms - 0x4000:ms - 0x4000 + 3] == b'\x21' + w(mv), 'MYSIZE site'   # kept as is
    for bk in (0, 1, 2):
        put(bk, 0x7FDE, b'\xCD' + w(0x78B7), b'\xCD' + w(m['handler']), 'trampoline CALL handler')

    # bank 3: the DOS1 kernel, taken from the HB-F1XD ROM, plus the bank-switch stub
    b3 = bytearray(hb)
    assert b3[0x3FC0:] == bytes(64), 'hb-f1xd tail not empty'
    b3[0x3FD0:0x3FD0 + len(BANK_STUB)] = BANK_STUB
    banks[3] = b3
    log.append([3, '4000-7FFF', '<vendor DOS1 kernel+TC8566AF>', '<hb-f1xd 12f2cc79 + 7FD0 32F07FC9 + 7FD4 C3B778>', 'bank3'])
    return b''.join(bytes(b) for b in banks), log


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('models', nargs='*', default=['st', 'gt'], choices=['st', 'gt'])
    ap.add_argument('--store', default=DEF_STORE, help='where to look for the input dumps (by sha1)')
    ap.add_argument('--out', help='output directory (default: STORE/machines/panasonic)')
    ap.add_argument('--patches', action='store_true', help='also write synth_<model>_patches.json')
    a = ap.parse_args()
    out_dir = a.out or os.path.join(a.store, 'machines', 'panasonic')
    hb_p = find_by_sha(a.store, HB_SHA) or sys.exit(f"hb-f1xd_disk.rom (sha1 {HB_SHA[:8]}) not found under {a.store}")
    hb = open(hb_p, 'rb').read()
    rc = 0
    for key in a.models:
        m = MODELS[key]
        disk, src = disk_rom(a.store, m)
        out, log = build(disk, hb, m)
        ok = sha1(out) == m['out_sha']
        dst = os.path.join(out_dir, m['out'])
        if not ok:
            print(f"{key}: FAIL  sha1 {sha1(out)} != {m['out_sha']}  (nothing written)"); rc = 1; continue
        if os.path.exists(dst):
            state = 'already present, identical' if open(dst, 'rb').read() == out else 'EXISTS AND DIFFERS, not overwritten'
            rc |= state.startswith('EXISTS')
        else:
            os.makedirs(out_dir, exist_ok=True); open(dst, 'wb').write(out); state = 'written'
        if a.patches:
            json.dump(log, open(os.path.join(HERE, f'synth_{key}_patches.json'), 'w'), indent=1)
        print(f"{key}: OK  {m['out']}  sha1 {m['out_sha'][:8]}  patches {len(log)}  {state}\n     from {src}")
    sys.exit(rc)


if __name__ == '__main__':
    main()
