; dome_draw.s: draw the rotating geodesic dome and the ship (as6809,
; gcc6809 -mabi=bx)
;
;   void dome_draw(unsigned char step);   step in B, 0..DOME_STEPS-1 = one turn
;   void ship_draw(unsigned char lat);    lat in B, 0 (peak) .. SHIP_STEPS-1
;
; Both feed precomputed vector lists to the same chunk loop below, so the
; ship gets the same real-hardware compensation as the dome and stays put on
; its surface.
; Every view is precomputed by tools/gen_dome.py (see its docstring for the
; data format and why). 5-fold symmetry: view = step mod DOME_VIEWS. Mirror
; symmetry: views 0..DOME_STORED-1 are stored, view v beyond that is stored
; view DOME_VIEWS-v drawn with x negated.
;
; Per chunk: Reset0Ref, (if DOME_ANCHOR_Y) a fixed blank move to the anchor,
; a move to the start at scale _dome_pos_scale (calibrated for the console's
; ramp tail, see gen_dome.py; both moves by move_ab, a lean Moveto_d), then
; this module's own list loop at DOME_LINE_SCALE. It
; drives the VIA the way BIOS Draw_Line_d does, but reads 2-byte entries
; (dy, dx) for lines and 3-byte entries (0x80, dy, dx) for blank moves, and
; has a mirrored copy (NEGB on dx), so the data is 1/3 smaller than BIOS
; Draw_VLp lists and only half the views are stored. The mux stays on ~12
; cycles per entry so the Y sample-and-hold charges fully on real hardware
; (tau ~2.7 cycles; the BIOS's 7 leave a few % of a big Y jump behind).
;
; Needs DP = $D0 (true in the frame loop after Wait_Recal). Preserves U, Y.

	.module	dome_draw
	.include "dome_cfg.inc"

	.globl	_dome_draw, _ship_draw, _zero_ref_settle
	.globl	draw_entries, mirror, move_ab	; for missile_draw.s, radar.s
	.globl	_dome_views, _ship_views, _dome_pos_scale, _ship_lift
	.globl	_dome_burst, _dome_shake, _dome_sink, _dome_dim

Intensity_a	= 0xF2AB
Reset0Ref	= 0xF354
VIA_t1_cnt_lo	= 0xD004
; direct-page offsets (DP = $D0)
P_B		= 0x00		; VIA port B (mux enable, bit 0)
P_A		= 0x01		; VIA port A (DAC)
T1H		= 0x05		; timer 1 high: writing it starts the vector
SR		= 0x0A		; shift register: $FF = beam on, $00 = blank
IFR		= 0x0D		; interrupt flags: $40 = timer 1 done
CNTL		= 0x0C		; peripheral control: $CE = integrators run
DOME_INTENSITY	= 0x6f
SHIP_INTENSITY	= 0x7f

	.area	.bss
mirror:	.blkb	1
lift:	.blkb	1		; ship mid-jump: an extra move up after each start (0 = none)
; The dome collapsing (all 0 otherwise; set by e-srg.c): _dome_burst is
; added to the position scale (a wrong calibration: the runs fly apart from
; the anchor), _dome_shake (0 or 2^k-1) jitters each run by a random
; +-shake/2, _dome_sink moves every run down (the lift move), _dome_dim
; dims it.
_dome_burst:	.blkb	1
_dome_shake:	.blkb	1
_dome_sink:	.blkb	1
_dome_dim:	.blkb	1
seed:	.blkb	1

	.area	.text

; void zero_ref_settle(void): recharge the integrators' zero reference to
; DAC 0 fully. Call it after reading the joystick. BIOS Joy_Analog leaves
; the mux enabled on each pot's channel during its search, and the Y pot's
; channel (mux 3 = channel 1) is also the zero reference, so the reference
; ends up near the stick's Y value. Reset0Ref only reconnects it for ~8
; cycles (tau ~2.7), so ~5% of that error survived as a velocity offset that
; shifted the first chains drawn (seen on a real Vectrex 2026-10-06 with the
; stick held down-left; vecx doesn't model the reference). ~35 cycles here
; leave < 0.1%.
_zero_ref_settle:
	clr	*P_A			; DAC 0
	ldd	#0x0302
	sta	*P_B			; mux channel 1 (zero reference), disabled
	stb	*P_B			; enabled: the reference charges toward 0
	ldb	#6
1$:	decb				; ~30 cycles
	bne	1$
	ldb	#0x01
	stb	*P_B			; disable the mux
	rts

_ship_draw:
	pshs	u,y
	clr	mirror
	lda	_ship_lift		; mid-jump: drawn this much higher
	sta	lift
	ldx	#_ship_views
	aslb
	abx				; unsigned: SHIP_STEPS*2 may exceed 127
	ldx	,x
	pshs	x
	lda	#SHIP_INTENSITY
	jsr	Intensity_a
	puls	x
	bra	chunk

_dome_draw:
	pshs	u,y
1$:	cmpb	#DOME_VIEWS		; step mod DOME_VIEWS
	blo	2$
	subb	#DOME_VIEWS
	bra	1$
2$:	clr	mirror
	lda	_dome_sink		; collapsing: every run lower (else 0)
	sta	lift
	cmpb	#DOME_STORED
	blo	3$
	negb				; view DOME_VIEWS - v, mirrored
	addb	#DOME_VIEWS
	inc	mirror
3$:	ldx	#_dome_views
	aslb
	ldx	b,x			; B <= 2*24, fits the signed 5/8-bit offset
	pshs	x
	lda	#DOME_INTENSITY
	suba	_dome_dim
	jsr	Intensity_a
	puls	x
chunk:
	ldb	,x+			; entries in this chunk, 0 = end
	lbeq	done
	clra
	tfr	d,y			; Y = entry count
	pshs	x
	jsr	Reset0Ref
	.if	DOME_ANCHOR_Y		; the picture is beyond +-127: same blank
	lda	#DOME_ANCHOR_SCALE	; move to the anchor for every chunk, so its
	sta	VIA_t1_cnt_lo		; analog error shifts the whole picture only
	lda	#DOME_ANCHOR_Y
	clrb
	bsr	move_ab
	.endif
	lda	_dome_pos_scale		; calibrated: see gen_dome.py TAIL_DEFAULT
	adda	_dome_burst		; (collapsing: more, up to 255)
	bcc	6$
	lda	#255
6$:	sta	VIA_t1_cnt_lo
	puls	x
	ldd	,x++			; absolute start (y, x)
	tst	mirror
	beq	4$
	negb
4$:	bsr	move_ab
	lda	lift
	beq	5$
	clrb
	bsr	move_ab			; (same scale: lift in position units)
5$:	tst	_dome_shake
	beq	7$
	bsr	jitter			; collapsing: a random nudge
	stb	,-s
	bsr	jitter
	lda	,s+
	bsr	move_ab
7$:	lda	#DOME_LINE_SCALE
	sta	VIA_t1_cnt_lo
	bsr	draw_entries
	bra	chunk
done:
	puls	u,y,pc

; jitter: B = random in -shake/2 .. +shake/2 (seed = seed*13 + 7, top 5
; bits: an 8-bit LCG's low bits repeat quickly). Clobbers A.
jitter:
	lda	seed
	ldb	#13
	mul
	addb	#7
	stb	seed
	lsrb
	lsrb
	lsrb
	andb	_dome_shake
	lda	_dome_shake
	lsra
	pshs	a
	subb	,s+
	rts

; move_ab: blank move by (A = dy, B = dx) at the scale in VIA_t1_cnt_lo, from
; the beam's position; waits for it. Like BIOS Moveto_d (which also leaves the
; integrators running, $CE) without its fixed settle delays: ~30 cycles +
; scale instead of ~70-110 + scale. The Y mux is held 14 cycles (S/H).
move_ab:
	sta	*P_A			; y to the DAC
	clr	*P_B			; mux on: sample y
	lda	#0xCE			; integrators run, zero off
	sta	*CNTL
	clr	*SR			; beam off
	nop
	inc	*P_B			; mux off
	stb	*P_A			; x to the DAC
	clr	*T1H			; go
	ldb	#0x40
1$:	bitb	*IFR
	beq	1$
	rts

; draw_entries: draw Y (>= 1) entries from X at the scale in VIA_t1_cnt_lo,
; from the beam's position, x negated if `mirror` is set. Returns X past the
; entries. Clobbers D, Y. Also used by missile_draw.s.
draw_entries:
	ldb	,x+			; first entry byte; the loops prefetch the next
	tst	mirror			; one while the beam is moving
	lbne	m_entry
	; ---- normal list loop ------------------------------------------
	; std *P_B writes port B (mux) then port A (DAC) in one instruction:
	; A = 0, B = dy: mux on, y to the DAC; A = 1, B = dx: mux off, x.
n_entry:
	cmpb	#0x80
	beq	n_move
	clra
	std	*P_B			; mux on: sample y
	ldb	,x+
	lda	#1
	nop				; Y hold ~14 cycles (S/H tau ~2.7)
	std	*P_B			; mux off, x to the DAC
	ldd	#0xFF00
	sta	*SR			; beam on
	stb	*T1H			; go: the beam moves for LINE_SCALE cycles
	leay	-1,y			; meanwhile: count and prefetch
	beq	n_last
	ldb	,x+
	lda	#0x40
1$:	bita	*IFR
	beq	1$
	clr	*SR			; beam off
	bra	n_entry
n_last:
	lda	#0x40
1$:	bita	*IFR
	beq	1$
	clr	*SR
	rts
n_move:
	ldb	,x+
	clra
	std	*P_B
	ldb	,x+
	lda	#1
	nop
	std	*P_B
	clr	*T1H			; beam stays off
	leay	-1,y
	beq	2$
	ldb	,x+
	lda	#0x40
3$:	bita	*IFR
	beq	3$
	bra	n_entry
2$:	lda	#0x40
4$:	bita	*IFR
	beq	4$
	rts
	; ---- mirrored list loop (x negated) ------------------------------
m_entry:
	cmpb	#0x80
	beq	m_move
	clra
	std	*P_B			; mux on: sample y
	ldb	,x+
	negb
	lda	#1			; (Y hold ~14 cycles)
	std	*P_B			; mux off, x to the DAC
	ldd	#0xFF00
	sta	*SR			; beam on
	stb	*T1H			; go
	leay	-1,y
	beq	m_last
	ldb	,x+
	lda	#0x40
1$:	bita	*IFR
	beq	1$
	clr	*SR			; beam off
	bra	m_entry
m_last:
	lda	#0x40
1$:	bita	*IFR
	beq	1$
	clr	*SR
	rts
m_move:
	ldb	,x+
	clra
	std	*P_B
	ldb	,x+
	negb
	lda	#1
	std	*P_B
	clr	*T1H			; beam stays off
	leay	-1,y
	beq	2$
	ldb	,x+
	lda	#0x40
3$:	bita	*IFR
	beq	3$
	bra	m_entry
2$:	lda	#0x40
4$:	bita	*IFR
	beq	4$
	rts
