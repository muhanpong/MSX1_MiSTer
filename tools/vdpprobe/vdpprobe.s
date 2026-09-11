        .module vdpprobe
        .area   _CODE
;----------------------------------------------------------------------
; VDPPROBE.COM -- one screen of numbers that decides why a raster split
; lands on the wrong line (or not at all) as the CPU clock goes up.
;
; Run once per OSD CPU SPEED step and compare the columns.  T0 identifies
; the step by itself, so a screenshot is self-labelling and the four runs
; can be taken in any order.  T1/T0 is the split position as a fraction of
; the frame: if the trigger is raster-locked that fraction is the same at
; every clock, and if it is not, it drifts (or T1 goes to 0 = never fires).
;
; Everything is polled with interrupts off except T5, which installs its
; own handler at 0x0038 (page 0 is RAM under MSX-DOS) and puts DOS's three
; bytes back afterwards.
;
; Status registers are reached by pointing R#15 at them: write n, then
; 0x8F.  Reading S#0 clears the vblank flag F and the interrupt; reading
; S#1 clears the line flag FH.  Both are used as edge detectors, so no
; other code may read them during a measurement.
;----------------------------------------------------------------------

start:
        di
        ld      a, (#0xF3DF)        ; RG0SAV -- R#0 also holds mode bits
        ld      (#r0sav), a

        ei
        ld      de, #banner         ; banner first: a hang after this still
        call    puts                ; leaves a trail on screen
        di

        call    t0_framelen
        ld      de, #l_frame
        call    show
        call    t1_fhpos
        ld      de, #l_fhpos
        call    show
        ld      hl, (#v_fhclr)
        ld      de, #l_fhclr
        call    show
        call    t4_fh_ie0
        ld      de, #l_fhie0
        call    show
        call    t5_irqcnt
        ld      de, #l_irq
        call    show
        call    t6_fh_line0
        ld      de, #l_fhl0
        call    show
        call    t8_fh_ie0_noreg
        ld      de, #l_fhie0b
        call    show
        call    t9_r23_shift
        ld      hl, (#v_r23a)
        ld      de, #l_r23a
        call    show
        ld      hl, (#v_r23b)
        ld      de, #l_r23b
        call    show
        ld      hl, (#v_r23c)
        ld      de, #l_r23c
        call    show
        ld      hl, (#v_r23d)
        ld      de, #l_r23d
        call    show
        call    t7_vdpwr
        ld      de, #l_vdpw
        call    show

        call    restore
        ei
        ld      de, #legend
        call    puts
        ret

;----------------------------------------------------------------------
; VDP primitives.  All assume interrupts are off.

wrvdp:                              ; write E to register D
        ld      a, e
        out     (#0x99), a
        ld      a, d
        or      #0x80
        out     (#0x99), a
        ret

rdst:                               ; read status register A into A
        out     (#0x99), a
        ld      a, #0x8F
        out     (#0x99), a
        in      a, (#0x99)
        ret

st0:                                ; leave S#0 selected, as the BIOS expects
        xor     a
        out     (#0x99), a
        ld      a, #0x8F
        out     (#0x99), a
        ret

wait_vbl:                           ; wait for the next vblank, give up eventually
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

ie1_on:
        ld      a, (#0xF3DF)
        or      #0x10
        jr      set_r0
ie1_off:
        ld      a, (#0xF3DF)
        and     #0xEF
set_r0:
        ld      e, a
        ld      d, #0
        jp      wrvdp

;----------------------------------------------------------------------
; T0  frame length in poll iterations.  The one number that is meant to
;     change with the clock: it labels the run and is what T1 divides by.
t0_framelen:
        call    wait_vbl
        ld      hl, #0
t0a:
        inc     hl
        xor     a
        call    rdst
        and     #0x80
        ret     nz
        ld      a, h
        cp      #0x7F
        jr      c, t0a
        ld      hl, #0
        ret

;----------------------------------------------------------------------
; T1  iterations from the start of vblank until FH (S#1 bit 0) comes up,
;     IE1 on, R#19 = 0x60.  0 = it never came up: the split never fires.
; T3  the read that saw FH must have cleared it; 0 = cleared (correct).
t1_fhpos:
        call    ie1_on
        ld      de, #0x1360         ; R#19 = 0x60
        call    wrvdp
        call    wait_vbl            ; clear FH INSIDE the new frame: clearing it
        ld      a, #1               ; before the wait leaves the scan line free to
        call    rdst                ; reach R#19 while waiting, and the first poll
                                    ; then sees a flag from the previous frame
        ld      hl, #0
t1a:
        inc     hl
        ld      a, #1
        call    rdst
        and     #0x01
        jr      nz, t1_hit
        ld      a, h
        cp      #0x7F
        jr      c, t1a
        ld      hl, #0xFFFF         ; never fired -- T3 has no meaning
        ld      (#v_fhclr), hl
        ld      hl, #0
        ret
t1_hit:
        push    hl
        ld      a, #1               ; second read: FH must now be 0
        call    rdst
        ld      h, #0
        ld      l, a
        ld      (#v_raw1), hl       ; whole byte, to prove S#1 is what is read
        and     #0x01
        ld      l, a
        ld      h, #0
        ld      (#v_fhclr), hl
        pop     hl
        ret

;----------------------------------------------------------------------
; T4  does FH still set with IE1 OFF?  On a real V9938 the flag does not
;     depend on the enable -- IE1 only gates the interrupt request.
;     1 = sets (hardware behaviour), 0 = stuck, the defect already on record.
t4_fh_ie0:
        call    ie1_off
        ld      de, #0x1360
        call    wrvdp
        ; Let four whole frames pass with IE1 already off before measuring.
        ; Without this the test inherits state from T1, where IE1 was on: an
        ; emulator with an H-scan event already scheduled can fire it once more
        ; after the enable goes away, and the probe would then report a
        ; divergence that is really its own ordering.
        call    wait_vbl
        call    wait_vbl
        call    wait_vbl
        call    wait_vbl
        ld      a, #1
        call    rdst                ; clear FH inside the new frame
        ld      hl, #0
t4a:
        inc     hl
        ld      a, #1
        call    rdst
        and     #0x01
        jr      nz, t4_yes
        ld      a, h
        cp      #0x7F
        jr      c, t4a
        ld      hl, #0
        ret
t4_yes:
        ld      hl, #1
        ret


;----------------------------------------------------------------------
; T5  line interrupts actually delivered over 16 frames.  Separates "the
;     flag sets but no interrupt arrives" from "neither happens".  Want 0x10.
t5_irqcnt:
        ld      hl, #0x0038
        ld      de, #savevec
        ld      bc, #3
        ldir
        ld      a, #0xC3
        ld      (#0x0038), a
        ld      hl, #isr
        ld      (#0x0039), hl

        ld      hl, #0
        ld      (#c_irq), hl
        ld      (#c_frm), hl
        call    ie1_on
        ld      de, #0x1360
        call    wrvdp
        im      1
        ei
t5wait:
        ld      a, (#c_frm)
        cp      #16
        jr      c, t5wait
        di
        ld      hl, #savevec
        ld      de, #0x0038
        ld      bc, #3
        ldir
        ld      hl, (#c_irq)
        ret

isr:
        push    af
        push    bc
        push    de
        push    hl
        ld      a, #1               ; S#1 first: FH is what is being counted
        call    rdst
        and     #0x01
        jr      z, isr_v
        ld      hl, (#c_irq)
        inc     hl
        ld      (#c_irq), hl
isr_v:
        xor     a                   ; S#0 clears the interrupt and F
        call    rdst
        and     #0x80
        jr      z, isr_out
        ld      hl, (#c_frm)
        inc     hl
        ld      (#c_frm), hl
isr_out:
        pop     hl
        pop     de
        pop     bc
        pop     af
        ei
        reti

;----------------------------------------------------------------------
; T6  FH with R#19 = 0.  Line 0 is the case a vblank-side clear used to
;     destroy.  1 = fires, 0 = does not.
t6_fh_line0:
        call    ie1_on
        ld      de, #0x1300
        call    wrvdp
        call    wait_vbl            ; clear after the wait -- see t1_fhpos
        ld      a, #1
        call    rdst
        ld      hl, #0
t6a:
        inc     hl
        ld      a, #1
        call    rdst
        and     #0x01
        jr      nz, t6_yes
        ld      a, h
        cp      #0x7F
        jr      c, t6a
        ld      hl, #0
        ret
t6_yes:
        ld      hl, #1
        ret

;----------------------------------------------------------------------
; T8  same as T4 but WITHOUT rewriting R#19 after IE1 goes off.  T6 left
;     R#19 = 0 and IE1 on; this turns IE1 off and touches nothing else.
;     T4=1 with T8=0 means the flag is not unconditional -- it is the
;     register write that re-arms it, which is a much narrower difference
;     than "the flag ignores IE1".
t8_fh_ie0_noreg:
        call    ie1_off
        call    wait_vbl
        call    wait_vbl
        call    wait_vbl
        call    wait_vbl
        ld      a, #1
        call    rdst
        ld      hl, #0
t8a:
        inc     hl
        ld      a, #1
        call    rdst
        and     #0x01
        jr      nz, t8_yes
        ld      a, h
        cp      #0x7F
        jr      c, t8a
        ld      hl, #0
        ret
t8_yes:
        ld      hl, #1
        ret

;----------------------------------------------------------------------
; T9  T1 again, but with R#23 (vertical offset) = 64.  The real chip
;     compares R#19 against the DISPLAY line, which R#23 shifts, so the
;     match must move: T9 should come out well below T1.  If T9 == T1 the
;     comparison is against a raw counter instead, and that -- not the IE1
;     enable -- is what makes a wandering R#23 produce matches the
;     reference never has.
t9_r23_shift:                       ; measure FH position for four R#23 values
        ld      ix, #v_r23a
        ld      b, #0               ; first offset
t9_loop:
        push    bc
        call    ie1_on
        ld      d, #23              ; R#23 = B
        ld      e, b
        call    wrvdp
        ld      de, #0x1360         ; R#19 = 0x60
        call    wrvdp
        call    wait_vbl            ; let the write settle for a whole frame
        call    wait_vbl
        ld      a, #1
        call    rdst                ; clear FH inside the new frame
        ld      hl, #0
t9a:
        inc     hl
        ld      a, #1
        call    rdst
        and     #0x01
        jr      nz, t9_hit
        ld      a, h
        cp      #0x7F
        jr      c, t9a
        ld      hl, #0
t9_hit:
        ld      0(ix), l
        ld      1(ix), h
        inc     ix
        inc     ix
        pop     bc
        ld      a, b
        add     a, #64
        ld      b, a
        jr      nz, t9_loop         ; 0, 64, 128, 192, then wraps to 0 -> stop
        ld      de, #0x1700         ; R#23 back to 0
        call    wrvdp
        ret


;----------------------------------------------------------------------
; T7  VDP register writes completed in one frame.  A turbo pacer that caps
;     VDP accesses shows up here as this number failing to scale with T0.
;     R#7 is rewritten with the value SCREEN 0 already holds.
t7_vdpwr:
        call    wait_vbl
        ld      hl, #0
t7a:
        inc     hl
        xor     a
        out     (#0x99), a
        ld      a, #0x87
        out     (#0x99), a
        xor     a
        call    rdst
        and     #0x80
        ret     nz
        ld      a, h
        cp      #0x7F
        jr      c, t7a
        ret

;----------------------------------------------------------------------
restore:
        ld      a, (#r0sav)
        ld      e, a
        ld      d, #0
        call    wrvdp
        ld      de, #0x1300         ; R#19 = 0
        call    wrvdp
        ld      de, #0x1700         ; R#23 = 0
        call    wrvdp
        jp      st0

;----------------------------------------------------------------------
show:                               ; DE = label, HL = value.  Puts R#23 back
        push    hl                  ; first: a non-zero vertical offset scrolls
        push    de                  ; the text screen out of sight, so a hang
        ld      de, #0x1700         ; mid-sweep would show a blank screen.
        call    wrvdp
        ld      a, (#r0sav)
        ld      e, a
        ld      d, #0
        call    wrvdp
        call    st0
        pop     de
        pop     hl
        ei
        call    putline
        di
        ret

putline:                            ; DE = label, HL = value
        push    hl
        call    puts
        pop     hl
        call    puthex
        ld      de, #crlf
        jp      puts

puts:
        ld      c, #9
        jp      0x0005

puthex:                             ; HL as four hex digits.  BDOS destroys
        push    hl                  ; registers, so every call is bracketed --
        ld      a, h                ; without this the low byte prints garbage
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

banner:
        .ascii  "VDPPROBE 20260912b - FH vs R23"
        .db     13, 10, 13, 10, 0x24
l_frame:
        .ascii  "T0 frame len   $"
l_fhpos:
        .ascii  "T1 vbl->FH     $"
l_fhclr:
        .ascii  "T3 FH re-read  $"
l_fhie0:
        .ascii  "T4 FH w/ IE1=0 $"
l_irq:
        .ascii  "T5 line IRQ/16 $"
l_fhl0:
        .ascii  "T6 FH line 0   $"
l_fhie0b:
        .ascii  "T8 IE1=0 no R19$"
l_r23a:
        .ascii  "T9 FH R23=0    $"
l_r23b:
        .ascii  "T9 FH R23=64   $"
l_r23c:
        .ascii  "T9 FH R23=128  $"
l_r23d:
        .ascii  "T9 FH R23=192  $"
l_vdpw:
        .ascii  "T7 VDP wr/fr   $"
l_raw1:
        .ascii  "R1 raw S#1     $"
l_raw0:
        .ascii  "R0 raw S#0     $"
crlf:
        .db     13, 10, 0x24
legend:
        .db     13, 10
        .ascii  "T9 sweep: where FH lands as R23 moves"
        .db     13, 10
        .ascii  "T1=0 never fires. want T3=0000"
        .db     13, 10
        .ascii  "T4=0001 T5=0010 T6=0001"
        .db     13, 10, 0x24

r0sav:    .db 0
savevec:  .db 0, 0, 0
c_irq:    .dw 0
c_frm:    .dw 0
v_frame:  .dw 0
v_fhpos:  .dw 0
v_fhclr:  .dw 0
v_fhie0:  .dw 0
v_irq:    .dw 0
v_fhl0:   .dw 0
v_fhie0b: .dw 0
v_r23a:   .dw 0
v_r23b:   .dw 0
v_r23c:   .dw 0
v_r23d:   .dw 0
v_vdpw:   .dw 0
v_raw1:   .dw 0
v_raw0:   .dw 0
