#!/usr/bin/env python3
"""Golden model of rtl/peripheral/SOUND/msx_audio/y8950_addon.sv.

Transcribed from openMSX src/sound/Y8950.cc and Y8950Adpcm.cc (the 'emu' side): same
register semantics, same integer arithmetic, one calcSample() per sample tick.

  y8950_model.py gen <seed> <script>      write a random script
  y8950_model.py run <script> <log>       run a script, write the expected log

Script lines:  W aa dd | R aa | S | T n      Log lines:  R aa vv | S vv | F aa dd | A out dac irq
"""
import random
import sys


def tdiv(a, b):
    """C integer division (truncates toward zero)."""
    q = abs(a) // abs(b)
    return q if (a >= 0) == (b >= 0) else -q


def clip16(x):
    return max(-32768, min(32767, x))


F1 = [1, 3, 5, 7, 9, 11, 13, 15, -1, -3, -5, -7, -9, -11, -13, -15]
F2 = [57, 57, 57, 57, 77, 102, 128, 153] * 2
T1, T2, EOS, BRDY, BSY = 0x40, 0x20, 0x10, 0x08, 0x01


class Y8950:
    def __init__(self):
        self.ram = bytearray(b"\xff" * (256 * 1024))
        self.reg = [0] * 256
        self.status = 0
        self.mask = 0
        self.start = 0
        self.stop = 7
        self.delta = 0
        self.addr_mask = (1 << 18) - 1
        self.reg7 = 0
        self.reg15 = 0
        self.read_delay = 0
        self.rom = False
        self.volume = 255
        self.t1v = self.t2v = self.t1c = self.t2c = 0
        self.t1run = self.t2run = False
        self.tpre = 0
        self.dac = 0
        self.log = []
        self.restart()
        self.set_status(BRDY)

    # -- status
    def set_status(self, f):
        self.status |= f

    def reset_status(self, f):
        self.status &= ~f

    def read_status(self):
        irq = 0x80 if (self.status & self.mask & 0x78) else 0
        return ((self.status & (0x07 | self.mask)) & 0x79) | 0x06 | irq

    def irq(self):
        return 1 if (self.status & self.mask & 0x78) else 0

    # -- adpcm
    def playing(self):
        return (self.reg7 & 0xC0) == 0x80

    def restart(self):
        self.mem_ptr = self.start
        self.now_step = (1 << 16) - self.delta
        self.out = 0
        self.output = 0
        self.diff = 0x7F
        self.next_lev = 0
        self.sample_step = 0
        self.adpcm_data = 0

    def adpcm_reset_status(self):
        mode = self.reg7 & 0xE0
        if (mode & ~0x40) == 0x20 or mode == 0:
            self.set_status(BRDY)

    def rd_mem(self, ptr):
        return 0 if self.rom else self.ram[(ptr // 2) & self.addr_mask]

    def wr_mem(self, ptr, v):
        if not self.rom:
            self.ram[(ptr // 2) & self.addr_mask] = v

    def write(self, rg, data):
        if not (rg == 0x04 and data & 0x80):
            self.reg[rg] = data & 0xC0 if rg == 0x16 else data & 0x07 if rg == 0x17 else data
        if rg == 0x02:
            self.t1v = data
        elif rg == 0x03:
            self.t2v = data
        elif rg == 0x04:
            if data & 0x80:
                self.reset_status(0x78)
            else:
                self.mask = ~data & 0x78
                self.status &= 0x87 | self.mask
                if data & 1 and not self.t1run:
                    self.t1c = self.t1v
                if data & 2 and not self.t2run:
                    self.t2c = self.t2v
                self.t1run = bool(data & 1)
                self.t2run = bool(data & 2)
            self.adpcm_reset_status()
        elif rg == 0x07:
            self.reg7 = data
            if data & 0x80:
                self.set_status(BSY)
            else:
                self.reset_status(BSY)
            if self.reg7 & 0x01:
                self.reg7 = 0
            if self.reg7 & 0x80:
                self.restart()
            if self.reg7 & 0x20:
                self.mem_ptr = self.start
                self.read_delay = 2
                if (self.reg7 & 0xA0) == 0x20:
                    self.set_status(BRDY)
            else:
                self.mem_ptr = 0
        elif rg == 0x08:
            self.rom = bool(data & 1)
            self.addr_mask = (1 << 16) - 1 if data & 2 else (1 << 18) - 1
            self.log.append("F 08 %02x" % (data & 0x40))
        elif rg == 0x09:
            self.start = (self.start & 0x7F807) | (data << 3)
        elif rg == 0x0A:
            self.start = (self.start & 0x007FF) | (data << 11)
        elif rg == 0x0B:
            self.stop = (self.stop & 0x7F807) | (data << 3)
        elif rg == 0x0C:
            self.stop = (self.stop & 0x007FF) | (data << 11)
        elif rg == 0x0F:
            self.reg15 = data
            mode = self.reg7 & 0xE0
            if mode == 0x60:
                if self.read_delay:
                    self.mem_ptr = self.start
                    self.read_delay = 0
                if self.mem_ptr <= self.stop:
                    self.wr_mem(self.mem_ptr, data)
                    self.mem_ptr += 2
                    self.set_status(BRDY)
                    if self.mem_ptr > self.stop:
                        self.set_status(EOS)
                        self.mem_ptr = self.start
            elif mode == 0x80:
                self.reset_status(BRDY)
        elif rg == 0x10:
            self.delta = (self.delta & 0xFF00) | data
        elif rg == 0x11:
            self.delta = (self.delta & 0x00FF) | (data << 8)
        elif rg == 0x12:
            self.volume = data
        elif rg == 0x15:
            if self.reg[0x08] & 0x04:
                s8 = data - 256 if data & 0x80 else data
                tmp = s8 * 256 + self.reg[0x16]
                self.dac = clip16((tmp * 4) >> (7 - self.reg[0x17]))
        elif rg >= 0x20:
            if rg < 0xE0:
                d = (data & 0x0F) | 0x30 if (rg >> 4) == 0xC else data
                self.log.append("F %02x %02x" % (rg, d))

    def read(self, rg):
        if rg == 0x05 or rg == 0x1A:
            return 0xFF
        if rg == 0x0F:
            if (self.reg7 & 0xE0) != 0x20:
                return 0
            if self.read_delay:
                self.mem_ptr = self.start
                self.read_delay -= 1
                self.set_status(BRDY)
                return self.reg15
            if self.mem_ptr > self.stop:
                self.set_status(EOS)
                return 0
            v = self.rd_mem(self.mem_ptr)
            self.mem_ptr += 2
            self.set_status(BRDY)
            return v
        if rg == 0x13:
            return (self.output >> 8) & 0xFF
        if rg == 0x14:
            return (self.output >> 16) & 0xFF
        if rg == 0x19:
            return ((self.reg[0x19] & self.reg[0x18]) | (~self.reg[0x18] & 0xFF) | 0xF0) & 0xFF
        return self.reg[rg]

    def tick(self):
        # timers: 80 us = 4 sample periods, 320 us = 16
        if self.t1run and (self.tpre & 3) == 3:
            if self.t1c == 0xFF:
                self.t1c = self.t1v
                self.set_status(T1)
            else:
                self.t1c += 1
        if self.t2run and self.tpre == 15:
            if self.t2c == 0xFF:
                self.t2c = self.t2v
                self.set_status(T2)
            else:
                self.t2c += 1
        self.tpre = (self.tpre + 1) & 15

        if not self.playing():
            return
        self.now_step += self.delta
        if self.now_step & ~0xFFFF:
            self.now_step &= 0xFFFF
            if not (self.mem_ptr & 1):
                if self.reg7 & 0x20:
                    self.adpcm_data = self.rd_mem(self.mem_ptr)
                else:
                    self.adpcm_data = self.reg15
                    self.set_status(BRDY)
                val = self.adpcm_data >> 4
            else:
                val = self.adpcm_data & 0x0F
            prev_out = self.out
            self.out = clip16(self.out + tdiv(self.diff * F1[val], 8))
            self.diff = max(0x7F, min(0x6000, tdiv(self.diff * F2[val], 64)))
            prev_lev = self.next_lev
            self.next_lev = tdiv(prev_out + self.out, 2)
            d_lev = self.next_lev - prev_lev
            self.sample_step = d_lev * ((self.volume * self.delta) >> 16)
            tmp = d_lev * ((self.volume * self.now_step) >> 16)
            self.output = prev_lev * self.volume + tmp
            self.mem_ptr += 1
            if (self.reg7 & 0x20) and self.mem_ptr > self.stop:
                self.set_status(EOS)
                if self.reg7 & 0x10:
                    self.restart()
                else:
                    self.reg7 = 0
        else:
            self.output += self.sample_step

    def sample(self):
        if self.playing() and not (self.reg7 & 0x08):
            return self.output >> 12
        return 0


def run(script, logf):
    y = Y8950()
    for line in open(script):
        t = line.split()
        if not t:
            continue
        if t[0] == "W":
            y.write(int(t[1], 16), int(t[2], 16))
        elif t[0] == "R":
            y.log.append("R %s %02x" % (t[1].lower(), y.read(int(t[1], 16))))
        elif t[0] == "S":
            y.log.append("S %02x" % y.read_status())
        elif t[0] == "T":
            for _ in range(int(t[1])):
                y.tick()
                y.log.append("A %d %d %d" % (y.sample(), y.dac, y.irq()))
    open(logf, "w").write("\n".join(y.log) + "\n")


def gen(seed, script):
    r = random.Random(seed)
    o = []
    W = lambda a, d: o.append("W %02X %02X" % (a, d & 0xFF))

    def region():
        a = r.randrange(0, 0x1000)
        n = r.choice([1, 1, 2, 3, 6])
        return a, a + n - 1          # in 4-byte units (address registers are <<3 nibbles)

    def set_addr(a, b):
        W(0x09, a & 0xFF); W(0x0A, a >> 8); W(0x0B, b & 0xFF); W(0x0C, b >> 8)

    for _ in range(40):
        kind = r.choice(["mem", "mem", "cpu", "poke", "timer", "dac"])
        if kind == "mem":
            a, b = region()
            nbytes = (b - a + 1) * 4
            if r.random() < 0.3:
                W(0x08, r.choice([0x00, 0x02, 0x40, 0x01]))
            W(0x04, r.choice([0x00, 0x78, 0x60, 0x80, 0x08]))
            W(0x07, 0x01); W(0x07, 0x60); set_addr(a, b)
            for i in range(nbytes + r.choice([0, 0, 1, 3])):
                W(0x0F, r.randrange(256))
                if r.random() < 0.2:
                    o.append("S")
            o.append("S")
            W(0x04, 0x80)
            W(0x07, 0x01); W(0x07, 0x20); set_addr(a, b)
            for i in range(nbytes + 2 + r.choice([0, 1, 2])):
                o.append("R 0F")
            o.append("S")
            W(0x07, 0x01)
            W(0x10, r.randrange(256)); W(0x11, r.choice([0x10, 0x40, 0x80, 0xC0, 0xFF, r.randrange(256)]))
            W(0x12, r.choice([255, 255, 128, r.randrange(256)]))
            set_addr(a, b)
            W(0x07, 0xA0 | r.choice([0, 0, 0x10, 0x08]))
            for _ in range(r.randrange(1, 6)):
                o.append("T %d" % r.randrange(1, 60))
                o.append("S")
                if r.random() < 0.3:
                    o.append("R 13"); o.append("R 14")
                if r.random() < 0.2:
                    W(0x12, r.randrange(256))
                if r.random() < 0.2:
                    W(0x11, r.randrange(256))
            if r.random() < 0.5:
                W(0x07, 0x01)
        elif kind == "cpu":
            W(0x07, 0x01)
            W(0x10, r.randrange(256)); W(0x11, r.choice([0x20, 0x60, 0xF0]))
            W(0x12, r.randrange(256))
            W(0x07, 0x80)
            for _ in range(r.randrange(4, 30)):
                W(0x0F, r.randrange(256))
                o.append("S")
                o.append("T %d" % r.randrange(1, 12))
                o.append("S")
            W(0x07, 0x01)
        elif kind == "poke":
            for _ in range(r.randrange(3, 20)):
                a = r.choice([r.randrange(0x20, 0x100), r.randrange(0x01, 0x20), 0xBD, 0xC0 + r.randrange(9)])
                if a in (0x07, 0x0F):
                    continue
                W(a, r.randrange(256))
                if r.random() < 0.5:
                    o.append("R %02X" % r.randrange(256))
                if r.random() < 0.3:
                    o.append("S")
            W(0x08, 0x00)
        elif kind == "timer":
            W(0x02, r.choice([0xFF, 0xFE, 0xF0, r.randrange(256)]))
            W(0x03, r.choice([0xFF, 0xFE, r.randrange(250, 256)]))
            W(0x04, r.choice([0x03, 0x01, 0x02, 0x43, 0x23]))
            for _ in range(r.randrange(2, 8)):
                o.append("T %d" % r.randrange(1, 80))
                o.append("S")
                if r.random() < 0.4:
                    W(0x04, 0x80)
                    o.append("S")
            W(0x04, r.choice([0x00, 0x78]))
        else:
            W(0x08, 0x04)
            for _ in range(r.randrange(2, 10)):
                W(0x17, r.randrange(8)); W(0x16, r.randrange(256)); W(0x15, r.randrange(256))
                o.append("T 1")
            W(0x08, 0x00)
    open(script, "w").write("\n".join(o) + "\n")


if __name__ == "__main__":
    if sys.argv[1] == "gen":
        gen(int(sys.argv[2]), sys.argv[3])
    else:
        run(sys.argv[2], sys.argv[3])
