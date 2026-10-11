// fixmath.h — fixed-point helpers for gcc6809 (-mint8: int is 8 bits)
#ifndef FIXMATH_H
#define FIXMATH_H

// Signed 8x8 -> 16-bit multiply (fixmath.s). Use this instead of
// `(long)a * b` when a and b are signed chars or small constants: gcc6809
// miscompiles those into an unsigned MUL (wrong for negative values), and
// the correct generic path (_mulhi3) is several times slower.
long smul8(signed char a, signed char b);

// (a * b) / 128 with rounding, for Q7 (x128) constants such as sin/cos.
// Arithmetic >> on a signed long is fine (constant shift count).
#define MULQ7(a, b) ((smul8((signed char)(a), (signed char)(b)) + 64) >> 7)

#endif // FIXMATH_H
