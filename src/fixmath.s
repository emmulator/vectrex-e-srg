; fixmath.s — fast signed 8x8 -> 16-bit multiply for gcc6809 (-mint8)
;
; Why this exists: gcc6809 miscompiles `(long)signed_char * const` and
; `(long)signed_char * (long)signed_char` into the 6809's UNSIGNED `mul`
; with no sign correction, so negative operands come out +256*x wrong.
; The correct generic path (_mulhi3, a 16x16 libgcc routine) is slow.
; This routine is both correct and fast (~40 cycles): unsigned MUL, then
; subtract the two-complement corrections from the high byte.
;
; ABI (gcc6809 -mabi=bx): first 8-bit arg in B, second arg at 2,s,
; 16-bit result returned in X. Clobbers D, CC.
;
;   long smul8(signed char a, signed char b);

	.module	fixmath.s
	.area	.text
	.globl	_smul8
_smul8:
	lda	2,s		; A = b, B = a
	pshs	d		; 0,s = b, 1,s = a
	mul			; D = (unsigned)a * (unsigned)b
	tst	1,s		; a < 0 ?  then result -= b << 8
	bpl	1$
	suba	0,s
1$:	tst	0,s		; b < 0 ?  then result -= a << 8
	bpl	2$
	suba	1,s
2$:	tfr	d,x
	leas	2,s
	rts
