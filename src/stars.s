; stars.s: the stars behind the dome (as6809, gcc6809 -mabi=bx)
;
;   void stars_draw(unsigned char off);
;
; Dots in the sky above the dome (none low enough for the dome to hide), all
; shifted right by `off` (wrapping round the screen's width), so the game
; turns them with the dome: off follows dome_angle. Each: Reset0Ref, then
; BIOS Dot_d to its position (~250 cycles a star).
;
; Needs DP = $D0. Preserves U, Y.

	.module	stars
	.globl	_stars_draw

Intensity_a	= 0xF2AB
Reset0Ref	= 0xF354
Dot_d		= 0xF2C3
Vec_Dot_Dwell	= 0xC828
VIA_t1_cnt_lo	= 0xD004
STAR_INTENSITY	= 0x3f		; dim: behind everything else
STAR_DWELL	= 4		; beam-on time of each dot (BIOS loop count)
STAR_SCALE	= 0x7f		; positions in the units of BIOS text

	.area	.text

; (y, x): random (seed 60) with no two closer than 14, no x gap over 48 and
; each third of the sky's height used; y >= 8 clears the dome's top (~-32)
stars:	.byte	44,29, 41,-50, 111,-11, 67,119, 13,42, 93,-81
	.byte	27,-34, 13,71, 89,-6, 60,-124, 87,28, 73,-52
stars_end:

_stars_draw:
	pshs	b,u
	lda	#STAR_INTENSITY
	jsr	Intensity_a
	lda	#STAR_DWELL
	sta	Vec_Dot_Dwell
	ldu	#stars
1$:	jsr	Reset0Ref
	lda	#STAR_SCALE
	sta	VIA_t1_cnt_lo
	ldd	,u++
	addb	,s			; x + off, wrapping
	jsr	Dot_d
	cmpu	#stars_end
	bne	1$
	puls	b,u,pc
