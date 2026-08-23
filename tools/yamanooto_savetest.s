        .module yamanooto_savetest
        .area   _CODE
;----------------------------------------------------------------------
; Yamanooto flash / register test cart.
;
;   Load: Slot A -> Load -> Mapper = Yamanooto.
;
; Result is the BORDER COLOUR (no BIOS text, so it works whatever the
; screen mode is).  The first failing test wins; green means everything
; passed:
;
;     3  light green   ALL PASS
;     6  dark red      T1 FAIL  erase never produced 0xFF (or timed out)
;     8  medium red    T2 FAIL  byte program never read back
;     9  light red     T3 FAIL  a program with WREN CLEAR got through
;    10  dark yellow   T4 FAIL  OFFR write had no effect
;    13  magenta       T5 FAIL  OFFR was written while SPIEN was set
;    11  light yellow  T6 FAIL  low-64KB erase hit the wrong span
;
; Why each test exists
; --------------------
; T1/T2  the JEDEC path itself -- erase then program, the thing the
;        Yamanooto save routine actually does.
; T3     the WREN gate.  An ordinary K5 bank write of 0x98 to 0x50AA once
;        walked the SHARED flash command FSM into CFI and made the whole
;        ROM window read 0x00; flash_rq now carries (cpu_rd | flash_wr_en).
; T6     the low-64KB sector map.  boot_sector is now hardwired 1, so an erase
;        confirmed below 0x10000 uses the 8KB bottom-boot map instead of the
;        64KB one.  For Yamanooto that is a REAL behaviour change on a path that
;        persists -- before the fix it took the 64KB branch, computed the sector
;        index from addr[15:13] and then scaled it by 16 bits, so an erase at
;        0x8000 wiped 0x40000 and left the target intact.  T1-T5 all work at
;        0x100000 and cannot see any of this.
; T4/T5  the OFFR guard.  0x7FFE is three registers on real hardware --
;        OFFR, or MOFFR when MSTEN, or SPICON when SPIEN -- and we only
;        implement OFFR, so the write is now qualified.  T4 proves OFFR
;        still works normally; T5 proves it is ignored with SPIEN set.
;        Nothing we normally run reaches this path, which is exactly why
;        it needs a purpose-built cart.
;
; Scratch area is flash 0x100000 (segment 128), 1 MB into the image and
; clear of this 32 KB ROM.  The whole 64 KB sector there is erased first,
; so the test never depends on what the loader padded the image with.
;
; The routine runs from RAM 0xC000: it re-banks page 1 and erases flash, and
; flash.sv returns 0x00 for EVERY read while the fill runs -- so instruction
; fetch from the cart would die.  A real save routine has the same constraint on
; real hardware.
;
; It is therefore LINKED at 0xC000 (area _RESID), not merely copied there.  An
; earlier version linked everything at 0x4000 and copied; its `call`/`jp` targets
; still pointed into the cart, which by then was re-banked to 0xFF, and the CPU
; ran off into the BIOS.  openMSX caught that -- the border never changed and PC
; was sitting at 0x19AD.  Anything running from RAM must be linked for RAM.
;
; build_msxrom.sh places the _RESID blob at cart offset 0x2000 (CPU 0x6000),
; which init copies to 0xC000.
;
; openMSX status (2026-08-23)
; ---------------------------
; Running this under openMSX (-romtype Yamanooto) found two real bugs that the
; RTL testbench structurally CANNOT find, because that bench injects the bus
; sequence directly and never executes the Z80 code:
;   * the resident routine was linked at 0x4000 and merely copied, so its
;     call/jp targets still pointed into the cart -- which by then was re-banked
;     to 0xFF.  The CPU ran off into the BIOS.
;   * T2 read once instead of data-polling.  openMSX models the 60 us program
;     time and returns toggle status meanwhile.
; Both are fixed here.
;
; UNRESOLVED: openMSX still reports T2, while its own flash debuggable shows the
; byte was programmed (flash[0x100000] = A5) and the CPU can read it back
; (mem[0x4000] = A5).  Those two facts contradict a T2 failure, and a progress
; marker written to 0xC800 read back as 0 even though the routine demonstrably
; ran -- so the introspection itself is not trustworthy and no conclusion should
; be drawn from the openMSX border colour yet.  Note also that openMSX has no
; OFFR guard, so T5 is EXPECTED to fail there; only our core should show green.
;----------------------------------------------------------------------

; ---- Yamanooto registers ---------------------------------------------
ENAR    = 0x7FFF                ; bit0 REGEN, bit1 SPIEN, bit2 MSTEN, bit4 WREN
OFFR    = 0x7FFE                ; mapper offset, in units of 4 segments
BANK0   = 0x5000                ; K5 bank register for page 0x4000-0x5FFF

REGEN   = 0x01
SPIEN   = 0x02
WREN    = 0x10

; ---- JEDEC unlock (cpu_addr[11:1] = 0x555 / 0x2AA) -------------------
UNLK_A  = 0x4AAA
UNLK_B  = 0x4555

SCRATCH = 128                   ; segment -> flash 0x100000
TARGET  = 0x4000                ; first byte of the banked page

; ---- border colours ---------------------------------------------------
C_PASS  = 3
C_T1    = 6
C_T2    = 8
C_T3    = 9
C_T4    = 10
C_T5    = 13
C_T6    = 11

        .db     0x41, 0x42
        .dw     init
        .dw     0,0,0
        .ds     6
        .ascii  "YAMATEST"

init:
        di
        ld      hl, #0x6000             ; blob staged here by build_msxrom.sh
        ld      de, #0xC000
        ld      bc, #(resident_end - resident)
        ldir
        jp      0xC000

;======================================================================
        .area   _RESID
resident:
        ; ENAR = 0 : registers locked, WREN clear.  Bank writes need WREN
        ; CLEAR (bank_hit carries ~flash_wr_en), so banking is done here.
        xor     a
        ld      (#ENAR), a
        ld      a, #SCRATCH
        ld      (#BANK0), a             ; page 0x4000 -> flash 0x100000

;----------------------------------------------------------------------
; T1  erase the 64 KB sector, expect 0xFF
;----------------------------------------------------------------------
        call    wren_on
        ld      a, #0xAA
        ld      (#UNLK_A), a
        ld      a, #0x55
        ld      (#UNLK_B), a
        ld      a, #0x80
        ld      (#UNLK_A), a
        ld      a, #0xAA
        ld      (#UNLK_A), a
        ld      a, #0x55
        ld      (#UNLK_B), a
        ld      a, #0x30
        ld      (#TARGET), a            ; confirm -> erases the sector holding it
        call    wren_off

        ; Wait for the erased value itself rather than for "not busy".  The two
        ; implementations report busy differently -- flash.sv returns 0x00 for
        ; every read during the fill, openMSX returns proper JEDEC toggle status
        ; -- so a "non-zero means done" poll passes instantly on openMSX and the
        ; test would then read a half-erased byte.  Waiting for 0xFF is the same
        ; question on both, and is what a real driver's data-poll amounts to.
        ld      bc, #0                  ; 65536 tries, ~0.9 s at 3.58 MHz
poll_erase:
        ld      a, (#TARGET)
        inc     a                       ; 0xFF -> 0
        jr      z, t1_ok
        dec     bc
        ld      a, b
        or      c
        jr      nz, poll_erase
        ld      a, #C_T1                ; never reached 0xFF
        jp      show
t1_ok:

;----------------------------------------------------------------------
; T2  byte program 0xA5, expect to read it back
;----------------------------------------------------------------------
        call    wren_on
        call    prog_a5
        call    wren_off
        ; Poll for the programmed value, do not read once and hope.  A byte
        ; program is not instantaneous on a real part -- openMSX models 60 us and
        ; returns toggle status meanwhile, so a single read lands on the status
        ; byte and the test would report a false failure.  flash.sv writes SDRAM
        ; directly so its first read already matches; the poll costs it nothing.
        ld      bc, #0
poll_prog:
        ld      a, (#TARGET)
        cp      #0xA5
        jr      z, t2_ok
        dec     bc
        ld      a, b
        or      c
        jr      nz, poll_prog
        ld      a, #C_T2
        jp      show
t2_ok:

;----------------------------------------------------------------------
; T3  the same program sequence with WREN CLEAR must do nothing
;----------------------------------------------------------------------
        xor     a
        ld      (#ENAR), a              ; WREN clear
        ld      a, #0xAA
        ld      (#UNLK_A), a
        ld      a, #0x55
        ld      (#UNLK_B), a
        ld      a, #0xA0
        ld      (#UNLK_A), a
        ld      a, #0x5A
        ld      (#TARGET), a            ; must NOT reach the flash
        ld      a, (#TARGET)
        cp      #0xA5                   ; still the T2 value?
        jr      z, t3_ok
        ld      a, #C_T3
        jp      show
t3_ok:

;----------------------------------------------------------------------
; T4  OFFR must work normally.  offset = OFFR*4 segments, so OFFR=1
;     moves this page 4 segments (32 KB) up, inside the erased sector,
;     where the byte is still 0xFF.
;
;     NOTE the offset is folded in WHEN THE BANK REGISTER IS WRITTEN --
;     bankReg is stored already offset-adjusted (yamanooto.sv: "bankReg
;     [2][4]; // offset-adjusted -> flash address", and mem_addr uses it
;     directly).  So OFFR does nothing until the bank is re-written.
;     Getting this wrong made the first version of this cart report a
;     false T4 failure in simulation.
;----------------------------------------------------------------------
        ld      a, #REGEN
        ld      (#ENAR), a
        ld      a, #1
        ld      (#OFFR), a
        xor     a
        ld      (#ENAR), a              ; WREN/REGEN clear: bank writes need this
        ld      a, #SCRATCH
        ld      (#BANK0), a             ; re-latch the bank -> picks up OFFR
        ld      a, (#TARGET)
        cp      #0xA5
        jr      nz, t4_ok               ; changed -> OFFR took effect
        ld      a, #C_T4
        jp      show
t4_ok:

;----------------------------------------------------------------------
; T5  with SPIEN set, 0x7FFE is SPICON, not OFFR.  Writing 0 there must
;     NOT restore the offset -- if it does, the guard is not working and
;     the genuine firmware's MOFFR/SPICON writes would destroy OFFR.
;----------------------------------------------------------------------
        ld      a, #(REGEN | SPIEN)
        ld      (#ENAR), a
        xor     a
        ld      (#OFFR), a              ; must be ignored
        xor     a
        ld      (#ENAR), a
        ld      a, #SCRATCH
        ld      (#BANK0), a             ; re-latch: if OFFR had been cleared this
                                        ; would bring 0xA5 back into the window
        ld      a, (#TARGET)
        cp      #0xA5
        jr      nz, t5_ok               ; still offset -> guard held
        ld      a, #C_T5
        jp      show
t5_ok:
        ; restore OFFR=0 so T6's segment numbers mean what they say
        ld      a, #REGEN
        ld      (#ENAR), a
        xor     a
        ld      (#OFFR), a
        xor     a
        ld      (#ENAR), a

;----------------------------------------------------------------------
; T6  an erase below 0x10000 must clear ONE 8KB sector, not 64KB and not
;     some unrelated span.  Segments 4 and 5 (flash 0x8000 / 0xA000) are
;     adjacent 8KB sectors inside the low 64KB and are clear of this 32KB
;     ROM, which occupies segments 0-3.
;
;     Erase both, mark both, then erase segment 4 only:
;       seg4 must read 0xFF   (it was the target)
;       seg5 must still read its marker  (it must NOT have been swept up)
;     Under the old 64KB branch the erase at 0x8000 landed on 0x40000, so
;     seg4 would still hold its marker and this fails on the first check.
;----------------------------------------------------------------------
        ld      a, #4
        call    setbank
        call    erase_here
        ld      a, #5
        call    setbank
        call    erase_here

        ld      a, #4
        call    setbank
        ld      c, #0x5A
        call    prog_c
        ld      a, #5
        call    setbank
        ld      c, #0x3C
        call    prog_c

        ld      a, #4
        call    setbank
        call    erase_here
        ld      a, (#TARGET)
        inc     a                       ; target must now be 0xFF
        jr      nz, t6_fail
        ld      a, #5
        call    setbank
        ld      a, (#TARGET)
        cp      #0x3C                   ; neighbour must have survived
        jr      z, t6_ok
t6_fail:
        ld      a, #C_T6
        jp      show
t6_ok:
        ld      a, #C_PASS

;----------------------------------------------------------------------
show:
        out     (#0x99), a              ; VDP R7 = text/border colour
        ld      a, #0x87
        out     (#0x99), a
stop:
        jr      stop

;---- helpers ---------------------------------------------------------
wren_on:
        ld      a, #WREN
        ld      (#ENAR), a
        ret
wren_off:
        xor     a
        ld      (#ENAR), a
        ret
setbank:                                ; A = segment;  needs WREN/REGEN clear
        push    af
        xor     a
        ld      (#ENAR), a
        pop     af
        ld      (#BANK0), a
        ret

erase_here:                             ; erase the sector holding TARGET, wait for 0xFF
        call    wren_on
        ld      a, #0xAA
        ld      (#UNLK_A), a
        ld      a, #0x55
        ld      (#UNLK_B), a
        ld      a, #0x80
        ld      (#UNLK_A), a
        ld      a, #0xAA
        ld      (#UNLK_A), a
        ld      a, #0x55
        ld      (#UNLK_B), a
        ld      a, #0x30
        ld      (#TARGET), a
        call    wren_off
        ld      bc, #0
eh_poll:
        ld      a, (#TARGET)
        inc     a
        ret     z                       ; reached 0xFF
        dec     bc
        ld      a, b
        or      c
        jr      nz, eh_poll
        ret                             ; timed out; the caller's check catches it

prog_c:                                 ; program C at TARGET, wait for it
        call    wren_on
        ld      a, #0xAA
        ld      (#UNLK_A), a
        ld      a, #0x55
        ld      (#UNLK_B), a
        ld      a, #0xA0
        ld      (#UNLK_A), a
        ld      a, c
        ld      (#TARGET), a
        call    wren_off
        ld      b, #0
pc_poll:
        ld      a, (#TARGET)
        cp      c
        ret     z
        djnz    pc_poll
        ret

prog_a5:
        ld      a, #0xAA
        ld      (#UNLK_A), a
        ld      a, #0x55
        ld      (#UNLK_B), a
        ld      a, #0xA0
        ld      (#UNLK_A), a
        ld      a, #0xA5
        ld      (#TARGET), a
        ret
resident_end:
