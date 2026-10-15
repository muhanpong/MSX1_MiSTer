; NHTEST -- hardware checks for the Neon Horizon corruption on the sdram128 core
; Run from Disk BASIC:  BLOAD "NHTEST.BIN",R   (AUTOEXEC.BAS does it)
; Cart: NHTEST.ROM = Neon Horizon with its "AB" header cleared (does not boot,
;       still detected as ASCII16-X by the signature at 0010h).
;
;  T1  cart 8 MB: 512 x 16 KB pages, sum16 + xor8 per page, against the table of
;      the original image.  Two passes: a page that differs only in pass 2 is
;      content that changed while being read.
;  T2  flash byte-program, exactly as Neon does at 5.6 s: bank 121h in the 4000h
;      window, AA->4AAAh 55->4555h A0->4AAAh 45h->4000h.  Then read the byte back
;      and re-run T1 (only page 121h may differ: expected, and reported as such).
;  T3  VRAM 128 KB: write a pattern through port 98h, read it back.
;  T5  (v2) every page cart -> VRAM by an unrolled OUTI chain in SCREEN 5 with the
;      display off, as Neon draws; read back through 98h, checked against the table.
;      Pass 1 at Neon's 18 T per byte, pass 2 at ~70 T: fast-only errors are timing,
;      errors in both are data.
;  T4  mapper RAM segments 4..N-1 (page 2, N found by wrap): pattern write/read.
;  T6  (v3) byte writes in mapper RAM must leave the neighbour byte intact (DQM).
;  T7  (v4) decompressor RAM patterns: overlapping LDIR, back-reference copies.
;  T8  (v4) cart pages 104h/105h shown in SCREEN 5 for 12 s, VRAM re-verified
;      every second with the display on.
;  T9  (v5) Neon's interpreter pattern: bank write to 7000h/7100h then at once
;      512 bytes OUTIed from the 8000h window; checked against slow cart reads.
;  Reset the machine afterwards (T3 overwrites the screen, T4 DOS2 segments).

CHPUT   equ 00A2h
RDSLT   equ 000Ch
ENASLT  equ 0024h
INITXT  equ 006Ch
EXPTBL  equ 0FCC1h

        org 0C000h
start:
        ; the stack: CLEAR 200,&HBFFF put BASIC's at ~BD16h, in page 2 -- T4/T6 map
        ; test segments there and a push on their mismatch path landed on the data
        ; under test (seen as 1 bad byte per segment in the T6NEG control).  Page 3.
        ld (savsp),sp
        ld sp,0EF00h
        call main
        ld sp,(savsp)
        ret
main:
        ; turbo R: run as Z80 (the A1F/A1FX show the corruption too)
        ld a,(002Dh) : cp 3 : jr c,.noturbo
        ld a,80h : call 0180h
.noturbo:
        call t3                 ; VRAM first: it ends with INITXT (clears the screen)
        call findcart
        jr nc,.found
        ld hl,s_title : call puts
        ld hl,s_nocart : call puts
        ret
.found:
        ld (cartslot),a
        ld a,1 : ld (pass),a : call t5 : ld (bad5a),hl
        ld a,2 : ld (pass),a : call t5 : ld (bad5b),hl
        call INITXT
        ld hl,s_title : call puts
        ld hl,s_t3r : call puts
        ld hl,(vbad) : call phex16 : call crlf
        ld hl,s_slot : call puts
        ld a,(cartslot) : call phex : call crlf
        ld a,1 : ld (pass),a : call t1 : ld (bad1),hl
        ld a,2 : ld (pass),a : call t1 : ld (bad2),hl
        call t2
        ld a,3 : ld (pass),a : call t1 : ld (bad3),hl
        call t4
        call t6
        call t7
        call t9
        call t8
        ; summary
        ld hl,s_sum9 : call puts
        ld hl,(bad9) : call phex16 : ld a,'/' : call CHPUT
        ld hl,(first9) : call phex16 : call crlf
        ld hl,s_sum8 : call puts
        ld a,(bad8) : call phex : ld a,'/' : call CHPUT
        ld a,(first8) : call phex : call crlf
        ld hl,s_sum7 : call puts
        ld hl,(bad7a) : call phex16 : ld a,' ' : call CHPUT
        ld hl,(bad7b) : call phex16 : ld a,' ' : call CHPUT
        ld hl,(bad7c) : call phex16 : call crlf
        ld hl,s_sum6 : call puts
        ld hl,(bad6a) : call phex16 : ld a,' ' : call CHPUT
        ld hl,(bad6b) : call phex16 : ld a,' ' : call CHPUT
        ld hl,(bad6c) : call phex16 : call crlf
        ld hl,s_sum5 : call puts
        ld hl,(bad5a) : call phex16 : ld a,' ' : call CHPUT
        ld hl,(bad5b) : call phex16 : call crlf
        ld hl,s_sum : call puts
        ld hl,(bad1) : call phex16 : ld a,' ' : call CHPUT
        ld hl,(bad2) : call phex16 : ld a,' ' : call CHPUT
        ld hl,(bad3) : call phex16 : call crlf
        ld hl,s_sum2 : call puts
        ld a,(t2before) : call phex : ld a,' ' : call CHPUT
        ld a,(t2after) : call phex : ld a,' ' : call CHPUT
        ld a,(t2next) : call phex : call crlf
        ld hl,s_sum3 : call puts
        ld hl,(vbad) : call phex16 : ld a,' ' : call CHPUT
        ld hl,(rbad) : call phex16 : ld a,'/' : call CHPUT
        ld a,(nseg) : call phex : call crlf
        call t5list
        ld hl,s_done : call puts
        ret

; ---------------------------------------------------------------------------
; find the slot whose 4010h reads "ASCII16X"  -> A = slot id, CF=0
findcart:
        ld b,0                  ; primary
.prim:
        ld a,b : ld e,a : ld d,0
        ld hl,EXPTBL : add hl,de
        ld a,(hl) : and 80h
        or b
        ld c,a                  ; slot id with expanded flag
        bit 7,a
        jr z,.one
        ld d,0                  ; secondary loop
.sec:
        ld a,d : add a,a : add a,a : or c
        push bc : push de
        call chksig
        pop de : pop bc
        ret nc
        inc d : ld a,d : cp 4 : jr nz,.sec
        jr .next
.one:
        ld a,c
        push bc
        call chksig
        pop bc
        ret nc
.next:
        inc b : ld a,b : cp 4 : jr nz,.prim
        scf
        ret
; A = slot id; CF=0 if signature matches, A preserved
chksig:
        ld (tmpslot),a
        ld hl,4010h : ld de,sig : ld b,8
.l:     push bc : push de : push hl
        ld a,(tmpslot) : call RDSLT
        pop hl : pop de : pop bc
        ld c,a : ld a,(de) : cp c
        jr nz,.no
        inc hl : inc de : djnz .l
        ei
        ld a,(tmpslot) : or a   ; CF=0
        ret
.no:    ei
        scf
        ret
sig:    db "ASCII16X"

; ---------------------------------------------------------------------------
; select cart bank A(lo) with high bit in E (0/1) into the 4000h window
setbank:
        push hl
        ld h,60h : ld l,0
        bit 0,e : jr z,.b
        ld h,61h
.b:     ld (hl),a
        pop hl
        ret

cart_on:
        di
        ld a,(cartslot) : ld h,40h : call ENASLT
        di
        ret
cart_off:
        ld a,(EXPTBL) : ld h,40h : call ENASLT
        ei
        ret

; checksum 4000h-7FFFh -> HL = sum16, C = xor8
cksum:
        ld hl,0 : ld c,0 : ld de,4000h
.l:     ld a,(de)
        ld b,a
        xor c : ld c,a
        ld a,b
        add a,l : ld l,a
        jr nc,.n
        inc h
.n:     inc e
        jr nz,.l
        inc d
        ld a,d : cp 80h
        jr nz,.l
        ret

; T1: all 512 pages against tbl (3 bytes per page: sumlo sumhi xor)
t1:
        ld hl,s_t1 : call puts
        ld a,(pass) : add a,'0' : call CHPUT : call crlf
        ld hl,0 : ld (bad),hl
        ld hl,0 : ld (pg),hl
.page:
        call cart_on
        ld hl,(pg)
        ld a,l : ld e,h : call setbank
        call cksum              ; HL sum, C xor
        push bc : push hl
        call cart_off
        ; tbl entry = tbl + 3*pg
        ld hl,(pg) : ld d,h : ld e,l : add hl,hl : add hl,de
        ld de,tbl : add hl,de
        ex de,hl                ; DE -> entry
        pop hl : pop bc
        ld (gotsum),hl : ld a,c : ld (gotxor),a
        ld a,(de) : cp l : jr nz,.bad
        inc de : ld a,(de) : cp h : jr nz,.bad
        inc de : ld a,(de) : cp c : jr nz,.bad
        jr .ok
.bad:
        ld hl,(bad) : inc hl : ld (bad),hl
        ld a,h : or a : jr nz,.ok
        ld a,l : cp 7 : jr nc,.ok           ; list the first 6
        ld hl,s_pg : call puts
        ld hl,(pg) : call phex16
        ld a,' ' : call CHPUT
        ld hl,(gotsum) : call phex16
        ld a,'/' : call CHPUT
        ld a,(gotxor) : call phex
        call crlf
.ok:
        ld hl,(pg)
        ld a,l : and 0Fh : jr nz,.nodot
        ld a,'.' : call CHPUT
.nodot:
        inc hl : ld (pg),hl
        ld a,h : cp 2 : jp nz,.page
        call crlf
        ld hl,s_bad : call puts
        ld hl,(bad) : call phex16 : call crlf
        ld hl,(bad)
        ret

; ---------------------------------------------------------------------------
; T5: the way Neon draws -- cart page -> VRAM through an unrolled OUTI chain (one
; cart read every 18 T, code fetched in between), VRAM address set as the game's
; RAM routine does (R#14, low, high|40h under DI).  Eight 16 KB pages fill VRAM,
; then each is read back through port 98h and checked against tbl.  64 rounds.
t5:
        ; SCREEN 5, display off -- the mode Neon draws its pictures in (R#0 = 06h,
        ; R#1 = 22h).  In SCREEN 0 an 18 T OUTI chain loses ~4% of its writes even
        ; with the display off (openMSX 2026 slot model, measured on hardware); the
        ; release core draws Neon correctly in this mode, so a mismatch here is the
        ; cart read path, not the VDP.  RG0SAV/RG1SAV are left alone: INITXT restores.
        di
        ld a,06h : out (99h),a : ld a,80h : out (99h),a
        ld a,20h : out (99h),a : ld a,81h : out (99h),a
        ei
        ld hl,0 : ld (bad),hl
        ld hl,0 : ld (pg),hl
.round:
        ld b,0                  ; k = VRAM bank 0..7
.wk:    push bc
        call cart_on            ; ENASLT clobbers BC
        pop bc : push bc
        ld hl,(pg) : ld a,b : add a,l : ld l,a
        ld a,l : ld e,h : call setbank
        pop bc : push bc
        ld a,b : ld hl,0 : call vset_w
        ; DI for the chain: the BIOS ISR moved the VRAM pointer (openMSX, one
        ; byte lost per interrupt); the question here is the cart read path
        ld hl,4000h : ld c,98h
        ld d,64
        ld a,(pass) : cp 2 : jr z,.slow
.ch:    call outi256            ; pass 1: 18 T per byte, as Neon
        dec d : jr nz,.ch
        jr .wdone
.slow:  call outi256s           ; pass 2: ~70 T per byte
        dec d : jr nz,.slow
.wdone:
        ei
        call cart_off
        pop bc
        inc b : ld a,b : cp 8 : jr nz,.wk
        ; verify the eight pages
        ld b,0
.vk:    push bc
        di
        ld a,b : call vaddr_r
        call vsum               ; HL sum, C xor
        ei
        ld (gotsum),hl : ld a,c : ld (gotxor),a
        pop bc : push bc
        ld hl,(pg) : ld a,b : add a,l : ld l,a
        ld (cur5),hl
        ld d,h : ld e,l : add hl,hl : add hl,de
        ld de,tbl : add hl,de
        ld de,(gotsum)
        ld a,(hl) : cp e : jr nz,.bad
        inc hl : ld a,(hl) : cp d : jr nz,.bad
        inc hl : ld a,(gotxor) : cp (hl) : jr z,.ok
.bad:   ld hl,(bad) : inc hl : ld (bad),hl
        ld a,h : or a : jr nz,.ok
        ld a,l : cp 5 : jr nc,.ok       ; keep the first 4 per pass
        dec a : add a,a : add a,a      ; 4 bytes per entry: pass, pg lo/hi, xor-ish
        ld e,a : ld d,0
        ld hl,(pass) : ld a,l
        ld hl,(listp) : add hl,de
        ld (hl),a : inc hl
        ld de,(cur5) : ld (hl),e : inc hl : ld (hl),d : inc hl
        ld a,(gotxor) : ld (hl),a
.ok:    pop bc
        inc b : ld a,b : cp 8 : jr nz,.vk
        ld hl,(pg) : ld de,8 : add hl,de : ld (pg),hl
        ld a,h : cp 2 : jp nz,.round
        ld a,(pass) : cp 1 : jr nz,.p2
        ld hl,list5b : ld (listp),hl
.p2:    ld hl,(bad)
        ret
; VRAM write address A:HL (A = 16 KB bank), as the game: DI, R#14, low, high|40h, EI
vset_w:
        di
        out (99h),a : ld a,8Eh : out (99h),a
        ld a,l : out (99h),a
        ld a,h : and 3Fh : or 40h : out (99h),a
        ret
; sum16/xor8 of 16 KB from port 98h
vsum:   ld hl,0 : ld c,0 : ld de,4000h
.l:     in a,(98h)
        ld b,a
        xor c : ld c,a
        ld a,b
        add a,l : ld l,a
        jr nc,.n
        inc h
.n:     dec de
        ld a,d : or e : jr nz,.l
        ret
outi256:
        rept 256
        outi
        endr
        ret
outi256s:                       ; ~70 T per byte (B counts 256 down to 0)
        ld b,0
.l:     outi
        nop : nop : nop : nop : nop : nop : nop : nop
        jp nz,.l
        ret
; print the kept T5 entries
t5list:
        ld hl,list5a : ld b,8
.l:     ld a,(hl) : or a : jr z,.n
        push bc : push hl
        push hl : ld hl,s_t5e : call puts : pop hl
        ld a,(hl) : add a,'0' : call CHPUT : ld a,' ' : call CHPUT
        inc hl : ld e,(hl) : inc hl : ld d,(hl) : ex de,hl : call phex16
        call crlf
        pop hl : pop bc
.n:     inc hl : inc hl : inc hl : inc hl
        djnz .l
        ret

; T2: Neon's flash byte-program at cart address 484000h (bank 121h, offset 0)
t2:
        ld hl,s_t2 : call puts
        call cart_on
        ld e,1 : ld a,21h : call setbank
        ld a,(4000h) : ld (t2before),a
        ld a,0AAh : ld (4AAAh),a
        ld a,055h : ld (4555h),a
        ld a,0A0h : ld (4AAAh),a
        ld a,045h : ld (4000h),a
        ld b,0                  ; let the SDRAM write land
.w:     djnz .w
        ld a,(4000h) : ld (t2after),a
        ld a,(4001h) : ld (t2next),a
        call cart_off
        ld hl,s_before : call puts : ld a,(t2before) : call phex
        ld hl,s_after : call puts : ld a,(t2after) : call phex
        ld hl,s_next : call puts : ld a,(t2next) : call phex
        call crlf
        ld hl,s_t2exp : call puts
        ret

; T3: VRAM 128 KB pattern  byte(a) = lo(a) xor hi(a) xor (a>>14)*35h
t3:
        di
        ld b,0                  ; b = 16 KB bank 0..7
.wb:    push bc
        ld a,b : call vaddr_w
        pop bc : push bc
        call pat_k              ; C = bank constant
        ld de,0
.wl:    ld a,e : xor d : xor c
        out (98h),a
        inc de
        ld a,d : cp 40h : jr nz,.wl
        pop bc
        inc b : ld a,b : cp 8 : jr nz,.wb
        ld hl,0 : ld (bad),hl
        ld b,0
.rb:    push bc
        ld a,b : call vaddr_r
        pop bc : push bc
        call pat_k
        ld de,0
.rl:    in a,(98h)
        ld h,a
        ld a,e : xor d : xor c
        cp h
        jr z,.rok
        push hl : ld hl,(bad) : inc hl : ld (bad),hl : pop hl
.rok:   inc de
        ld a,d : cp 40h : jr nz,.rl
        pop bc
        inc b : ld a,b : cp 8 : jr nz,.rb
        ei
        ld hl,(bad) : ld (vbad),hl
        call INITXT
        ret
pat_k:  ld a,b : ld c,0
.k:     or a : ret z
        push af : ld a,c : add a,35h : ld c,a : pop af
        dec a : jr .k
; A = 16 KB VRAM bank: R#14 = A, address 0, write / read
vaddr_w:
        out (99h),a : ld a,8Eh : out (99h),a
        xor a : out (99h),a : ld a,40h : out (99h),a
        ret
vaddr_r:
        out (99h),a : ld a,8Eh : out (99h),a
        xor a : out (99h),a : out (99h),a
        ret

; T4: mapper segments 4..N-1 through page 2 (8000h), byte = lo xor hi xor seg.
; N = the first segment >= 4 whose first 16 bytes equal segment 0's (this program
; at C000h): the mapper wraps there.  Found by reading only.
t4:
        ld hl,s_t4 : call puts
        di
        ld b,4
.sz:    ld a,b : out (0FEh),a
        ld hl,8000h : ld de,0C000h : ld c,16
.cmp:   ld a,(de) : cp (hl) : jr nz,.diff
        inc hl : inc de : dec c : jr nz,.cmp
        jr .gotn                ; wrapped: B = segment count
.diff:  inc b : jr nz,.sz       ; up to 255
        dec b
.gotn:  ld a,b : ld (nseg),a
        ld b,4
        ld a,(nseg) : cp 5 : jp c,.none
.ws:    ld a,b : out (0FEh),a
        ld hl,8000h
.wl:    ld a,l : xor h : xor b : ld (hl),a
        inc hl : ld a,h : cp 0C0h : jr nz,.wl
        inc b : ld a,(nseg) : cp b : jr nz,.ws
        ld hl,0 : ld (bad),hl
        ld b,4
.rs:    ld a,b : out (0FEh),a
        ld hl,8000h
.rl:    ld a,l : xor h : xor b : cp (hl)
        jr z,.ok
        push hl : ld hl,(bad) : inc hl : ld (bad),hl : pop hl
.ok:    inc hl : ld a,h : cp 0C0h : jr nz,.rl
        inc b : ld a,(nseg) : cp b : jr nz,.rs
.none:  ld a,1 : out (0FEh),a
        ei
        ld hl,s_t4n : call puts
        ld a,(nseg) : call phex : call crlf
        ld hl,s_t4r : call puts
        ld hl,(bad) : call phex16 : call crlf
        ld hl,(bad) : ld (rbad),hl
        ret

; ---------------------------------------------------------------------------
; T6: byte writes must not touch their neighbour.  A CPU byte write is a 16-bit
; SDRAM write with the other byte masked by DQM (sdram_tdm: DQM = A[12:11], write
; latency 0); T4 wrote both bytes of every word in order, which hides a mask
; failure.  Mapper segments 4..N-1 in page 2: fill with P1 (lo^hi^5Ah), rewrite
; the EVEN bytes only with ~P1, verify (odd must still be P1, even ~P1); then the
; same with the ODD bytes.  Counts: evwr = even-write errors, odd-victim = odd
; bytes changed by even writes, ev-victim = even bytes changed by odd writes.
t6:
        ld hl,0 : ld (bad6a),hl : ld (bad6b),hl : ld (bad6c),hl
        ld a,(nseg) : cp 5 : ret c
        di
        ld b,4
.seg:   ld a,b : out (0FEh),a
        ; fill P1
        ld hl,8000h
.f:     ld a,l : xor h : xor 5Ah : ld (hl),a
        inc hl : ld a,h : cp 0C0h : jr nz,.f
        ; even bytes <- ~P1 (19 T apart)
        ld hl,8000h
.e:     ld a,l : xor h : xor 5Ah : cpl
        IFDEF T6NEG
        ld (hl),a : inc hl : ld (hl),a : inc hl   ; negative control: clobber the neighbour
        ELSE
        ld (hl),a : inc hl : inc hl
        ENDIF
        ld a,h : cp 0C0h : jr nz,.e
        ; verify
        ld hl,8000h
.v1:    ld a,l : xor h : xor 5Ah : cpl : cp (hl) : jr z,.v1a
        push hl : ld hl,(bad6a) : inc hl : ld (bad6a),hl : pop hl
.v1a:   inc hl
        ld a,l : xor h : xor 5Ah : cp (hl) : jr z,.v1b
        push hl : ld hl,(bad6b) : inc hl : ld (bad6b),hl : pop hl
.v1b:   inc hl : ld a,h : cp 0C0h : jr nz,.v1
        ; odd bytes <- ~P1, even bytes (now ~P1) must survive
        ld hl,8001h
.o:     ld a,l : xor h : xor 5Ah : cpl
        ld (hl),a : inc hl : inc hl
        ld a,h : cp 0C0h : jr nz,.o
        ld hl,8000h
.v2:    ld a,l : xor h : xor 5Ah : cpl : cp (hl) : jr z,.v2a
        push hl : ld hl,(bad6c) : inc hl : ld (bad6c),hl : pop hl
.v2a:   inc hl : ld a,h : cp 0C0h : jr nz,.v2
        inc b : ld a,(nseg) : cp b : jr nz,.seg
        ld a,1 : out (0FEh),a
        ei
        ld hl,s_t6 : call puts
        ld hl,(bad6a) : call phex16 : ld a,' ' : call CHPUT
        ld hl,(bad6b) : call phex16 : ld a,' ' : call CHPUT
        ld hl,(bad6c) : call phex16 : call crlf
        ret

; ---------------------------------------------------------------------------
; T7: the RAM patterns of a decompressor (Neon unpacks its pictures into RAM and
; draws from there).  Mapper segments 4..7 in page 2.
;  A) overlapping LDIR (RLE expansion): k seed bytes at 8000h, then LDIR
;     HL=8000h DE=8000h+k BC=1000h-k -- every byte read was written k bytes (k
;     iterations, 21 T each) earlier.  Verify (HL) == (HL-k).  k = 1,2,3,5,8,13,21,64.
;  B) back-reference copies: 256 x LDIR src=8000h+16*r dst=A000h+32*i len=(r&31)+1
;     (r = a program byte), compared with the source immediately after the copy
;     and once more after all 256.
; Counts: ovl = A mismatches, bref = B immediate, late = B re-check.
t7:
        ld hl,0 : ld (bad7a),hl : ld (bad7b),hl : ld (bad7c),hl
        ld a,(nseg) : cp 8 : ret c
        di
        ld b,4
.seg:   ld a,b : out (0FEh),a
        push bc
        ; ---- A ----
        ld ix,klist
.k:     ld a,(ix) : or a : jr z,.adone
        ld c,a                  ; k
        ld hl,8000h : ld de,0C000h : ld b,c
.seed:  ld a,(de) : xor l : ld (hl),a : inc hl : inc de : djnz .seed
        ld hl,1000h : ld e,c : ld d,0 : or a : sbc hl,de
        ld b,h : ld c,l                        ; BC = 1000h - k
        push bc
        ld hl,8000h : ld d,80h : ld e,(ix)      ; DE = 8000h + k
        ldir
        ; verify (DE) == (HL) over the copied range, DE = HL + k
        pop bc
        ld hl,8000h : ld d,80h : ld e,(ix)
.vl:    ld a,(de) : cp (hl) : jr z,.vok
        push hl : ld hl,(bad7a) : inc hl : ld (bad7a),hl : pop hl
.vok:   inc hl : inc de : dec bc : ld a,b : or c : jr nz,.vl
        inc ix : jr .k
.adone:
        ; ---- B ----
        ld ix,0C000h            ; r source
        ld hl,0A000h : ld (dst7),hl
        ld b,0
.bl:    push bc
        ld a,(ix) : inc ix
        ld e,a : ld d,0
        ld hl,8000h : add hl,de : add hl,de : add hl,de : add hl,de
        add hl,de : add hl,de : add hl,de : add hl,de
        add hl,de : add hl,de : add hl,de : add hl,de
        add hl,de : add hl,de : add hl,de : add hl,de   ; HL = 8000h + 16*r
        ld (src7),hl
        and 31 : inc a : ld c,a : ld b,0 : ld (len7),bc
        ld de,(dst7)
        push hl : push de
        ldir
        IFDEF T7NEG
        pop de : push de : ld a,(de) : cpl : ld (de),a   ; negative control: clobber dst[0]
        ENDIF
        pop de : pop hl
        ld bc,(len7)
.cmp:   ld a,(de) : cp (hl) : jr z,.cok
        push hl : ld hl,(bad7b) : inc hl : ld (bad7b),hl : pop hl
.cok:   inc hl : inc de : dec bc : ld a,b : or c : jr nz,.cmp
        ld hl,(dst7) : ld de,32 : add hl,de : ld (dst7),hl
        pop bc
        djnz .bl
        ; re-check all 256 copies
        ld ix,0C000h
        ld hl,0A000h : ld (dst7),hl
        ld b,0
.rl:    push bc
        ld a,(ix) : inc ix
        ld e,a : ld d,0
        ld hl,8000h : add hl,de : add hl,de : add hl,de : add hl,de
        add hl,de : add hl,de : add hl,de : add hl,de
        add hl,de : add hl,de : add hl,de : add hl,de
        add hl,de : add hl,de : add hl,de : add hl,de
        and 31 : inc a : ld c,a : ld b,0
        ld de,(dst7)
.rcmp:  ld a,(de) : cp (hl) : jr z,.rok
        push hl : ld hl,(bad7c) : inc hl : ld (bad7c),hl : pop hl
.rok:   inc hl : inc de : dec bc : ld a,b : or c : jr nz,.rcmp
        ld hl,(dst7) : ld de,32 : add hl,de : ld (dst7),hl
        pop bc
        djnz .rl
        pop bc
        inc b : ld a,b : cp 8 : jp nz,.seg
        ld a,1 : out (0FEh),a
        ei
        ld hl,s_t7 : call puts
        ld hl,(bad7a) : call phex16 : ld a,' ' : call CHPUT
        ld hl,(bad7b) : call phex16 : ld a,' ' : call CHPUT
        ld hl,(bad7c) : call phex16 : call crlf
        ret
klist:  db 1,2,3,5,8,13,21,64,0

; ---------------------------------------------------------------------------
; T8: a picture shown.  Cart pages 104h/105h (Neon's packed picture data: noise,
; every pixel counts) -> VRAM 0000h-7FFFh by the T5 chain, SCREEN 5 page 0, then
; the display is turned ON for ~12 s (screenshot it) while the 32 KB is re-read
; through port 98h every second and checked against the table.
; bad8 = passes (of 12) with a mismatch, first8 = first such pass (FF = none).
t8:
        xor a : ld (bad8),a : ld a,0FFh : ld (first8),a
        di
        ld a,06h : out (99h),a : ld a,80h : out (99h),a      ; SCREEN 5
        ld a,20h : out (99h),a : ld a,81h : out (99h),a      ; display off
        ld a,1Fh : out (99h),a : ld a,82h : out (99h),a      ; page 0
        ld b,0
.wk:    push bc
        call cart_on
        pop bc : push bc
        ld a,b : add a,4 : ld e,1 : call setbank              ; page 104h+b
        pop bc : push bc
        ld a,b : ld hl,0 : call vset_w
        ld hl,4000h : ld c,98h : ld d,64
.ch:    call outi256
        dec d : jr nz,.ch
        ei
        call cart_off
        pop bc
        inc b : ld a,b : cp 2 : jr nz,.wk
        IFDEF T8NEG
        di                                                   ; negative control: one VRAM byte off
        xor a : ld hl,1234h : call vset_w
        ld a,0A5h : out (98h),a
        ei
        ENDIF
        di
        ld a,60h : out (99h),a : ld a,81h : out (99h),a      ; display ON
        ei
        ld b,12
.pass:  push bc
        call wait1s
        pop bc : push bc
        ld a,12 : sub b : ld (pass),a                         ; 0..11
        di
        ld c,0                  ; c = bad flag
        ld b,0
.vk:    push bc
        ld a,b : call vaddr_r
        call vsum
        ld (gotsum),hl : ld a,c : ld (gotxor),a
        pop bc : push bc
        ld hl,104h : ld a,b : add a,l : ld l,a
        ld d,h : ld e,l : add hl,hl : add hl,de
        ld de,tbl : add hl,de
        ld de,(gotsum)
        ld a,(hl) : cp e : jr nz,.bad
        inc hl : ld a,(hl) : cp d : jr nz,.bad
        inc hl : ld a,(gotxor) : cp (hl) : jr z,.ok
.bad:   pop bc : ld c,1 : push bc
.ok:    pop bc
        inc b : ld a,b : cp 2 : jr nz,.vk
        ei
        ld a,c : or a : jr z,.pok
        ld a,(bad8) : inc a : ld (bad8),a
        ld a,(first8) : inc a : jr nz,.pok
        ld a,(pass) : ld (first8),a
.pok:   pop bc
        djnz .pass
        di
        ld a,20h : out (99h),a : ld a,81h : out (99h),a
        ei
        call INITXT
        ld hl,s_t8 : call puts
        ld a,(bad8) : call phex : ld a,'/' : call CHPUT
        ld a,(first8) : call phex : call crlf
        ret
wait1s: ld de,0
.w:     dec de : ld a,d : or e : jr nz,.w          ; 65536 x 24 T = 0.44 s
        ld de,0
.w2:    dec de : ld a,d : or e : jr nz,.w2
        ret

; ---------------------------------------------------------------------------
; T9: Neon's draw interpreter (code at 3065h in its RAM): it stores the new bank
; in a RAM variable, writes it to 7100h (8000h window, banks 100h+) and fetches its
; next stream byte from the new bank a few cycles later, then OUTIs data to VRAM.
; Here: pages 1 and 2 both on the cart; for every bank b (all 512) a RAM write,
; the bank write at 7000h/7100h, and at once 512 bytes from 8000h+(b&31)*512
; OUTIed to VRAM; 32 banks fill one 16 KB VRAM bank, which is then compared byte
; for byte with the cart read back slowly through the 4000h window (T1 proved
; those reads).  bad9 = differing bytes, first9 = first bank with a difference.
t9:
        ld hl,0 : ld (bad9),hl : ld hl,0FFFFh : ld (first9),hl
        di
        ld a,06h : out (99h),a : ld a,80h : out (99h),a      ; SCREEN 5, display off
        ld a,20h : out (99h),a : ld a,81h : out (99h),a
        ld hl,0 : ld (pg),hl                                 ; first bank of the group
.grp:   ; ---- write: 32 banks -> VRAM bank (pg>>5)&7 ----
        call cart12_on
        ld a,(pg) : rrca : rrca : rrca : rrca : rrca : and 7
        ld hl,0 : call vset_w
        ld b,32
.wb:    push bc
        ld hl,(pg) : ld a,32 : sub b : add a,l : ld l,a      ; bank = pg + (32-b)
        ld (cur9),hl
        ld a,l : ld (scratch9),a                             ; the game's RAM variable write
        ld a,h : or 70h : ld d,a : ld e,0                    ; 7000h / 7100h
        ld a,l : ld (de),a                                   ; bank -> 8000h window
        ld a,l : and 1Fh : add a,a : or 80h : ld h,a : ld l,0 ; 8000h + (b&31)*512
        ld c,98h
        call outi256 : call outi256
        IFDEF T9NEG
        ld a,(cur9) : and 3Fh : jr nz,.nn                    ; negative control: every 64th
        ld a,0A5h : out (98h),a                              ; bank one extra byte (shifts the rest)
.nn:
        ENDIF
        pop bc
        djnz .wb
        call cart12_off
        ; ---- verify the VRAM bank against slow cart reads ----
        ld a,(pg) : rrca : rrca : rrca : rrca : rrca : and 7
        call vaddr_r
        ld b,32
.vb:    push bc
        ld hl,(pg) : ld a,32 : sub b : add a,l : ld l,a
        ld (cur9),hl
        call cart_on
        ld hl,(cur9) : ld a,l : ld e,h : call setbank        ; same bank, 4000h window
        ld a,l : and 1Fh : add a,a : or 40h : ld h,a : ld l,0 ; 4000h + (b&31)*512
        ld de,512
.vl:    in a,(98h) : cp (hl) : jr z,.vok
        push hl : ld hl,(bad9) : inc hl : ld (bad9),hl
        ld hl,(first9) : inc hl : ld a,h : or l : jr nz,.vnf
        ld hl,(cur9) : ld (first9),hl
.vnf:   pop hl
.vok:   inc hl : dec de : ld a,d : or e : jr nz,.vl
        call cart_off
        di
        pop bc
        djnz .vb
        ld hl,(pg) : ld de,32 : add hl,de : ld (pg),hl
        ld a,h : cp 2 : jp nz,.grp
        ei
        ld hl,s_t9 : call puts
        ld hl,(bad9) : call phex16 : ld a,'/' : call CHPUT
        ld hl,(first9) : call phex16 : call crlf
        ret
; pages 1 and 2 on the cart (DI held); back to BASIC ROM / RAM
cart12_on:
        di
        ld a,(cartslot) : ld h,40h : call ENASLT
        ld a,(cartslot) : ld h,80h : call ENASLT
        di
        ret
cart12_off:
        ld a,(EXPTBL) : ld h,40h : call ENASLT
        ld a,(0F343h) : ld h,80h : call ENASLT                ; RAMAD2
        di
        ret

; ---------------------------------------------------------------------------
puts:   ld a,(hl) : or a : ret z
        call CHPUT : inc hl : jr puts
crlf:   ld a,13 : call CHPUT : ld a,10 : jp CHPUT
phex16: ld a,h : call phex : ld a,l
phex:   push af : rrca : rrca : rrca : rrca : call .n : pop af
.n:     and 0Fh : add a,'0' : cp '9'+1 : jr c,.o : add a,7
.o:     jp CHPUT

s_title: db "NHTEST 5 - Neon Horizon / sdram128",13,10,0
s_nocart: db "No ASCII16X cart found (load NHTEST.ROM)",13,10,0
s_slot:  db "cart slot ",0
s_t1:    db "T1 cart 8MB pass ",0
s_pg:    db " BAD pg ",0
s_bad:   db "bad pages: ",0
s_t2:    db "T2 flash program 484000h",13,10,0
s_before: db " before ",0
s_after: db " after ",0
s_next:  db " next ",0
s_t2exp: db " expect before FF after 45 next FF",13,10
         db " pass 3: only pg 0121 may be BAD",13,10,0
s_t3:    db "T3 VRAM 128KB",13,10,0
s_t3r:   db "T3 VRAM bad bytes: ",0
s_t4:    db "T4 mapper RAM",13,10,0
s_t4n:   db " segments: ",0
s_t4r:   db "T4 RAM bad bytes: ",0
s_t7:    db "T7 RAM ovl/bref/late: ",0
s_sum7:  db "SUM T7 ovl/bref/late: ",0
s_t9:    db "T9 bankswitch+OUTI bad/first: ",0
s_sum9:  db "SUM T9 bnksw bad/first: ",0
s_t8:    db "T8 disp-on bad passes/first: ",0
s_sum8:  db "SUM T8 dispon bad/first: ",0
s_t6:    db "T6 bytewr ev/oddvic/evvic: ",0
s_sum6:  db "SUM T6 ev/oddv/evv: ",0
s_sum5:  db "SUM T5 OUTI fast/slow: ",0
s_t5e:   db " T5 BAD pass/pg ",0
s_sum:   db "SUM T1 bad p1 p2 p3: ",0
s_sum2:  db "SUM T2 bef/aft/nxt: ",0
s_sum3:  db "SUM T3 VRAM, T4 RAM/seg: ",0
s_done:  db "DONE - please reset",13,10,0

cartslot: db 0
bad9:   dw 0
first9: dw 0
cur9:   dw 0
scratch9: db 0
bad7a:  dw 0
bad7b:  dw 0
bad7c:  dw 0
src7:   dw 0
dst7:   dw 0
len7:   dw 0
bad8:   db 0
first8: db 0
savsp:  dw 0
bad6a:  dw 0
bad6b:  dw 0
bad6c:  dw 0
bad5a:  dw 0
bad5b:  dw 0
cur5:   dw 0
listp:  dw list5a
list5a: ds 16
list5b: ds 16
nseg:   db 0
tmpslot: db 0
pass:   db 0
pg:     dw 0
bad:    dw 0
gotsum: dw 0
bad1:   dw 0
bad2:   dw 0
bad3:   dw 0
vbad:   dw 0
rbad:   dw 0
gotxor: db 0
t2before: db 0
t2after: db 0
t2next: db 0
tbl:    incbin "nhtbl.bin"
endprog:
