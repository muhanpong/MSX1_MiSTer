#!/usr/bin/env python3
"""APROBE for fullsys (tb_msx.sv -DAPROBE): replaces the BIOS at 0000h (GT pack).
The MSX-AUDIO as the CPU sees it: port decode, WAIT handshake, status, /INT.
Every result is one byte on port 2Fh; tb_msx.sv holds the expected list.

  phase 1  R4=80h, IN C0h                       -> 06h   (card present, no flags)
           R2=FFh, R4=09h (timer 1, 80 us), wait ~1 ms, IN C0h   -> C6h
           EI / HALT; the ISR reads C0h          -> C6h   (so /INT reached the CPU)
           the ISR stops the timer and resets the flags; IN C0h -> 06h
  phase 2  8 bytes into the sample RAM, IN C0h  -> EOS (bit 4) set
           read them back (after the two dummy reads)            -> A0h..A7h
  phase 0Fh done

No assembler on this machine has the syntax of the other probes, so the bytes are
emitted here; `mkaprobe.py > aprobe.hex`.  Code stays below 0180h (turbor.sv
overlays 0180h-018Bh) and off 002Dh."""
code = bytearray(); labels = {}; fix = []
def b(*x): code.extend(x)
def lab(n): labels[n] = len(code)
def call(n): b(0xCD); fix.append((len(code), n, 'abs')); b(0, 0)
def jp(n):   b(0xC3); fix.append((len(code), n, 'abs')); b(0, 0)
def jrnz(n): b(0x20); fix.append((len(code), n, 'rel')); b(0)
def djnz(n): b(0x10); fix.append((len(code), n, 'rel')); b(0)
def pad(a):
    assert len(code) <= a, hex(len(code)); code.extend(b'\0' * (a - len(code)))
def wr(reg, val): b(0x01, val, reg); call('wr')          # ld bc,reg:val / call wr
def out(p, v): b(0x3E, v, 0xD3, p)                       # ld a,v / out (p),a
def rep_status(): b(0xDB, 0xC0, 0xD3, 0x2F)              # in a,(C0h) / out (2Fh),a

b(0xF3); jp('start')
pad(0x38)                                                # IM 1 handler
rep_status()
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
out(0x2E, 1)
wr(0x04, 0x80); rep_status()
wr(0x02, 0xFF); wr(0x04, 0x09)
b(0x06, 0x00); lab('d1'); djnz('d1')                     # ~0.9 ms at 3.58 MHz
rep_status()
b(0xFB, 0x76)                                            # ei / halt
rep_status()
out(0x2E, 2)
def addr():
    wr(0x09, 0x10); wr(0x0A, 0x00); wr(0x0B, 0x11); wr(0x0C, 0x00)
wr(0x07, 0x01); wr(0x07, 0x60); addr()
b(0x1E, 0xA0); lab('w1')                                 # ld e,A0h
b(0x06, 0x0F, 0x4B); call('wr')                          # ld b,0Fh / ld c,e
b(0x1C, 0x7B, 0xFE, 0xA8); jrnz('w1')                    # inc e / ld a,e / cp A8h
rep_status()
wr(0x07, 0x01); wr(0x07, 0x20); addr()
b(0x3E, 0x0F, 0xD3, 0xC0, 0xDB, 0xC1, 0xDB, 0xC1)        # select R#0F, two dummy reads
b(0x06, 0x08); lab('r1')
b(0xDB, 0xC1, 0xD3, 0x2F); djnz('r1')
wr(0x07, 0x01)
out(0x2E, 0x0F)
lab('end'); b(0x18, 0xFE)
assert len(code) < 0x180, hex(len(code))
for pos, n, k in fix:
    t = labels[n]
    if k == 'abs': code[pos] = t & 255; code[pos + 1] = t >> 8
    else:
        d = t - (pos + 1); assert -128 <= d < 128; code[pos] = d & 255
print('\n'.join('%02x' % x for x in code))
