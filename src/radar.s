; radar.s: Elite-style 3D radar (as6809, gcc6809 -mabi=bx)
;
;   void radar_draw(unsigned char rot);   dome at rotation rot
;
; An ellipse stands for the plane through the sphere's centre, seen from the
; camera's side, with the dome as a small roof in the middle. Each flying
; missile is a stick from its spot on that plane up to its height, with a
; heading line from its top toward the centre: missiles fly straight at the
; sphere's centre, so that is the line the stick's top travels along. The spot turns with the dome like the missile does: the near
; side of the dome is the bottom of the ellipse. A missile aimed at the
; ship's cell (radar_ring/radar_phi, set by the game; ring 255 = none) gets
; its stick drawn three times (brighter) and a heading line twice as long; the
; game also blinks the ellipse (radar_dim).
;
; A missile's line is fixed in the dome's frame, so its spot needs only its
; distance R and its azimuth on screen j: x = R sin(theta) sin(j),
; y = -R sin(theta) cos(j) * flat, height = R cos(theta), with the per-ring
; factors in radar_k (tools/gen_dome.py radar_k). Five 8x8 MULs per missile.
;
; Drawing: one Reset0Ref, a move to the centre, the ellipse (one list, from
; and back to the centre), then each blip as one list from the centre and
; back. Every list closes on itself at one scale, so a console's ramp tail
; only grows the picture a little, without drift between the parts.
;
; Needs DP = $D0. Preserves U, Y.

	.module	radar
	.include "missile_cfg.inc"

	.globl	_radar_draw, _radar_ring, _radar_phi, _radar_dim
	.globl	_missiles, absin, _radar_k, _radar_frame
	.globl	draw_entries, mirror, move_ab

Intensity_a	= 0xF2AB
Reset0Ref	= 0xF354
VIA_t1_cnt_lo	= 0xD004
RADAR_BRIGHT	= 0x7f
HEAD_SHIFT	= 2		; heading line: 1/4 of the way to the centre (aimed: 1/2)

; struct missile (missile.h)
M_STATE	= 0
M_RING	= 1
M_PHI	= 2
M_R	= 13
M_SIZE	= 46
NMIS	= 3

	.area	.bss
_radar_ring:	.blkb	1
_radar_phi:	.blkb	1
_radar_dim:	.blkb	1	; the ellipse's intensity (set by the game)
rrot:	.blkb	1
rcount:	.blkb	1
rr:	.blkb	1	; R * 32
rj:	.blkb	1	; azimuth on screen
hr:	.blkb	1	; x radius
hy:	.blkb	1	; y radius
hh:	.blkb	1	; stick height
bx:	.blkb	1
by:	.blkb	1
blip:	.blkb	20	; the blip's list (entries)

	.area	.text

_radar_draw:
	pshs	u,y
	stb	rrot
	clr	mirror
	lda	_radar_dim
	jsr	Intensity_a
	jsr	Reset0Ref
	lda	#RADAR_CSCALE
	sta	VIA_t1_cnt_lo
	lda	#RADAR_CY
	ldb	#RADAR_CX
	jsr	move_ab
	lda	#RADAR_ESCALE
	sta	VIA_t1_cnt_lo
	ldx	#_radar_frame
	ldb	,x+
	clra
	tfr	d,y
	jsr	draw_entries
	lda	#RADAR_BRIGHT
	jsr	Intensity_a
	lda	#RADAR_SCALE
	sta	VIA_t1_cnt_lo
	ldu	#_missiles
	lda	#NMIS
	sta	rcount
1$:	lda	M_STATE,u
	cmpa	#1
	lbne	9$
	lda	M_R,u			; R * 8
	cmpa	#RADAR_RMAX
	lbhs	9$			; beyond the radar's range
	ldd	M_R,u
	lslb
	rola
	lslb
	rola
	sta	rr			; R * 32 (R < 8)
	; j = (phi + rot) mod 240
	ldb	M_PHI,u
	addb	rrot
	bcc	2$
	addb	#256-MIS_STEPS
	bra	3$
2$:	cmpb	#MIS_STEPS
	blo	3$
	subb	#MIS_STEPS
3$:	stb	rj
	; ring factors
	ldb	M_RING,u
	lda	#3
	mul
	ldx	#_radar_k
	abx
	lda	rr
	ldb	,x
	mul
	sta	hr
	lda	rr
	ldb	1,x
	mul
	sta	hy
	lda	rr
	ldb	2,x
	mul
	sta	hh
	; x = hr |sin j| (negative for j > 120)
	ldb	rj
	jsr	absin
	lda	hr
	mul
	ldb	rj
	cmpb	#MIS_HALF
	bls	4$
	nega
4$:	sta	bx
	; y = -hy cos j, cos j = sin(j + 60)
	ldb	rj
	addb	#MIS_QUARTER
	bcc	5$
	addb	#256-MIS_STEPS
	bra	6$
5$:	cmpb	#MIS_STEPS
	blo	6$
	subb	#MIS_STEPS
6$:	stb	rj
	jsr	absin
	lda	hy
	mul
	ldb	rj
	cmpb	#MIS_HALF
	bhi	7$			; cos < 0: far side, up
	nega
7$:	sta	by
	; the list: move to the spot, stick up (three times if aimed at the
	; ship), a heading line from the stick's top toward the centre (the
	; missile's path: it flies straight at the sphere's centre), move back
	ldy	#4			; entries
	lda	#HEAD_SHIFT
	sta	rj			; heading: 1/2^HEAD_SHIFT of the way to the centre
	ldx	#blip
	lda	#0x80
	sta	,x+
	lda	by
	ldb	bx
	std	,x++			; move to the spot
	lda	hh
	clrb
	std	,x++			; stick
	lda	M_RING,u
	cmpa	_radar_ring
	bne	8$
	lda	M_PHI,u
	cmpa	_radar_phi
	bne	8$
	lda	hh			; aimed at the ship: down and up again
	nega
	clrb
	std	,x++
	nega
	std	,x++
	ldy	#6
	lda	#HEAD_SHIFT-1		; and a heading line twice as long
	sta	rj
8$:	lda	by
	adda	hh
	sta	hy			; the stick's top: (by + hh, bx)
	ldb	bx
10$:	asra
	asrb
	dec	rj
	bne	10$
	nega				; heading: -(top) / 2^shift
	negb
	std	,x++
	adda	hy			; back: -(top + heading)
	addb	bx
	nega
	negb
	pshs	d
	lda	#0x80
	sta	,x+
	puls	d
	std	,x
	ldx	#blip
	jsr	draw_entries
9$:	leau	M_SIZE,u
	dec	rcount
	lbne	1$
	puls	u,y,pc
