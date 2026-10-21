; VPROBE for fullsys (tb_msx.sv -DVPROBE, MSX_V9968 build): replaces the BIOS at 0000h.
; Drives the V9968 (reset mode = V9958) through ports 98h-9Bh from the stock Z80 and
; checks what comes back.  Phases (OUT (2Eh),n), each followed by its error count on
; port 2Fh (low, high), the RPROBE protocol:
;   1  VRAM through port 98h: 1 KB at 00000h, 1 KB at 1C000h (R#14 = 7), written
;      with OUT (98h),A and read back with IN A,(98h); then 00000h again (aliasing)
;   2  SCREEN 5, display on, HMMV fill 256 x 4 dots with 5Ah; poll S#2 CE until
;      done (error = timeout), read the 512 bytes back through port 98h
;   3  two VBLANKs (S#0 F set) with the display on -- the V9968 fetching VRAM
;      through the V slot while the bench checks every read (error = timeout)
;   4  IM 1 interrupt: R#1 IE0 on, EI, wait for the jump to 0038h (error = timeout)
;   0Fh done
; No stack and no RAM.  The code starts at 0040h and skips 0180h-018Bh (turbor.sv).
        org 0
        jr start
        ds 38h - $, 0
        jp vint                         ; IM 1 (phase 4).  No RAM: the pushed PC is lost
        ds 40h - $, 0

        macro VREG reg, val
        ld a,val : out (99h),a : ld a,80h | reg : out (99h),a
        endm
        ; VRAM address: R#14 = bank, then A7..0, A13..8 (| 40h for write)
        macro VADDR bank, a13, wr
        VREG 14, bank
        xor a : out (99h),a : ld a,a13 | (wr * 40h) : out (99h),a
        endm
        macro REPORT
        ld a,e : out (2Fh),a : ld a,d : out (2Fh),a
        endm

        ; write 1 KB: byte = L xor H xor salt
        macro VWRITE4K salt
        ld hl,0
.w:     ld a,l : xor h : xor salt : out (98h),a
        inc hl : ld a,h : cp 04h : jr nz,.w
        endm
        macro VCHECK4K salt
        ld hl,0
.r:     in a,(98h) : ld b,a
        ld a,l : xor h : xor salt : cp b : jr z,.ok
        inc de
.ok:    inc hl : ld a,h : cp 04h : jr nz,.r
        endm

start:  di
    IFDEF R800
        jp r800sw                       ; (the switch code sits past 0190h: no room here)
r800ret:
    ENDIF
        VREG 8, 08h                     ; VR = 1 (64K x 4 addressing), sprites on
        VREG 1, 00h                     ; display off: the CPU owns the VRAM port
        ld a,1 : out (2Eh),a
        ld de,0
        VADDR 0, 0, 1
        VWRITE4K 0A5h
        VADDR 7, 0, 1
        VWRITE4K 3Ch
        VADDR 0, 0, 0
        VCHECK4K 0A5h
        VADDR 7, 0, 0
        VCHECK4K 3Ch
        VADDR 0, 0, 0
        VCHECK4K 0A5h
        REPORT

        ld a,2 : out (2Eh),a
        ld de,0
        VREG 0, 06h                     ; SCREEN 5
        VREG 1, 40h                     ; display on, no interrupts
        VREG 2, 1Fh                     ; pattern name table at 00000h
        VREG 9, 00h
        VREG 17, 36                     ; R#36.. auto-increment through port 9Bh
        ld hl,hmmv : ld b,11 : ld c,9Bh
        otir
        ld bc,0
ce:     VREG 15, 2
        in a,(99h) : and 1 : jr z,cedone
        dec bc : ld a,b : or c : jr nz,ce
        inc de                          ; CE never cleared
cedone: VREG 15, 0
        VADDR 0, 0, 0
        ld hl,200h
fr:     in a,(98h) : cp 5Ah : jr z,frok
        inc de
frok:   dec hl : ld a,h : or l : jr nz,fr
        jp part2
        assert $ <= 0180h
        ; turbor.sv overlays 0180h-018Bh (CHGCPU) in every pack this bench runs
        ; (seen: the FS-A1FX run fetched OUT (E5h),A / RET there and went off to 18FFh)
        ds 0190h - $, 0
    IFDEF R800
        ; R800 variant (-DR800, turbo R pack): S1990 reg 6 bit 5 = 0 selects the R800, so
        ; the rest runs on NextZ80 with the handshaked V9968 WAIT path (vdp_gap_r800)
r800sw: ld a,6 : out (0E4h),a : xor a : out (0E5h),a
        ld b,0
.sw:    djnz .sw                        ; let cpuswap_ctl hand the bus over
        jp r800ret
    ENDIF
part2:  REPORT

        ld a,3 : out (2Eh),a
        ld de,0
        in a,(99h)                      ; S#0: clear F
        ld c,2
vbl:    ld hl,0
vw:     in a,(99h) : rlca : jr c,vgot
        dec hl : ld a,h : or l : jr nz,vw
        inc de : jr vto                 ; no VBLANK in ~65536 polls
vgot:   dec c : jr nz,vbl
vto:    REPORT

        ld a,4 : out (2Eh),a
        ld de,0
        in a,(99h)                      ; S#0: clear F
        VREG 1, 60h                     ; display on, IE0 on
        im 1 : ei
        ld hl,0
iw:     dec hl : ld a,h : or l : jr nz,iw
        di
        inc de                          ; no interrupt in ~65536 loops
        jr idone
vint:   di
        in a,(99h)                      ; S#0: acknowledge
idone:  VREG 1, 40h
        REPORT

        ld a,0Fh : out (2Eh),a
park:   jr park

hmmv:   db 0,0, 0,0, 0,1, 4,0, 5Ah, 0, 0C0h   ; DX DY NX=256 NY=4 CLR ARG HMMV
        assert $ < 4000h
