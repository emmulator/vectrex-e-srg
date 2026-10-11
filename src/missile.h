// missile.h: enemy missiles for E-SRG
//
// A missile flies a straight line through the centre of a cell toward the
// centre of the sphere the dome is cut from. The line is fixed in the dome's
// frame, so the missile turns with the dome. missile_draw.s advances and projects
// it every frame; tools/gen_dome.py makes the tables (missile_data.c) and
// documents the fixed-point state below.
#ifndef MISSILE_H
#define MISSILE_H

#include "dome_data.h"
#include "missile_data.h"

// Bullets fly the same kind of radial line, outward from the ship's cell,
// so they can only meet missiles aimed at that cell.
#define NMIS 3                     // missile slots: missiles[0 .. NMIS-1]
#define NBUL 2                     // bullet slots: missiles[NMIS .. NOBJ-1]
#define NOBJ 5                     // missile_draw.s NOBJ
#define KIND_MISSILE 0
#define KIND_BULLET 1

// Layout shared with missile_draw.s (M_* offsets): keep in step, 46 bytes.
struct missile {
    unsigned char state;           // 0 free, 1 flying, 2 just hit the dome
    unsigned char ring;            // ring of its cell (sprite, hiding)
    unsigned char phi;             // cell azimuth, rotation steps
    unsigned char kind;            // KIND_MISSILE or KIND_BULLET
    unsigned char pos[12];         // H, A, B, R: 24-bit each (top 16 bits 5.11)
    unsigned char inc[12];         // their per-frame increments, 24-bit each
    long sx, sy;                   // where it was drawn (screen units at POS_SCALE)
    unsigned char vis;             // 1 if on screen and not behind the dome (0 when spawning)
    unsigned char life;            // bullet: frames left
    signed char vx, vy;            // missile_draw.s: motion between projections
    unsigned char scale, mirror;   // missile_draw.s: how to draw the dart
    const unsigned char *sprite;
    long px, py;                   // missile_draw.s: position at the last projection
    unsigned char age;             // missile_draw.s: frames since the last projection
    unsigned char fresh;           // > 0: project in the next frames (set 2 for a bullet)
};

extern struct missile missiles[NOBJ];

// An explosion: a precomputed animation (missile_data.c expl_frames) at a
// fixed screen position. Layout shared with missile_draw.s (E_*): 5 bytes.
#define NEXPL 2
struct expl {
    unsigned char t;               // 0 free, else frames since the hit + 1
    long sx, sy;                   // screen position (units at POS_SCALE)
};
extern struct expl explosions[NEXPL];

// Set by missiles_calibrate() for missile_draw.s: move scales for 1, 2 and 3 DAC
// units per screen unit, and the screen y offset.
extern unsigned char mis_scale[3];
extern long mis_oy;

// Recompute mis_scale/mis_oy from dome_pos_scale (call at start and after
// calibrating). On a console whose ramp runs `tail` cycles past T1, a move at
// scale S with DAC value v travels v*(S + tail), and the dome's unit is a DAC
// step at dome_pos_scale = NOMINAL + (LINE_MUL-1)*tail, i.e. P + tail. So m
// units per DAC step need S = m*(P + tail) - tail. The dome's anchor move (at
// its own scale) lands short or long by the same physics; mis_oy follows it
// so missiles meet the dome where it is really drawn.
void missiles_calibrate(void);

// Advance every flying missile one frame; a landing sets state 2.
void missiles_step(void);

// Draw the flying missiles and bullets with the dome at rotation `rot`.
void missiles_draw(unsigned char rot);

// Draw the explosions.
void explosions_draw(void);

// Radar (radar.s): draw it with the dome at rotation `rot`. A missile aimed
// at cell (radar_ring, radar_phi) is highlighted; radar_ring 255 = none.
extern unsigned char radar_ring, radar_phi;
extern unsigned char radar_dim;     // the ellipse's intensity
void radar_draw(unsigned char rot);

// A flight's per-frame increments at dst from fl_dir (mis_dir[ring]) and
// fl_spd (mis_speed[speed]); see tools/gen_dome.py.
extern const unsigned char *fl_dir;
extern unsigned char fl_spd;
void flight_inc(unsigned char *dst);

// Broken tiles (kept by the game) and their cracks (cracks.s).
extern unsigned char broken[NCELLS];
extern unsigned char nbroken;
void cracks_draw(unsigned char rot);

// The readouts (hud.s): lines of glyphs (hud_glyphs) from a baseline start
// (DAC units at scale $A0), set by the game when a value changes. 19 bytes.
struct hud_line {
    signed char y, x;
    unsigned char n;                 // glyphs (0 = line not drawn)
    const unsigned char *g[8];
};
#define HUD_INTEG 0                  // lines: integrity, lives, score
#define HUD_LIVES 1
#define HUD_SCORE 2
extern struct hud_line hud_lines[3];
void hud_draw(void);

// Copy 12 bytes (a flight's state or increments) fast.
void copy12(unsigned char *dst, const unsigned char *src);

#endif // MISSILE_H
