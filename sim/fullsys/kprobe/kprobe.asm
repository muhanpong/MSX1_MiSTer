; KPROBE for fullsys (tb_msx.sv -DKPROBE): replaces the BIOS at 0000h.
; 128 JIS level-1 glyphs x 32 bytes = 4096 reads of port D9h per phase, the
; board KPROBE's count.  Phases are marked by OUT (2Eh),n (the bench counts per
; phase and checks every read against the kanji image in SDRAM):
;   1  Z80 stock speed, INIR (21 T per byte)
;   2  Z80, IN A,(D9h) with ~50 T between reads
;   3  R800 (S1990 register 6 = 40h), INIR
;   0Fh done
; No stack and no RAM: the machine runs straight from reset with page 3 unset
; (the first version CALLed through a stack at F000h and restarted every 81 us).
; INIR's destination is ROM (writes ignored).  turbor.sv overlays 002Dh and
; 0180h-018Bh: the code starts at 0040h and ends below 0180h.
        org 0
        jr start
        ds 40h - $, 0
start:  di
        ld a,6 : out (0E4h),a : ld a,60h : out (0E5h),a     ; Z80
        ld a,1 : out (2Eh),a
        ld e,0
p1:     ld a,e : and 3Fh : out (0D8h),a
        ld a,e : rlca : rlca : and 03h : add a,10h : out (0D9h),a
        ld hl,4000h : ld b,32 : ld c,0D9h
        inir
        inc e : ld a,e : cp 80h : jr nz,p1
        ld a,2 : out (2Eh),a
        ld e,0
p2:     ld a,e : and 3Fh : out (0D8h),a
        ld a,e : rlca : rlca : and 03h : add a,10h : out (0D9h),a
        ld b,32
p2b:    in a,(0D9h)
        nop : nop : nop : nop : nop : nop : nop : nop : nop : nop
        djnz p2b
        inc e : ld a,e : cp 80h : jr nz,p2
        ld a,6 : out (0E4h),a : ld a,40h : out (0E5h),a     ; R800
        ld a,3 : out (2Eh),a
        ld e,0
p3:     ld a,e : and 3Fh : out (0D8h),a
        ld a,e : rlca : rlca : and 03h : add a,10h : out (0D9h),a
        ld hl,4000h : ld b,32 : ld c,0D9h
        inir
        inc e : ld a,e : cp 80h : jr nz,p3
        ld a,0Fh : out (2Eh),a
park:   jr park
        assert $ < 0180h
