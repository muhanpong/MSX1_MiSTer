#!/usr/bin/env python3
"""Build SCCCH5.COM -- a hardware test for the SCC+ ch5 divergence (D5).

The bug (fixed in 565ac47, hardware-unverified until now): `scc_mode` folded
bank3 bit7 -- a MAPPER term -- into the CHIP mode.  Paging a bank without bit7
into 0xA000-0xBFFF during playback flipped the chip to Compatible, and IKASCC
then latches ch5's waveform from ch4's shared RAM (IKASCC_player_s.v:309), so
ch5 audibly became a ch4 mirror.

This makes the outcome BINARY instead of a timbre judgement:

    ch4 waveform = 32 x 0x00      (silence)
    ch5 waveform = square +/-100  (loud, ~437 Hz)
    ch1          = same square an octave down (~218 Hz), a "still running" drone

    phase 1  window OPEN    -> drone + high tone
    phase 2  window CLOSED  -> BOTH must continue

    high tone vanishes while the drone keeps going  ==  bug present

Register map, Plus mode (rtl/peripheral/slots/scc_sound.sv, scc_ablo_remap):
    B800-B87F ch1..ch4 wave   B880-B89F ch5 wave (Plus only)
    B8A0-B8A9 freq x5         B8AA-B8AE vol x5    B8AF enable
Mapper (rtl/peripheral/slots/konami_scc.sv):
    BFFE/F mode register (bit5 = Plus)   B000-B7FF bank3 (bit7 = window visible)

Timing is VDP vblank polling, so the test is valid at any OSD CPU speed.
Only absolute jumps are used -- no relative-offset arithmetic to get wrong.
"""
import sys

NEGCTL = '--negctl' in sys.argv

ORG    = 0x0100
BDOS   = 0x0005
ENASLT = 0x0024
EXPTBL = 0xFCC1
RAMAD2 = 0xF343

items  = []      # (size, fn(labels)->bytes) or ('L', name)

def raw(*bs):            items.append((len(bs), lambda L, bs=bs: bytes(bs)))
def lab(name):           items.append(('L', name))
def w16(v):              return bytes((v & 0xFF, (v >> 8) & 0xFF))
def op_nn(op, name):     items.append((3, lambda L, op=op, n=name: bytes((op,)) + w16(L[n])))

# --- the few opcodes we need -------------------------------------------------
def CALL(n):     op_nn(0xCD, n)
def JP(n):       op_nn(0xC3, n)
def JP_C(n):     op_nn(0xDA, n)
def JP_NZ(n):    op_nn(0xC2, n)
def JP_Z(n):     op_nn(0xCA, n)
def JP_NC(n):    op_nn(0xD2, n)
def LD_DE(n):    op_nn(0x11, n)
def LD_HL(n):    op_nn(0x21, n)

def LD_A_n(v):   raw(0x3E, v)
def LD_B_n(v):   raw(0x06, v)
def LD_C_n(v):   raw(0x0E, v)
def LD_H_n(v):   raw(0x26, v)
def LD_A_mem(a): raw(0x3A, a & 0xFF, a >> 8)
def LD_mem_A(a): raw(0x32, a & 0xFF, a >> 8)
def LD_HL_nn(a): raw(0x21, a & 0xFF, a >> 8)
def LD_DE_nn(a): raw(0x11, a & 0xFF, a >> 8)
def LD_BC_nn(a): raw(0x01, a & 0xFF, a >> 8)
def CP_n(v):     raw(0xFE, v)
def RET():       raw(0xC9)
def RET_NC():    raw(0xD0)
def PUSH_AF():   raw(0xF5)
def POP_AF():    raw(0xF1)
def PUSH_BC():   raw(0xC5)
def POP_BC():    raw(0xC1)
def XOR_A():     raw(0xAF)
def OR_A():      raw(0xB7)
def OR_C():      raw(0xB1)
def OR_n(v):     raw(0xF6, v)
def AND_n(v):    raw(0xE6, v)
def SCF():       raw(0x37)
def DI():        raw(0xF3)
def EI():        raw(0xFB)
def INC_HL():    raw(0x23)
def INC_C():     raw(0x0C)
def INC_B():     raw(0x04)
def LD_mHL_A():  raw(0x77)
def LD_A_mHL():  raw(0x7E)
def LD_A_B():    raw(0x78)
def LD_A_C():    raw(0x79)
def LD_B_A():    raw(0x47)
def LD_C_A():    raw(0x4F)
def RLCA():      raw(0x07)
def RLA():       raw(0x17)
def ADD_HL_BC(): raw(0x09)
def LDIR():      raw(0xED, 0xB0)
def OUT_99():    raw(0xD3, 0x99)
def IN_99():     raw(0xDB, 0x99)
def DEC_B():     raw(0x05)
def DEC_C():     raw(0x0D)

def emit():
    labels, pc = {}, ORG
    for it in items:
        if it[0] == 'L': labels[it[1]] = pc
        else:            pc += it[0]
    out, pc = bytearray(), ORG
    for it in items:
        if it[0] == 'L': continue
        b = it[1](labels)
        assert len(b) == it[0], (len(b), it[0])
        out += b; pc += it[0]
    return bytes(out), labels

# =============================================================================
#  program
# =============================================================================
SCC   = 0xB800          # SCC+ register window (needs mode bit5 AND bank3 bit7)
BANK3 = 0xB000          # bank register for A000-BFFF
MODE  = 0xBFFE          # SCC+ mode register

def puts(msg):          # BDOS 9
    LD_DE(msg); LD_C_n(9); CALL('bdos')

# ---- entry ------------------------------------------------------------------
lab('start')
puts('msg_hello')
DI()
CALL('find_scc')                 # CF=1 not found, else A = slot byte
JP_C('nf')
LD_mem_A(0)                      # placeholder patched below -> (found_slot)
items[-1] = (3, lambda L: bytes((0x32,)) + w16(L['found_slot']))

LD_H_n(0x80); CALL('enaslt')     # page 2 := cart slot
CALL('setup')                    # program the chip, sound starts

LD_C_n(3); CALL('wait_sec')      # phase 1: window OPEN

# *** the transition under test ***
if NEGCTL:
    # positive control: drop the CHIP to Compatible for real, via the mode
    # register.  ch5 must then mirror ch4 (silence) -- if the measurement cannot
    # see THAT, it cannot see the bug either.
    XOR_A(); LD_mem_A(MODE)
else:
    # the actual D5 scenario: a MAPPER write only.  The chip must stay Plus.
    XOR_A(); LD_mem_A(BANK3)

LD_C_n(6); CALL('wait_sec')      # phase 2: window CLOSED -- both must continue

if NEGCTL:
    LD_A_n(0x20); LD_mem_A(MODE)     # back to Plus so the window works again
LD_A_n(0x80); LD_mem_A(BANK3)    # reopen so we can silence the chip
XOR_A();      LD_mem_A(SCC+0xAF) # enable = 0
CALL('restore')
EI()
puts('msg_done')
RET()

lab('nf')
CALL('restore')
EI()
puts('msg_nf')
RET()

lab('bdos');   raw(0xC3, BDOS & 0xFF, BDOS >> 8)      # JP 0005h
lab('enaslt'); raw(0xC3, ENASLT & 0xFF, ENASLT >> 8)  # JP 0024h

# ---- restore page 2 to its normal RAM slot ----------------------------------
lab('restore')
LD_A_mem(RAMAD2); LD_H_n(0x80); CALL('enaslt'); RET()

# ---- program the SCC+ -------------------------------------------------------
lab('setup')
LD_A_n(0x20); LD_mem_A(MODE)     # Plus mode  (chip)
LD_A_n(0x80); LD_mem_A(BANK3)    # window visible (mapper)

LD_HL_nn(SCC + 0x60); LD_B_n(32); XOR_A()   # ch4 wave = silence
lab('z1'); LD_mHL_A(); INC_HL(); DEC_B(); JP_NZ('z1')

LD_HL_nn(SCC + 0x80); LD_B_n(16); LD_A_n(0x64)   # ch5 wave = square +100
lab('s1'); LD_mHL_A(); INC_HL(); DEC_B(); JP_NZ('s1')
LD_B_n(16); LD_A_n(0x9C)                          #             ... -100
lab('s2'); LD_mHL_A(); INC_HL(); DEC_B(); JP_NZ('s2')

LD_HL_nn(SCC + 0x80); LD_DE_nn(SCC + 0x00); LD_BC_nn(32); LDIR()   # ch1 = same square

LD_A_n(0xFF); LD_mem_A(SCC + 0xA0)   # ch1 freq lo   n=0x1FF -> ~218 Hz
LD_A_n(0x01); LD_mem_A(SCC + 0xA1)   # ch1 freq hi
LD_A_n(0xFF); LD_mem_A(SCC + 0xA8)   # ch5 freq lo   n=0x0FF -> ~437 Hz
XOR_A();      LD_mem_A(SCC + 0xA9)   # ch5 freq hi
LD_A_n(0x0A); LD_mem_A(SCC + 0xAA)   # ch1 vol 10
XOR_A();      LD_mem_A(SCC + 0xAD)   # ch4 vol 0
LD_A_n(0x0F); LD_mem_A(SCC + 0xAE)   # ch5 vol 15
LD_A_n(0x11); LD_mem_A(SCC + 0xAF)   # enable ch1 + ch5
RET()

# ---- wait C seconds, counted in VDP frames (CPU-speed independent) ----------
lab('wait_sec')
lab('ws_outer')
LD_B_n(60)
lab('ws_frame')
CALL('vblank')
DEC_B(); JP_NZ('ws_frame')
DEC_C(); JP_NZ('ws_outer')
RET()

lab('vblank')                     # wait for one VDP vblank (S#0 bit7)
XOR_A(); OUT_99(); LD_A_n(0x8F); OUT_99()     # status pointer := 0
lab('vb1')
IN_99(); RLA(); JP_NC('vb1')      # bit7 -> CF
RET()

# ---- find the SCC+ cartridge ------------------------------------------------
# Walk primary 0..3; for an expanded primary walk its 4 subslots.  Returns the
# slot byte in A with CF=0, or CF=1 if nothing answered.
lab('find_scc')
LD_C_n(0)                                    # C = primary
lab('fs_p')
LD_HL_nn(EXPTBL); LD_B_n(0); ADD_HL_BC(); LD_A_mHL(); AND_n(0x80)
JP_Z('fs_flat')
LD_B_n(0)                                    # B = subslot
lab('fs_s')
LD_A_B(); RLCA(); RLCA(); OR_C(); OR_n(0x80) # 80h | (sub<<2) | pri
CALL('try_slot')
RET_NC()
INC_B(); LD_A_B(); CP_n(4); JP_NZ('fs_s')
JP('fs_next')
lab('fs_flat')
LD_A_C(); CALL('try_slot'); RET_NC()
lab('fs_next')
INC_C(); LD_A_C(); CP_n(4); JP_NZ('fs_p')
SCF(); RET()

# ---- probe one slot ---------------------------------------------------------
# A = slot byte.  CF=0 and A = slot byte if this slot holds an SCC+.
lab('try_slot')
PUSH_BC(); PUSH_AF()
LD_H_n(0x80); CALL('enaslt')
LD_A_n(0x20); LD_mem_A(MODE)          # Plus
LD_A_n(0x80); LD_mem_A(BANK3)         # window open
LD_A_n(0x5A); LD_mem_A(SCC + 0x80)    # write into the PRIVATE ch5 RAM
LD_A_n(0xA5); LD_mem_A(SCC + 0x81)
LD_A_mem(SCC + 0x80); CP_n(0x5A); JP_NZ('ts_no')
LD_A_mem(SCC + 0x81); CP_n(0xA5); JP_NZ('ts_no')
# it reads back -- but so would plain RAM.  Close the window: the same address
# must now be ROM, i.e. must NOT still read as our pattern.
XOR_A(); LD_mem_A(BANK3)
LD_A_mem(SCC + 0x80); CP_n(0x5A); JP_NZ('ts_yes')
LD_A_mem(SCC + 0x81); CP_n(0xA5); JP_Z('ts_no')     # both survived -> plain RAM
lab('ts_yes')
LD_A_n(0x80); LD_mem_A(BANK3)         # reopen
POP_AF(); POP_BC(); OR_A(); RET()     # CF = 0
lab('ts_no')
POP_AF(); POP_BC(); SCF(); RET()

# ---- messages ---------------------------------------------------------------
def msg(name, text):
    lab(name)
    raw(*text.encode('ascii'), 0x24)      # '$'

msg('msg_hello',
    "SCC+ ch5 test (D5)\r\n"
    "ch4 wave = silence, ch5 wave = square.\r\n"
    "Listen: a low drone AND a higher tone.\r\n"
    "3s window OPEN, then 6s window CLOSED.\r\n"
    "The higher tone must NOT disappear.\r\n")
msg('msg_done',
    "\r\ndone.  Did the higher tone survive?\r\n"
    "  yes -> ch5 keeps its own waveform, D5 fix holds\r\n"
    "  no  -> ch5 collapsed to ch4, bug present\r\n")
msg('msg_nf',
    "No SCC+ found.  Set OSD SLOT A or B to SCC+ and load a ROM into it.\r\n")

lab('found_slot'); raw(0x00)

# =============================================================================
blob, labels = emit()
args = [a for a in sys.argv[1:] if not a.startswith('--')]
out = args[0] if args else 'SCCCH5.COM'
open(out, 'wb').write(blob)
print(f"{out}  {len(blob)} bytes  (0x{ORG:04X}-0x{ORG+len(blob)-1:04X})")
for k in ('start', 'setup', 'find_scc', 'try_slot', 'wait_sec', 'vblank', 'found_slot'):
    print(f"   {k:12s} 0x{labels[k]:04X}")
