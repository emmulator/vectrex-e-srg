// missile.c: calibration for missile_draw.s (see missile.h)
#include "dome.h"
#include "missile.h"

extern unsigned char dome_pos_scale;

unsigned char mis_scale[3];
long mis_oy;

void missiles_calibrate(void)
{
    // -mint8: everything in (unsigned) long, which is 16-bit here
    unsigned long p = dome_pos_scale;
    unsigned long k = DOME_LINE_MUL - 1;          // dome_pos_scale = NOMINAL + k*tail
    unsigned long d = p - DOME_POS_NOMINAL;       // k * tail (calibration >= nominal)
    unsigned long v, a;
    unsigned char m;

    if (p < DOME_POS_NOMINAL)                     // below nominal: treat as no tail
        d = 0;
    for (m = 1; m <= 3; m++) {                    // m*(p + tail) - tail = (m*k*p + (m-1)*d) / k
        v = ((unsigned long)m * k * p + (unsigned long)(m - 1) * d + k / 2) / k;
        mis_scale[m - 1] = (unsigned char)(v > 255 ? 255 : v);
    }
    // the anchor move really goes |DAC| * (ASCALE + tail) / (p + tail) dome units
    a = ((unsigned long)(-DOME_ANCHOR_DAC) * (k * DOME_ANCHOR_SCALE + d)
         + (k * p + d) / 2) / (k * p + d);
    mis_oy = MIS_OY + MIS_ANCHOR_NOM - (long)a;
}
