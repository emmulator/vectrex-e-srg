; bios.s: the C entry points for the BIOS routines e-srg calls with
; arguments, replacing PeerC's vec_rum_fct_pjc.c (which links wrappers for
; the whole BIOS, ~640 bytes). Same names and calling convention as PeerC's
; (its headers still declare them): first argument in B, the next on the
; stack (caller pops). Wait_Recal, Read_Btns, Joy_Analog and Reset0Ref are
; called straight at their BIOS addresses (PeerC's vec_rum_0x*.c only
; define symbols) and need nothing here.

	.module	bios
	.area	.text
	.globl	__Print_Str_d, __Sound_Byte, __Intensity_a, _abort

; abort() (libgcc's divide calls it on /0): restart the console, as PeerC's
; gcc.c does.
_abort	.equ	0xF000

; void _Print_Str_d(int x, int y, char *s): x in B, y at 4,s (after the
; pushed U), s in X. BIOS Print_Str_d: A = y, B = x, U = string.
__Print_Str_d:
	pshs	u
	lda	4,s
	tfr	x,u
	jsr	0xF37A
	puls	u,pc

; void _Sound_Byte(unsigned char value, unsigned char reg): value in B, reg
; at 2,s. BIOS Sound_Byte: A = register, B = value.
__Sound_Byte:
	lda	2,s
	jmp	0xF256

; void _Intensity_a(unsigned char a): BIOS Intensity_a takes A.
__Intensity_a:
	tfr	b,a
	jmp	0xF2AB
