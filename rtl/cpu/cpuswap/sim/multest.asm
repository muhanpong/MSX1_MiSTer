;  R800 MULUB / MULUW on NextZ80 (a Z80 runs these as NOPs, so this test is not
;  part of the lockstep comparison).  Every case preloads F from a known byte,
;  runs the multiply, and reports the result and F through OUT:
;     10h H   11h L   12h F        (MULUB)
;     13h D   14h E   then H, L, F (MULUW)
;  gen_mulref.py produces the expected log.  OUT (0FFh) ends the run.
        DEVICE NOSLOT64K
        ORG 0
;  Page 0 belongs to the turbo R BIOS overlay in the bench (002Dh reads back as 03h,
;  0180h-018Bh as the CHGCPU/GETCPU stubs), so the test itself lives at 8000h.
        jp start

        ORG 8000h
start:
        nop                     ; the bench hands the bus to NextZ80 at the first swap point
        ld sp,0D000h

;  set A and F: push {A, F} and pop af
setaf   macro mval, fval
        ld h,mval
        ld l,fval
        push hl
        pop af
        endm

report3 macro                   ; H, L, F
        ld a,h
        out (10h),a
        ld a,l
        out (11h),a
        push af
        pop hl
        ld a,l
        out (12h),a
        endm

report5 macro                   ; D, E, then H, L, F
        ld a,d
        out (13h),a
        ld a,e
        out (14h),a
        report3
        endm

mulub_b macro aval, rval, fval  ; ED C1
        ld b,rval
        setaf aval, fval
        db 0EDh,0C1h
        report3
        endm

mulub_c macro aval, rval, fval  ; ED C9
        ld c,rval
        setaf aval, fval
        db 0EDh,0C9h
        report3
        endm

mulub_d macro aval, rval, fval  ; ED D1
        ld d,rval
        setaf aval, fval
        db 0EDh,0D1h
        report3
        endm

mulub_e macro aval, rval, fval  ; ED D9
        ld e,rval
        setaf aval, fval
        db 0EDh,0D9h
        report3
        endm

muluw_bc macro hlval, bcval, fval   ; ED C3
        ld bc,bcval
        ld h,0
        ld l,fval
        push hl
        pop af
        ld hl,hlval
        db 0EDh,0C3h
        report5
        endm

;  ---------------- MULUB A,r ----------------
        mulub_b 000h, 000h, 000h
        mulub_b 001h, 001h, 000h
        mulub_b 010h, 010h, 000h
        mulub_b 0FFh, 0FFh, 000h
        mulub_c 080h, 002h, 0FFh
        mulub_c 07Fh, 001h, 0FFh
        mulub_c 000h, 05Ah, 0FFh
        mulub_d 012h, 034h, 012h
        mulub_d 0FFh, 001h, 012h
        mulub_e 0A5h, 05Ah, 0EDh
        mulub_e 001h, 0FFh, 000h
        mulub_e 000h, 000h, 0FFh

;  ---------------- MULUW HL,BC ----------------
        muluw_bc 00000h, 00000h, 000h
        muluw_bc 00001h, 00001h, 000h
        muluw_bc 01000h, 00010h, 000h
        muluw_bc 0FFFFh, 0FFFFh, 0FFh
        muluw_bc 08000h, 00002h, 0FFh
        muluw_bc 000FFh, 00100h, 012h
        muluw_bc 01234h, 00000h, 0EDh

;  ---------------- MULUW HL,SP ----------------
;  SP is the operand here, so set the flags first and keep the stack out of the way.
        ld h,0
        ld l,012h
        push hl
        pop af                  ; F = 12h
        ld sp,00002h
        ld hl,01234h
        db 0EDh,0F3h
        ld sp,0D000h            ; stack back before reporting (LD SP does not touch F)
        report5

        ld h,0
        ld l,0FFh
        push hl
        pop af                  ; F = FFh
        ld sp,08000h
        ld hl,0FFFFh
        db 0EDh,0F3h
        ld sp,0D000h
        report5

;  ---------------- an ED opcode in the same block that must stay a NOP ----------------
        ld hl,0BEEFh
        db 0EDh,0C5h            ; not MULUB/MULUW: NOP, HL unchanged
        db 0EDh,0CBh            ; not MULUB/MULUW: NOP
        report3

        ld a,0FFh
        out (0FFh),a
        halt

        SAVEBIN "multest.bin",0,0E000h
