; vdptools.rom -- the V9968 Cartridge test programs (hra1129/V9968_Cartridge test/,
; MIT licence, (c) 2026 HRA!) on one ASCII16 MegaROM with a menu, for the MiSTer MSX core.
;
; The programs are MSX-DOS .COM files.  This ROM is their DOS: a program is copied from
; the ROM banks to RAM at 0100h, page 0-2 become RAM, and page 0 gets the vectors a DOS
; leaves there -- 0000h (warm boot: back to the menu), 0005h (BDOS: console functions
; only, every file function fails), 000Ch RDSLT, 001Ch CALSLT and 0038h (the interrupt,
; passed on to the BIOS) -- implemented by the stub in page 3 (STUB, E000h-EFFFh).
; RDSLT / CALSLT handle page-0 targets (the BIOS and the SUB-ROM), which is all the
; programs use.  (0006h) = E000h is the top of the TPA.
;
; Menu: cursor keys / joystick up-down, SPACE or trigger A to run, after a program
; ESC or trigger B back to the menu.  Inside a program its own keys apply (most quit
; with ESC); joystick port 1 trigger A acts as SPACE and trigger B as ESC there too,
; through BDOS key input and through the patched PPI keyboard reads (RST 30h).
;
; Boots from the cartridge INIT before any disk ROM: no DOS, no disk needed.
; Build: sjasmplus vdptools.asm   (ASCII16, 512 KB, mapper registers 6000h / 7000h)

CHSNS	= 009Ch
CHGET	= 009Fh
CHPUT	= 00A2h
INITXT	= 006Ch
GTSTCK	= 00D5h
GTTRIG	= 00D8h
KILBUF	= 0156h
ENASLT	= 0024h
EXPTBL	= 0FCC1h
SLTTBL	= 0FCC5h
LINL40	= 0F3AEh
CSRY	= 0F3DCh

STUB	= 0E000h		; page-3 stub; also the BDOS entry and the TPA top
STK	= 0EFF0h		; menu / loader stack
CAP	= 0E400h		; console capture ring, CAP .. CAP+CAPN-1
CAPN	= 0800h

	output	"bank0.bin"
	org	4000h

; ---------------------------------------------------------------- bank 0: header, menu
	db	"AB"
	dw	init
	dw	0, 0, 0
	ds	6, 0

init:
	di
	ld	sp, STK
	ld	hl, stub_src
	ld	de, STUB
	ld	bc, stub_end - STUB
	ldir
	; slots: the ROM in page 1, the RAM in page 3 (pages 0-2 use the same RAM slot)
	in	a, (0A8h)
	ld	(s_a8), a
	rrca
	rrca
	and	3
	ld	b, 1
	call	slot_id
	ld	(s_rom), a
	ld	a, (s_a8)
	rlca
	rlca
	and	3
	ld	(s_p3), a
	ld	b, 3
	call	slot_id
	ld	(s_ram), a
	ld	a, (0FFFFh)
	cpl
	ld	(s_ff), a		; P3's sub-slot register (only meaningful if expanded)
	ei
	jp	menu

; A = primary slot, B = page -> A = slot id (EXPTBL form) of that page
slot_id:
	ld	c, a
	ld	hl, EXPTBL
	ld	e, a
	ld	d, 0
	add	hl, de
	ld	a, (hl)
	and	80h
	jr	z, .plain
	or	c
	ld	c, a
	ld	hl, SLTTBL
	add	hl, de
	ld	a, (hl)
.sh:	dec	b
	jp	m, .got
	rrca
	rrca
	jr	.sh
.got:	and	3
	rlca
	rlca
	or	c
	ret
.plain:	ld	a, c
	ret

; ---------------------------------------------------------------- menu (page 1, BIOS in page 0)
menu:
	ld	sp, STK
	call	KILBUF
	call	vdp_clean
	ld	a, 80
	ld	(LINL40), a
	call	INITXT
	ld	hl, txt_title
	call	puts
	xor	a
	ld	(m_prev), a
.draw:
	call	draw_items
.key:
	call	read_input		; A: 1 up, 2 down, 3 select, 0 none
	or	a
	jr	z, .key
	cp	3
	jr	z, .run
	ld	b, a
	ld	a, (m_sel)
	dec	b
	jr	nz, .down
	or	a
	jr	z, .key
	dec	a
	jr	.set
.down:	inc	a
	cp	N_ITEMS
	jr	nc, .key
.set:	ld	(m_sel), a
	jr	.draw
.run:
	ld	a, (m_sel)
	ld	l, a
	ld	h, 0
	add	hl, hl
	add	hl, hl
	ld	de, items
	add	hl, de			; items: dw name, db bank, db 0 ... (4 bytes) and len table
	inc	hl
	inc	hl
	ld	a, (hl)			; first bank
	push	af
	ld	a, (m_sel)
	ld	l, a
	ld	h, 0
	add	hl, hl
	ld	de, lens
	add	hl, de
	ld	e, (hl)
	inc	hl
	ld	d, (hl)
	ex	de, hl
	pop	af
	jp	run_com			; in the page-3 stub, does not return

; back here from the stub after a program ended (BIOS in page 0, this ROM in page 1)
menu_back:
	ld	sp, STK
	call	vdp_clean
	ld	a, 80
	ld	(LINL40), a
	call	INITXT
	call	iniplt
	call	replay
.rl:	ld	a, 1			; a held trigger is not the next press
	call	GTTRIG
	or	a
	jr	nz, .rl
	ld	a, 3
	call	GTTRIG
	or	a
	jr	nz, .rl
	call	KILBUF
	ld	hl, txt_back
	call	puts
.w:	call	read_input
	cp	4
	jr	nz, .w
	jp	menu

draw_items:
	ld	b, 0
.it:	ld	a, b
	cp	N_ITEMS
	ret	nc
	push	bc
	ld	h, 2			; column 2
	ld	l, b
	inc	l
	inc	l
	inc	l
	inc	l			; row 4 + item
	call	POSIT
	ld	a, (m_sel)
	pop	bc
	push	bc
	cp	b
	ld	a, ' '
	jr	nz, .mk
	ld	a, '>'
.mk:	call	CHPUT
	ld	a, ' '
	call	CHPUT
	ld	l, b
	ld	h, 0
	add	hl, hl
	add	hl, hl
	ld	de, items
	add	hl, de
	ld	e, (hl)
	inc	hl
	ld	d, (hl)
	ex	de, hl
	call	puts
	pop	bc
	inc	b
	jr	.it

POSIT	= 00C6h

; registers a program may leave set that INITXT does not rewrite
vdp_clean:
	ld	hl, clean_regs
	ld	b, clean_end - clean_regs
	di
.r:	xor	a
	out	(99h), a
	ld	a, (hl)
	or	80h
	out	(99h), a
	inc	hl
	djnz	.r
	ei
	ret
clean_regs:
	db	46, 15, 19, 23, 25, 26, 27, 28, 29, 30	; R#46 = 0: STOP
clean_end:

iniplt:					; default palette (SUB-ROM INIPLT), MSX2 and later
	ld	a, (0FAF8h)
	or	a
	ret	z
	ld	ix, 0141h
	jp	015Fh			; EXTROM

; print the program's console output again (the tail when the ring wrapped)
replay:
	ld	a, (cap_wrap)
	or	a
	ld	hl, CAP
	jr	z, .from
	ld	hl, (cap_ptr)
	; skip to the first line start
.sk:	ld	a, (hl)
	call	cap_inc
	cp	0Ah
	jr	z, .from
	ld	de, (cap_ptr)
	or	a
	push	hl
	sbc	hl, de
	pop	hl
	jr	nz, .sk
	ret
.from:	ld	de, (cap_ptr)
	or	a
	push	hl
	sbc	hl, de
	pop	hl
	ret	z
	ld	a, (hl)
	push	hl
	call	CHPUT
	pop	hl
	call	cap_inc
	jr	.from

puts:	ld	a, (hl)
	or	a
	ret	z
	call	CHPUT
	inc	hl
	jr	puts

; read_input -> A = 1 up, 2 down, 3 select (SPACE / RETURN / trigger A),
;               4 back (ESC / trigger B), 0 nothing.  Waits for the release.
read_input:
	call	CHSNS
	jr	z, .joy
	call	CHGET
	cp	1Eh
	ld	b, 1
	jr	z, .ret
	cp	1Fh
	ld	b, 2
	jr	z, .ret
	cp	' '
	ld	b, 3
	jr	z, .ret
	cp	0Dh
	jr	z, .ret
	cp	1Bh
	ld	b, 4
	jr	z, .ret
	xor	a
	ret
.joy:	ld	a, 1
	call	GTTRIG
	ld	b, 3
	or	a
	jr	nz, .rel
	ld	a, 3
	call	GTTRIG
	ld	b, 4
	or	a
	jr	nz, .rel
	ld	a, 1
	call	GTSTCK
	cp	1
	ld	b, 1
	jr	z, .rel
	cp	5
	ld	b, 2
	jr	z, .rel
	xor	a
	ret
.rel:	; wait until the stick and the triggers are released
	push	bc
.r1:	ld	a, 1
	call	GTTRIG
	or	a
	jr	nz, .r1
	ld	a, 3
	call	GTTRIG
	or	a
	jr	nz, .r1
	ld	a, 1
	call	GTSTCK
	or	a
	jr	nz, .r1
	pop	bc
.ret:	ld	a, b
	ret

txt_title:
	db	"V9968 VDP check tools  (HRA! test/, MIT)", 0Dh, 0Ah
	db	"Up/Down  SPACE or A: run  ESC or B: menu", 0Dh, 0Ah, 0
txt_back:
	db	0Dh, 0Ah, "-- ESC or B: back to the menu --", 0

; name, first bank, (pad)
items:
	dw	n_chk
	db	B_CHK, 0
	dw	n_reg
	db	B_REG, 0
	dw	n_view
	db	B_VIEW, 0
	dw	n_int
	db	B_INT, 0
	dw	n_diag
	db	B_DIAG, 0
	dw	n_strs
	db	B_STRS, 0
	dw	n_test
	db	B_TEST, 0
	dw	n_rw
	db	B_RW, 0
N_ITEMS	= ($ - items) / 4
lens:	dw	L_CHK, L_REG, L_VIEW, L_INT, L_DIAG, L_STRS, L_TEST, L_RW

n_chk:	db	"VDPCHK   register / VRAM / command", 0
n_reg:	db	"VDPREG   command end registers", 0
n_view:	db	"VDPVIEW  pictures P01-P19", 0
n_int:	db	"VDPINT   line interrupts P20-P23", 0
n_diag:	db	"VDPDIAG  screen switch diagnosis", 0
n_strs:	db	"VRAMSTRS VRAM stress", 0
n_test:	db	"VDPTEST  command end stress", 0
n_rw:	db	"VRAMRW   VRAM read / write", 0

; never executed: loaders that guess the mapper from the LD (nn),A targets in the
; whole image (the MiSTer core's mapper_detect.sv, openMSX) would otherwise see
; the programs' LD (8000h),A and pick Konami.  7000h counts for ASCII16.
mapper_hint:
	rept	32
	ld	(7000h), a
	endr

; ---------------------------------------------------------------- the page-3 stub (copied to E000h)
stub_src:
	disp	STUB

bdos_entry:
	jp	bdos_main		; E000h: BDOS, (0006h) = TPA top

; variables
s_a8:	db	0			; A8h at INIT: page 0 BIOS, page 1 ROM, pages 2-3 RAM
s_ff:	db	0			; page 3's sub-slot register at INIT
s_rom:	db	0
s_ram:	db	0
s_p3:	db	0
m_sel:	db	0
m_prev:	db	0
cap_ptr: dw	CAP
cap_wrap: db	0
c_bank:	db	0
c_off:	dw	0
c_dst:	dw	0
c_left:	dw	0
c_n:	dw	0
cs_a8:	db	0
cs_ff:	db	0
cs_iy:	dw	0

; ---- load the program (A = first bank, HL = length) and run it
run_com:
	di
	ld	sp, STK
	ld	(c_bank), a
	ld	(c_left), hl
	ld	hl, CAP
	ld	(cap_ptr), hl
	xor	a
	ld	(cap_wrap), a
	ld	hl, 0100h
	ld	(c_dst), hl
	ld	hl, 0
	ld	(c_off), hl
.loop:
	ld	hl, (c_left)
	ld	a, h
	or	l
	jr	z, .done
	; n = min(left, 4000h - off, page end - dst)
	ld	de, (c_off)
	ld	hl, 4000h
	or	a
	sbc	hl, de			; to the bank end
	ld	de, (c_left)
	call	min_hl_de
	push	hl
	ld	hl, (c_dst)
	ld	a, h
	and	0C0h
	add	a, 40h
	ld	d, a
	ld	e, 0			; page end (0 for page 3: 10000h)
	ex	de, hl
	or	a
	sbc	hl, de			; to the page end
	pop	de
	call	min_hl_de
	ld	(c_n), hl
	call	copy_part
	; advance
	ld	de, (c_n)
	ld	hl, (c_dst)
	add	hl, de
	ld	(c_dst), hl
	ld	hl, (c_left)
	or	a
	sbc	hl, de
	ld	(c_left), hl
	ld	hl, (c_off)
	add	hl, de
	ld	a, h
	cp	40h
	jr	c, .same
	ld	hl, 0
	ld	a, (c_bank)
	inc	a
	ld	(c_bank), a
.same:	ld	(c_off), hl
	jr	.loop
.done:
	; page 1 back to the menu bank, then pages 1-2 RAM, page 0 RAM
	call	rom_p1
	xor	a
	ld	(6000h), a
	ld	a, (s_ram)
	ld	h, 40h
	call	ENASLT
	ld	a, (s_ram)
	ld	h, 80h
	call	ENASLT
	di
	ld	a, (s_ram)
	call	sel_p0
	ld	a, 0C3h
	ld	hl, ret_menu
	ld	(0000h), a
	ld	(0001h), hl
	ld	hl, bdos_entry
	ld	(0005h), a
	ld	(0006h), hl
	ld	hl, rdslt_stub
	ld	(000Ch), a
	ld	(000Dh), hl
	ld	hl, calslt_stub
	ld	(001Ch), a
	ld	(001Dh), hl
	ld	hl, enaslt_stub
	ld	(0024h), a
	ld	(0025h), hl
	ld	hl, int_stub
	ld	(0038h), a
	ld	(0039h), hl
	ld	hl, pad_kbd
	ld	(0030h), a
	ld	(0031h), hl
	; empty command line and FCB
	xor	a
	ld	(0080h), a
	ld	a, 0Dh
	ld	(0081h), a
	ld	hl, 005Ch
	ld	(hl), 0
	inc	hl
	ld	b, 11
.fcb:	ld	(hl), ' '
	inc	hl
	djnz	.fcb
	ld	sp, STUB
	ld	hl, 0
	push	hl			; RET from the program = warm boot
	ei
	jp	0100h

min_hl_de:				; HL = min(HL, DE), unsigned
	or	a
	sbc	hl, de
	add	hl, de
	ret	c
	ex	de, hl
	ret

rom_p1:	ld	a, (s_rom)
	ld	h, 40h
	jp	ENASLT

; copy c_n bytes of bank c_bank at c_off to c_dst (inside one page)
copy_part:
	ld	a, (c_dst + 1)
	rlca
	rlca
	and	3
	cp	2
	jr	z, .p2
	push	af
	call	rom_p1
	ld	a, (c_bank)
	ld	(7000h), a
	ld	a, (s_rom)
	ld	h, 80h
	call	ENASLT			; page 2 = the bank
	pop	af
	ld	hl, (c_off)
	ld	de, 8000h
	add	hl, de
	cp	1
	jr	nz, .n1
	push	hl
	ld	a, (s_ram)
	ld	h, 40h
	call	ENASLT			; page 1 = RAM
	pop	hl
	jr	.cp
.n1:	cp	3
	jr	z, .cp
	; page 0: RAM for the copy, the BIOS again after it
	di
	push	hl
	ld	a, (s_ram)
	call	sel_p0
	pop	hl
	ld	de, (c_dst)
	ld	bc, (c_n)
	ldir
	ld	a, (EXPTBL)
	call	sel_p0
	ei
	ret
.cp:	ld	de, (c_dst)
	ld	bc, (c_n)
	ldir
	ret
.p2:	call	rom_p1
	ld	a, (c_bank)
	ld	(6000h), a		; page 1 = the bank
	ld	a, (s_ram)
	ld	h, 80h
	call	ENASLT			; page 2 = RAM
	ld	hl, (c_off)
	ld	de, 4000h
	add	hl, de
	ld	de, (c_dst)
	ld	bc, (c_n)
	ldir
	ret

; page 0 to slot A (EXPTBL form); interrupts must be off.  Destroys A, B, C.
; A primary other than page 3's keeps the sub-slot it has (the BIOS: set at boot).
sel_p0:
	ld	c, a
	and	3
	ld	b, a
	in	a, (0A8h)
	and	0FCh
	or	b
	out	(0A8h), a
	ld	a, (s_p3)
	cp	b
	ret	nz
	bit	7, c
	ret	z
	ld	a, c
	rrca
	rrca
	and	3
	ld	b, a
	ld	a, (0FFFFh)
	cpl
	and	0FCh
	or	b
	ld	(0FFFFh), a
	ret

; ---- back to the menu: page 0 BIOS, page 1 this ROM (menu bank), page 2 RAM
ret_menu:
	di
	ld	sp, STK
	ld	a, (s_ram)
	rlca
	jr	nc, .nx
	ld	a, (s_ff)
	ld	(0FFFFh), a
.nx:	ld	a, (s_a8)
	out	(0A8h), a
	xor	a
	ld	(6000h), a
	ei
	jp	menu_back

; ---- 0038h with RAM in page 0: the BIOS interrupt handler, through the slots
int_stub:
	push	af
	push	bc
	; the BIOS handler reads S#0 assuming R#15 = 0; a program that leaves R#15
	; set (VDPTEST does: its wreg returns A = 80h + register) never acknowledges
	; the VDP interrupt and the interrupt re-enters until the stack is gone
	xor	a
	out	(99h), a
	ld	a, 8Fh
	out	(99h), a
	in	a, (0A8h)
	push	af
	ld	a, (0FFFFh)
	cpl
	push	af
	ld	a, (EXPTBL)
	call	sel_p0
	call	0038h			; BIOS KEYINT: returns with EI
	di
	pop	bc			; B = the sub-slot register
	ld	a, (s_ram)
	rlca
	jr	nc, .nx
	ld	a, b
	ld	(0FFFFh), a
.nx:	pop	af
	out	(0A8h), a
	pop	bc
	pop	af
	ei
	ret

; ---- CALSLT (IY high = slot, IX = address in page 0); returns with interrupts off
calslt_stub:
	di
	push	bc
	push	af
	in	a, (0A8h)
	ld	(cs_a8), a
	ld	a, (0FFFFh)
	cpl
	ld	(cs_ff), a
	ld	(cs_iy), iy
	ld	a, (cs_iy + 1)
	call	sel_p0
	pop	af
	pop	bc
	call	.jpix
	di
	push	af
	call	cs_restore
	pop	af
	ret
.jpix:	jp	(ix)

; ---- RDSLT (A = slot, HL = address in page 0) -> A
rdslt_stub:
	di
	push	bc
	push	af
	in	a, (0A8h)
	ld	(cs_a8), a
	ld	a, (0FFFFh)
	cpl
	ld	(cs_ff), a
	pop	af
	call	sel_p0
	ld	c, (hl)
	call	cs_restore
	ld	a, c
	pop	bc
	ret

enaslt_stub:
	ret

; ---- RST 30h: the programs' "IN A,(0A9h)" keyboard reads are patched to
; RST 30h / NOP (pack.py).  Reads the row like the IN did, then joystick
; port 1 trigger A pulls SPACE (row 8 bit 0) and trigger B pulls ESC
; (row 7 bit 2) low.  Flags, BC and the interrupt state are kept.
pad_kbd:
	push	bc
	push	af
	ld	a, i			; P/V = IFF2
	push	af
	di
	in	a, (0AAh)
	and	0Fh
	ld	c, a
	in	a, (0A9h)
	ld	b, a
	ld	a, c
	cp	7
	jr	z, .r7
	cp	8
	jr	nz, .done
	call	pad_read
.ta:	bit	4, a			; trigger A (label: test_pad.tcl)
	jr	nz, .done
	res	0, b			; SPACE
	jr	.done
.r7:	call	pad_read
.tb:	bit	5, a			; trigger B (label: test_pad.tcl)
	jr	nz, .done
	res	2, b			; ESC
.done:	pop	af
	jp	po, .di
	ei
.di:	pop	af
	ld	a, b
	pop	bc
	ret

pad_read:				; A = PSG R#14 of joystick port 1 (C destroyed)
	ld	a, 15
	out	(0A0h), a
	in	a, (0A2h)
	ld	c, a
	and	0BFh
	out	(0A1h), a
	ld	a, 14
	out	(0A0h), a
	in	a, (0A2h)
	push	af
	ld	a, 15
	out	(0A0h), a
	ld	a, c
	out	(0A1h), a
	pop	af
	ret

cs_restore:				; slots back as before CALSLT / RDSLT (destroys A)
	ld	a, (s_ram)
	rlca
	jr	nc, .nx
	ld	a, (cs_ff)
	ld	(0FFFFh), a
.nx:	ld	a, (cs_a8)
	out	(0A8h), a
	ret

; ---- BDOS: console functions; the rest fail (A = FFh)
bdos_main:
	ld	a, c
	or	a
	jp	z, ret_menu
	cp	1
	jr	z, f_conin
	cp	2
	jr	z, f_conout
	cp	6
	jr	z, f_dirio
	cp	7
	jr	z, f_in
	cp	8
	jr	z, f_in
	cp	9
	jr	z, f_strout
	cp	0Bh
	jr	z, f_const
	cp	1Ah			; set DTA
	jr	z, f_ok
	ld	a, 0FFh
	jr	f_ret
f_ok:	xor	a
f_ret:	ld	l, a
	ld	h, 0
	ld	b, h
	ei
	ret
f_conout:
	ld	a, e
	call	con_out
	jr	f_ok
f_strout:
	ex	de, hl
.s:	ld	a, (hl)
	cp	'$'
	jr	z, f_ok
	push	hl
	call	con_out
	pop	hl
	inc	hl
	jr	.s
f_conin:
	call	getkey
	push	af
	call	con_out
	pop	af
	jr	f_ret
f_in:	call	getkey
	jr	f_ret
f_dirio:
	ld	a, e
	cp	0FFh
	jr	nz, f_conout
	call	keyready
	or	a
	jr	z, f_ret
	call	getkey
	jr	f_ret
f_const:
	call	keyready
	jr	f_ret

con_out:				; CHPUT and keep a copy for the result screen
	ld	hl, (cap_ptr)
	ld	(hl), a
	push	af
	call	cap_inc
	ld	(cap_ptr), hl
	pop	af
	jr	b_chput

cap_inc:				; HL + 1 inside the ring (sets cap_wrap on the wrap)
	inc	hl
	push	af
	ld	a, h
	cp	high (CAP + CAPN)
	jr	nz, .ok
	ld	h, high CAP
	ld	a, 1
	ld	(cap_wrap), a
.ok:	pop	af
	ret

b_chput:
	ld	ix, CHPUT
	jr	callmain
b_chsns:
	ld	ix, CHSNS
	jr	callmain
b_chget:
	ld	ix, CHGET
	jr	callmain
b_gttrig:				; A = trigger number -> A
	ld	ix, GTTRIG
callmain:
	ld	iy, (EXPTBL - 1)
	jp	calslt_stub

; a key from the keyboard, or SPACE for trigger A and ESC for trigger B (port 1)
getkey:
	call	b_chsns
	jr	z, .joy
	jp	b_chget
.joy:	ld	a, 1
	call	b_gttrig
	or	a
	ld	c, ' '
	jr	nz, .rel
	ld	a, 3
	call	b_gttrig
	or	a
	ld	c, 1Bh
	jr	nz, .rel
	jr	getkey
.rel:	push	bc
.r:	ld	a, 1
	call	b_gttrig
	or	a
	jr	nz, .r
	ld	a, 3
	call	b_gttrig
	or	a
	jr	nz, .r
	pop	bc
	ld	a, c
	ret

keyready:				; A = FFh if a key or a trigger is waiting
	call	b_chsns
	ld	a, 0FFh
	ret	nz
	ld	a, 1
	call	b_gttrig
	or	a
	ret	nz
	ld	a, 3
	call	b_gttrig
	ret

stub_end:
	ent

	assert	stub_end - STUB <= CAP - STUB
	assert	$ < 8000h
	ds	8000h - $, 0FFh

	include	"banks.inc"		; B_xxx / L_xxx, written by pack.py
