; missile_draw.s: enemy missiles, the player's bullets and explosions
; (as6809, gcc6809 -mabi=bx)
;
;   void missiles_step(void);              advance every flight one frame
;   void missiles_draw(unsigned char rot); draw them, dome at rotation rot
;   void explosions_draw(void);            draw the explosions
;
; Bullets are the same kind of object (M_KIND 1): a radial line through a
; cell, flown outward, drawn as a short line along it.
; A missile flies a straight line through the centre of a cell toward the
; sphere's centre, fixed in the dome's frame, so it turns with the dome. Its
; screen position depends on the rotation, so it is projected here every
; frame in fixed point, following mis_project_int() in tools/gen_dome.py step
; by step (the generator checks that model against exact projection: < 2
; screen units off). See gen_dome.py "enemy missiles" for the state format.
;
; Drawing: Reset0Ref, one move to the missile's tip, then its precomputed
; dart shape at a scale that follows the perspective, through dome_draw.s's
; entry loop. The move is at _mis_scale[m-1], m = 1, 2 or 3 DAC units per
; screen unit by distance: missile.c sets those from the calibrated
; dome_pos_scale so a move's length agrees with the dome's on a console with
; a ramp tail, and sets _mis_oy to match where the dome's anchor move
; really puts the dome.
;
; Needs DP = $D0 for drawing (true in the frame loop). Preserves U, Y.

	.module	missile_draw
	.include "dome_cfg.inc"
	.include "missile_cfg.inc"

	.globl	_missiles_step, _missiles_draw, _missiles, _explosions_draw, _explosions
	.globl	_mis_absin, _mis_inv, _mis_occ, _mis_sprites, _mis_scale, _mis_oy
	.globl	_expl_frames
	.globl	draw_entries, mirror, move_to, tx, ty	; move_to: also cracks.s

Intensity_a	= 0xF2AB
Reset0Ref	= 0xF354
VIA_t1_cnt_lo	= 0xD004
; direct-page offsets (DP = $D0)
P_B		= 0x00
P_A		= 0x01
T1H		= 0x05
IFR		= 0x0D
SR		= 0x0A		; shift register: $FF = beam on
CNTL		= 0x0C		; $CE: integrators run (Reset0Ref leaves $CC)
MIS_INTENSITY	= 0x7f

; struct missile (missile.h): keep in step
M_STATE	= 0		; 0 free, 1 flying, 2 just hit the dome
M_RING	= 1
M_PHI	= 2		; cell azimuth, rotation steps
M_KIND	= 3		; 0 missile, 1 bullet
M_H	= 4		; H, A, B, R: 24-bit, top 16 bits 5.11
M_A	= 7
M_B	= 10
M_R	= 13
M_DH	= 16		; increments per frame, 24-bit, same units
M_DA	= 19
M_DB	= 22
M_DR	= 25
M_SX	= 28		; screen position drawn (units at POS_SCALE)
M_SY	= 30
M_VIS	= 32		; 1 if on screen and not hidden (drawn)
M_LIFE	= 33		; bullet: frames left
M_VX	= 34		; per-frame motion on screen, for the frames between
M_VY	= 35		;   projections
M_SCL	= 36		; dart scale, view (pointer) and mirror flag
M_MIR	= 37		; bit 0: x mirrored, bit 1: bullet (flipped)
M_SPR	= 38
M_PX	= 40		; position at the last projection
M_PY	= 42
M_AGE	= 44		; frames since the last projection (max 15)
M_NEW	= 45		; > 0: project in the next frames (new, or just appeared)
M_SIZE	= 46
NOBJ	= 5		; missiles.h NOBJ (3 missiles + 2 bullets)
; struct expl (missile.h)
E_T	= 0		; 0 free, else frames since the hit + 1
E_SX	= 1
E_SY	= 3
E_SIZE	= 5
NEXPL	= 2

	.area	.bss
_missiles:	.blkb	NOBJ*M_SIZE
_explosions:	.blkb	NEXPL*E_SIZE
mproj:	.blkb	1	; the slot projected this frame
tx:	.blkb	2	; move_to target
ty:	.blkb	2
mcount:	.blkb	1
mrot:	.blkb	1	; dome rotation
mj:	.blkb	1	; missile azimuth on screen, rotation steps
tmp:	.blkb	2
hs:	.blkb	2	; H sin, H cos (5.11)
hc:	.blkb	2
zz:	.blkb	2	; depth (5.11)
uu:	.blkb	2	; height term (5.11)
inv:	.blkb	2	; perspective S*32/Z
mframe:	.blkb	1	; the slot projected this frame
pvis:	.blkb	1
; multiply scratch
ma:	.blkb	2
mm:	.blkb	1
msg:	.blkb	1
mp:	.blkb	2
mq:	.blkb	2
mu:	.blkb	2
acx:	.blkb	1
fx:	.blkb	1	; flip_entries: x mask
_fl_dir:	.blkb	2	; flight_inc: direction (4 x 16-bit)
_fl_spd:	.blkb	1	; flight_inc: speed
; move_to
py:	.blkb	1
px:	.blkb	1

	.area	.text

; ---- void missiles_step(void) ------------------------------------------
; H, A, B, R += their increments (16-bit, sign-extended into 24 bits). A
; flight ends (state 2) when R reaches 1.0 = $080000, which the generator
; makes happen exactly on a frame.
_missiles_step:
	pshs	u
	ldu	#_missiles
	lda	#NOBJ
	sta	mcount
1$:	lda	M_STATE,u
	cmpa	#1
	bne	3$
	ldd	M_H+1,u
	addd	M_DH+1,u
	std	M_H+1,u
	lda	M_H,u
	adca	M_DH,u
	sta	M_H,u
	ldd	M_A+1,u
	addd	M_DA+1,u
	std	M_A+1,u
	lda	M_A,u
	adca	M_DA,u
	sta	M_A,u
	ldd	M_B+1,u
	addd	M_DB+1,u
	std	M_B+1,u
	lda	M_B,u
	adca	M_DB,u
	sta	M_B,u
	ldd	M_R+1,u
	addd	M_DR+1,u
	std	M_R+1,u
	lda	M_R,u
	adca	M_DR,u
	sta	M_R,u
	tst	M_KIND,u
	beq	4$
	dec	M_LIFE,u		; bullet: gone when its time is up
	bne	3$
	clr	M_STATE,u
	bra	3$
4$:	cmpa	#8			; missile landed? R <= 1.0
	blo	2$
	bhi	3$
	ldd	M_R+1,u
	bne	3$
2$:	lda	#2
	sta	M_STATE,u
3$:	leau	M_SIZE,u
	dec	mcount
	bne	1$
	puls	u,pc

; ---- void missiles_draw(unsigned char rot) ---------------------------------
_missiles_draw:
	pshs	u,y
	stb	mrot
	lda	#MIS_INTENSITY
	jsr	Intensity_a
	; one object is projected per frame (a projection costs ~1k cycles):
	; the first one asking for it (M_NEW: new, or just came into view, to
	; learn its motion), else the next slot in turn. The others move by their
	; last per-frame motion.
	lda	mframe
	inca
	cmpa	#NOBJ
	blo	8$
	clra
8$:	sta	mframe
	sta	mproj
	ldu	#_missiles
	clrb
9$:	lda	M_STATE,u
	cmpa	#1
	bne	10$
	tst	M_NEW,u
	beq	10$
	dec	M_NEW,u
	stb	mproj
	bra	11$
10$:	leau	M_SIZE,u
	incb
	cmpb	#NOBJ
	blo	9$
11$:	ldu	#_missiles
	lda	#NOBJ
	sta	mcount
1$:	lda	M_STATE,u
	cmpa	#1
	bne	5$
	lda	M_AGE,u
	cmpa	#15
	bhs	12$
	inc	M_AGE,u
12$:	lda	#NOBJ
	suba	mcount			; slot index
	cmpa	mproj
	bne	4$
	pshs	u
	lbsr	project
	puls	u
	bra	6$
4$:	tst	M_VIS,u
	beq	7$
	ldb	M_VX,u
	sex
	addd	M_SX,u
	std	M_SX,u
	cmpd	#MIS_XLIM		; moved off the screen?
	bgt	13$
	cmpd	#-MIS_XLIM
	blt	13$
	ldb	M_VY,u
	sex
	addd	M_SY,u
	std	M_SY,u
	cmpd	#MIS_YHI
	bgt	13$
	cmpd	#MIS_YLO
	bge	6$
13$:	clr	M_VIS,u
	bra	7$
6$:	tst	M_VIS,u
	beq	7$
	pshs	u
	lbsr	draw_it
	puls	u
	bra	7$
5$:	clr	M_VIS,u
7$:	leau	M_SIZE,u
	dec	mcount
	bne	1$
	puls	u,y,pc

; project the missile at U: sets M_VIS (0 if off screen or behind the dome)
; and, if visible, M_SX/M_SY, M_VX/M_VY, M_SCL, M_SPR, M_MIR
project:
	lda	M_VIS,u
	sta	pvis
	clr	M_VIS,u
	; mj = (phi + rot) mod 240
	ldb	M_PHI,u
	addb	mrot
	bcc	1$
	addb	#256-MIS_STEPS		; the sum passed 255: subtract 240
	bra	2$
1$:	cmpb	#MIS_STEPS
	blo	2$
	subb	#MIS_STEPS
2$:	stb	mj
	; hidden behind the dome? R < 1.0 + occ*(1/64), occ by ring and mirrored mj
	cmpb	#MIS_HALF
	bls	3$
	negb				; 240 - mj
	subb	#256-MIS_STEPS
3$:	lsrb				; one entry per 4 steps
	lsrb
	stb	tmp
	lda	M_RING,u
	ldb	#MIS_OCC_ROW
	mul
	addb	tmp
	adca	#0
	ldx	#_mis_occ
	ldb	d,x
	beq	4$
	lda	#32
	mul				; occ * 32 = (r - 1) in 5.11
	addd	#0x0800
	cmpd	M_R,u
	lbhi	off			; R below the threshold: hidden
4$:	; hs = H * sin(mj), hc = H * cos(mj) = H * sin(mj + 60)
	ldb	mj
	lbsr	absin
	stb	mm
	ldd	M_H,u			; H >= 0
	std	ma
	lbsr	mulm
	ldb	mj
	cmpb	#MIS_HALF
	bls	5$			; sin < 0 for mj > 120
	ldd	mq
	coma
	comb
	addd	#1
	std	mq
5$:	ldd	mq
	std	hs
	ldb	mj
	addb	#MIS_QUARTER
	bcc	6$
	addb	#256-MIS_STEPS
	bra	7$
6$:	cmpb	#MIS_STEPS
	blo	7$
	subb	#MIS_STEPS
7$:	stb	tmp
	lbsr	absin
	stb	mm
	lbsr	mulm			; |hc| in mq (ma = H still)
	; Z = A -+ |hc| |fz|, U = B -+ |hc| |uz| (fwd.z, up.z < 0; sign of cos)
	ldd	mq
	std	ma
	ldb	#MIS_FZ
	lbsr	mulc
	std	zz
	ldb	#MIS_UZ
	lbsr	mulc
	std	uu
	ldb	tmp
	cmpb	#MIS_HALF
	bhi	8$			; cos < 0: add
	ldd	M_A,u
	subd	zz
	std	zz
	ldd	M_B,u
	subd	uu
	std	uu
	bra	81$
8$:	ldd	M_A,u
	addd	zz
	std	zz
	ldd	M_B,u
	addd	uu
	std	uu
81$:
	; drawable depth?
	ldd	zz
	cmpd	#MIS_ZMIN
	lblt	near
	cmpd	#MIS_ZMAX
	lbge	off
	; inv = T[i] - ((T[i] - T[i+1]) * f + 64) >> 7,  i = Z >> 7, f = Z & 127,
	; as (diff * 2f + 128) >> 8 (diff < 8192 near the camera)
	andb	#0x7f
	lslb
	stb	mm			; 2f
	ldd	zz
	lslb
	rola				; A = Z >> 7
	tfr	a,b
	lslb				; 2i (i <= 126)
	ldx	#_mis_inv
	abx
	ldd	,x
	std	inv
	subd	2,x			; diff (< 8192)
	std	tmp
	lda	tmp+1
	ldb	mm
	mul				; lo * 2f
	addd	#128
	sta	mp			; (lo * 2f + 128) >> 8
	lda	tmp
	ldb	mm
	mul				; hi * 2f
	addb	mp
	adca	#0
	std	tmp
	ldd	inv
	subd	tmp
	std	inv
	; screen position: x = hs * inv >> 16, y = U * inv >> 16 + OYREL
	ldd	hs
	lbsr	mulhi
	cmpd	#MIS_XLIM
	lbgt	off
	cmpd	#-MIS_XLIM
	lblt	off
	std	hs			; (hs is free now: new x)
	ldd	uu
	lbsr	mulhi
	addd	_mis_oy
	cmpd	#MIS_YHI
	lbgt	off
	cmpd	#MIS_YLO
	lblt	off
	std	uu			; new y
	; per-frame motion: the change since the last projection / M_AGE, if it
	; was on screen then; if not, project again next frame to learn it
	clr	M_VX,u
	clr	M_VY,u
	tst	pvis
	bne	13$
	lda	#1
	sta	M_NEW,u
	bra	12$
13$:	subd	M_PY,u
	lbsr	per_frame
	stb	M_VY,u
	ldd	hs
	subd	M_PX,u
	lbsr	per_frame
	stb	M_VX,u
12$:	clr	M_AGE,u
	ldd	hs
	std	M_SX,u
	std	M_PX,u
	ldd	uu
	std	M_SY,u
	std	M_PY,u
	; sprite scale = ((inv >> 7) * KSPR) >> 6, at least 1
	ldd	inv
	lslb
	rola				; A = inv >> 7 (inv < 32768)
	ldb	#MIS_KSPR
	mul
	lslb
	rola
	lslb
	rola				; A = (...) >> 6
	tsta
	bne	9$
	inca
9$:	sta	M_SCL,u
	; sprite view: q = round(mj / 5) = ((mj + 2) * 205) >> 10, mod 48;
	; q > 24 is view 48 - q mirrored. A bullet uses the missile's picture
	; turned tip-outward (drawn with x and y negated, M_MIR bit 1) and
	; smaller (BUL_K / 16).
	clr	M_MIR,u
	ldb	mj
	addb	#2
	lda	#205
	mul
	lsra
	lsra
	cmpa	#MIS_SPR_PHI
	blo	10$
	clra
10$:	cmpa	#MIS_SPR_STORED-1
	bls	11$
	nega
	adda	#MIS_SPR_PHI
	inc	M_MIR,u
11$:	sta	tmp
	lda	M_RING,u
	ldb	#MIS_SPR_STORED
	mul
	addb	tmp
	adca	#0
	lslb
	rola
	ldx	#_mis_sprites
14$:	ldx	d,x
	stx	M_SPR,u
	tst	M_KIND,u
	beq	15$
	lda	M_MIR,u			; bullet: flipped, and smaller
	ora	#2
	sta	M_MIR,u
	lda	M_SCL,u
	ldb	#BUL_K
	mul
	lsra
	rorb
	lsra
	rorb
	lsra
	rorb
	lsra
	rorb				; * BUL_K / 16
	tstb
	bne	16$
	incb
16$:	stb	M_SCL,u
15$:
	inc	M_VIS,u
off:	rts

; too near the camera: if it was on screen, it flies on out of the screen
; past the viewer: keep it, twice as fast and half as big again each
; projection, until the motion takes it off the screen
near:	tst	pvis
	beq	off
	inc	M_VIS,u
	clr	M_AGE,u
	ldb	M_VX,u
	lbsr	dbl8
	stb	M_VX,u
	ldb	M_VY,u
	lbsr	dbl8
	stb	M_VY,u
	sex				; and move on this frame too
	addd	M_SY,u
	std	M_SY,u
	ldb	M_VX,u
	sex
	addd	M_SX,u
	std	M_SX,u
	lda	M_SCL,u
	cmpa	#48			; (a big dart at a big scale is slow to draw)
	bhs	1$
	tfr	a,b
	lsrb
	pshs	b
	adda	,s+			; * 1.5
	sta	M_SCL,u
1$:	rts

; B = 2 * B, clamped to -128..127
dbl8:	aslb
	bvc	1$
	ldb	#127
	bcc	1$			; (was positive)
	ldb	#-128
1$:	rts

; draw the object at U: one move to the tip, then its shape
draw_it:
	lda	M_MIR,u
	sta	mirror
	bita	#2
	bne	flip_it
	ldd	M_SX,u
	std	tx
	ldd	M_SY,u
	std	ty
	bsr	move_to
	lda	M_SCL,u
	sta	VIA_t1_cnt_lo
	ldx	M_SPR,u
	ldb	,x+			; entry count
	clra
	tfr	d,y
	jmp	draw_entries		; (returns to our caller)

; a bullet: the picture with y negated, and x negated unless mirrored
flip_it:
	anda	#1
	deca				; mirrored: 0, else $FF
	sta	fx
	ldd	M_SX,u
	std	tx
	ldd	M_SY,u
	std	ty
	bsr	move_to
	lda	M_SCL,u
	sta	VIA_t1_cnt_lo
	ldx	M_SPR,u
	ldb	,x+			; entry count
	clra
	tfr	d,y
; draw Y entries from X with dy negated and dx = (dx ^ fx) - fx (negated if
; fx = $FF). Few entries (bullets): no prefetching.
flip_entries:
	ldb	,x+
	cmpb	#0x80
	beq	3$
	negb
	clra
	std	*P_B			; mux on: sample y
	ldb	,x+
	eorb	fx
	subb	fx
	lda	#1
	std	*P_B			; mux off, x to the DAC
	ldd	#0xFF00
	sta	*SR			; beam on
	stb	*T1H
	lda	#0x40
1$:	bita	*IFR
	beq	1$
	clr	*SR
	bra	4$
3$:	ldb	,x+			; blank move
	negb
	clra
	std	*P_B
	ldb	,x+
	eorb	fx
	subb	fx
	lda	#1
	std	*P_B
	clr	*T1H
	lda	#0x40
2$:	bita	*IFR
	beq	2$
4$:	leay	-1,y
	bne	flip_entries
	rts

; Reset0Ref, then one blank move to (ty, tx) (screen units at POS_SCALE,
; |tx|, |ty| <= 381) at _mis_scale[m-1], m = 1, 2 or 3 DAC units per unit.
move_to:
	jsr	Reset0Ref
	lbsr	absmax			; D = max(|tx|, |ty|)
	ldx	#_mis_scale
	cmpd	#127
	bls	20$			; m = 1
	leax	1,x
	cmpd	#254
	bls	21$			; m = 2
	leax	1,x			; m = 3
	ldd	ty
	lbsr	div3
	stb	py
	ldd	tx
	lbsr	div3
	stb	px
	bra	22$
21$:	ldd	ty			; (d + 1) >> 1
	addd	#1
	asra
	rorb
	stb	py
	ldd	tx
	addd	#1
	asra
	rorb
	stb	px
	bra	22$
20$:	ldb	ty+1
	stb	py
	ldb	tx+1
	stb	px
22$:	lda	,x
	sta	VIA_t1_cnt_lo
	lda	#0xCE			; the move, as BIOS Moveto_d (Y held longer)
	sta	*CNTL
	ldb	py
	clra
	std	*P_B			; mux on, y to the DAC
	ldb	px
	lda	#1
	nop
	nop
	nop
	std	*P_B			; mux off, x
	clr	*T1H
	lda	#0x40
23$:	bita	*IFR
	beq	23$
	rts

; ---- void explosions_draw(void) ----------------------------------------------
; each explosion: its animation step (t - 1) / 2 at the hit's screen position,
; fading
_explosions_draw:
	pshs	u,y
	ldu	#_explosions
	lda	#NEXPL
	sta	mcount
1$:	lda	E_T,u
	beq	2$
	lsla				; intensity 0x7f - 2t
	nega
	adda	#0x7f
	jsr	Intensity_a
	clr	mirror
	ldd	E_SX,u
	std	tx
	ldd	E_SY,u
	std	ty
	lbsr	move_to
	lda	#EXPL_SCALE
	sta	VIA_t1_cnt_lo
	ldb	E_T,u
	decb
	andb	#0xfe			; ((t - 1) >> 1) * 2: pointer index
	ldx	#_expl_frames
	abx
	ldx	,x
	ldb	,x+
	clra
	tfr	d,y
	pshs	u
	jsr	draw_entries
	puls	u
2$:	leau	E_SIZE,u
	dec	mcount
	bne	1$
	puls	u,y,pc

; B = D / M_AGE of the object at U (frames since the last projection,
; >= 1), clamped to -128..127: (|D| * 256/age) >> 8
per_frame:
	clr	msg
	tsta
	bpl	1$
	com	msg
	coma
	comb
	addd	#1
1$:	cmpd	#2047
	bls	2$
	ldd	#2047
2$:	std	ma
	ldb	M_AGE,u
	cmpb	#1
	bne	3$
	ldd	ma			; age 1: the change itself
	bra	4$
3$:	ldx	#recip
	ldb	b,x
	stb	mm
	lda	ma+1
	mul
	addd	#128
	sta	mp+1
	lda	ma
	ldb	mm
	mul
	addb	mp+1
	adca	#0			; D = (|D| * r) >> 8
4$:	cmpd	#127
	bls	5$
	ldb	#127
5$:	tst	msg
	beq	6$
	negb
6$:	rts
recip:	.byte	0, 0, 128, 85, 64, 51, 43, 37, 32, 28, 26, 23, 21, 20, 18, 17

; D = max(|tx|, |ty|)
absmax:
	ldd	ty
	bpl	1$
	coma
	comb
	addd	#1
1$:	std	tmp
	ldd	tx
	bpl	2$
	coma
	comb
	addd	#1
2$:	cmpd	tmp
	bhs	3$
	ldd	tmp
3$:	rts

; B = round(D / 3) for |D| <= 381: (|D| * 85 + 128) >> 8, signed
div3:
	clr	msg
	tsta
	bpl	1$
	com	msg
	coma
	comb
	addd	#1
1$:	std	ma
	lda	ma+1
	ldb	#85
	mul
	std	mp
	lda	ma
	ldb	#85
	mul
	tfr	b,a
	clrb
	addd	mp
	addd	#128
	tfr	a,b
	tst	msg
	beq	2$
	negb
2$:	rts

; mq = round(ma * mm / 255), ma >= 0. Model: p = a m; p += p >> 8;
; (p + 128) >> 8. Clobbers D.
mulm:
	lda	ma+1
	ldb	mm
	mul
	std	mp			; lo * m
	lda	ma
	ldb	mm
	mul
	addb	mp
	adca	#0			; D = p >> 8
	std	mq
	addb	mp+1			; + p0
	adca	#0
	addd	#128
	tfr	a,b
	clra
	addd	mq			; p>>8 + ((p>>8 + p0 + 128) >> 8)
	std	mq
	rts

; D = round(ma * B / 256), ma >= 0. Clobbers mp.
mulc:
	stb	mm
	lda	ma+1
	mul
	addd	#128
	sta	mp+1			; (lo * k + 128) >> 8
	lda	ma
	ldb	mm
	mul
	addb	mp+1
	adca	#0
	rts

; D = (a * inv + $8000) >> 16, signed a (in D), unsigned inv. Sign-magnitude.
mulhi:
	clr	msg
	tsta
	bpl	1$
	com	msg
	coma
	comb
	addd	#1
1$:	std	ma
	lda	ma+1
	ldb	inv+1
	mul				; al * ul
	tfr	a,b
	clra
	addd	#128			; ((al ul + $8000) >> 8)
	std	mu
	clr	acx
	lda	ma
	ldb	inv+1
	mul				; ah * ul
	addd	mu
	std	mu
	bcc	2$
	inc	acx
2$:	lda	ma+1
	ldb	inv
	mul				; al * uh
	addd	mu
	std	mu
	bcc	3$
	inc	acx
3$:	lda	ma
	ldb	inv
	mul				; ah * uh
	addb	mu
	adca	acx			; + (middle sum >> 8)
	tst	msg
	beq	4$
	coma
	comb
	addd	#1
4$:	rts

; ---- void flight_inc(unsigned char *dst) -------------------------------------
; A flight's per-frame increments (4 x 24-bit at dst) from its direction
; (_fl_dir: 4 x signed 16-bit) and speed (_fl_spd): inc = sign *
; ((|dir| * spd + 128) >> 8), as gen_dome.py models it. Called at launch.
	.globl	_flight_inc, _fl_dir, _fl_spd
_flight_inc:
	pshs	u
	ldu	_fl_dir
	lda	#4
	sta	mcount
1$:	clr	msg
	ldd	,u++
	bpl	2$
	com	msg
	coma
	comb
	addd	#1
2$:	std	ma
	lda	ma+1
	ldb	_fl_spd
	mul
	addd	#128
	tfr	a,b
	clra
	std	mp			; (lo * spd + 128) >> 8
	lda	ma
	ldb	_fl_spd
	mul
	addd	mp			; |inc|
	clr	,x			; high byte: 0, or $FF if negative
	tst	msg
	beq	3$
	cmpd	#0
	beq	3$
	coma
	comb
	addd	#1
	com	,x
3$:	std	1,x
	leax	3,x
	dec	mcount
	bne	1$
	puls	u,pc

; B = |sin(B)| * 255 (B = 0..239 rotation steps) from the quarter-wave
; table: j mod 120, then 120 - j past 60. Clobbers X.
	.globl	absin
absin:	cmpb	#MIS_HALF
	blo	1$
	subb	#MIS_HALF
1$:	cmpb	#MIS_QUARTER
	bls	2$
	negb
	addb	#MIS_HALF
2$:	ldx	#_mis_absin
	abx
	ldb	,x
	rts

; ---- void copy12(unsigned char *dst, const unsigned char *src) -------------
; 12 bytes (a flight state or its increments), ~80 cycles (a C loop: ~400)
	.globl	_copy12
_copy12:
	pshs	u
	ldu	4,s			; src (dst in X)
	ldd	,u
	std	,x
	ldd	2,u
	std	2,x
	ldd	4,u
	std	4,x
	ldd	6,u
	std	6,x
	ldd	8,u
	std	8,x
	ldd	10,u
	std	10,x
	puls	u,pc
