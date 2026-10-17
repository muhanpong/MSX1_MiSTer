; RPROBE for fullsys (tb_msx.sv -DRPROBE): replaces the BIOS at 0000h (GT pack).
; Checks the memory paths core_builder's strobe review flagged, under a bench-side
; delay injection (tb_msx.sv INJ_*).  Phases (OUT (2Eh),n), each followed by its
; error count on port 2Fh (low, high):
;   1  Z80   mapper RAM: 32 segments x 256 bytes written with LD (HL),A, read back
;   2  Z80   FFFFh: 256 x (write subslot reg, read it, read 8000h), then the byte
;            planted at BFFFh (= FFFFh of the page-3 segment) must have survived
;            -- errors: low byte = wrong 8000h reads, high byte = sentinel lost
;   3  R800  as 1        4  R800  as 2        0Fh done
; No stack: page 3 is a test segment.  turbor.sv overlays 002Dh and 0180h-018Bh.
        org 0
        jr start
        ds 40h - $, 0

        macro RAMTEST
        ld de,0
        ld c,0
.ws:    ld a,c : out (0FEh),a
        ld hl,8000h
.wl:    ld a,l : xor h : xor c : ld (hl),a
        inc l : jr nz,.wl
        inc c : ld a,c : cp 32 : jr nz,.ws
        ld c,0
.rs:    ld a,c : out (0FEh),a
        ld hl,8000h
.rl:    ld a,l : xor h : xor c : cp (hl) : jr z,.ok
        inc de
.ok:    inc l : jr nz,.rl
        inc c : ld a,c : cp 32 : jr nz,.rs
        ld a,e : out (2Fh),a : ld a,d : out (2Fh),a
        endm

        macro SENTTEST
        ld de,0
        ld a,5 : out (0FEh),a : out (0FFh),a     ; pages 2 and 3: segment 5
        ld a,5Ah : ld (0BFFFh),a                 ; = FFFFh of the page-3 segment
        ld b,0
.l:     xor a : ld (0FFFFh),a                    ; subslot reg, value 00 (all subslots 0)
        ; (0Fh here crashed into RST 38h only while the PPI was never set up: every
        ;  page was slot 0, so FFFFh was slot 0's subslot register and page 0 left the
        ;  probe.  With the 82h mode word 0Fh passes -- docs/evidence_20261018)
        ld a,(0FFFFh)
        ld a,(8000h) : cp 85h : jr z,.k          ; RAMTEST left 80h^00h^05h there
        inc e
.k:     djnz .l
        ld a,(0BFFFh) : cp 5Ah : jr z,.s
        inc d
.s:     xor a : ld (0FFFFh),a
        ld a,e : out (2Fh),a : ld a,d : out (2Fh),a
        endm

start:  di
        ld a,82h : out (0ABh),a                             ; PPI mode word, as the BIOS: port A out
        ; (without it port A stays an input, ppi_out_a = 0 and OUT (A8h) does nothing --
        ;  every page is slot 0, writes reach no RAM; the first 20 runs measured that)
        ld a,6 : out (0E4h),a : ld a,60h : out (0E5h),a     ; Z80
        ld a,0F0h : out (0A8h),a                            ; pages 2,3 -> slot 3
        xor a : ld (0FFFFh),a                               ; subslot 0 (RAM)
        ld a,1 : out (2Eh),a
        RAMTEST
        ld a,2 : out (2Eh),a
        SENTTEST
        ld a,6 : out (0E4h),a : ld a,40h : out (0E5h),a     ; R800
        ld a,3 : out (2Eh),a
        RAMTEST
        ld a,4 : out (2Eh),a
        SENTTEST
        ld a,0Fh : out (2Eh),a
park:   jr park
        assert $ < 0180h
