; hud.s: the readouts (as6809, gcc6809 -mabi=bx)
;
;   void hud_draw(void);
;
; Draws HUD_LINES lines of glyphs (hud_lines, set by the game when a value
; changes): for each line with glyphs, Reset0Ref, one move to its baseline
; start, then each glyph, which ends at the next one's start. Vector glyphs
; from hud_glyphs (gen_dome.py HUD_GLYPHS) instead of BIOS text: Print_Str_d
; cost ~3.7k cycles for "DOME 100%"; these cost ~55 per stroke.
;
; Needs DP = $D0. Preserves U, Y.

	.module	hud
	.include "missile_cfg.inc"

	.globl	_hud_draw, _hud_lines
	.globl	draw_entries, mirror, move_ab

Intensity_a	= 0xF2AB
Reset0Ref	= 0xF354
VIA_t1_cnt_lo	= 0xD004
HUD_INTENSITY	= 0x5f
HUD_LINES	= 3
HUD_MOVE_SCALE	= 0xA0		; positions: reaches below the dome (y -116 = -146 at $7F)
HL_SIZE		= 19		; struct hud_line (missile.h): y, x, n, 8 glyph pointers

	.area	.bss
_hud_lines:	.blkb	HUD_LINES*HL_SIZE
hline:		.blkb	1
hcount:		.blkb	1
hptr:		.blkb	2

	.area	.text

_hud_draw:
	pshs	u,y
	clr	mirror
	lda	#HUD_INTENSITY
	jsr	Intensity_a
	ldu	#_hud_lines
	lda	#HUD_LINES
	sta	hline
1$:	lda	2,u			; glyphs on this line
	beq	3$
	sta	hcount
	jsr	Reset0Ref
	lda	#HUD_MOVE_SCALE
	sta	VIA_t1_cnt_lo
	lda	,u			; baseline start (y, x), DAC units at HUD_MOVE_SCALE
	ldb	1,u
	jsr	move_ab
	lda	#HUD_SCALE
	sta	VIA_t1_cnt_lo
	leax	3,u
	stx	hptr
2$:	ldx	hptr
	ldx	,x
	ldb	,x+
	clra
	tfr	d,y
	jsr	draw_entries
	ldx	hptr
	leax	2,x
	stx	hptr
	dec	hcount
	bne	2$
3$:	leau	HL_SIZE,u
	dec	hline
	bne	1$
	puls	u,y,pc
