; cracks.s: broken tiles (as6809, gcc6809 -mabi=bx)
;
;   void cracks_draw(unsigned char rot);   dome at rotation rot
;
; Each broken tile (broken[0 .. nbroken-1], cell numbers, kept by the game)
; gets a crack at its centre: one of 4 zig-zags (cell & 3), mirrored if
; cell & 4, with its own flickering intensity. crack_look (by ring and j / 8)
; gives the scale and a flattened version of the shape, so the crack lies
; on the tile (thin where the tile is seen edge-on). The
; centre's screen position comes from crack_pos by ring and azimuth on screen
; (tools/gen_dome.py make_cracks): j = (phi + rot) mod 240, mirrored to
; 0..120 (x negated beyond), stored for every 4th j and blended between;
; x = -128 there means the centre faces away: not drawn.
; Positioning: the first crack (and every CHAIN-th) as the missiles do
; (missile_draw.s move_to: Reset0Ref, one calibrated move); the others by a
; move from the previous crack's centre at _mis_scale[0] (1 DAC unit = 1
; screen unit with the console's ramp tail), split in two if over 127 units
; (a fresh move_to if over 254). Each crack's list ends back at its centre,
; so the chain only carries the moves' own small errors.
;
; Needs DP = $D0. Preserves U, Y.

	.module	cracks
	.include "missile_cfg.inc"

	.globl	_cracks_draw, _broken, _nbroken
	.globl	_mis_cell_ring, _mis_cell_phi, _crack_pos, _crack_look, _crack_shapes, _mis_oy
	.globl	move_to, move_ab, tx, ty, draw_entries, mirror, _mis_scale

Intensity_a	= 0xF2AB
VIA_t1_cnt_lo	= 0xD004
P_B		= 0x00
P_A		= 0x01
CHAIN		= 6		; cracks per Reset0Ref

	.area	.bss
crot:	.blkb	1
ctime:	.blkb	1
ccount:	.blkb	1
ccell:	.blkb	1
cring:	.blkb	1
cj:	.blkb	1
cneg:	.blkb	1
cf:	.blkb	1	; j & 3: blend between table entries
ctmp:	.blkb	2
cchain:	.blkb	1	; cracks since the last Reset0Ref (0: reset next)
cx:	.blkb	2	; beam position (the last crack's centre)
cy:	.blkb	2
cdx:	.blkb	2
cdy:	.blkb	2

	.area	.text

; flicker: intensity steps, each tile at its own phase, changing every 2 frames
flick:	.byte	0x7f, 0x50, 0x68, 0x3c, 0x7f, 0x5c, 0x44, 0x70
	.byte	0x60, 0x38, 0x78, 0x54, 0x48, 0x7f, 0x40, 0x64

_cracks_draw:
	pshs	u,y
	stb	crot
	inc	ctime
	ldb	_nbroken
	lbeq	99$
	stb	ccount
	clr	cchain
	ldu	#_broken
1$:	ldb	,u+
	stb	ccell
	ldx	#_mis_cell_phi
	abx
	lda	,x
	adda	crot			; j = (phi + rot) mod 240
	bcc	2$
	adda	#256-MIS_STEPS
	bra	3$
2$:	cmpa	#MIS_STEPS
	blo	3$
	suba	#MIS_STEPS
3$:	clr	cneg
	cmpa	#MIS_HALF
	bls	4$
	nega				; 240 - j, x negated
	adda	#MIS_STEPS
	inc	cneg
4$:	sta	cj
	ldx	#_mis_cell_ring
	ldb	ccell
	abx
	lda	,x
	sta	cring
	ldb	#CRACK_ROW
	mul
	std	ctmp
	ldb	cj
	lsrb				; one entry per 4 steps
	lsrb
	clra
	addd	ctmp
	lslb
	rola				; * 2 bytes per entry
	ldx	#_crack_pos
	leax	d,x
	lda	,x
	cmpa	#0x80
	lbeq	9$			; faces away
	ldb	,x
	sex
	std	tx
	ldb	1,x
	sex
	std	ty
	lda	cj			; between entries: (4 a + f (b - a)) / 4,
	anda	#3			;   f = j & 3
	sta	cf
	beq	5$
	lda	2,x
	cmpa	#0x80
	lbeq	9$			; the next entry faces away
	ldb	2,x
	sex
	subd	tx
	std	cdx			; b - a (cdx, cdy: scratch here)
	ldb	3,x
	sex
	subd	ty
	std	cdy
	ldd	tx			; 4 a
	aslb
	rola
	aslb
	rola
	std	tx
	ldd	ty
	aslb
	rola
	aslb
	rola
	std	ty
	lda	cf
	lsra
	bcc	51$
	ldd	tx			; + (b - a)
	addd	cdx
	std	tx
	ldd	ty
	addd	cdy
	std	ty
51$:	lda	cf
	anda	#2
	beq	52$
	ldd	cdx			; + 2 (b - a)
	aslb
	rola
	addd	tx
	std	tx
	ldd	cdy
	aslb
	rola
	addd	ty
	std	ty
52$:	ldd	tx			; / 4
	asra
	rorb
	asra
	rorb
	std	tx
	ldd	ty
	asra
	rorb
	asra
	rorb
	std	ty
5$:	tst	cneg
	beq	6$
	ldd	tx
	coma
	comb
	addd	#1
	std	tx
6$:	ldd	ty
	addd	_mis_oy
	std	ty
	lda	ccell			; flicker
	ldb	#5
	mul
	lda	ctime
	lsra
	pshs	a
	addb	,s+
	andb	#15
	ldx	#flick
	lda	b,x
	sta	*P_A			; intensity, as BIOS Intensity_a without the call
	ldd	#0x0504
	sta	*P_B			; mux channel 2 (Z), disabled
	stb	*P_B			; enabled: the Z sample-and-hold charges
	stb	*P_B
	ldb	#0x01
	stb	*P_B			; mux off
	; position: chained from the previous crack, or a fresh move_to
	tst	cchain
	beq	20$
	ldd	tx
	subd	cx
	std	cdx
	addd	#254			; |dx| <= 254?
	cmpd	#508
	bhi	20$
	ldd	ty
	subd	cy
	std	cdy
	addd	#254
	cmpd	#508
	bhi	20$
	lda	_mis_scale
	sta	VIA_t1_cnt_lo
	ldd	cdx
	addd	#127			; both within 127: one move
	cmpd	#254
	bhi	21$
	ldd	cdy
	addd	#127
	cmpd	#254
	bhi	21$
	lda	cdy+1
	ldb	cdx+1
	jsr	move_ab
	bra	22$
21$:	ldd	cdx			; two moves: half, then the rest
	asra
	rorb
	stb	cdx			; (high byte: free now) first half of dx
	ldd	cdy
	asra
	rorb
	stb	cdy
	lda	cdy
	ldb	cdx
	jsr	move_ab
	lda	cdy+1
	suba	cdy
	ldb	cdx+1
	subb	cdx
	jsr	move_ab
	bra	22$
20$:	jsr	move_to
	clr	cchain
22$:	ldd	tx
	std	cx
	ldd	ty
	std	cy
	lda	cchain
	inca
	cmpa	#CHAIN
	blo	23$
	clra
23$:	sta	cchain
	lda	ccell			; shape: cell & 3, mirrored if cell & 4
	lsra
	lsra
	anda	#1
	sta	mirror
	lda	cring			; look: (scale, variant) at ring * 16 + j / 8
	ldb	#16
	mul
	lda	cj
	lsra
	lsra
	lsra
	pshs	a
	addb	,s+
	lslb				; (< 256: ring <= 11)
	ldx	#_crack_look
	abx
	lda	,x
	sta	VIA_t1_cnt_lo
	ldb	1,x			; variant * 4 + (cell & 3), pointers
	lslb
	lslb
	lda	ccell
	anda	#3
	pshs	a
	addb	,s+
	lslb
	ldx	#_crack_shapes
	abx
	ldx	,x
	ldb	,x+
	clra
	tfr	d,y
	jsr	draw_entries
9$:	dec	ccount
	lbne	1$
99$:	puls	u,y,pc
