; MPROBE: MoonSound wave-memory write cost and integrity (fullsys -DVPROBE +kprobe, GT pack,
; +moonsound).  OUT (2Eh),n starts phase n; OUT (2Fh) lo,hi = that phase's error count.
;  1 fill source 8000h-83FFh (segment 4) with p = L^H^3Ch
;  2 Z80  OTIR 1024 -> wave 210000h                     (timed)
;  3 Z80  read back 210000h, compare with p             (errors)
;  4 Z80  loop: LD A,(HL) / OUT (7Fh) / LD (DE),A, DE += 7 in page 3 -> wave 211000h (timed)
;  5 Z80  read back 211000h + page-3 copies             (errors)
;  6 R800 OTIR 1024 -> 212000h   7 R800 read back   8 R800 loop -> 213000h   9 R800 read back
;  0Fh done
N       equ 1024
        org 0
        jr start
        ds 40h - $, 0

        macro WADDR hi, mid
        ld a,3 : out (7Eh),a : ld a,hi : out (7Fh),a
        ld a,4 : out (7Eh),a : ld a,mid : out (7Fh),a
        ld a,5 : out (7Eh),a : xor a : out (7Fh),a
        ld a,6 : out (7Eh),a
        endm

start:  di
        ld a,82h : out (0ABh),a
        ld a,6 : out (0E4h),a : ld a,60h : out (0E5h),a     ; Z80
        ld a,0F0h : out (0A8h),a                            ; pages 2,3 -> slot 3
        xor a : ld (0FFFFh),a
        ld a,4 : out (0FEh),a : ld a,5 : out (0FFh),a
        ld sp,0F800h
        xor a : ld (0F001h),a
        ld a,5 : out (0C6h),a : ld a,3 : out (0C7h),a       ; 105h = NEW|NEW2
        ld a,2 : out (7Eh),a : ld a,1 : out (7Fh),a         ; memory access mode
        ld a,1 : out (2Eh),a
        ld hl,8000h
fill:   ld a,l : xor h : xor 3Ch : ld (hl),a
        inc hl : ld a,h : cp 80h + N/256 : jr nz,fill
        xor a : out (2Fh),a : out (2Fh),a
        call body
        ld a,6 : out (0E4h),a : ld a,40h : out (0E5h),a     ; R800
        ld b,0
.sw:    djnz .sw
        call body
        ld a,0Fh : out (2Eh),a
park:   jr park
        assert $ < 0180h
        ds 0190h - $, 0

; body: phases base+1 .. base+4 (base 1 for Z80, 5 for R800) -- phase number in (phase)
phase   equ 0F000h
body:   ld a,(0F001h) : or a : jr z,.z      ; 0F001h: 0 first time, 1 second
        ld a,4
.z:     ld (phase),a
        ld a,1 : ld (0F001h),a
        ; --- OTIR upload
        ld a,(phase) : add a,2 : out (2Eh),a
        ld a,(phase) : add a,a : add a,21h : ld (wh),a     ; 21h / 29h
        call setw
        ld hl,8000h : ld c,7Fh : ld d,N/256
.o:     ld b,0 : otir
        dec d : jr nz,.o
        xor a : out (2Fh),a : out (2Fh),a
        ; --- read back
        ld a,(phase) : add a,3 : out (2Eh),a
        call setw
        call rdcmp
        ld a,e : out (2Fh),a : ld a,d : out (2Fh),a
        ; --- stress loop
        ld a,(phase) : add a,4 : out (2Eh),a
        ld a,(wh) : inc a : ld (wh),a
        call setw
        ld hl,8000h : ld de,0C000h
.s:     ld a,(hl) : out (7Fh),a : ld (de),a
        inc hl
        ex de,hl : ld bc,7 : add hl,bc : ex de,hl
        ld a,h : cp 80h + N/256 : jr nz,.s
        xor a : out (2Fh),a : out (2Fh),a
        ; --- read back + page-3 copies
        ld a,(phase) : add a,5 : out (2Eh),a
        call setw
        call rdcmp
        push de
        ld hl,8000h : ld ix,0C000h : ld de,0
.c:     ld a,l : xor h : xor 3Ch : cp (ix+0) : jr z,.k
        inc de
.k:     ld bc,7 : add ix,bc
        inc hl : ld a,h : cp 80h + N/256 : jr nz,.c
        pop hl : add hl,de : ex de,hl
        ld a,e : out (2Fh),a : ld a,d : out (2Fh),a
        ret
wh      equ 0F002h
setw:   ld a,3 : out (7Eh),a : ld a,(wh) : out (7Fh),a
        ld a,4 : out (7Eh),a : xor a : out (7Fh),a
        ld a,5 : out (7Eh),a : xor a : out (7Fh),a
        ld a,6 : out (7Eh),a
        ret
rdcmp:  ld hl,8000h : ld de,0
.r:     in a,(7Fh) : ld b,a
        ld a,l : xor h : xor 3Ch : cp b : jr z,.ok
        inc de
.ok:    inc hl : ld a,h : cp 80h + N/256 : jr nz,.r
        ret
        assert $ < 4000h
