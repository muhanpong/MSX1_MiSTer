#!/usr/bin/env python3
# make_ascii16x_erase_hang.py
#
# MSX1 ASCII16X sector-erase FREEZE reproduction cart (regression test).
# Hand-assembled Z80 (no external assembler; two-pass label resolver emits raw
# opcodes, each instruction commented with its opcode for cross-checking).
#
# Faithfully reproduces the real game's hang: it issues an AMD/JEDEC 6-cycle
# sector-erase (which rtl/peripheral/slots/ascii16x.sv does NOT implement) and
# then polls the target FOREVER for 0xFF. On the current core the byte never
# becomes 0xFF, so the Z80 spins in an infinite loop -> true hang (OSD/HPS
# alive, forced reset required).  After a sector-erase FIX, the target reads
# 0xFF, the poll exits, and the border CYCLES = pass.  Same cart, two outcomes.
#
# Page-1 design (cart guaranteed mapped at INIT), bankRegs[0]=0 so executing
# code stays mapped, data targets at 0x50xx (bank0 offset 0x10xx), DI so the
# hang is a clean Z80 loop.
#
# JEDEC command window (addr[13]=0, i.e. 0x4000-0x5FFF):
#   AA -> 0x4AAA (off[11:1]=0x555), 55 -> 0x4554 (off[11:1]=0x2AA),
#   A0 -> 0x4AAA (program), 80 -> 0x4AAA (erase setup), 30 -> target (erase).
#
# Border colours (VDP R7 via OUT (0x99)):
#   SOLID MAGENTA (col 13) + machine frozen + needs manual reset
#                       = HANG REPRODUCED (erase not implemented; expected now).
#   CYCLING border      = erase completed -> PASS (only after the fix).
#   SOLID RED (col 8)   = the byte-program sanity write failed (broken bprog).

import sys

ROM_SIZE  = 0x10000
PAD       = 0xFF
ORG       = 0x4000
CODE_OFF  = 0x18
DATA_TGT  = 0x5000           # byte-program sanity target (bank0 off 0x1000)
ERASE_TGT = 0x5080           # erase target (bank0 off 0x1080), clear of code
UNLOCK_A  = 0x4AAA
UNLOCK_B  = 0x4554
BANKREG0  = 0x6000
MARKER    = 0x0D             # magenta: shown frozen during the hang

prog = []
def b(*xs):            prog.append(list(xs))
def label(n):          prog.append(('L', n))
def jr(name, cc=None): prog.append(('JR', cc, name))
def jp(name, cc=None): prog.append(('JP', cc, name))
def LDAn(n):  b(0x3E, n)                 # LD A,n
def LDnnA(a): b(0x32, a & 0xFF, a >> 8)  # LD (nn),A
def OUT99():  b(0xD3, 0x99)              # OUT (0x99),A

# ---- INIT --------------------------------------------------------
b(0xF3)                              # DI
b(0x0E, 0x00)                        # LD C,0x00     ; border-cycle accumulator
LDAn(0x00); LDnnA(BANKREG0)          # bankRegs[0]=0 (bank-reg write; FSM unaffected)

# ---- byte-program sanity: write 0xA5 to 0x5000, read back --------
b(0x21, DATA_TGT & 0xFF, DATA_TGT >> 8)  # LD HL,0x5000
LDAn(0xAA); LDnnA(UNLOCK_A)          # AA -> 0x4AAA
LDAn(0x55); LDnnA(UNLOCK_B)          # 55 -> 0x4554
LDAn(0xA0); LDnnA(UNLOCK_A)          # A0 -> 0x4AAA
LDAn(0xA5)                           # LD A,0xA5
b(0x77)                              # LD (HL),A     ; program byte
b(0x7E)                              # LD A,(HL)     ; read back
b(0xFE, 0xA5)                        # CP 0xA5
jp('red_fail', 'NZ')                 # JP NZ,red_fail

# ---- program known 0x00 to the erase target ---------------------
b(0x21, ERASE_TGT & 0xFF, ERASE_TGT >> 8)  # LD HL,0x5080
LDAn(0xAA); LDnnA(UNLOCK_A)          # AA -> 0x4AAA
LDAn(0x55); LDnnA(UNLOCK_B)          # 55 -> 0x4554
LDAn(0xA0); LDnnA(UNLOCK_A)          # A0 -> 0x4AAA
LDAn(0x00)                           # LD A,0x00
b(0x77)                              # LD (HL),A     ; target = 0x00 (known non-0xFF)

# ---- 6-cycle JEDEC sector erase ---------------------------------
LDAn(0xAA); LDnnA(UNLOCK_A)          # cycle1
LDAn(0x55); LDnnA(UNLOCK_B)          # cycle2
LDAn(0x80); LDnnA(UNLOCK_A)          # cycle3 (erase setup)
LDAn(0xAA); LDnnA(UNLOCK_A)          # cycle4
LDAn(0x55); LDnnA(UNLOCK_B)          # cycle5
LDAn(0x30); b(0x77)                  # cycle6: 30 -> (HL)  (sector erase confirm)

# ---- marker colour = MAGENTA (entered poll / frozen here) --------
LDAn(MARKER); OUT99()                # colour 13
LDAn(0x87);   OUT99()                # R7 | 0x80

# ---- INFINITE poll for 0xFF (real-game style hang) --------------
label('poll')
b(0x7E)                              # LD A,(HL)
b(0xFE, 0xFF)                        # CP 0xFF
jr('poll', 'NZ')                     # JR NZ,poll    ; spins forever until erased
# erase completed (only after fix) -> CYCLING success
label('success')
b(0x79)                              # LD A,C
b(0xE6, 0x0F)                        # AND 0x0F
OUT99()                              # OUT (0x99),A  colour
LDAn(0x87); OUT99()                  # R7 | 0x80
b(0x11, 0x00, 0x00)                  # LD DE,0x0000  delay
label('sdelay')
b(0x1B)                              # DEC DE
b(0x7A)                              # LD A,D
b(0xB3)                              # OR E
jr('sdelay', 'NZ')                   # JR NZ,sdelay
b(0x0C)                              # INC C
jr('success')                        # JR success

# ---- byte-program sanity failed -> SOLID RED --------------------
label('red_fail')
LDAn(0x08); OUT99()                  # colour 8 (red)
LDAn(0x87); OUT99()                  # R7 | 0x80
label('rhold')
jr('rhold')                          # JR rhold

# -------- assemble (two pass) ------------------------------------
addrs = {}
pc = ORG + CODE_OFF
for it in prog:
    if isinstance(it, list):   pc += len(it)
    elif it[0] == 'L':         addrs[it[1]] = pc
    elif it[0] == 'JP':        pc += 3
    else:                      pc += 2
code = bytearray(); pc = ORG + CODE_OFF
for it in prog:
    if isinstance(it, list):
        code += bytes(it); pc += len(it)
    elif it[0] == 'L':
        continue
    elif it[0] == 'JP':
        op = {'NZ': 0xC2, 'Z': 0xCA, None: 0xC3}[it[1]]; tgt = addrs[it[2]]
        code += bytes([op, tgt & 0xFF, tgt >> 8]); pc += 3
    else:
        op = (0x20 if it[1] == 'NZ' else 0x18) if it[0] == 'JR' else 0x10
        tgt = addrs[it[2] if it[0] == 'JR' else it[1]]
        rel = tgt - (pc + 2)
        if not -128 <= rel <= 127:
            sys.exit("rel jump out of range: %s -> %d" % (it, rel))
        code += bytes([op, rel & 0xFF]); pc += 2

# -------- build ROM ----------------------------------------------
rom = bytearray([PAD]) * ROM_SIZE
init = ORG + CODE_OFF
rom[0x00] = ord('A'); rom[0x01] = ord('B')
rom[0x02] = init & 0xFF; rom[0x03] = init >> 8
rom[0x04:0x10] = bytes(12)
rom[0x10:0x18] = b"ASCII16X"
rom[CODE_OFF:CODE_OFF + len(code)] = code
if CODE_OFF + len(code) > (ERASE_TGT - ORG):
    sys.exit("code overruns data target region!")
out = "ascii16x_erase_hang.rom"
with open(out, "wb") as f:
    f.write(rom)

# -------- report -------------------------------------------------
def hexdump(data, base, length):
    for i in range(0, length, 16):
        row = data[i:i+16]
        print("  %04X: %-47s  %s" % (base + i,
              " ".join("%02X" % x for x in row),
              "".join(chr(x) if 32 <= x < 127 else "." for x in row)))
print("Wrote %s  (%d bytes = 0x%X)" % (out, len(rom), len(rom)))
print("INIT entry = 0x%04X   code length = %d   end = 0x%04X" %
      (init, len(code), init + len(code)))
print("\nFirst 32 bytes:")
hexdump(rom[:32], 0x4000, 32)
print("\nINIT code region (0x%04X .. 0x%04X):" % (init, init + len(code)))
hexdump(code, init, len(code))
print("\nLabels:")
for k in ('poll', 'success', 'sdelay', 'red_fail', 'rhold'):
    print("  %-9s = 0x%04X" % (k, addrs[k]))
