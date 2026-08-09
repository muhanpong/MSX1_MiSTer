        .module ascii16x_game_repro
        .area   _CODE
;----------------------------------------------------------------------
; Faithful repro of Neon Horizon's flash save bank-scramble bug.
; Uses the GAME's exact JEDEC addresses (0x7AAA/0x7555/0x7000, addr[13]=1),
; run from RAM (like the game's CF16/CF40 trampoline). Detects whether the
; erase writes scramble bankRegs[1] (page2 mapping) -> the freeze cause.
;   RED   = bankRegs[1] scrambled by the 0x7xxx erase (CURRENT broken core)
;   CYCLE = banks intact AND sector erased to 0xFF (fix works)
;   MAGENTA = banks intact but sector not 0xFF (erase fill missing)
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

; ===== resident @ RAM 0xC000 : JR-only (position independent) =====
resident:
        ; map page2 (0x8000) to bank0 via bankRegs[1] (0x7000 write)
        xor     a
        ld      (#0x7000), a
        ld      a, (#0x8000)        ; page2[0] should be 0x41 ('A' from file 0)
        cp      #0x41
        jr      nz, fail_red        ; precondition (page2 maps cart bank0)
        ; --- GAME's exact 6-cycle sector-erase (all addr[13]=1) ---
        ld      a, #0xAA
        ld      (#0x7AAA), a
        ld      a, #0x55
        ld      (#0x7555), a
        ld      a, #0x80
        ld      (#0x7AAA), a
        ld      a, #0xAA
        ld      (#0x7AAA), a
        ld      a, #0x55
        ld      (#0x7555), a
        ld      a, #0x30
        ld      (#0x7000), a        ; erase confirm to sector 0x7000
        ; --- did the erase writes SCRAMBLE bankRegs[1]? ---
        ld      a, (#0x8000)
        cp      #0x41
        jr      nz, fail_red        ; <- CURRENT CORE lands here = bug confirmed
        ; banks intact -> check sector actually erased to 0xFF (bounded poll)
        ld      bc, #0
epoll:
        ld      a, (#0x7000)
        cp      #0xFF
        jr      z, success
        dec     bc
        ld      a, b
        or      c
        jr      nz, epoll
        ; banks ok but not 0xFF -> magenta
        ld      a, #13
        out     (#0x99), a
        ld      a, #0x87
        out     (#0x99), a
mhold:
        jr      mhold
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
