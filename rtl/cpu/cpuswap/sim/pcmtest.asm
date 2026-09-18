;  PCMPLY hardware player (rtl/peripheral/turbor/pcm_play.sv).
;
;  Each run sets A (bit 7 = VRAM, bits 1-0 = rate), HL = start, BC = length and
;  calls the BIOS entry at 0186h, which the turbo R overlay answers.  The player
;  parks the CPU inside that opcode fetch and reads the samples itself, so the
;  bench's D lines are the sample stream and `Z pcm <n> <aborted>` closes each
;  run.  Carry on return is the abort flag; it is reported through OUT (20h).
;
;  Runs 3 and 4 must not park the CPU at all (nothing to play), so they produce
;  no Z line.  With +pcmstop=<n> the bench presses CTRL+STOP once n samples have
;  been put out, and the run in progress ends early with carry set.
;
;  The log is core-independent: the same trace must come out of T80s, NextZ80 and
;  any hand-over rhythm.
        DEVICE NOSLOT64K
        ORG 0
;  Page 0 belongs to the turbo R BIOS overlay in the bench, so the test lives at 8000h.
        jp start

        ORG 8000h
start:
        nop                     ; the bench hands the bus to NextZ80 at the first swap point
        ld sp,0F000h            ; stack above E000h: its writes stay out of the trace

play    macro aval, src, len
        ld a,aval
        ld hl,src
        ld bc,len
        call 0186h              ; PCMPLY
        call repcy
        endm

;  ---------------- 1: 8 samples at 15.75 kHz (q = 0)
        play 000h, 09000h, 8
;  ---------------- 2: 4 samples at 7.875 kHz (q = 1), a different buffer
        play 001h, 09008h, 4
;  ---------------- 3: length 0 -- nothing to play, returns at once, carry clear
        play 000h, 09000h, 0
;  ---------------- 4: VRAM asked for (bit 7) -- not implemented, returns at once
        play 080h, 09000h, 4
;  ---------------- 5: 16 samples, long enough for a CTRL+STOP to land inside it
        play 000h, 09010h, 16

        ld a,0FFh
        out (0FFh),a
        halt

;  carry -> OUT (20h): 01h aborted, 00h ran to the end
repcy:
        ld a,0
        adc a,0
        out (20h),a
        ret

;  ---------------- sample data: every byte distinct, so each one shows as a D line
        ORG 9000h
        db 001h,002h,003h,004h,005h,006h,007h,008h      ; run 1
        db 011h,012h,013h,014h                          ; run 2
        ORG 9010h
        db 020h,021h,022h,023h,024h,025h,026h,027h      ; run 5
        db 028h,029h,02Ah,02Bh,02Ch,02Dh,02Eh,02Fh

        SAVEBIN "pcmtest.bin",0,0E000h
