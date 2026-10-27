; LPROBE: ch4 latency under load (fullsys -DVPROBE -DLPROBE +kprobe, GT pack, +moonsound).
; tb_msx.sv (LPROBE) records, per phase, the engine's read latency (ms_mem_rd_req rise ->
; ms_mem_rd_valid) and write latency (ms_mem_wr_req rise -> bridge idle) in clk_sdram.
;  1 Z80: NEW2, one 16-bit header at 200000h (wave 384, table header 4), 24 voices keyed
;  2 Z80: idle, 24 voices playing                     (playback only)
;  3 R800: idle loop, 24 voices playing               (playback + R800 fetches)
;  4 R800: OTIR 1024 B -> 220000h while playing       (playback + upload)
;  5 R800: 1024 reg 6 reads while playing             (playback + readback)
;  8 R800: SCREEN 8 + sprites, HS, full-page HMMM copies waited on CE   (playback + VDP load)
;  6 R800: keys off, idle                             (upload with nothing playing)
;     R800: OTIR 1024 B -> 224000h
;  7 idle (only so that phase 6 is reported before the probe ends)
;  0Fh done
N       equ 1024
        org 0
        jr start
        ds 40h - $, 0

start:  di
        ld a,82h : out (0ABh),a
        ld a,6 : out (0E4h),a : ld a,60h : out (0E5h),a     ; Z80
        ld a,0F0h : out (0A8h),a
        xor a : ld (0FFFFh),a
        ld a,4 : out (0FEh),a : ld a,5 : out (0FFh),a
        ld sp,0F800h
        ld a,5 : out (0C6h),a : ld a,3 : out (0C7h),a       ; 105h = NEW|NEW2
        ld a,1 : out (2Eh),a
        ld a,2 : out (7Eh),a : ld a,1 : out (7Fh),a         ; memory access mode
        ld a,20h : ld b,0 : ld c,0 : call setw              ; 200000h
        ld hl,hdr : ld b,12 : ld c,7Fh : otir
        ld a,2 : out (7Eh),a : ld a,11h : out (7Fh),a       ; table header 4 (200000h) + access
        ; 24 voices: wave 384, fn 200h, oct -1 .. +5 cycling, pan centre, TL 0
        ld e,0
.kv:    ld a,e : add a,20h : out (7Eh),a                     ; field 1: fn lsb, wave bit 8
        ld a,1 : out (7Fh),a
        ld a,e : add a,08h : out (7Eh),a                     ; field 0: wave lsb (header load)
        ld a,80h : out (7Fh),a
        ld a,e : and 7 : sub 1 : and 0Fh                     ; oct = (n & 7) - 1
        rlca : rlca : rlca : rlca : or 4                     ; fn bits 9:7 = 4 (fn 200h)
        ld b,a : ld a,e : add a,38h : out (7Eh),a : ld a,b : out (7Fh),a
        ld a,e : add a,50h : out (7Eh),a : ld a,1 : out (7Fh),a    ; TL 0, load now
.ld:    in a,(0C4h) : and 2 : jr nz,.ld                      ; header loaded
        ld a,e : add a,68h : out (7Eh),a : ld a,80h : out (7Fh),a  ; key on
        inc e : ld a,e : cp 24 : jr nz,.kv
        ld a,2 : out (2Eh),a
        call idle
        ld a,6 : out (0E4h),a : ld a,40h : out (0E5h),a     ; R800
        ld b,0
.sw:    djnz .sw
        ld a,3 : out (2Eh),a
        call idle : call idle
        ld a,4 : out (2Eh),a
        ld a,22h : ld b,0 : ld c,0 : call setw
        call upload
        ld a,5 : out (2Eh),a
        ld a,22h : ld b,0 : ld c,0 : call setw
        ld hl,0 : ld d,N/256
.r:     ld b,0
.r1:    in a,(7Fh) : djnz .r1
        dec d : jr nz,.r
        ld a,8 : out (2Eh),a
        call vdpload
        ld a,6 : out (2Eh),a
        ld e,0
.ko:    ld a,e : add a,68h : out (7Eh),a : xor a : out (7Fh),a
        inc e : ld a,e : cp 24 : jr nz,.ko
        call idle
        ld a,22h : ld b,40h : ld c,0 : call setw
        call upload
        ld a,7 : out (2Eh),a                                ; closes phase 6's numbers
        call idle
        ld a,0Fh : out (2Eh),a
park:   jr park

        ; turbor.sv overlays 0180h-018Bh of the main ROM (CHGCPU / GETCPU stubs) in every
        ; pack this bench runs: the first lprobe had idle there, so idle returned after one
        ; pass through the stub (OUT (E5h),A; RET) and switched the CPU mode.  Skip it.
        assert $ < 0180h
        ds 0190h - $, 0
; idle first: its inner loop (.i1) is at 0195h, where tb_msx.sv LPROBE counts M1 fetches
idle:   ld d,1
.i0:    ld bc,600
.i1:    dec bc : ld a,b : or c : jr nz,.i1
        dec d : jr nz,.i0
        ret
; wave address A:B:C (hi, mid, lo) into regs 3-5, select reg 6
setw:   push af : ld a,3 : out (7Eh),a : pop af : out (7Fh),a
        ld a,4 : out (7Eh),a : ld a,b : out (7Fh),a
        ld a,5 : out (7Eh),a : ld a,c : out (7Fh),a
        ld a,6 : out (7Eh),a
        ret
upload: ld hl,0 : ld c,7Fh : ld d,N/256
.o:     ld b,0 : otir
        dec d : jr nz,.o
        ret
; The heaviest VRAM load at hand: SCREEN 8 (display fetch twice SCREEN 5's), sprites on,
; V9968 high-speed commands (port 9Ch bit 7 = 0 unlocks R#20; R#20 bit 0 = HS), and VK
; full-page HMMM copies (read + write per dot) page 0 -> page 1, each waited for on S#2 CE
; (timeout -> EEh on port 2Fh)
VK      equ 6
vdpload:
        xor a : out (9Ch),a                                  ; unlock the V9968 registers
        ld a,01h : ld e,20 : call vdpw                       ; HS
        ld a,0Eh : ld e,0 : call vdpw                        ; G7
        ld a,40h : ld e,1 : call vdpw
        ld a,1Fh : ld e,2 : call vdpw
        ld a,08h : ld e,8 : call vdpw                        ; sprites on, 64K x 4
        xor a : ld e,9 : call vdpw
        ld d,VK
.v:     ld a,32 : ld e,17 : call vdpw                        ; R#17: auto-increment from R#32
        ld hl,vcmd : ld b,15 : ld c,9Bh : otir
        ld a,2 : ld e,15 : call vdpw
        ld bc,0
.ce:    in a,(99h) : and 1 : jr z,.done
        dec bc : ld a,b : or c : jr nz,.ce
        ld a,0EEh : out (2Fh),a
.done:  xor a : ld e,15 : call vdpw
        dec d : jr nz,.v
        ret
vdpw:   out (99h),a : ld a,e : or 80h : out (99h),a
        ret
; 16-bit, start 201000h, loop 0, end 4096, AR 15, RR 4
hdr:    db 0A0h, 10h, 00h, 00h, 00h, 0F0h, 00h, 00h, 0F0h, 00h, 04h, 00h
; HMMM: SX 0, SY 0, DX 0, DY 256 (page 1), NX 256, NY 212, CLR -, ARG 0, CMD D0h
vcmd:   db 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 212, 0, 0, 0, 0D0h
        assert $ < 4000h
