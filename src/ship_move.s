; ship_move.s: the ship's moves and jumps (as6809, gcc6809 -mabi=bx)
;
;   void move_start(unsigned char to);   move to a neighbouring cell
;   void jump_start(unsigned char to);   jump to a cell two away
;   void move_step(void);                each frame while move_left > 0
;
; The ship rests on cell centres. A move lasts MOVE_FRAMES frames, a jump
; JUMP_FRAMES; the dome rotation and the ship latitude run linearly in 8.8
; fixed point from where they are to the cell's (dome turned the short way
; round, so the cell comes to the front), and the last frame lands exactly.
; A jump also lifts the ship on an arc (ship_lift, drawn by dome_draw.s).
; (Was C: the long arithmetic made gcc6809 pull in ~0.7 KB.)

	.module	ship_move
	.include "dome_cfg.inc"

	.globl	_move_start, _jump_start, _move_step
	.globl	_dome_angle, _ship_lat, _cell, _move_left, _ship_lift
	.globl	_cell_step, _cell_lat

JUMP_FRAMES	= 24
STEPS		= 240			; DOME_STEPS
STEPS_FP	= 0xF000		; STEPS * 256

	.area	.bss
_dome_angle:	.blkb	1	; dome rotation, 0..STEPS-1
_ship_lat:	.blkb	1	; ship latitude view, 0 = on the peak
_cell:		.blkb	1	; current cell, or the destination while moving
_move_left:	.blkb	1	; frames left in the current move or jump, 0 = at rest
_ship_lift:	.blkb	1	; mid-jump: the ship drawn this far up (DAC units)
mlen:	.blkb	1		; frames in this move (MOVE_FRAMES or JUMP_FRAMES)
acc_s:	.blkb	2		; dome rotation, 8.8
acc_l:	.blkb	2		; ship latitude, 8.8
inc_s:	.blkb	2		; per frame
inc_l:	.blkb	2
msign:	.blkb	1

	.area	.text

; jump arc by frames left: 4 h k (n - k) / n^2, k = n - left, h = 24
lift_tab:
	.byte	0, 4, 7, 10, 13, 16, 18, 20, 21, 22, 23, 24
	.byte	24, 24, 23, 22, 21, 20, 18, 16, 13, 10, 7, 4

_move_start:
	lda	#MOVE_FRAMES
	bra	start
_jump_start:
	lda	#JUMP_FRAMES
start:	sta	mlen
	sta	_move_left
	stb	_cell
	; ds = step[to] - angle, the short way round (the peak: no turn)
	ldd	#0
	tst	_cell
	beq	2$
	ldx	#_cell_step
	ldb	_cell
	abx
	ldb	,x
	clra
	subb	_dome_angle
	sbca	#0
	cmpd	#STEPS/2
	ble	1$
	subd	#STEPS
	bra	2$
1$:	cmpd	#-120			; (-STEPS/2: as6809 halves -240 as unsigned)
	bge	2$
	addd	#STEPS
2$:	bsr	per_frame
	std	inc_s
	ldx	#_cell_lat
	ldb	_cell
	abx
	ldb	,x
	clra
	subb	_ship_lat
	sbca	#0
	bsr	per_frame
	std	inc_l
	lda	_dome_angle
	clrb
	std	acc_s
	lda	_ship_lat
	clrb
	std	acc_l
	rts

; D = D * 256 / mlen (signed; |D| <= 120). 16 frames: D << 4. 24 frames:
; (D << 5) / 3 as (|D << 5| * 171) >> 9 (0.2% short: the landing snaps).
per_frame:
	lslb
	rola
	lslb
	rola
	lslb
	rola
	lslb
	rola
	pshs	a
	lda	mlen
	cmpa	#MOVE_FRAMES
	puls	a
	beq	9$
	lslb				; << 5
	rola
	clr	msign
	tsta
	bpl	1$
	com	msign
	coma
	comb
	addd	#1
1$:	pshs	b			; |D| * 171 >> 9: hi * 171 + (lo * 171) >> 8, >> 1
	ldb	#171
	mul				; hi * 171
	std	acc_l			; (scratch: start sets acc_l afterwards)
	puls	a
	ldb	#171
	mul
	tfr	a,b
	clra
	addd	acc_l
	lsra
	rorb
	tst	msign
	beq	9$
	coma
	comb
	addd	#1
9$:	rts

_move_step:
	ldd	acc_s			; dome rotation += inc, mod STEPS
	addd	inc_s
	cmpd	#STEPS_FP
	blo	1$
	tst	inc_s
	bmi	2$
	subd	#STEPS_FP
	bra	1$
2$:	addd	#STEPS_FP
1$:	std	acc_s
	addd	#0x80			; rounded
	cmpa	#STEPS
	blo	3$
	clra
3$:	sta	_dome_angle
	ldd	acc_l
	addd	inc_l
	std	acc_l
	addd	#0x80
	sta	_ship_lat
	dec	_move_left
	lda	mlen
	cmpa	#JUMP_FRAMES
	bne	4$
	ldx	#lift_tab
	ldb	_move_left
	lda	b,x
	sta	_ship_lift
4$:	tst	_move_left
	bne	9$
	clr	_ship_lift		; landed: exactly on the cell
	ldb	_cell
	beq	5$
	ldx	#_cell_step
	abx
	lda	,x
	sta	_dome_angle
5$:	ldx	#_cell_lat
	ldb	_cell
	abx
	lda	,x
	sta	_ship_lat
9$:	rts
