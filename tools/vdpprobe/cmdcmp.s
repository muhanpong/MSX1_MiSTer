        .module cmdcmp
        .area   _CODE
;----------------------------------------------------------------------
; CMDCMP.COM -- every throttled VDP command, timed in one pass.
;
; vdp_wait_control.vhd throttles seven command opcodes (SRCH, LINE,
; LMMV, LMMM, HMMV, HMMM, YMMM); the other nine entries are 0x8000 =
; unthrottled.  Of the seven, only HMMM has ever been calibrated against
; openMSX (tables 602 and 606, GoFigure boot workload).  CEPROBE showed
; HMMV running 17% slow against the same reference, so this probe times
; all seven with one fixed workload each and one CPU/frame reference, so
; that the same disk run on the board and under openMSX gives a
; per-opcode correction factor directly.
;
; Everything is measured in G4 (SCREEN 5) with the command area at
; VRAM 0x4000..0xBFFF -- above every text-mode table, below 64 KB, so
; the report survives and a 64 KB-VRAM MSX2 still runs it.
; R#0/R#1 are restored from the BIOS save area between measurements.
;
; D7 is the reference: iterations of a plain S#2 poll loop across four
; VR rising edges.  VR is a LEVEL, so unlike the vblank F flag it cannot
; be destroyed by the read -- CEPROBE proved F is lost by fast polling
; on the real chip too.  Divide D0..D6 by D7 before comparing platforms.
;----------------------------------------------------------------------

start:
        di
        ld      a, (#0xF3DF)        ; RG0SAV
        ld      (#r0sav), a
        ld      a, (#0xF3E0)        ; RG1SAV
        ld      (#r1sav), a

        ld      de, #banner
        call    puts
        di                          ; BDOS returns with interrupts ENABLED.  Every
                                    ; status read below leaves R#15 pointing at the
                                    ; register it read, and the BIOS interrupt
                                    ; handler assumes R#15 = 0 when it reads S#0 to
                                    ; clear F -- with R#15 = 2 the flag never clears,
                                    ; /INT stays asserted and the handler re-enters
                                    ; forever.  CEPROBE only escaped this because its
                                    ; first post-banner measurement polled S#0.

        ld      hl, #cb_hmmv
        ld      a, #1
        ld      de, #l_hmmv
        call    measure
        ld      hl, #cb_hmmm
        ld      a, #1
        ld      de, #l_hmmm
        call    measure
        ld      hl, #cb_lmmv
        ld      a, #1
        ld      de, #l_lmmv
        call    measure
        ld      hl, #cb_lmmm
        ld      a, #1
        ld      de, #l_lmmm
        call    measure
        ld      hl, #cb_ymmm
        ld      a, #1
        ld      de, #l_ymmm
        call    measure
        ld      hl, #cb_line
        ld      a, #32
        ld      de, #l_line
        call    measure
        ld      hl, #cb_srch
        ld      a, #32
        ld      de, #l_srch
        call    measure

        call    g4_on
        call    ref4
        call    g4_off
        ld      de, #l_ref
        call    show

        call    scrmode
        ld      de, #l_scr
        call    show

        ld      de, #legend
        call    puts
        ret

;----------------------------------------------------------------------
; measure: HL = command block, A = repeat count, DE = label.
;          Runs the batch inside G4, prints the summed CE-poll count.
measure:
        ld      (#blk_ptr), hl
        ld      (#rep_n), a
        ld      (#lbl_ptr), de
        call    g4_on
        call    runn
        call    g4_off
        ld      de, (#lbl_ptr)
        jp      show

runn:                               ; -> HL = total CE-poll iterations
        ld      hl, #0
        ld      (#acc), hl
        ld      a, (#rep_n)
        ld      b, a
rn1:
        push    bc
        ld      hl, (#blk_ptr)
        call    docmd
        call    wait_ce
        ld      de, (#acc)
        add     hl, de
        ld      (#acc), hl
        pop     bc
        djnz    rn1
        ld      hl, (#acc)
        ret

;----------------------------------------------------------------------
; D7  iterations of a plain S#2 poll loop across four VR rising edges.
ref4:
        call    wait_vbl
        ld      a, #2
        call    rdst
        and     #0x40
        ld      (#vrprev), a
        ld      hl, #0
        ld      e, #0
r41:
        inc     hl
        ld      a, #2
        call    rdst
        and     #0x40
        ld      (#vrcur), a
        ld      a, (#vrprev)
        or      a
        jr      nz, r42
        ld      a, (#vrcur)
        or      a
        jr      z, r42
        inc     e
r42:
        ld      a, (#vrcur)
        ld      (#vrprev), a
        ld      a, e
        cp      #4
        ret     nc
        ld      a, h
        cp      #0x7F
        jr      c, r41
        ld      hl, #0
        ret

;----------------------------------------------------------------------
; CA  SCRMOD (H) and LINLEN (L) -- which screen the report is printed on.
scrmode:
        ld      a, (#0xFCAF)
        ld      h, a
        ld      a, (#0xF3B0)
        ld      l, a
        ret

;----------------------------------------------------------------------
; VDP helpers (interrupts off throughout)
wrvdp:                              ; register D = E
        ld      a, e
        out     (#0x99), a
        ld      a, d
        or      #0x80
        out     (#0x99), a
        ret

rdst:                               ; status register A -> A
        out     (#0x99), a
        ld      a, #0x8F
        out     (#0x99), a
        in      a, (#0x99)
        ret

st0:
        xor     a
        out     (#0x99), a
        ld      a, #0x8F
        out     (#0x99), a
        ret

g4_on:                              ; G4 without touching R#2..R#9
        ld      de, #0x0006         ; R#0 = 0x06 (M3, M4)
        call    wrvdp
        ld      a, (#r1sav)         ; R#1: clear M1/M2 only.  IE0 must be
        and     #0xE7               ; LEFT ALONE -- writing 0x40 here hangs
        ld      e, a                ; wait_vbl on a flag that never comes.
        ld      d, #1
        call    wrvdp
        ret

g4_off:
        ld      a, (#r0sav)
        ld      e, a
        ld      d, #0
        call    wrvdp
        ld      a, (#r1sav)
        ld      e, a
        ld      d, #1
        call    wrvdp
        jp      st0

wait_vbl:
        ld      bc, #0x7FFF
wv1:
        xor     a
        call    rdst
        and     #0x80
        ret     nz
        dec     bc
        ld      a, b
        or      c
        jr      nz, wv1
        ret

wait_ce:                            ; poll S#2 until CE (bit0) clears
        ld      hl, #0
wce:
        inc     hl
        ld      a, #2
        call    rdst
        and     #0x01
        ret     z
        ld      a, h
        cp      #0x7F
        jr      c, wce
        ret

;----------------------------------------------------------------------
; issue the 15-byte command block at (HL) through R#17 autoincrement
docmd:
        ld      a, #32              ; R#17 = 32, autoincrement
        out     (#0x99), a
        ld      a, #0x91
        out     (#0x99), a
        ld      b, #15
dc1:
        ld      a, (hl)
        out     (#0x9B), a
        inc     hl
        ex      (sp), hl            ; ~19 T of padding between VDP accesses
        ex      (sp), hl
        djnz    dc1
        ret

;----------------------------------------------------------------------
show:                               ; DE = label, HL = value
        ei
        call    putline
        di
        ret

putline:
        push    hl
        call    puts
        pop     hl
        call    puthex
        ld      de, #crlf
        jp      puts

puts:
        ld      c, #9
        jp      0x0005

puthex:
        push    hl
        ld      a, h
        call    puthex8
        pop     hl
        ld      a, l
        call    puthex8
        ret
puthex8:
        push    af
        rrca
        rrca
        rrca
        rrca
        call    puthex4
        pop     af
        call    puthex4
        ret
puthex4:
        push    hl
        push    bc
        and     #0x0F
        add     a, #0x30
        cp      #0x3A
        jr      c, ph1
        add     a, #7
ph1:
        ld      e, a
        ld      c, #2
        call    0x0005
        pop     bc
        pop     hl
        ret

;----------------------------------------------------------------------
; command blocks: R#32 .. R#46
;   SXlo SXhi SYlo SYhi | DXlo DXhi DYlo DYhi | NXlo NXhi NYlo NYhi | CLR ARG CMD
; Source rows live at y=128 (VRAM 0x4000), destinations at y=256
; (0x8000), so nothing reaches 0xC000 and a 64 KB-VRAM MSX2 is safe.
cb_hmmv:
        .db     0, 0, 0, 0
        .db     0, 0, 128, 0        ; DX=0   DY=128
        .db     0, 1, 128, 0        ; NX=256 NY=128
        .db     0xEE, 0x00, 0xC0
cb_hmmm:
        .db     0, 0, 128, 0        ; SX=0   SY=128
        .db     0, 0, 0, 1          ; DX=0   DY=256
        .db     0, 1, 128, 0        ; NX=256 NY=128
        .db     0x00, 0x00, 0xD0
cb_lmmv:                            ; per-PIXEL fill, so half the height
        .db     0, 0, 0, 0
        .db     0, 0, 128, 0        ; DX=0   DY=128
        .db     0, 1, 64, 0         ; NX=256 NY=64
        .db     0x0E, 0x00, 0x80
cb_lmmm:
        .db     0, 0, 128, 0        ; SX=0   SY=128
        .db     0, 0, 0, 1          ; DX=0   DY=256
        .db     0, 1, 64, 0         ; NX=256 NY=64
        .db     0x00, 0x00, 0x90
cb_ymmm:                            ; Y-only move; NX is not used
        .db     0, 0, 128, 0        ; SY=128
        .db     0, 0, 0, 1          ; DX=0   DY=256
        .db     0, 0, 128, 0        ; NY=128
        .db     0x00, 0x00, 0xE0
cb_line:
        .db     0, 0, 0, 0
        .db     0, 0, 200, 0        ; DX=0   DY=200
        .db     255, 0, 100, 0      ; NX=255 NY=100
        .db     0x0F, 0x00, 0x70
cb_srch:                            ; data-dependent: if it stops at once
        .db     0, 0, 128, 0        ; the count collapses to the CPU floor
        .db     0, 0, 0, 0
        .db     0, 0, 0, 0
        .db     0x0A, 0x00, 0x60

banner:
        .ascii  "CMDCMP 20260912a - VDP cmd timing"
        .db     13, 10, 13, 10, 0x24
l_hmmv:
        .ascii  "D0 HMMV 256x128$"
l_hmmm:
        .ascii  "D1 HMMM 256x128$"
l_lmmv:
        .ascii  "D2 LMMV 256x64 $"
l_lmmm:
        .ascii  "D3 LMMM 256x64 $"
l_ymmm:
        .ascii  "D4 YMMM 256x128$"
l_line:
        .ascii  "D5 LINE x32    $"
l_srch:
        .ascii  "D6 SRCH x32    $"
l_ref:
        .ascii  "D7 ref 4 frames$"
l_scr:
        .ascii  "CA scrmod:width$"
crlf:
        .db     13, 10, 0x24
legend:
        .db     13, 10
        .ascii  "Divide D0-D6 by D7, then compare"
        .db     13, 10
        .ascii  "the board against openMSX."
        .db     13, 10, 0x24

r0sav:   .db 0
r1sav:   .db 0
vrprev:  .db 0
vrcur:   .db 0
rep_n:   .db 0
blk_ptr: .dw 0
lbl_ptr: .dw 0
acc:     .dw 0
