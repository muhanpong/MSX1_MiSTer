#!/usr/bin/env python3
"""Op script for tb_cpuvis.sv: the CPU-visible behaviour of the MoonSound ports.

    cpuvis_ops.py > ops.txt

Line: <kind> <port_hex> <data_hex> <gap_clk>   (see tb_cpuvis.sv for the kinds).
Each block names the SPEC item it covers (docs/opl4_scratch/SPEC.md).  The
expected values are not written here: cpuvis_check.py computes them from the
openMSX model at the cycle each access actually happened.

Gaps: 200 clk (1.55 us at 128.86 MHz) is about an R800 OUT-to-OUT; 4..20 clk
polls look at BUSY right after an access.  Writes to sample RAM stay at
0x200000+ (RAM on a MoonSound; openMSX ignores CPU writes to the 2 MB ROM).
"""
G = 200
ops = []


def c(text):
    ops.append(f"# {text}")


def W(port, data, gap=G): ops.append(f"W {port:02x} {data:02x} {gap}")
def R(port, gap=G): ops.append(f"R {port:02x} 00 {gap}")
def S(gap=G): ops.append(f"S c4 00 {gap}")
def P(mask, gap=4): ops.append(f"P c4 {mask:02x} {gap}")
def X(cycles, gap=G): ops.append(f"X 00 {cycles:02x} {gap}")


def wreg(r, v, gap=G):            # wave register write: select + data
    W(0x7E, r, gap); W(0x7F, v, gap)


def rreg(r, gap=G):               # wave register read: select + read
    W(0x7E, r, gap); R(0x7F, gap)


def fm(bank, r, v, gap=G):
    W(0xC4 if bank == 0 else 0xC6, r, gap); W(0xC5 if bank == 0 else 0xC7, v, gap)


def memadr(a):
    wreg(0x03, (a >> 16) & 0xFF); wreg(0x04, (a >> 8) & 0xFF); wreg(0x05, a & 0xFF)


c("C-NEW2 / C-STATUS: power-up status, wave port while NEW2=0")
S(50)
R(0x7F)                      # wave read works with NEW2=0 (latch 0 -> reg 0)
W(0x7E, 0x05); W(0x7F, 0x55)  # both ignored with NEW2=0
c("C-ID: NEW2 on, the one-shot 02h on the next status read (FM write still BUSY at +20)")
fm(1, 0x05, 0x03)
S(20); S(); S()
R(0x7F)                      # latch is still 0: the select above was ignored
c("C-REG2: device ID and read-back of bits 4:0")
rreg(0x02)
W(0x7F, 0x11); R(0x7F)       # mode=1 (memory access), tblhdr=4
R(0x7E)                      # the latch is not readable: FFh
c("C-MEMW / C-MEMR: four bytes to 0x200000 and back; reg 3/4/5 read-back")
memadr(0x200000)
W(0x7E, 0x06)
for b in (0xA1, 0xA2, 0xA3, 0xA4):
    W(0x7F, b)
wreg(0x05, 0x00); W(0x7E, 0x06)
for _ in range(4):
    R(0x7F)
rreg(0x03); rreg(0x04); rreg(0x05)
c("C-REG3: the two upper bits of reg 3 read as 0")
wreg(0x03, 0xE0); R(0x7F)
c("D4: reg 4 written without reg 5")
memadr(0x200010)
W(0x7E, 0x06); W(0x7F, 0xB1); W(0x7F, 0xB2)
wreg(0x04, 0x01)
wreg(0x06, 0xB3)
memadr(0x200012); W(0x7E, 0x06); R(0x7F)
memadr(0x200112); W(0x7E, 0x06); R(0x7F)
c("D7: a reg 6 read right after reg 6 writes, no reg 5 in between")
memadr(0x200120); W(0x7E, 0x06); W(0x7F, 0xD0); W(0x7F, 0xD1)
memadr(0x200120); W(0x7E, 0x06); W(0x7F, 0xC1); R(0x7F)
c("D3: reg 6 with the memory-access bit (reg 2 bit 0) off")
wreg(0x02, 0x10)
memadr(0x200130); W(0x7E, 0x06); W(0x7F, 0xE1); R(0x7F)
wreg(0x02, 0x11)
memadr(0x200130); W(0x7E, 0x06); R(0x7F)
c("C-LD / C-HDR: wave number on slot 0 -> LD until the header is in; fields 5-9 read back the header")
wreg(0x08, 0x03)
S(20)
P(0x02, 200)
for r in (0x08, 0x80, 0x98, 0xB0, 0xC8, 0xE0):
    rreg(r)
c("C-SLOTRD: slot registers read back what was written (field 4 bit 5 included)")
wreg(0x98, 0x5A); R(0x7F)
wreg(0x68, 0x2A); R(0x7F)
wreg(0x50, 0xFF); R(0x7F)
wreg(0x20, 0x03); R(0x7F)
wreg(0x38, 0x4B); R(0x7F)
c("C-MIX / D6: F8h after reset, F9h, the other plain registers")
rreg(0xF8)
wreg(0xF9, 0x2D); R(0x7F)
wreg(0x00, 0x5C); R(0x7F)
wreg(0x07, 0x3C); R(0x7F)
c("C-BUSY: BUSY right after each kind of access, polled every 4 clk")
W(0xC4, 0xA0); S(10); P(0x01)
W(0xC5, 0x43); P(0x01)
R(0xC5)                      # FM register read-back
W(0xC6, 0xA0); R(0xC7)       # bank 1 A0h, never written
W(0x7E, 0x20); P(0x01)
W(0x7F, 0x03); P(0x01)
memadr(0x200140)
W(0x7E, 0x06); R(0x7F); P(0x01)
W(0x7F, 0x77); P(0x01)
W(0x7E, 0x05); W(0x7F, 0x40); P(0x01)
c("D5: NEW2 off and on again")
fm(1, 0x05, 0x01)
S()
fm(1, 0x05, 0x03)
S(); S()
c("C-OPL2: NEW=0 maps bank-1 writes to bank 0; reads use the raw latch")
fm(1, 0x05, 0x02)
fm(1, 0xA1, 0x55)
R(0xC7)
W(0xC4, 0xA1); R(0xC5)
fm(1, 0x05, 0x03)
S()
c("D9 / D6: warm reset")
X(0x80)
S()
rreg(0x02)
fm(1, 0x05, 0x03)
S(); S()
R(0x7F)
rreg(0x02)
rreg(0xF8)

print("\n".join(ops))
