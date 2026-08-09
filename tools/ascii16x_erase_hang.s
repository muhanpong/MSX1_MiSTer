        .module ascii16x_erase_hang
        .area   _CODE
; Faithful repro of Neon Horizon ENDING freeze via ERASE path (reviewer#5 validated).
; bankReg0=0x03 -> CPU 0x7000 maps flash 0xF000. Program 0x00 there (non-0xFF),
; then game's 6-cycle sector-erase confirm to 0x7000, poll 0x7000 for 0xFF.
;   CURRENT-buggy flash.sv: erases block7(base+0x70000) -> 0xF000 stays 0x00 -> MAGENTA hang.
;   Fix#2 (8KB @ 0xE000-0xFFFF): 0xF000 -> 0xFF -> CYCLE.  512KB ROM keeps block7 in-bounds.
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
resident:
        ld      a, #0x03
        ld      (#0x6000), a            ; bankReg0=0x03 -> 0x7000 => flash 0xF000
        ld      a, #0xAA
        ld      (#0x4AAA), a
        ld      a, #0x55
        ld      (#0x4555), a
        ld      a, #0xA0
        ld      (#0x4AAA), a
        xor     a
        ld      (#0x7000), a            ; program 0x00 -> flash 0xF000
        ld      bc, #0
pv:
        ld      a, (#0x7000)
        or      a
        jr      z, pv_ok
        dec     bc
        ld      a, b
        or      c
        jr      nz, pv
        jr      fail_red
pv_ok:
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
        ld      (#0x7000), a            ; sector-erase confirm -> flash 0xF000
        ld      a, #13
        out     (#0x99), a
        ld      a, #0x87
        out     (#0x99), a
epoll:
        ld      a, (#0x7000)
        cp      #0xFF
        jr      z, success
        jr      epoll                   ; buggy: 0x00 forever -> MAGENTA; fixed: ->CYCLE
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
