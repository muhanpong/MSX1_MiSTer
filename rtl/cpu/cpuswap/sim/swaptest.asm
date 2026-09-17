;  cpuswap lockstep program (sjasmplus).
;
;  Everything the bench compares is written to 8000h-DFFFh or sent with OUT.
;  E000h-FFFFh (stack, ISR scratch) is excluded: interrupts land at different
;  instructions on different cores, so nothing there is reproducible.  The ISRs
;  preserve every register they touch, so the compared data does not depend on
;  where an interrupt hits.  Flags are written with bits 3/5 masked (undocumented,
;  not transferred); after block I/O only Z is kept (NextZ80 implements the
;  documented effects only; T80 derives N from the transferred byte).

ITERS   equ 6
VAR_IT  equ 8000h           ; iteration counter
VAR_LOG equ 8002h           ; flags_out write pointer
LOGBUF  equ 9000h
LOGEND  equ 0C0h            ; high byte where the log wraps (C0FFh is the IM 2 vector)
ISRCNT  equ 0E000h
SPSAVE  equ 0E010h          ; chgcpu: SP across the switch
EIMARK  equ 0E002h          ; 1 only between EI and the instruction after it
EIBAD   equ 8050h           ; written only if an interrupt was taken right after EI

        DEVICE NOSLOT64K
        ORG 0
start:  di
        ld sp,0FFF0h
        im 1
        jp main

        ORG 10h
rst10:  inc a
        ret

        ORG 18h
rst18:  add a,b
        ret

        ORG 38h
isr:    push af
        push bc
        call eicheck
        in a,(99h)          ; acknowledge (the bench drops INT)
        ld a,(ISRCNT)
        inc a
        ld (ISRCNT),a
        pop bc
        pop af
        ei
        reti

        ORG 66h
nmi:    retn

;  0180h-018Bh and 002Dh belong to the turbo R BIOS overlay: keep code out of them.
BIOS_CHGCPU equ 0180h
BIOS_GETCPU equ 0183h
        ORG 0200h

; ---------------------------------------------------------------- helpers
flags_out:                  ; log A and F&D7h, preserves everything
        push af
        push hl
        push bc
        push af
        pop bc
        ld hl,(VAR_LOG)
        ld (hl),b
        inc hl
        ld a,c
        and 0D7h
        ld (hl),a
        inc hl
        ld a,h
        cp LOGEND
        jr c,.nowrap
        ld hl,LOGBUF
.nowrap:
        ld (VAR_LOG),hl
        pop bc
        pop hl
        pop af
        ret

flags_z:                    ; log A and F&40h (Z), preserves everything
        push af
        push hl
        push bc
        push af
        pop bc
        ld hl,(VAR_LOG)
        ld (hl),b
        inc hl
        ld a,c
        and 40h
        ld (hl),a
        inc hl
        ld (VAR_LOG),hl
        pop bc
        pop hl
        pop af
        ret

eicheck:                    ; an interrupt between EI and the next instruction is a Z80 violation
        ld a,(EIMARK)
        or a
        ret z
        ld a,0EEh
        ld (EIBAD),a
        ret

delay:                      ; > 1 PCM tick on either core; preserves BC
        push bc
        ld c,6
.d1:    ld b,0
.d2:    djnz .d2
        dec c
        jr nz,.d1
        pop bc
        ret

dump:                       ; all main registers to 8100h..; preserves everything
        ld (8100h),bc
        ld (8102h),de
        ld (8104h),hl
        ld (8106h),ix
        ld (8108h),iy
        ld (810Ah),sp
        exx
        ld (810Ch),bc
        ld (810Eh),de
        ld (8110h),hl
        exx
        call flags_out
        ex af,af'
        call flags_out
        ex af,af'
        ret

;  turbo R CHGCPU-style switch: A = 0 Z80, 1 R800 ROM mode, 2 R800 DRAM mode.
;  The context goes through the stack and SP through RAM, as the turbo R BIOS has
;  to do (each real CPU keeps its own registers).  Preserves everything.
chgcpu: push af
        push bc
        push de
        push hl
        push ix
        push iy
        exx
        push bc
        push de
        push hl
        exx
        ex af,af'
        push af
        ex af,af'
        ld c,60h
        or a
        jr z,.set
        ld c,40h
        dec a
        jr z,.set
        ld c,00h
.set:   ld (SPSAVE),sp
        ld a,6
        out (0E4h),a
        ld a,c
        out (0E5h),a
        ld sp,(SPSAVE)
        ex af,af'
        pop af
        ex af,af'
        exx
        pop hl
        pop de
        pop bc
        exx
        pop iy
        pop ix
        pop hl
        pop de
        pop bc
        pop af
        ret

isr2:   push af
        push bc
        call eicheck
        in a,(99h)
        ld a,(ISRCNT+1)
        inc a
        ld (ISRCNT+1),a
        pop bc
        pop af
        ei
        reti

; ---------------------------------------------------------------- main
main:   xor a
        ld (VAR_IT),a
        ld hl,LOGBUF
        ld (VAR_LOG),hl

iter:
; --- S: CPU switch, four per iteration: a bare OUT to S1990 register 6, then the
;     turbo R BIOS entries CHGCPU/GETCPU served by the overlay
        ld a,6
        out (0E4h),a
        in a,(0E4h)
        ld (8060h),a            ; 06h
        in a,(0E5h)
        ld (8061h),a            ; 60h: Z80, ROM mode
        xor a
        out (0E5h),a            ; bare OUT: R800, DRAM mode
        in a,(0E5h)
        ld (8062h),a            ; 00h
        call BIOS_GETCPU
        ld (8067h),a            ; 2: R800 DRAM
        ld a,(002Dh)
        ld (8070h),a            ; 03h: turbo R

; --- A: arithmetic and flags, chained through the carry
        ld a,(VAR_IT)
        ld b,a
        add a,9Ch
        call flags_out
        adc a,b
        call flags_out
        sub 37h
        call flags_out
        sbc a,b
        call flags_out
        and 5Ah
        call flags_out
        or 81h
        call flags_out
        xor b
        call flags_out
        cp 40h
        call flags_out
        inc a
        call flags_out
        dec a
        call flags_out
        rla
        call flags_out
        rra
        call flags_out
        rlca
        call flags_out
        rrca
        call flags_out
        cpl
        call flags_out
        neg
        call flags_out
        scf
        call flags_out
        ccf
        call flags_out
        ld a,19h
        add a,28h
        daa
        call flags_out
        sub 7
        daa
        call flags_out
        ld hl,1234h
        ld de,0FEDCh
        add hl,de
        call flags_out
        ld (8010h),hl
        ld bc,5A5Ah
        adc hl,bc
        call flags_out
        sbc hl,de
        call flags_out
        ld (8012h),hl

; --- B: alternate set and DE/HL exchange, many times so swaps land in every bank state
        ld bc,1111h
        ld de,2222h
        ld hl,3333h
        exx
        ld bc,4444h
        ld de,5555h
        ld hl,6666h
        ld a,77h
        ex af,af'
        ld a,(VAR_IT)
        ld b,a
        ld a,88h
        ld c,0
.bloop: exx
        ex de,hl
        inc hl
        ex af,af'
        inc a
        exx
        add hl,de
        ex de,hl
        ex af,af'
        dec a
        inc c
        djnz .bloop
        call dump

; --- C: index registers, undocumented halves, DD/FD CB
        ld ix,8180h
        ld iy,81C0h
        ld a,(VAR_IT)
        ld (ix+5),a
        ld (iy-3),0A5h
        add a,(ix+5)
        call flags_out
        inc (ix+5)
        rlc (ix+5)
        set 3,(iy-3)
        res 7,(iy-3)
        bit 6,(iy-3)
        call flags_out
        ld l,(ix+5)
        ld h,(iy-3)
        ld (8020h),hl
        ld ixh,12h
        ld a,ixl
        add a,ixh
        call flags_out
        ld iyl,a
        ld (8024h),ix
        ld (8026h),iy
        ld hl,0BEEFh
        push hl
        ex (sp),ix
        pop hl
        ld (8028h),ix
        ld (802Ah),hl
        sub (iy+7Fh)
        call flags_out

; --- D: CB shifts, ED, I and R
        ld a,(VAR_IT)
        add a,5Dh
        ld b,a
        rlc b
        rrc b
        rl b
        rr b
        sla b
        sra b
        srl b
        sli b
        ld a,b
        call flags_out
        bit 2,b
        call flags_out
        set 7,b
        res 0,b
        ld (802Ch),bc
        ld hl,8030h
        ld (hl),3Ch
        ld a,0A1h
        rld
        call flags_out
        rrd
        call flags_out
        ld a,5Bh
        ld i,a
        xor a
        ld a,i
        call flags_out          ; P = IFF2 = 0
        ld a,(VAR_IT)
        ld r,a
        nop
        ld b,3
        djnz $
        ld a,r
        ld (8032h),a
        ld a,(VAR_IT)
        or 80h
        ld r,a
        ex af,af'
        ex af,af'
        ld a,r
        ld (8033h),a

        xor a
        call BIOS_CHGCPU        ; back to Z80
        call BIOS_GETCPU
        ld (8063h),a            ; 0
        in a,(0E5h)
        ld (8068h),a            ; 60h (register 6 unaffected by the GETCPU read)

; --- E: block moves and searches
        ld hl,8200h
        ld b,0
        ld a,(VAR_IT)
        ld c,a
.fill:  ld a,l
        xor c
        ld (hl),a
        inc hl
        djnz .fill
        ld hl,8200h
        ld de,8400h
        ld bc,0100h
        ldir
        call flags_out
        ld hl,84FFh
        ld de,86FFh
        ld bc,0080h
        lddr
        call flags_out
        ld hl,8200h
        ld bc,0100h
        ld a,(VAR_IT)
        xor 40h
        cpir
        call flags_out
        ld (8034h),hl
        ld (8036h),bc
        ld hl,82FFh
        ld bc,0100h
        ld a,0FFh
        cpdr
        call flags_out
        ld (8038h),hl
        ld (803Ah),bc
        ld hl,8200h
        ld de,8500h
        ld bc,3
        ldi
        ldi
        call flags_out
        ldd
        call flags_out
        ld (803Ch),de

; --- F: calls, conditional control flow, RST, stack order
        ld a,(VAR_IT)
        ld b,7
        rst 10h
        rst 18h
        call flags_out
        cp 10h
        call c,.sub_c
        call nc,.sub_nc
        call z,.sub_c
        ld hl,.jpt
        jp (hl)
.sub_c: add a,3
        ret nz
        inc a
        ret
.sub_nc:
        sub 1
        ret c
        dec a
        ret
.jpt:   call flags_out
        ld bc,0102h
        ld de,0304h
        ld hl,0506h
        ld ix,0708h
        ld iy,090Ah
        push bc
        push de
        push hl
        push ix
        push iy
        pop bc
        pop de
        pop hl
        pop ix
        pop iy
        call dump
        ld b,20
.jrl:   dec a
        jr z,.jrz
        djnz .jrl
.jrz:   call flags_out

        ld a,81h
        call BIOS_CHGCPU        ; R800, ROM mode, turbo LED follows
        call BIOS_GETCPU
        ld (8064h),a            ; 1
        in a,(0E5h)
        ld (8069h),a            ; 40h
        in a,(0A7h)
        ld (806Ah),a            ; 00h: A7h reads the pause key, not the LEDs

; --- G: I/O
        in a,(12h)
        ld (8040h),a
        ld c,34h
        in b,(c)
        call flags_out
        ld (8041h),bc
        ld a,(VAR_IT)
        out (7),a
        ld bc,0356h
        out (c),a
        ld hl,8300h
        ld bc,0460h
        inir
        call flags_z
        ld hl,8300h
        ld bc,0461h
        otir
        call flags_z
        ld hl,8310h
        ld bc,0262h
        ini
        ind
        call flags_z
        ld hl,8300h
        ld bc,0263h
        outi
        outd
        call flags_z

; --- H: interrupts (IM 1, IM 2, IM 0) with HALT
        im 1
        ld a,1                  ; EI delay: INT has been pending through the DI section above
        ld (EIMARK),a
        xor a
        ei
        ld (EIMARK),a           ; must run before any interrupt
        ld a,i
        call flags_out          ; P = IFF2 = 1
        ld hl,8600h
        ld b,0
.ibusy: ld a,b
        xor l
        ld (hl),a
        inc hl
        djnz .ibusy
        halt
        di
        ld a,0C0h
        ld i,a
        im 2
        ei
        ld b,0
.i2:    ld a,(VAR_IT)
        add a,b
        ld (8700h),a
        djnz .i2
        halt
        di
        im 0
        ei
        halt
        di
        im 1

; --- T: turbo R system timer, PCM, pause
        push bc                 ; C carries a timer reading below: keep it out of the dumps
        out (0E6h),a
        in a,(0E7h)
        ld (8071h),a            ; 00h right after the clear
        in a,(0E6h)
        ld c,a
        call delay
        in a,(0E6h)
        sub c
        jr z,.tmrstill
        ld a,1
.tmrstill:
        ld (807Ah),a            ; 1: the timer counts
        pop bc
        ld a,02h                ; not muted, D/A direct
        out (0A5h),a
        in a,(0A5h)
        ld (8072h),a            ; 82h: comparator 80h >= 80h
        ld a,7Fh
        out (0A4h),a            ; D 7f
        in a,(0A5h)
        ld (8073h),a            ; 82h
        ld a,81h
        out (0A4h),a            ; D 81
        in a,(0A5h)
        ld (8074h),a            ; 02h
        in a,(0A4h)
        cp 2
        ld a,0
        adc a,a
        ld (807Bh),a            ; 1: counter cleared by the write (0 or 1 by now)
        ld a,03h                ; BUFF: the value waits for the next 15.7 kHz tick
        out (0A5h),a
        ld a,55h
        out (0A4h),a
        call delay              ; D 55
        ld a,66h
        out (0A4h),a
        ld a,02h                ; BUFF off: the pending value lands now
        out (0A5h),a            ; D 66
        ld a,12h                ; hold
        out (0A5h),a
        in a,(0A5h)
        ld (8075h),a            ; 92h: held 80h >= 66h
        xor a
        out (0A5h),a            ; M 1: everything muted
        in a,(0A5h)
        ld (8076h),a            ; 80h
        ld a,02h
        out (0A5h),a            ; M 0
        ld a,80h
        out (0A4h),a            ; D 80
        in a,(0A7h)
        ld (8077h),a            ; 00h
        ld a,(VAR_IT)
        or a
        jr nz,.nopause
        ld a,02h                ; hardware pause enable: the bench presses Pause twice
        out (0A7h),a
        ld b,40
.pw:    djnz .pw                ; runs only once the bench has released the pause
        in a,(0A7h)
        ld (8079h),a            ; 00h: pressed twice
        xor a
        out (0A7h),a
.nopause:

; --- next iteration
        xor a
        call BIOS_CHGCPU        ; Z80
        ld a,5
        out (0E4h),a
        in a,(0E5h)
        ld (8065h),a            ; reg 5: 00h
        ld a,0Fh
        out (0E4h),a
        in a,(0E5h)
        ld (8066h),a            ; reg 15: 8Bh
        call dump
        ld a,(VAR_IT)
        out (1),a
        inc a
        ld (VAR_IT),a
        cp ITERS
        jp nz,iter
        out (0FFh),a
        jr $

        ORG 0C0FFh
        dw isr2

        SAVEBIN "swaptest.bin",0,10000h
