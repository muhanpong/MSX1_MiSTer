# indeptest: the Wonder Boy in Monster World CPU switch (OTIR to S1990 reg 6, SP across
# the switch, the frozen CPU finishes its own OTIR later), N round trips Z80 -> R800 -> Z80.
# OUT 01h <cpu>: 5Ah 'Z' / 52h 'R' at each check point; OUT 02h <count>; OUT FFh ends.
import sys
N=5
WB=len(sys.argv)>1 and sys.argv[1]=='wb'   # Wonder Boy start: CHGCPU (BIOS stub) to R800 first
mem=bytearray(65536); pc=0; labels={}; fix=[]
def org(a):
    global pc; pc=a
def b(*xs):
    global pc
    for x in xs: mem[pc]=x&0xFF; pc+=1
def lab(n): labels[n]=pc
def w(n):  # 16-bit label ref
    global pc
    fix.append((pc,n)); pc+=2
SPSAVE=0xE010; CNT=0x8000; WORK=0x8001
org(0)
b(0xF3)                       # di
b(0x3E,6, 0xD3,0xE4, 0xDB,0xE5)   # ld a,6 / out (E4),a / in a,(E5)
b(0xCB,0x6F)                  # bit 5,a  (1 = Z80)
b(0xCA); w('r800_first')      # jp z,r800_first
b(0x31,0xF0,0xFF)             # ld sp,FFF0
b(0xC3); w('main')
lab('r800_first')             # the R800's first instruction ever is at 0000h: like the BIOS,
b(0xC3); w('tail')            # finish the switch the Z80 started (its SP is in SPSAVE)
org(0x100); lab('main')
b(0x3E,N, 0x32,CNT&0xFF,CNT>>8)        # ld a,N / ld (CNT),a
if WB:
    b(0x3E,0x82, 0xCD,0x80,0x01)        # ld a,82h / call 0180h (CHGCPU stub: R800 DRAM)
    b(0xCD); w('logcpu')                # 'R'
    b(0x3E,0, 0xCD); w('switch')        # the game's own switch, back to the Z80
lab('loop')
b(0xCD); w('logcpu')
b(0x3E,4, 0xCD); w('switch')           # to R800 (DRAM mode): table[4..5] = 00 60
b(0xCD); w('logcpu')
b(0x21,WORK&0xFF,WORK>>8, 0x34)         # ld hl,WORK / inc (hl)   -- work done on the R800
b(0x3E,0, 0xCD); w('switch')           # back to Z80: table[0..1] = 60 60
b(0xCD); w('logcpu')
b(0x21,CNT&0xFF,CNT>>8, 0x35)           # ld hl,CNT / dec (hl)
b(0xC2); w('loop')
b(0x3A,WORK&0xFF,WORK>>8, 0xD3,0x02)    # ld a,(WORK) / out (02),a
b(0xD3,0xFF)                            # end
lab('logcpu')
b(0xF5, 0x3E,6, 0xD3,0xE4, 0xDB,0xE5, 0xCB,0x6F, 0x3E,0x52, 0x28,0x02, 0x3E,0x5A, 0xD3,0x01, 0xF1, 0xC9)
#  push af / ld a,6 / out (E4) / in (E5) / bit 5,a / ld a,'R' / jr z,+2 / ld a,'Z' / out (01),a / pop af / ret
lab('switch')                 # A = mode index (0 Z80, 4 R800 DRAM); the game's routine (ROM 02420h)
b(0xF3, 0xE5, 0xC5)           # di / push hl / push bc
b(0x4F, 0x06,0x00, 0x21); w('table'); b(0x09)   # ld c,a / ld b,0 / ld hl,table / add hl,bc
b(0x3E,6, 0xD3,0xE4, 0xDB,0xE5)           # ld a,6 / out (E4),a / in a,(E5)
b(0x06,0x01, 0xCB,0x6F, 0x28,0x01, 0x04)  # ld b,1 / bit 5,a / jr z,+1 / inc b
b(0x0E,0xE5)                              # ld c,E5
b(0xED,0x73,SPSAVE&0xFF,SPSAVE>>8)        # ld (SPSAVE),sp
b(0xED,0xB3)                              # otir
lab('tail')
b(0xF3, 0x00)                             # di / nop
b(0xED,0x7B,SPSAVE&0xFF,SPSAVE>>8)        # ld sp,(SPSAVE)
b(0xC1, 0xE1, 0xC9)                       # pop bc / pop hl / ret
lab('table'); b(0x60,0x60,0x40,0x60,0x00,0x60)
for a,n in fix: mem[a]=labels[n]&0xFF; mem[a+1]=labels[n]>>8
open('wbtest.hex' if WB else 'indeptest.hex','w').write('\n'.join('%02x'%x for x in mem)+'\n')
print({k:hex(v) for k,v in labels.items()})
