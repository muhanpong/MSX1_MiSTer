        .module ascii16x_prog_hang
        .area   _CODE
;----------------------------------------------------------------------
; FAITHFUL repro of Neon Horizon's ACTUAL freeze: byte-PROGRAM to the
; 0x7000 window (DE=0x7000, addr[13]=1) followed by a verify-poll, exactly
; like the game's program loop @0x08E0 (LD (DE),A; LD A,(DE); CP (HL); JR NZ).
; Runs from RAM (like the game's CF16/CF40 trampoline).
;   bankReg0=0 -> page1(0x4000-7FFF)=bank0, so 0x7000 -> flash offset 0x3000 (=0xFF).
;   Program 0x5A -> 0x7000, then read-back poll for 0x5A.
;   CURRENT CORE: prog FSM drops the addr[13]=1 data write -> 0x7000 stays 0xFF
;                 -> poll never matches -> MAGENTA frozen = the real freeze.
;   AFTER FIX  : data write programs 0x5A -> poll matches -> CYCLE = PASS.
; Load: Slot A -> Load -> Mapper type = ASCII16X.
;----------------------------------------------------------------------
        .db     0x41, 0x42
        .dw     init
        .dw     0,0,0
        .ds     6
        .ascii  "ASCII16X"
init:
        di
        ld      hl, #resident
        ld      de, #0xC000
        ld      bc, #(resident_end - resident)
        ldir
        jp      0xC000

; ===== resident @ RAM 0xC000 : JR-only =====
resident:
        ; bankReg0 = 0 -> page1 0x7000 maps to flash offset 0x3000 (=0xFF)
        xor     a
        ld      (#0x6000), a
        ; sanity: 0x7000 should read 0xFF (erased) before programming
        ld      a, (#0x7000)
        cp      #0xFF
        jr      nz, fail_red          ; precondition broken
        ; --- byte-program 0x5A -> 0x7000 (unlock at 0x4xxx, data at 0x7xxx) ---
        ld      a, #0xAA
        ld      (#0x4AAA), a
        ld      a, #0x55
        ld      (#0x4555), a
        ld      a, #0xA0
        ld      (#0x4AAA), a
        ld      a, #0x5A
        ld      (#0x7000), a          ; DATA byte to addr[13]=1  <-- THE freeze trigger
        ; --- marker: MAGENTA, then verify-poll like the game ---
        ld      a, #13
        out     (#0x99), a
        ld      a, #0x87
        out     (#0x99), a
vpoll:
        ld      a, (#0x7000)
        cp      #0x5A
        jr      nz, vpoll             ; CURRENT CORE: 0xFF forever -> FREEZE (magenta)
success:
        inc     c
        ld      a, c
        and     #0x0F
        out     (#0x99), a
        ld      a, #0x87
        out     (#0x99), a
        ld      b, #0
sdly:
        djnz    sdly
        jr      success
fail_red:
        ld      a, #8
        out     (#0x99), a
        ld      a, #0x87
        out     (#0x99), a
fhold:
        jr      fhold
resident_end:
