// dome.h: rotating geodesic dome (play surface) for E-SRG
//
// A geodesic dome of hexagons and pentagons (a Goldberg polyhedron cap,
// pentagon at the top) seen in perspective from a fixed camera; it rotates
// about its vertical axis so the player can move all the way around it.
// Every view (projection, occlusion, drawing order) is precomputed by
// tools/gen_dome.py into dome_data.c/h + dome_cfg.inc and drawn by
// dome_draw.s; tweak the look (size, curvature, camera) in the generator.
#ifndef DOME_H
#define DOME_H

#include "dome_data.h"

// Draw the dome at rotation `step` (0..DOME_STEPS-1 = one full turn).
void dome_draw(unsigned char step);

// Draw the ship on the dome's front meridian at latitude `lat`
// (0 = on the peak .. SHIP_STEPS-1 = lowest, just above the rim).
void ship_draw(unsigned char lat);

// The stars above the dome, shifted right by off (stars.s): one turn of the
// dome moves them once round the screen's width.
void stars_draw(unsigned char off);

// The dome collapsing (dome_draw.s; all 0 otherwise): burst is added to the
// position scale (the runs fly apart), shake (0 or 2^k-1) jitters each run,
// sink moves every run down, dim lowers the intensity.
extern unsigned char dome_burst, dome_shake, dome_dim;
extern signed char dome_sink;

// The ship's position and its moves (ship_move.s). cell: the ship's cell, or
// the destination while moving; move_left: frames left in the move, 0 = at
// rest; ship_lift: mid-jump height for ship_draw.
extern unsigned char dome_angle, ship_lat, cell, move_left;
extern signed char ship_lift;
void move_start(unsigned char to);    // to a neighbouring cell
void jump_start(unsigned char to);    // to a cell two away, over one
void move_step(void);                 // each frame while move_left

// Recharge the integrators' zero reference to DAC 0 after reading the
// joystick (Joy_Analog leaves it near the stick's Y value; see dome_draw.s).
void zero_ref_settle(void);

#endif // DOME_H
