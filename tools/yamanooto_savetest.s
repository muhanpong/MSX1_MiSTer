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
;     6  dark red      T1 FAIL  erase did not produce 0xFF
;     8  medium red    T2 FAIL  byte program did not take
;     9  light red     T3 FAIL  a program with WREN CLEAR got through
;    10  dark yellow   T4 FAIL  OFFR write had no effect
;    13  magenta       T5 FAIL  OFFR was written while SPIEN was set
;    14  grey          erase timed out (flash never left the busy state)
;
; Why each test exists
; --------------------
; T1/T2  the JEDEC path itself -- erase then program, the thing the
;        Yamanooto save routine actually does.
; T3     the WREN gate.  An ordinary K5 bank write of 0x98 to 0x50AA once
;        walked the SHARED flash command FSM into CFI and made the whole
;        ROM window read 0x00; flash_rq now carries (cpu_rd | flash_wr_en).
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
; The routine runs from RAM 0xC000: it re-banks pages 1 and 2 and erases
; flash, so it cannot be executing out of the cart while it does that.
; A real save routine has the same constraint on real hardware.
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
C_TMO   = 14

        .db     0x41, 0x42
        .dw     init
        .dw     0,0,0
        .ds     6
        .ascii  "YAMATEST"

init:
        di
        ld      hl, #resident
        ld      de, #0xC000
        ld      bc, #(resident_end - resident)
        ldir
        jp      0xC000

;======================================================================
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

        ; The RTL returns 0x00 while the fill runs, so poll until it stops.
        ld      bc, #0                  ; 65536 tries
poll_erase:
        ld      a, (#TARGET)
        or      a
        jr      nz, erase_done
        dec     bc
        ld      a, b
        or      c
        jr      nz, poll_erase
        ld      a, #C_TMO
        jp      show                    ; never left the busy state
erase_done:
        ld      a, (#TARGET)
        inc     a                       ; 0xFF -> 0
        jr      z, t1_ok
        ld      a, #C_T1
        jp      show
t1_ok:

;----------------------------------------------------------------------
; T2  byte program 0xA5, expect to read it back
;----------------------------------------------------------------------
        call    wren_on
        call    prog_a5
        call    wren_off
        ld      a, (#TARGET)
        cp      #0xA5
        jr      z, t2_ok
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
