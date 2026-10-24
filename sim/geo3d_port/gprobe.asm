; GPROBE: per-byte cost of CPU I/O to the Geo3D ports (9Dh/9Fh) vs the V9968 (98h) and an
; unused port (2Dh, the negative control: nothing decodes it, so no pacer, no wait).
; Runs over the BIOS through tb_msx -DVPROBE +kprobe=<hex>; OUT (2Eh),n marks the
; start of phase n, the bench prints its time.  Same loop shape on every port.
;   1 OUT (9Fh),A x256 (index 50h VDATA: stream, harmless)   2 OUT (9Dh),A x256 (index)
;   3 OUT (98h),A x256 (VRAM)   4 OUT (2Dh),A x256 (control)
;   5 OTIR 256 -> 9Fh           6 OTIR 256 -> 2Dh (control)
;   7 IN A,(9Dh) x256 (status)  8 IN A,(2Dh) x256 (control)
;   9 one frame upload: index 00h + 24 bytes (OTIR) + index 48h + RUN (27 bytes)
;  10 poll IN (9Dh) until RUN busy = 0     0Fh end
        org 0
        jr start
        ds 40h - $, 0
        macro VREG reg, val
        ld a,val : out (99h),a : ld a,80h | reg : out (99h),a
        endm
        macro LOOPOUT port
        ld b,0
.l:     out (port),a : djnz .l
        endm
        macro LOOPIN port
        ld b,0
.l:     in a,(port) : djnz .l
        endm
start:  di
    IFDEF R800
        jp r800sw
r800ret:
    ENDIF
        VREG 1, 00h
        VREG 14, 0
        xor a : out (99h),a : ld a,40h : out (99h),a
        ld a,50h : out (9Dh),a
        ld a,1 : out (2Eh),a
        LOOPOUT 9Fh
        ld a,2 : out (2Eh),a
        ld a,50h
        LOOPOUT 9Dh
        ld a,3 : out (2Eh),a
        LOOPOUT 98h
        ld a,4 : out (2Eh),a
        LOOPOUT 2Dh
        ld a,50h : out (9Dh),a
        ld a,5 : out (2Eh),a
        ld hl,1000h : ld bc,009Fh : otir
        ld a,6 : out (2Eh),a
        ld hl,1000h : ld bc,002Dh : otir
        ld a,7 : out (2Eh),a
        LOOPIN 9Dh
        ld a,8 : out (2Eh),a
        LOOPIN 2Dh
        jp part2
        assert $ <= 0180h
        ds 0190h - $, 0
    IFDEF R800
r800sw: ld a,6 : out (0E4h),a : xor a : out (0E5h),a
        ld b,0
.sw:    djnz .sw
        jp r800ret
    ENDIF
part2:  ld a,9 : out (2Eh),a
        xor a : out (9Dh),a
        ld hl,gcfg : ld bc,189Fh : otir
        ld a,48h : out (9Dh),a
        ld a,1 : out (9Fh),a
        ld a,10 : out (2Eh),a
        xor a : out (9Dh),a
        ld de,0
poll:   in a,(9Dh) : inc de : and 1 : jr nz,poll
        ld a,e : out (2Fh),a : ld a,d : out (2Fh),a
        ld a,0Fh : out (2Eh),a
park:   jr park
gcfg:   dw 4000h, 0, 0,  0, 4000h, 0,  0, 0, 4000h, 0, 0, 0
        assert $ < 4000h
