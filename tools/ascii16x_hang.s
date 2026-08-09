        .module ascii16x_hang
        .area   _CODE
;----------------------------------------------------------------------
; ASCII16X freeze-repro cart: byte-program (works) -> program 0x00 ->
; JEDEC sector-erase -> set MAGENTA border -> INFINITE poll for 0xFF.
; Current core (no erase): poll never sees 0xFF -> true hang (magenta,
; needs forced reset) = faithful Neon Horizon ending repro.
; After sector-erase fix: poll exits -> CYCLING border = PASS (regression).
; Load: Slot A -> Load -> set Mapper type = ASCII16X. File offset0 = CPU 0x4000.
;----------------------------------------------------------------------
        .db     0x41, 0x42      ; "AB" cart signature  (CPU 0x4000)
        .dw     init            ; INIT entry
        .dw     0x0000          ; STATEMENT
        .dw     0x0000          ; DEVICE
        .dw     0x0000          ; TEXT
        .ds     6               ; pad to 0x4010
        .ascii  "ASCII16X"      ; 0x4010 cosmetic marker (8 bytes) -> 0x4018

init:
        di
        ; ---- sanity byte-program: 0xA5 -> 0x5000, readback ----
        ld      a, #0xAA
        ld      (#0x4AAA), a    ; unlock1 (off[11:1]=0x555)
        ld      a, #0x55
        ld      (#0x4554), a    ; unlock2 (off[11:1]=0x2AA)
        ld      a, #0xA0
        ld      (#0x4AAA), a    ; program command
        ld      a, #0xA5
        ld      (#0x5000), a    ; data write (bank0 off 0x1000)
        ld      a, (#0x5000)
        cp      #0xA5
        jp      nz, red_fail

        ; ---- program known 0x00 -> target 0x5080 ----
        ld      a, #0xAA
        ld      (#0x4AAA), a
        ld      a, #0x55
        ld      (#0x4554), a
        ld      a, #0xA0
        ld      (#0x4AAA), a
        xor     a               ; a = 0x00
        ld      (#0x5080), a    ; target now 0x00

        ; ---- JEDEC 6-cycle sector-erase -> 0x5080 ----
        ld      a, #0xAA
        ld      (#0x4AAA), a
        ld      a, #0x55
        ld      (#0x4554), a
        ld      a, #0x80
        ld      (#0x4AAA), a    ; erase setup
        ld      a, #0xAA
        ld      (#0x4AAA), a
        ld      a, #0x55
        ld      (#0x4554), a
        ld      a, #0x30
        ld      (#0x5080), a    ; sector erase confirm

        ; ---- marker: border MAGENTA (col 13) via VDP R7 ----
        ld      a, #13
        out     (#0x99), a
        ld      a, #0x87        ; R7 | 0x80
        out     (#0x99), a

        ; ---- INFINITE poll for erase completion (0xFF) ----
poll:
        ld      a, (#0x5080)
        cp      #0xFF
        jr      nz, poll        ; spins forever if erase never fills 0xFF

        ; ---- erase done (only after fix): cycle border = PASS ----
success:
        inc     c
        ld      a, c
        and     #0x0F
        out     (#0x99), a
        ld      a, #0x87
        out     (#0x99), a
        ld      de, #0x0000
sdelay:
        dec     de
        ld      a, d
        or      e
        jr      nz, sdelay
        jr      success

red_fail:
        ld      a, #8           ; red = byte-program broken
        out     (#0x99), a
        ld      a, #0x87
        out     (#0x99), a
rhold:
        jr      rhold
