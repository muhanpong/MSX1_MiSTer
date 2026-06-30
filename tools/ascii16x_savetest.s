        .module ascii16x_savetest
        .area   _CODE
;----------------------------------------------------------------------
; ASCII16X SAVE test cart. Stores a "number" (0..8) at flash 0x10000
; (block 1) using thermometer encoding so byte-program (bit-clear only,
; no erase) can increment it: 0xFF=0, 0xFE=1, 0xFC=2 ... 0x00=8.
;   Boot: read flash 0x10000, border color = count of cleared bits.
;   SPACE: number+1 (byte-program new thermometer), border updates.
; Persistence test: SPACE to pick a color -> OSD "SRAM Save" -> power
; cycle -> fresh Slot A Load. If border = same color -> save persisted.
; Runs the routine from RAM 0xC000 (so bankReg0=4 remap of page1 is safe).
; Load: Slot A -> Load -> Mapper = ASCII16X.
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

resident:
        ld      a, #4
        ld      (#0x6000), a        ; bankReg0=4 -> page1 0x4000 = flash 0x10000
show:
        ld      a, (#0x4000)        ; saved thermometer byte
        ld      b, #0               ; b = number (count of 0 bits)
        ld      c, #8
cnt:
        rrca
        jr      c, skip             ; bit=1 -> not cleared
        inc     b
skip:
        dec     c
        jr      nz, cnt
        ld      a, b
        out     (#0x99), a          ; VDP R7 = border color = number
        ld      a, #0x87
        out     (#0x99), a
poll:
        ld      a, #8
        out     (#0xAA), a          ; select keyboard row 8
        in      a, (#0xA9)          ; columns (active low)
        bit     0, a                ; bit0 = SPACE
        jr      nz, poll            ; not pressed -> keep polling
        ; SPACE pressed: increment thermometer (clear one more bit)
        ld      a, (#0x4000)
        ld      b, a
        add     a, a               ; a = old<<1
        and     b                  ; a = (old<<1) & old = new
        ld      c, a
        ld      a, #0xAA
        ld      (#0x4AAA), a
        ld      a, #0x55
        ld      (#0x4554), a
        ld      a, #0xA0
        ld      (#0x4AAA), a
        ld      a, c
        ld      (#0x4000), a        ; byte-program new thermometer -> flash 0x10000
rel:
        ld      a, #8
        out     (#0xAA), a
        in      a, (#0xA9)
        bit     0, a
        jr      z, rel             ; wait for SPACE release (debounce)
        jr      show
resident_end:
