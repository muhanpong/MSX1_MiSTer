#!/usr/bin/env python3
# make_ascii16x_test.py
#
# Hand-assembled MSX1 ASCII16X flash stress cartridge (no external assembler:
# a tiny two-pass assembler emits raw Z80 opcodes from a label-resolved list,
# every instruction commented with its opcode for checking vs a Z80 reference).
#
# Targets the MSX1_MiSTer ASCII16X mapper (rtl/peripheral/slots/ascii16x.sv),
# which implements the AMD/JEDEC *byte-program* command but NOT *sector-erase*.
#
# Two phases, chained:
#   PHASE 1  byte-program 64 bytes + readback (known to PASS on the core).
#   PHASE 2  sector-erase probe: program a known 0x00 byte, issue the 6-cycle
#            JEDEC sector-erase, then BOUNDED-poll for 0xFF. Because the mapper
#            ignores erase, the byte never becomes 0xFF and the poll expires
#            -> "erase not implemented" is confirmed deterministically, with NO
#            real hang (the poll counter is finite).
#
# Everything runs from page 1 (0x4000-0x7FFF), which is guaranteed paged to the
# cartridge when the BIOS calls INIT. bankRegs[0] is left at 0 so executing code
# (bank 0, low offsets) stays mapped; data targets are at 0x50xx (bank 0 offset
# 0x10xx), well clear of the code.
#
# JEDEC command window (all addr[13]=0, i.e. 0x4000-0x5FFF):
#   AA -> 0x4AAA  (cpu_addr[11:1]==0x555)
#   55 -> 0x4554  (cpu_addr[11:1]==0x2AA)
#   80 -> 0x4AAA  (erase setup)
#   30 -> target  (sector-erase confirm; written to the sector address)
#   A0 -> 0x4AAA  (byte-program confirm; next write is the data byte)
#
# Border colour outcomes (VDP R7 via OUT (0x99)):
#   CYCLING border       = phase1 passed AND erase actually worked (unexpected
#                          on current core) -- "fully functional".
#   SOLID BLUE  (col 4)  = erase NOT implemented (EXPECTED) -- poll expired,
#                          target still 0x00.
#   SOLID RED   (col 8)  = a byte-program readback was wrong.
#   FROZEN (BIOS colour) = true core freeze (OSD alive, reset recovers).

import sys

# ------------------------------------------------------------------ constants
ROM_SIZE  = 0x10000          # 64 KB ASCII16X cart (size does not gate the
                             # forced mapper; keeps data targets in bounds).
PAD       = 0xFF
ORG       = 0x4000           # page-1 base
CODE_OFF  = 0x18             # file offset where INIT code begins
N_BYTES   = 0x40             # phase-1 byte count (easy to change)

DATA_BASE = 0x5000           # phase-1 target base  (bank0 offset 0x1000)
ERASE_TGT = 0x5080           # phase-2 erase target (bank0 offset 0x1080)
UNLOCK_A  = 0x4AAA           # off[11:1]=0x555
UNLOCK_B  = 0x4554           # off[11:1]=0x2AA
BANKREG0  = 0x6000           # addr[13]=1, addr[12]=0 -> bankRegs[0]

# ------------------------------------------------------------- mini-assembler
# items: list[int]      -> verbatim bytes
#        ('L',name)     -> label
#        ('JR',cc,name) -> 2 bytes: rel8   (cc in {None,'NZ'})
#        ('DJNZ',name)  -> 2 bytes: 0x10 + rel8
#        ('JP',cc,name) -> 3 bytes: abs16  (cc in {None,'NZ','Z'})
prog = []
def b(*xs):            prog.append(list(xs))
def label(n):          prog.append(('L', n))
def jr(name, cc=None): prog.append(('JR', cc, name))
def djnz(name):        prog.append(('DJNZ', name))
def jp(name, cc=None): prog.append(('JP', cc, name))

def LDAn(n):  b(0x3E, n)                              # LD A,n
def LDnnA(a): b(0x32, a & 0xFF, a >> 8)              # LD (nn),A
def OUT99():  b(0xD3, 0x99)                          # OUT (0x99),A

# ---- INIT --------------------------------------------------------
b(0xF3)                              # DI
b(0x0E, 0x00)                        # LD C,0x00      ; border-cycle accumulator
LDAn(0x00); LDnnA(BANKREG0)          # LD A,0 / LD (0x6000),A : bankRegs[0]=0 (bank-reg write; FSM unaffected)

# ===== PHASE 1: byte-program 64 bytes, data byte = low addr =======
b(0x06, N_BYTES)                     # LD B,N
b(0x21, DATA_BASE & 0xFF, DATA_BASE >> 8)  # LD HL,0x5000
label('bp_loop')
LDAn(0xAA); LDnnA(UNLOCK_A)          # AA -> 0x4AAA   unlock 1
LDAn(0x55); LDnnA(UNLOCK_B)          # 55 -> 0x4554   unlock 2
LDAn(0xA0); LDnnA(UNLOCK_A)          # A0 -> 0x4AAA   program cmd
b(0x7D)                              # LD A,L         ; data = index
b(0x77)                              # LD (HL),A      ; *** program write -> prog_we
b(0x7E)                              # LD A,(HL)      ; read back
b(0xBD)                              # CP L
jp('bp_fail', 'NZ')                  # JP NZ,bp_fail  (absolute: bp_fail is far)
b(0x23)                              # INC HL
djnz('bp_loop')                      # DJNZ bp_loop
# phase 1 passed -> fall into phase 2

# ===== PHASE 2: sector-erase probe ================================
b(0x21, ERASE_TGT & 0xFF, ERASE_TGT >> 8)  # LD HL,0x5080  (erase target)
# program a known 0x00 to the target (so we can detect erase->0xFF)
LDAn(0xAA); LDnnA(UNLOCK_A)          # AA -> 0x4AAA
LDAn(0x55); LDnnA(UNLOCK_B)          # 55 -> 0x4554
LDAn(0xA0); LDnnA(UNLOCK_A)          # A0 -> 0x4AAA
LDAn(0x00)                           # LD A,0x00
b(0x77)                              # LD (HL),A      ; program 0x00
b(0x7E)                              # LD A,(HL)      ; verify it is 0x00
b(0xFE, 0x00)                        # CP 0x00
jp('bp_fail', 'NZ')                  # JP NZ,bp_fail  (program of 0x00 failed)
# issue 6-cycle JEDEC sector erase
LDAn(0xAA); LDnnA(UNLOCK_A)          # cycle1: AA -> 0x4AAA
LDAn(0x55); LDnnA(UNLOCK_B)          # cycle2: 55 -> 0x4554
LDAn(0x80); LDnnA(UNLOCK_A)          # cycle3: 80 -> 0x4AAA  (erase setup)
LDAn(0xAA); LDnnA(UNLOCK_A)          # cycle4: AA -> 0x4AAA
LDAn(0x55); LDnnA(UNLOCK_B)          # cycle5: 55 -> 0x4554
LDAn(0x30); b(0x77)                  # cycle6: 30 -> (HL)    (sector erase confirm)
# bounded poll: outer B=8 x inner DE=65536  (finite -> never truly hangs)
b(0x06, 0x08)                        # LD B,0x08
label('poll_outer')
b(0x11, 0x00, 0x00)                  # LD DE,0x0000
label('poll_inner')
b(0x7E)                              # LD A,(HL)      ; read target
b(0xFE, 0xFF)                        # CP 0xFF        ; erased?
jp('erase_ok', 'Z')                  # JP Z,erase_ok
b(0x1B)                              # DEC DE
b(0x7A)                              # LD A,D
b(0xB3)                              # OR E
jr('poll_inner', 'NZ')              # JR NZ,poll_inner
djnz('poll_outer')                   # DJNZ poll_outer
# poll expired, target still != 0xFF -> erase NOT implemented -> SOLID BLUE
label('erase_blue')
LDAn(0x04); OUT99()                  # colour 4 (blue)
LDAn(0x87); OUT99()                  # R7 | 0x80
label('eb_hold')
jr('eb_hold')                        # JR eb_hold

# ----- erase worked -> CYCLING border (fully functional) ----------
label('erase_ok')
b(0x79)                              # LD A,C
b(0xE6, 0x0F)                        # AND 0x0F
OUT99()                              # OUT (0x99),A   colour
LDAn(0x87); OUT99()                  # R7 | 0x80
b(0x11, 0x00, 0x00)                  # LD DE,0x0000   delay
label('ok_delay')
b(0x1B)                              # DEC DE
b(0x7A)                              # LD A,D
b(0xB3)                              # OR E
jr('ok_delay', 'NZ')                # JR NZ,ok_delay
b(0x0C)                              # INC C
jr('erase_ok')                       # JR erase_ok

# ----- byte-program readback wrong -> SOLID RED -------------------
label('bp_fail')
LDAn(0x08); OUT99()                  # colour 8 (medium red)
LDAn(0x87); OUT99()                  # R7 | 0x80
label('bf_hold')
jr('bf_hold')                        # JR bf_hold

# -------------------------------------------------------- pass 1: addresses
addrs = {}
pc = ORG + CODE_OFF
for it in prog:
    if isinstance(it, list):       pc += len(it)
    elif it[0] == 'L':             addrs[it[1]] = pc
    elif it[0] == 'JP':            pc += 3
    else:                          pc += 2          # JR / DJNZ
# -------------------------------------------------------- pass 2: emit
code = bytearray()
pc = ORG + CODE_OFF
for it in prog:
    if isinstance(it, list):
        code += bytes(it); pc += len(it)
    elif it[0] == 'L':
        continue
    elif it[0] == 'JP':
        op = {'NZ': 0xC2, 'Z': 0xCA, None: 0xC3}[it[1]]
        tgt = addrs[it[2]]
        code += bytes([op, tgt & 0xFF, tgt >> 8]); pc += 3
    else:
        if it[0] == 'JR':
            op = 0x20 if it[1] == 'NZ' else 0x18; tgt = addrs[it[2]]
        else:
            op = 0x10; tgt = addrs[it[1]]
        rel = tgt - (pc + 2)
        if not -128 <= rel <= 127:
            sys.exit("rel jump out of range: %s -> %d" % (it, rel))
        code += bytes([op, rel & 0xFF]); pc += 2

# -------------------------------------------------------- build ROM image
rom = bytearray([PAD]) * ROM_SIZE
init = ORG + CODE_OFF
rom[0x00] = ord('A'); rom[0x01] = ord('B')
rom[0x02] = init & 0xFF; rom[0x03] = init >> 8      # INIT (LE)
rom[0x04:0x10] = bytes(12)                          # STATEMENT/DEVICE/TEXT/reserved
rom[0x10:0x18] = b"ASCII16X"                        # cosmetic marker (not used by detection)
rom[CODE_OFF:CODE_OFF + len(code)] = code
if CODE_OFF + len(code) > (ERASE_TGT - ORG):
    sys.exit("code overruns data target region!")

out = "ascii16x_flash_test.rom"
with open(out, "wb") as f:
    f.write(rom)

# -------------------------------------------------------- report
def hexdump(data, base, length):
    for i in range(0, length, 16):
        row = data[i:i+16]
        print("  %04X: %-47s  %s" % (
            base + i, " ".join("%02X" % x for x in row),
            "".join(chr(x) if 32 <= x < 127 else "." for x in row)))

print("Wrote %s  (%d bytes = 0x%X)" % (out, len(rom), len(rom)))
print("INIT entry = 0x%04X   code length = %d bytes   end = 0x%04X" %
      (init, len(code), init + len(code)))
print("\nFirst 32 bytes (file offset 0, maps to 0x4000):")
hexdump(rom[:32], 0x4000, 32)
print("\nINIT code region (0x%04X .. 0x%04X):" % (init, init + len(code)))
hexdump(code, init, len(code))
print("\nLabels:")
for k in ('bp_loop', 'poll_outer', 'poll_inner', 'erase_blue', 'eb_hold',
          'erase_ok', 'ok_delay', 'bp_fail', 'bf_hold'):
    print("  %-11s = 0x%04X" % (k, addrs[k]))
