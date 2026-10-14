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
;  T4  mapper RAM segments 4..N-1 (page 2, N found by wrap): pattern write/read.
;  Reset the machine afterwards (T3 overwrites the screen, T4 DOS2 segments).

CHPUT   equ 00A2h
RDSLT   equ 000Ch
ENASLT  equ 0024h
INITXT  equ 006Ch
EXPTBL  equ 0FCC1h

        org 0C000h
start:
        call t3                 ; VRAM first: it ends with INITXT (clears the screen)
        ld hl,s_title : call puts
        ld hl,s_t3r : call puts
        ld hl,(vbad) : call phex16 : call crlf
        call findcart
        jr nc,.found
        ld hl,s_nocart : call puts
        ret
.found:
        ld (cartslot),a
        ld hl,s_slot : call puts
        ld a,(cartslot) : call phex : call crlf
        ld a,1 : ld (pass),a : call t1 : ld (bad1),hl
        ld a,2 : ld (pass),a : call t1 : ld (bad2),hl
        call t2
        ld a,3 : ld (pass),a : call t1 : ld (bad3),hl
        call t4
        ; summary
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
puts:   ld a,(hl) : or a : ret z
        call CHPUT : inc hl : jr puts
crlf:   ld a,13 : call CHPUT : ld a,10 : jp CHPUT
phex16: ld a,h : call phex : ld a,l
phex:   push af : rrca : rrca : rrca : rrca : call .n : pop af
.n:     and 0Fh : add a,'0' : cp '9'+1 : jr c,.o : add a,7
.o:     jp CHPUT

s_title: db "NHTEST 1 - Neon Horizon / sdram128",13,10,0
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
s_sum:   db "SUM T1 bad p1 p2 p3: ",0
s_sum2:  db "SUM T2 bef/aft/nxt: ",0
s_sum3:  db "SUM T3 VRAM, T4 RAM/seg: ",0
s_done:  db "DONE - please reset",13,10,0

cartslot: db 0
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
