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
; Runs in G4 (SCREEN 5).  The command area sits above VRAM 0x4000, which
; clears EVERY text-mode table: SCREEN 1 puts its COLOUR table at 0x2000
; and its sprite patterns at 0x3800, so the old y=64 block (0x2000-0x5FFF)
; filled the colour table with 0xEE = fg 14 on bg 14 and printed the whole
; report in grey-on-grey.  The text was there all along; it was invisible.
; R#0/R#1 are restored from the BIOS save area afterwards.
;----------------------------------------------------------------------

start:
        di
        ld      a, (#0xF3DF)        ; RG0SAV
        ld      (#r0sav), a
        ld      a, (#0xF3E0)        ; RG1SAV
        ld      (#r1sav), a

        ld      de, #banner         ; print first: a hang after this still
        call    puts                ; leaves the banner on screen

        call    c0_frame            ; in the TEXT screen, not G4 -- C6..C9 below
        ld      de, #l_frame        ; say whether the mode changes the poll rate
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

        ld      a, #0
        call    fvrloss
        ld      de, #l_p0
        call    show
        ld      a, #4
        call    fvrloss
        ld      de, #l_p4
        call    show
        ld      a, #16
        call    fvrloss
        ld      de, #l_p16
        call    show

        call    scrmode
        ld      de, #l_scr
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
        ld      c, #1               ; A16..A14 = 1
        ld      hl, #0x0000         ; y=128, x=0  (128 * 128 = 0x04000)
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
; C6..C8  how many vblank F flags survive 32 frames, at three poll spacings.
;     VR (S#2 bit6) is a LEVEL -- reading it cannot destroy it -- so it is
;     the honest frame clock; the loop runs until VR has risen 0x20 times.
;     F (S#0 bit7) is a FLAG the read itself clears.  Result is packed
;     H = VR edges reached (0x20 unless the watchdog fired), L = F seen.
;     2020 = nothing lost.  A is the spacing: each unit is ~51 T of pad
;     between one poll pair and the next, so the sweep says whether the
;     loss is a race against the poll rate or something slower.
;     (The 20260912c build read bit5 here, which is HR, not VR.)
fvrloss:
        ld      (#pad_n), a
        call    wait_vbl
        ld      a, #2
        call    rdst
        and     #0x40
        ld      (#vrprev), a
        ld      de, #0              ; F events
        ld      hl, #0              ; VR rising edges
        ld      bc, #0              ; watchdog
fv1:
        ld      a, (#pad_n)
        or      a
        jr      z, fv2
        push    bc
        ld      b, a
fvp:
        ex      (sp), hl            ; 19 T each, restores HL and the stack
        ex      (sp), hl
        djnz    fvp
        pop     bc
fv2:
        xor     a
        call    rdst                ; S#0
        and     #0x80
        jr      z, fv3
        inc     de
fv3:
        ld      a, #2
        call    rdst                ; S#2
        and     #0x40               ; VR
        ld      (#vrcur), a
        ld      a, (#vrprev)
        or      a
        jr      nz, fv4             ; already high -- not an edge
        ld      a, (#vrcur)
        or      a
        jr      z, fv4
        inc     hl
fv4:
        ld      a, (#vrcur)
        ld      (#vrprev), a
        ld      a, l
        cp      #0x20
        jr      nc, fv5             ; 32 frames done
        inc     bc
        ld      a, b
        cp      #0xF0
        jr      c, fv1
fv5:
        ld      h, l                ; H = VR edges reached
        ld      l, e                ; L = F events seen
        jp      st0

;----------------------------------------------------------------------
; CA  which screen this report is actually printed on: H = SCRMOD, L =
;     LINLEN.  The 20260912 build's 0xEE fill at VRAM 0x2000 made the
;     whole report invisible; WHICH table that destroyed depends on the
;     mode, so measure the mode rather than assume it.
scrmode:
        ld      a, (#0xFCAF)        ; SCRMOD
        ld      h, a
        ld      a, (#0xF3B0)        ; LINLEN
        ld      l, a
        ret

;----------------------------------------------------------------------
; read VRAM byte at C:HL  (C = A16..A14, HL = A13..A0) -> A
; R#14 goes back to 0 before returning -- the BIOS text routines assume it.
rdvram:
        ld      e, c                ; R#14 = A16..A14
        ld      d, #14
        call    wrvdp
        ld      a, l
        out     (#0x99), a
        ld      a, h
        and     #0x3F
        out     (#0x99), a
        nop
        in      a, (#0x98)
        push    af
        ld      e, #0
        ld      d, #14
        call    wrvdp
        pop     af
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
        .db     0, 0, 128, 0        ; DX=0, DY=128  -> VRAM 0x4000
        .db     0, 1, 128, 0        ; NX=256, NY=128
        .db     0xEE, 0x00, 0xC0    ; CLR, ARG, CMD = HMMV
cmd_small:
        .db     0, 0, 0, 0
        .db     0, 0, 0x48, 1       ; DY=328, out of the big block's way
        .db     8, 0, 8, 0          ; NX=8, NY=8
        .db     0x55, 0x00, 0xC0
cmd_small2:
        .db     0, 0, 0, 0
        .db     0, 0, 0x52, 1       ; DY=338
        .db     8, 0, 8, 0
        .db     0x22, 0x00, 0xC0

banner:
        .ascii  "CEPROBE 20260912d - cmd engine"
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
l_p0:
        .ascii  "C6 F:VR pad0   $"
l_p4:
        .ascii  "C7 F:VR pad4   $"
l_p16:
        .ascii  "C8 F:VR pad16  $"
l_scr:
        .ascii  "CA scrmod:width$"
crlf:
        .db     13, 10, 0x24
legend:
        .db     13, 10
        .ascii  "C1/C0 = frames per command; same at"
        .db     13, 10
        .ascii  "every clock. C3=00EE C4=C5=0001."
        .db     13, 10
        .ascii  "C6-C8 want 2020 (H=frames L=F seen)"
        .db     13, 10, 0x24

r0sav:   .db 0
r1sav:   .db 0
vrprev:  .db 0
vrcur:   .db 0
pad_n:   .db 0
v_vr:    .dw 0
v_f:     .dw 0
v_frame: .dw 0
v_big:   .dw 0
v_small: .dw 0
v_ovr:   .dw 0
v_ce:    .dw 0
