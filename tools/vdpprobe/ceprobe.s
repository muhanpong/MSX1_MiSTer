        .module ceprobe
        .area   _CODE
;----------------------------------------------------------------------
; CEPROBE.COM -- does the VDP command engine keep its own time when the
; CPU clock goes up?
;
; The engine is VDP-side hardware, so a given command must take the same
; REAL time at every CPU step.  C1 is measured in the same poll units as
; C0 (one frame), so C1/C0 is the command's length in frames: that ratio
; is what must stay constant.  If it shrinks as the clock rises, the
; engine is being paced by the CPU instead of by itself, and code that
; fires commands back-to-back will overrun it -- which is what a screen
; split made of VDP commands looks like when it breaks.
;
; C3 is the overrun case itself: a second command issued while the first
; is still running.  The byte read back says which one won.
;
; Runs in G4 (SCREEN 5) with the command area kept above VRAM 0x2000 so
; the text screen it prints into survives.  R#0/R#1 are restored from the
; BIOS save area afterwards.
;----------------------------------------------------------------------

start:
        di
        ld      a, (#0xF3DF)        ; RG0SAV
        ld      (#r0sav), a
        ld      a, (#0xF3E0)        ; RG1SAV
        ld      (#r1sav), a

        ld      de, #banner         ; print first: a hang after this still
        call    puts                ; leaves the banner on screen

        call    g4_on
        call    c0_frame
        call    g4_off
        ld      de, #l_frame
        call    show

        call    g4_on
        call    c1_bigcmd
        call    g4_off
        ld      de, #l_big
        call    show

        call    g4_on
        call    c2_percmd
        call    g4_off
        ld      de, #l_small
        call    show

        call    g4_on
        call    c3_overrun
        call    g4_off
        ld      de, #l_ovr
        call    show

        call    g4_on
        call    c4_ce_after
        call    g4_off
        ld      de, #l_ce
        call    show

        call    c5_f_ie0
        ld      de, #l_fie0
        call    show

        ld      de, #legend
        call    puts
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

g4_on:                              ; G4 (SCREEN 5) without touching R#2..R#7
        ld      de, #0x0006         ; R#0 = 0x06  (M3, M4)
        call    wrvdp
        ld      a, (#r1sav)         ; R#1: clear M1/M2 only.  IE0 must be LEFT
        and     #0xE7               ; ALONE -- writing 0x40 here hung the first
        ld      e, a                ; version of this probe on hardware, because
        ld      d, #1               ; wait_vbl then waits for an F flag that
        call    wrvdp               ; never comes.  C5 measures exactly that.
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

wait_ce:                            ; poll S#2 until CE (bit0) clears; HL counts
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
; issue the 15-byte command block at (DE) through R#17 autoincrement
docmd:                              ; HL = pointer to the 15-byte block
        ld      a, #32              ; R#17 = 32, autoincrement (bit7 = 0)
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
; C0  frame length in poll units, the clock label and the divisor for C1
c0_frame:
        call    wait_vbl
        ld      hl, #0
c0a:
        inc     hl
        xor     a
        call    rdst
        and     #0x80
        ret     nz
        ld      a, h
        cp      #0x7F
        jr      c, c0a
        ld      hl, #0
        ret

;----------------------------------------------------------------------
; C1  one big HMMV (256 x 128 at y=64), timed in the same units as C0.
;     C1/C0 = how much of a frame the engine needs.  MUST NOT change with
;     the CPU clock.
c1_bigcmd:
        ld      hl, #cmd_big
        call    docmd
        call    wait_ce
        ret

;----------------------------------------------------------------------
; C2  small 8x8 fills completed in one frame, each waited out properly.
;     Scales with the CPU clock only through the polling overhead; a
;     command engine that is really running at VDP speed puts a ceiling
;     on it.
c2_percmd:
        call    wait_vbl
        ld      hl, #0
c2a:
        push    hl
        ld      hl, #cmd_small
        call    docmd
        call    wait_ce
        pop     hl
        inc     hl
        xor     a
        call    rdst
        and     #0x80
        ret     nz
        ld      a, h
        cp      #0x0F
        jr      c, c2a
        ret

;----------------------------------------------------------------------
; C3  overrun: fire the big fill (colour 0xEE), then immediately -- with no
;     CE poll at all -- fire a second fill (colour 0x22) somewhere else.
;     Then wait for quiet and read one pixel the FIRST command would have
;     written in its first few lines.
;       0xEE = the first command survived the second being queued
;       0x22 = the second command took over that area (it should not)
;       other = the first command was killed before it got there
c3_overrun:
        ld      hl, #cmd_big
        call    docmd
        ld      hl, #cmd_small2     ; no wait_ce here -- that is the point
        call    docmd
        call    wait_ce
        ld      hl, #0x2000         ; y=64, x=0  (64 * 128)
        call    rdvram
        ld      h, #0
        ld      l, a
        ret

;----------------------------------------------------------------------
; C4  CE right after a command is issued: 1 = the engine reported busy at
;     all.  0 means the command was already over, or CE never rises.
c4_ce_after:
        ld      hl, #cmd_big
        call    docmd
        ld      a, #2
        call    rdst
        and     #0x01
        ld      h, #0
        ld      l, a
        push    hl
        call    wait_ce
        pop     hl
        ret

;----------------------------------------------------------------------
; C5  vblank flag F with IE0 OFF.  On a real VDP the flag is independent of
;     the enable; IE0 only gates the interrupt request.  1 = sets, 0 = stuck.
;     Restores R#1 before returning, whatever the answer.
c5_f_ie0:
        call    wait_vbl            ; land inside a frame first
        ld      a, (#r1sav)
        and     #0xDF               ; IE0 = 0
        ld      e, a
        ld      d, #1
        call    wrvdp
        xor     a                   ; clear F
        call    rdst
        ld      hl, #0
c5a:
        inc     hl
        xor     a
        call    rdst
        and     #0x80
        jr      nz, c5_yes
        ld      a, h
        cp      #0x7F
        jr      c, c5a
        ld      hl, #0
        jr      c5_out
c5_yes:
        ld      hl, #1
c5_out:
        push    hl
        ld      a, (#r1sav)
        ld      e, a
        ld      d, #1
        call    wrvdp
        pop     hl
        ret

;----------------------------------------------------------------------
; read VRAM byte at HL (bits 16.14 assumed 0) -> A
rdvram:
        ld      e, #0               ; R#14 = A16..A14 = 0
        ld      d, #14
        call    wrvdp
        ld      a, l
        out     (#0x99), a
        ld      a, h
        and     #0x3F
        out     (#0x99), a
        nop
        in      a, (#0x98)
        ret

;----------------------------------------------------------------------
show:                               ; DE = label, HL = value, IRQs back on for BDOS
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
cmd_big:
        .db     0, 0, 0, 0          ; SX, SY
        .db     0, 0, 64, 0         ; DX=0, DY=64
        .db     0, 1, 128, 0        ; NX=256, NY=128
        .db     0xEE, 0x00, 0xC0    ; CLR, ARG, CMD = HMMV
cmd_small:
        .db     0, 0, 0, 0
        .db     0, 0, 200, 0        ; DY=200, out of the big block's way
        .db     8, 0, 8, 0          ; NX=8, NY=8
        .db     0x55, 0x00, 0xC0
cmd_small2:
        .db     0, 0, 0, 0
        .db     0, 0, 210, 0        ; DY=210
        .db     8, 0, 8, 0
        .db     0x22, 0x00, 0xC0

banner:
        .ascii  "CEPROBE 20260912 - command engine"
        .db     13, 10, 13, 10, 0x24
l_frame:
        .ascii  "C0 frame len   $"
l_big:
        .ascii  "C1 HMMV 256x128$"
l_small:
        .ascii  "C2 cmds / frame$"
l_ovr:
        .ascii  "C3 overrun byte$"
l_ce:
        .ascii  "C4 CE after cmd$"
l_fie0:
        .ascii  "C5 F w/ IE0=0  $"
crlf:
        .db     13, 10, 0x24
legend:
        .db     13, 10
        .ascii  "C1/C0 = frames per command. MUST be"
        .db     13, 10
        .ascii  "the same at every clock. C3 want 00EE"
        .db     13, 10
        .ascii  "C4 want 0001. C5 want 0001."
        .db     13, 10, 0x24

r0sav:   .db 0
r1sav:   .db 0
v_frame: .dw 0
v_big:   .dw 0
v_small: .dw 0
v_ovr:   .dw 0
v_ce:    .dw 0
