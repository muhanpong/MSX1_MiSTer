#!/usr/bin/env python3
"""YPROBE for fullsys (tb_msx.sv -DYPROBE): replaces the BIOS at 0000h (GT pack).
The Y8960 Cartridge in slot 1 as the CPU sees it.  One result byte per OUT (2Fh);
tb_msx.sv holds the expected list.

  mkyprobe.py            -> the probe (hex bytes, one per line)
  mkyprobe.py rom FILE   -> a 128 KB stand-in BIOS image: "AB" at 0, byte 10h of
                            every 8 KB bank = its bank number

  phase 1  slot memory     4000h, 4001h ("AB"), 4010h (bank 0), 6010h (1), 8010h (2)
  phase 2  enablers        7FFFh reads 00; C0h (the forced MSX-AUDIO) does not answer
                           yet; 7FFFh <- 87h, reads back 87h
  phase 3  SSG             SSG2 R#0 <- 55h, read at A2h; main PSG R#0 <- 12h by I/O,
                           read; main PSG R#1 <- 0Ah through 7FF0h/7FF1h, read
  phase 4  MSX-AUDIO       status at C0h; timer 1 (set through 7FF2h/7FF3h) -> flags;
                           EI/HALT, the ISR reads the status; after
  phase 5  ADPCM RAM       8 bytes in, EOS, the 8 bytes back
  phase 6  mapper          RAM mode, bank 10h in 8000h: write/read; bank 11h is not
                           it; bank 10h again; bank 0 at 8000h is not writable
  phase 7  SCC             bank 3Fh in 8000h: wave RAM 9800h write/read; a write to
                           9900h (the cartridge's pan) must not land in 9800h
  phase 8  OPM             status at 7Fh
  phase 9  volumes         every multiplier of the machine's chips is x1
  phase 10 volumes         7FF7h-7FFAh, 7FFEh written: the multipliers follow
  phase 0Fh done
"""
import sys
if len(sys.argv) > 2 and sys.argv[1] == 'rom':
    rom = bytearray(b'\x00' * 0x20000)
    rom[0:2] = b'AB'
    for bank in range(16):
        rom[bank * 0x2000 + 0x10] = bank
    open(sys.argv[2], 'wb').write(rom)
    sys.exit(0)

code = bytearray(); labels = {}; fix = []
def b(*x): code.extend(x)
def lab(n): labels[n] = len(code)
def call(n): b(0xCD); fix.append((len(code), n, 'abs')); b(0, 0)
def jp(n):   b(0xC3); fix.append((len(code), n, 'abs')); b(0, 0)
def jrnz(n): b(0x20); fix.append((len(code), n, 'rel')); b(0)
def djnz(n): b(0x10); fix.append((len(code), n, 'rel')); b(0)
def pad(a):
    assert len(code) <= a, hex(len(code)); code.extend(b'\0' * (a - len(code)))
def wr(reg, val): b(0x01, val, reg); call('wr')          # ld bc,reg:val / call wr  (OPL2)
def out(p, v): b(0x3E, v, 0xD3, p)                       # ld a,v / out (p),a
def rep(): b(0xD3, 0x2F)                                 # out (2Fh),a
def rep_in(p): b(0xDB, p); rep()                         # in a,(p) / report
def rep_mem(a): b(0x3A, a & 255, a >> 8); rep()          # ld a,(a) / report
def poke(a, v): b(0x3E, v, 0x32, a & 255, a >> 8)        # ld a,v / ld (a),a
def phase(n): out(0x2E, n)

b(0xF3); jp('start')
pad(0x38)                                                # IM 1 handler
rep_in(0xC0)
wr(0x04, 0x08)                                           # timers off, BUF RDY masked
wr(0x04, 0x80)                                           # flag reset
b(0xC9)
pad(0x50); lab('wr')
b(0x78, 0xD3, 0xC0, 0x79, 0xD3, 0xC1, 0xC9)              # ld a,b/out C0/ld a,c/out C1/ret
pad(0x60); lab('start')
b(0xF3)
out(0xAB, 0x82)                                          # PPI mode word, as the BIOS
out(0xE4, 0x06); out(0xE5, 0x60)                         # turbo R: Z80
out(0xA8, 0xF0)                                          # pages 2,3 -> slot 3
b(0xAF, 0x32, 0xFF, 0xFF)                                # subslot 0 (RAM)
b(0x31, 0x00, 0xF0)                                      # ld sp,F000h
b(0xED, 0x56)                                            # im 1
out(0xA8, 0xD4)                                          # page 3 RAM, pages 1,2 -> slot 1, page 0 BIOS
jp('main')
pad(0x190); lab('main')

phase(1)
rep_mem(0x4000); rep_mem(0x4001); rep_mem(0x4010); rep_mem(0x6010); rep_mem(0x8010)

phase(2)
rep_mem(0x7FFF)
rep_in(0xC0)                                             # the MSX-AUDIO waits for the enabler: FFh
poke(0x7FFF, 0x87); rep_mem(0x7FFF)

phase(3)
out(0xA0, 0x10); out(0xA1, 0x55)
out(0xA0, 0x10); rep_in(0xA2)                            # the cartridge's SSG2 R#0
out(0xA0, 0x00); out(0xA1, 0x12)
out(0xA0, 0x00); rep_in(0xA2)                            # the main PSG's R#0
poke(0x7FF0, 0x01); poke(0x7FF1, 0x0A)                   # the main PSG's R#1 through the slot
out(0xA0, 0x01); rep_in(0xA2)

phase(4)
wr(0x04, 0x80); rep_in(0xC0)
poke(0x7FF2, 0x02); poke(0x7FF3, 0xFF)                   # timer 1 value through the slot
poke(0x7FF2, 0x04); poke(0x7FF3, 0x09)                   # start timer 1, BUF RDY masked
b(0x06, 0x00); lab('d1'); djnz('d1')                     # ~0.9 ms at 3.58 MHz
rep_in(0xC0)
b(0xFB, 0x76)                                            # ei / halt
rep_in(0xC0)

phase(5)
def addr():
    wr(0x09, 0x10); wr(0x0A, 0x00); wr(0x0B, 0x11); wr(0x0C, 0x00)
wr(0x07, 0x01); wr(0x07, 0x60); addr()
b(0x1E, 0xA0); lab('w1')                                 # ld e,A0h
b(0x06, 0x0F, 0x4B); call('wr')                          # ld b,0Fh / ld c,e
b(0x1C, 0x7B, 0xFE, 0xA8); jrnz('w1')                    # inc e / ld a,e / cp A8h
rep_in(0xC0)
wr(0x07, 0x01); wr(0x07, 0x20); addr()
b(0x3E, 0x0F, 0xD3, 0xC0, 0xDB, 0xC1, 0xDB, 0xC1)        # select R#0F, two dummy reads
b(0x06, 0x08); lab('r1')
b(0xDB, 0xC1, 0xD3, 0x2F); djnz('r1')
wr(0x07, 0x01)

phase(6)
poke(0x4FFB, 0x01)                                       # RAM mode
poke(0x4FFE, 0x10)                                       # bank 2 = #16 (RAM)
poke(0x8000, 0x5A); poke(0x8001, 0xA5)
rep_mem(0x8000); rep_mem(0x8001)
poke(0x4FFE, 0x11); rep_mem(0x8000)                      # another RAM bank: padding (FFh)
poke(0x4FFE, 0x10); rep_mem(0x8000)
poke(0x4FFE, 0x00); poke(0x8000, 0x77); rep_mem(0x8000)  # ROM bank: still 'A'

phase(7)
poke(0x4FFE, 0x3F)                                       # bank 2 = #63: SCC registers
poke(0x9800, 0x12); poke(0x9801, 0x34)
poke(0x9900, 0x77)
rep_mem(0x9800); rep_mem(0x9801)

phase(8)
rep_in(0x7F)

#  phases 9 and 10 carry no result byte: tb_msx.sv reads the volume multipliers of the
#  machine's chips at each (all x1 before; after SSG 40h, OPLL 20h, OPL2 10h, SCC 40h,
#  master 40h: 32, 16, 8, 32 of 128)
phase(9)
poke(0x7FF7, 0x40); poke(0x7FF8, 0x20); poke(0x7FF9, 0x10); poke(0x7FFA, 0x40); poke(0x7FFE, 0x40)
phase(10)
poke(0x7FF7, 0x80); poke(0x7FF8, 0x80); poke(0x7FF9, 0x80); poke(0x7FFA, 0x80); poke(0x7FFE, 0x80)
phase(0x0F)
lab('end'); b(0x18, 0xFE)
for pos, n, k in fix:
    t = labels[n]
    if k == 'abs': code[pos] = t & 255; code[pos + 1] = t >> 8
    else:
        d = t - (pos + 1); assert -128 <= d < 128; code[pos] = d & 255
assert code[0x2D] == 0, 'byte 002Dh must stay 0'
print('\n'.join('%02x' % x for x in code))
