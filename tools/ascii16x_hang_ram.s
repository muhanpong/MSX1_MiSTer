        .module ascii16x_hang_ram
        .area   _CODE
;----------------------------------------------------------------------
; ASCII16X erase repro, RAM-resident poll (like real flash code).
; INIT (from cart): byte-program sanity, then COPY the resident routine
; to RAM 0xC000 and JP there. Resident (from RAM): program 0x00 -> erase
; -> MAGENTA -> INFINITE poll for 0xFF. Running from RAM means flash.sv's
; "busy" override of cart reads during erase does NOT corrupt code fetch.
;   MAGENTA frozen + forced reset = erase fill never completes (confirmed)
;   CYCLING border = sector became 0xFF = flash.sv erase ACTUALLY works
;   RED = byte-program sanity failed
; Load: Slot A -> Load -> Mapper type = ASCII16X.
;----------------------------------------------------------------------
        .db     0x41, 0x42      ; "AB"
        .dw     init
        .dw     0x0000
        .dw     0x0000
        .dw     0x0000
        .ds     6
        .ascii  "ASCII16X"

init:
        di
        ; ---- byte-program sanity (cart not busy yet) ----
        ld      a, #0xAA
        ld      (#0x4AAA), a
        ld      a, #0x55
        ld      (#0x4554), a
        ld      a, #0xA0
        ld      (#0x4AAA), a
        ld      a, #0xA5
        ld      (#0x5000), a
        ld      a, (#0x5000)
        cp      #0xA5
        jp      nz, red_fail
        ; ---- copy resident routine to RAM 0xC000, run from there ----
        ld      hl, #resident
        ld      de, #0xC000
        ld      bc, #(resident_end - resident)
        ldir
        jp      0xC000

red_fail:
        ld      a, #8
        out     (#0x99), a
        ld      a, #0x87
        out     (#0x99), a
rhold:
        jr      rhold

; ===== resident: executes at RAM 0xC000. Position-independent (JR only;
;       absolute data addresses 0x4xxx/0x5080 and port 0x99 are fine). =====
resident:
        ; program known 0x00 -> 0x5080
        ld      a, #0xAA
        ld      (#0x4AAA), a
        ld      a, #0x55
        ld      (#0x4554), a
        ld      a, #0xA0
        ld      (#0x4AAA), a
        xor     a
        ld      (#0x5080), a
        ; JEDEC 6-cycle sector-erase -> 0x5080
        ld      a, #0xAA
        ld      (#0x4AAA), a
        ld      a, #0x55
        ld      (#0x4554), a
        ld      a, #0x80
        ld      (#0x4AAA), a
        ld      a, #0xAA
        ld      (#0x4AAA), a
        ld      a, #0x55
        ld      (#0x4554), a
        ld      a, #0x30
        ld      (#0x5080), a
        ; marker: MAGENTA border (col 13)
        ld      a, #13
        out     (#0x99), a
        ld      a, #0x87
        out     (#0x99), a
        ; INFINITE poll for 0xFF (RAM-resident, won't crash on cart-busy)
rpoll:
        ld      a, (#0x5080)
        cp      #0xFF
        jr      nz, rpoll
        ; erase completed -> cycle border = PASS
rsucc:
        inc     c
        ld      a, c
        and     #0x0F
        out     (#0x99), a
        ld      a, #0x87
        out     (#0x99), a
        ld      b, #0
rdly:
        djnz    rdly
        jr      rsucc
resident_end:
