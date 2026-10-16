// E-SRG — Vectrex-native cartridge (gcc6809 + PeerC; scaffolded from the
// vectrex template).
//
// Every-frame loop: wait for the frame, read the stick, move the ship cell to
// cell, fly the enemy missiles, draw the rotating geodesic dome, the ship and
// the missiles.
// Build: make      Test: make test (writes build/e-srg.png)      Run: make run
// (The earlier cmoc version of this game lives in src/cmoc/: make cmoc.)

#include <vectrex.h>
#include "dome.h"
#include "missile.h"

// The game's version: shown on the BIOS boot screen under the name.
#ifndef VERSION_Y
#define VERSION_H -6
#define VERSION_W 48
#define VERSION_Y -40
#define VERSION_X -63
#endif
#define GAME_VERSION "1.0.1"              // (the Makefile reads it for the ROM names)
#if defined(DOME_NO_TAIL)                // + the build: E emulator (make emu),
#define GAME_BUILD "E"
#elif defined(DOME_MINE)                 //   M one particular Vectrex (make mine),
#define GAME_BUILD "M"
#else                                    //   V a typical Vectrex (make)
#define GAME_BUILD "V"
#endif
#define VERSION_TEXT "V" GAME_VERSION GAME_BUILD "\x80"

// cartridge header (the BIOS checks it: "g GCE", \x80-terminated strings).
// After the music: title lines for BIOS Print_List_hw (height, width, y, x,
// string), ended by a 0 byte.
struct title_line
{
    signed int height;                   // (int is 8 bits under -mint8)
    unsigned int width;
    int y;
    int x;
};

struct cartridge_t
{
    char copyright[11];
    const void *music;
    struct title_line name_at;
    char name[6];                        // exact sizes: no C NUL, the BIOS starts
    struct title_line version_at;        // the game right after `end`, so a stray
    char version[sizeof(VERSION_TEXT) - 1]; // extra 0 byte there runs as code
    char end;
};

const struct cartridge_t game_header
    __attribute__((section(".cartridge"), used)) =
{
    .copyright  = "g GCE 2026\x80",
    .music      = &Vec_Music_7,          // BIOS tune: Star Trek (make jukebox to hear them all)
    .name_at    = { -8, 80, -16, -72 },
    .name       = "E-SRG\x80",
    .version_at = { VERSION_H, VERSION_W, VERSION_Y, VERSION_X },
    .version    = VERSION_TEXT,
    .end        = 0
};

// The ship rests on cell centres and moves cell to cell (ship_move.s: a move
// to a neighbour, or a jump over one); the dome turns under it so the cell
// comes to the front.
// A jump (button 2) goes two cells in the stick's direction (or the last one
// it pointed, if centred), over the next one, broken or not; it must land on
// a whole cell. It takes longer than a move, and the ship rises and falls on
// an arc.
#define STICK_DEAD 40              // analog dead zone for spinning at the peak

// Chunk-start scale for dome_draw.s; trims the console's ramp tail (see
// tools/gen_dome.py TAIL_DEFAULT). Hold button 4 and push the stick left/right
// until the dome's polylines meet; the value is shown while button 4 is held.
// A stock Vectrex can't store it, so note the value and make it the default.
#if defined(DOME_NO_TAIL)                // emulators have no ramp tail (make emu)
unsigned char dome_pos_scale = DOME_POS_NOMINAL;
#elif defined(DOME_MINE)                 // one particular console (make mine)
unsigned char dome_pos_scale = DOME_POS_MINE;
#else                                    // a typical console (make)
unsigned char dome_pos_scale = DOME_POS_DEFAULT;
#endif

static char cal_text[] = "CAL 000\x80";
static char game_over_text[] = "GAME OVER\x80";
static unsigned char cal_repeat;

// Returns 1 while calibrating (button 4 held): the stick then trims the scale.
static unsigned char calibrate(void)
{
    unsigned char v;

    if (!(Vec_Btn_State & 8)) {      // button 4 (player 1) not held
        cal_repeat = 0;
        return 0;
    }
    if (Vec_Joy_1_X > STICK_DEAD || Vec_Joy_1_X < -STICK_DEAD) {
        if (cal_repeat == 0) {       // step now, then every 8 frames while held
            if (Vec_Joy_1_X > 0 && dome_pos_scale < DOME_POS_MAX)
                dome_pos_scale++;
            else if (Vec_Joy_1_X < 0 && dome_pos_scale > DOME_POS_MIN)
                dome_pos_scale--;
            cal_repeat = 8;
        }
        cal_repeat--;
    } else {
        cal_repeat = 0;
    }
    missiles_calibrate();            // missiles follow the trimmed scale
    v = dome_pos_scale;
    cal_text[4] = (char)('0' + v / 100);
    cal_text[5] = (char)('0' + (v / 10) % 10);
    cal_text[6] = (char)('0' + v % 10);
    Intensity_a(0x7f);
    Print_Str_d(110, -40, cal_text);
    return 1;
}

// The neighbour of cell c whose direction on screen is nearest stick
// direction d (0..31), less than 45 degrees off; 255 = none (gen_dome.py
// models it).
static unsigned char cell_toward(unsigned char c, unsigned char d)
{
    const unsigned char *a = cell_adj[c];
    unsigned char i, e, best = 255, bd = 32, want = (unsigned char)(d << 3);

    for (i = 0; i < 6 && a[1] != 255; i++, a += 2) {
        e = (unsigned char)(a[0] - want);
        if (e & 0x80)
            e = (unsigned char)-e;
        if (e < bd) {
            bd = e;
            best = a[1];
        }
    }
    return best;
}

// The ship stays on the front of the dome and moves cell to cell: the stick's
// angle picks the neighbour whose direction on screen matches it best, and
// the dome turns so the new cell comes to the front (so pushing left spins
// the dome right). At the peak, left/right spins the dome in place and only
// "down" leaves it, to the ring cell nearest the front.
// Broken cells as a bitmask (also kept as a list for cracks.s, see below).
static unsigned char broken_bits[(NCELLS + 7) / 8];
static const unsigned char bit_mask[8] = { 1, 2, 4, 8, 16, 32, 64, 128 };

static unsigned char is_broken(unsigned char c)
{
    return (unsigned char)(broken_bits[c >> 3] & bit_mask[c & 7]);
}

static unsigned char jump_req;      // jump pressed: jump once the ship rests
static unsigned char last_dir = 8;  // the stick's last direction (8 = up): for a jump with it centred
static void jump_sound(void);

static void ship_input(void)
{
    unsigned char gx, gy, d, v, m;

    if (move_left) {                 // input waits until the move lands
        move_step();
        return;
    }
    gx = (unsigned char)((unsigned char)(Vec_Joy_1_X ^ 0x80) >> 3);
    gy = (unsigned char)((unsigned char)(Vec_Joy_1_Y ^ 0x80) >> 3);
    // one quadrant is stored: fold, look up, mirror back
    d = stick_q[(unsigned char)((gy >= 16 ? gy - 16 : 15 - gy) << 4)
                | (gx >= 16 ? gx - 16 : 15 - gx)];
    if (d == 255) {                  // stick centred: only a jump moves,
        if (!jump_req)               // the way the stick last pointed
            return;
        d = last_dir;
    } else {
        if (gx < 16)                 // x < 0
            d = (unsigned char)(16 - d);
        if (gy < 16)                 // y < 0
            d = (unsigned char)((32 - d) & 31);
        last_dir = d;
    }
    v = dome_angle;
    while (v >= DOME_VIEWS)
        v -= DOME_VIEWS;
    if (jump_req) {                  // two cells on, over the next one
        jump_req = 0;
        if (cell != 0)
            m = cell_toward(cell, d);
        else
            m = (d >= 19 && d <= 29) ? peak_down[v] : (unsigned char)255;
        if (m != 255 && m != 0) {    // (no jumping over the peak)
            m = cell_toward(m, d);
            if (m != 255 && m != cell && !is_broken(m)) {
                jump_start(m);
                jump_sound();
            }
        }
        return;
    }
    if (cell != 0) {
        d = cell_toward(cell, d);
        if (d != 255 && !is_broken(d))   // broken cells: jump over them
            move_start(d);
        return;
    }
    if (d >= 19 && d <= 29) {        // the peak: down-ish (24 = straight down)
        if (!is_broken(peak_down[v]))
            move_start(peak_down[v]);
    } else if (Vec_Joy_1_X > STICK_DEAD) {   // right: the surface slides left
        if (dome_angle == 0)
            dome_angle = DOME_STEPS;
        dome_angle--;
    } else if (Vec_Joy_1_X < -STICK_DEAD) {
        if (++dome_angle == DOME_STEPS)
            dome_angle = 0;
    }
}

// ---- enemy missiles --------------------------------------------------------
// Each wave sets which rings of cells missiles aim at (ring 0 = the peak;
// the first rings come in from above, so they're on screen longest), their
// speed index and how many fly at once.
static unsigned char wave_rings = 5;      // targets in rings 0..wave_rings-1 (up to 34 deg)
// Missiles shot down; from low_rings_at on, missiles also come in low (all
// rings, down to the dome's bottom row: on screen for less time).
static unsigned char low_rings_at = 6;
static unsigned char kills;               // (stops at 255)
static unsigned char hits;                // missiles that hit the dome: low_rings_at of them
                                          //   also opens all rings (stops at 255)
unsigned long score10;                    // score / 10 (shown with a trailing 0): low 16 bits
static unsigned char score_hi;            //   and its top 8 (long is 16 bits under -mint8)
#define SCORE_MAX_HI 0x98                 // capped at 9,999,999 (= $98967F): 99,999,990
#define SCORE_MAX_LO 0x967F               //   points, 8 glyphs
static unsigned char integ_pct = 100;     // dome integrity, %: scales each kill's points
// Missile speed by score: from speed_score[i] (score / 10) on, missiles
// launch at speed_val[i] (fl_spd: 82 = the base speed, 1x; up to 255 = 3.1x).
// MIS_SPEED_TEST=n (test build): every missile at n.
#define SPEED_STEPS 5
static const unsigned long speed_score[SPEED_STEPS] = { 0, 1000, 2500, 5000, 10000 };
static const unsigned char speed_val[SPEED_STEPS] = { 82, 98, 115, 131, 164 };  // 1x 1.2x 1.4x 1.6x 2x
static unsigned char wave_live = 2;       // at most this many at once (<= NMIS)
static unsigned char spawn_timer = 50;    // frames until the next launch
#define SPAWN_GAP 40                      // frames between launches: SPAWN_GAP + 0..63

static unsigned long rng = 0xACE1;        // xorshift16 state

static unsigned char rand8(void)
{
    rng ^= rng << 7;
    rng ^= rng >> 9;
    rng ^= rng << 8;
    return (unsigned char)rng;
}

static unsigned char rand_below(unsigned char n)
{
    unsigned char r = rand8();

    while (r >= n)
        r -= n;
    return r;
}

// 1 if cell c can be a target: whole, and no missile already aimed at it
// (otherwise the second one would land on a cracked cell)
static unsigned char free_target(unsigned char c)
{
    struct missile *o = missiles;
    unsigned char i;

    if (is_broken(c))
        return 0;
    for (i = 0; i < NMIS; i++, o++)
        if (o->state == 1 && o->ring == mis_cell_ring[c] && o->phi == mis_cell_phi[c])
            return 0;
    return 1;
}

static void spawn(struct missile *m)
{
    unsigned char c, k;

#ifdef AIM_AT_SHIP                   // test build: every missile targets the ship's cell
    c = cell;
#else
    k = 8;                           // a free cell in the wave's rings (a few tries)
    do
        c = rand_below(mis_ring_end[(kills >= low_rings_at || hits >= low_rings_at ? MIS_RINGS : wave_rings) - 1]);
    while (!free_target(c) && --k);
    if (!free_target(c))
        return;                      // (none found this time)
#endif
    k = mis_cell_ring[c];
    m->ring = k;
    m->phi = mis_cell_phi[c];
    copy12(m->pos, mis_start[k]);
    fl_dir = mis_dir[k];
#ifdef MIS_SPEED_TEST
    fl_spd = MIS_SPEED_TEST;
#else
    k = SPEED_STEPS - 1;
    while (!score_hi && score10 < speed_score[k])
        k--;
    fl_spd = speed_val[k];
#endif
    flight_inc(m->inc);
    m->kind = KIND_MISSILE;
    m->fresh = 0;                    // off screen at first: waits for its turn
    m->age = 0;
    m->vis = 0;
    m->state = 1;
}

// ---- sound -------------------------------------------------------------------
// Effects write the AY-3-8912 directly (BIOS Sound_Byte), a few registers per
// frame while they last; no BIOS music driver. Fire: channel A, a falling
// tone. Hit: channel C, noise that deepens and fades. Crack (a missile
// breaks a tile): channel C too, a bright noise snap, then a low thud (tone C
// mixed in, falling) under deep noise. Lock-on: channel B pips (see
// lock_update).
static unsigned char locked, lock_t;
static unsigned char snd_fire, snd_hit;   // frames left
static unsigned char snd_crack;           // frames left
static unsigned long snd_thud;            // crack: tone C period, rising
#define CRACK_FRAMES 22
static unsigned long snd_period;          // fire: tone period, rising (pitch falls)

static void sound_init(void)
{
    Sound_Byte(8, 0);                // volumes A, B, C off
    Sound_Byte(9, 0);
    Sound_Byte(10, 0);
    Sound_Byte(2, 0x50);             // channel B: the lock-on pip (~1.2 kHz)
    Sound_Byte(3, 0);
    Sound_Byte(7, 0x1C);             // mixer: tones A, B, noise C; port A input (buttons)
}

static unsigned char snd_lock;           // channel B volume now
static unsigned char snd_jump;           // frames left: channel A, a rising tone

static void jump_sound(void)
{
    snd_jump = 24;                   // (the jump's length)
    snd_fire = 0;
    snd_period = 0x200;
}

static void sound_update(void)
{
    unsigned char v = (unsigned char)((locked && (lock_t & 15) < 3) ? 12 : 0);   // pip: 3 of every 16 frames

    if (v != snd_lock) {             // write only on a change
        snd_lock = v;
        Sound_Byte(9, v);
    }
    if (snd_fire) {
        snd_fire--;
        snd_period += 40;            // pitch falls
        Sound_Byte(0, (unsigned char)snd_period);
        Sound_Byte(1, (unsigned char)(snd_period >> 8));
        Sound_Byte(8, snd_fire ? (unsigned char)(snd_fire + 3) : 0);   // 14 .. 4, then off
    }
    if (snd_jump) {
        snd_jump--;
        snd_period -= 12;            // pitch rises
        Sound_Byte(0, (unsigned char)snd_period);
        Sound_Byte(1, (unsigned char)(snd_period >> 8));
        Sound_Byte(8, (unsigned char)(snd_jump ? 10 : 0));
    }
    if (snd_hit && snd_crack) {      // a hit takes channel C over
        snd_crack = 0;
        Sound_Byte(7, 0x1C);
    }
    if (snd_crack) {
        if (snd_crack == CRACK_FRAMES) {
            Sound_Byte(7, 0x18);     // tone C on too
            Sound_Byte(6, 3);        // the snap: bright noise
            Sound_Byte(10, 15);
        } else if (snd_crack == CRACK_FRAMES - 3) {
            Sound_Byte(6, 31);       // then deep noise and the thud
        }
        if (snd_crack < CRACK_FRAMES - 2) {
            snd_thud += 40;          // pitch falls
            Sound_Byte(4, (unsigned char)snd_thud);
            Sound_Byte(5, (unsigned char)(snd_thud >> 8));
            Sound_Byte(10, (unsigned char)(snd_crack > 15 ? 15 : snd_crack));
        }
        if (--snd_crack == 0) {
            Sound_Byte(7, 0x1C);
            Sound_Byte(10, 0);
        }
    }
    if (snd_hit) {
        snd_hit--;
        Sound_Byte(6, (unsigned char)(31 - (snd_hit >> 1)));   // noise deepens
        Sound_Byte(10, (unsigned char)(snd_hit >> 1 > 15 ? 15 : snd_hit >> 1));
    }
}

// ---- bullets and explosions ---------------------------------------------------
static unsigned char fire_req;            // fire pressed: shoot once the ship rests

// Fire along the ship's cell's radial line, outward (needs a free bullet slot).
static void fire(void)
{
    struct missile *b = missiles + NMIS, *m;
    unsigned char k, i;

    for (i = 0; i < NBUL && b->state; i++, b++)
        ;
    if (i == NBUL)
        return;
    k = mis_cell_ring[cell];
    b->ring = k;
    b->phi = mis_cell_phi[cell];
    copy12(b->pos, bul_start[k]);
    copy12(b->inc, bul_inc[k]);
    b->life = bul_life[k];           // until off screen, or on to the radar's
    for (i = 0, m = missiles; i < NMIS; i++, m++)   // edge if a missile is on its line
        if (m->state == 1 && m->ring == k && m->phi == b->phi)
            b->life = bul_life_far[k];
    b->kind = KIND_BULLET;
    b->fresh = 2;                    // project now and next frame: it moves fast
    b->age = 0;
    b->vis = 0;
    b->state = 1;
    snd_fire = 12;
    snd_period = 0x60;
}

static void explode_at(long sx, long sy)
{
    struct expl *e = explosions;
    unsigned char i;

    snd_hit = 32;
    for (i = 0; i < NEXPL && e->t; i++, e++)
        ;
    if (i == NEXPL)                  // both busy: reuse the older one
        e = explosions[0].t > explosions[1].t ? explosions : explosions + 1;
    e->sx = sx;
    e->sy = sy;
    e->t = 1;
}

static void explode(struct missile *m)
{
    if (m->vis)
        explode_at(m->sx, m->sy);
    else
        snd_hit = 32;                // off screen: only the sound
}

// A bullet hits a missile on the same line (same cell) once their distances
// from the centre cross: bullet R (outward) >= missile R (inward). Off-screen
// missiles count too (the radar shows them); they explode unseen, with the
// sound.
static void add_score(unsigned char v)   // (score / 10)
{
    unsigned long o = score10;

    score10 += v;
    if (score10 < o)
        score_hi++;                      // carry
    if (score_hi > SCORE_MAX_HI || (score_hi == SCORE_MAX_HI && score10 > SCORE_MAX_LO)) {
        score_hi = SCORE_MAX_HI;
        score10 = SCORE_MAX_LO;
    }
}

static void collide(void)
{
    struct missile *b = missiles + NMIS, *m;
    unsigned char i, j;
    unsigned long rb;

    for (i = 0; i < NBUL; i++, b++) {
        if (b->state != 1)
            continue;
        rb = ((unsigned long)b->pos[9] << 8) | b->pos[10];
        for (j = 0, m = missiles; j < NMIS; j++, m++) {
            if (m->state != 1 || m->phi != b->phi || m->ring != b->ring)
                continue;
            if (rb >= (((unsigned long)m->pos[9] << 8) | m->pos[10])) {
                explode(m);
                if (kills != 255)
                    kills++;
                add_score(integ_pct);    // 1000 points x integrity
                m->state = 0;
                b->state = 0;
                break;
            }
        }
    }
}

static void explosions_update(void)
{
    struct expl *e = explosions;
    unsigned char i;

    for (i = 0; i < NEXPL; i++, e++)
        if (e->t && ++e->t > EXPL_STEPS * EXPL_HOLD)
            e->t = 0;
}

// ---- broken tiles ----------------------------------------------------------
// A missile that reaches the dome breaks its tile: cracks.s draws a crack
// there. (No effect on the ship yet.) A whole cell with enough broken
// neighbours (all of them, if it has fewer: rim cells) collapses too, which
// can spread: otherwise the last few whole cells would be easy to defend
// (missiles only aim at whole cells). How many depends on the level:
// COLLAPSE_EASY - level (5 easy, 4 normal, 3 hard).
#define COLLAPSE_EASY 5
// Levels, chosen on the title screen (button 2). They differ in the
// collapse count above and in a dome death: easy costs no life, normal one,
// hard ends the game (kill_ship). Each has its own high score.
#define LEVEL_EASY   0
#define LEVEL_NORMAL 1
#define LEVEL_HARD   2
#define LEVELS       3
static unsigned char level = LEVEL_NORMAL;
#define DOME_LIMIT 38                     // integrity 0% at this many broken cells (half the dome)
unsigned char broken[NCELLS];             // broken cells, in the order they broke
unsigned char nbroken;

static void crack(unsigned char c)
{
    broken_bits[c >> 3] |= bit_mask[c & 7];
    broken[nbroken++] = c;
}

static unsigned char surrounded(unsigned char c)
{
    const unsigned char *a = cell_adj[c] + 1;    // (direction, neighbour) pairs
    unsigned char i, n = 0, b = 0, at = (unsigned char)(COLLAPSE_EASY - level);

    for (i = 0; i < 6 && *a != 255; i++, a += 2) {
        n++;
        if (is_broken(*a))
            b++;
    }
    return (unsigned char)(b >= (n < at ? n : at));
}

static void break_tile(struct missile *m)
{
    unsigned char c = m->ring ? mis_ring_end[m->ring - 1] : 0, i, x;
    unsigned char todo[16], ntodo = 0;        // cells whose neighbours to check
    const unsigned char *a;

    while (mis_cell_phi[c] != m->phi)     // the cell in its ring at its azimuth
        c++;
    if (is_broken(c))
        return;                          // (missiles don't aim at broken cells)
    crack(c);
    if (hits != 255)
        hits++;
    snd_crack = CRACK_FRAMES;            // the impact
    snd_thud = 0x300;
    snd_hit = 0;
    todo[ntodo++] = c;
    while (ntodo) {                      // collapse, spreading
        x = todo[--ntodo];
        a = cell_adj[x] + 1;
        for (i = 0; i < 6 && *a != 255; i++, a += 2)
            if (!is_broken(*a) && surrounded(*a)) {
                crack(*a);
                if (ntodo < 16)
                    todo[ntodo++] = *a;
            }
    }
}

// Readouts: dome integrity (100% less DOME_LIMIT's share per broken cell)
// with a little dome, lower right; lives as small ships under it; the score
// under the dome. Remade only when a value changes.
static unsigned char lives = 3;
static unsigned char integ_shown = 255, lives_shown = 255;
static unsigned long score_shown = 1;    // (forces the first update)

// A score's digits (score / 10 = hi * 65536 + lo), last first, into d[7];
// returns how many. 24 bits, divided by 10 a byte at a time.
static unsigned char score_digits(unsigned char hi, unsigned long lo, unsigned char *d)
{
    unsigned char b[3], i, r, n = 0;
    unsigned long q;

    b[0] = hi;
    b[1] = (unsigned char)(lo >> 8);
    b[2] = (unsigned char)lo;
    do {
        for (r = 0, i = 0; i < 3; i++) {
            q = ((unsigned long)r << 8) | b[i];
            b[i] = (unsigned char)(q / 10);
            r = (unsigned char)(q % 10);
        }
        d[n++] = r;
    } while ((b[0] | b[1] | b[2]) && n < 7);
    return n;
}

// The high scores, one per level, on the title pages: labels in BIOS text,
// numbers in the HUD's vector digits (more BIOS lines made the title page
// too slow). Normal's is also kept in the BIOS's high-score slot (Vec_High_Score: 6
// characters, right-aligned, then $80), which survives the reset button and
// which the BIOS shows at the top of its boot screen after a warm start (a
// reset, or a menu cart launching the game). At start the game reads it back,
// so the high score survives a reset. The slot holds 6 digits: higher scores
// are kept there as 999990 (the title page still shows the real one until a
// reset). After power-on the BIOS clears it to "     0". (The UVMC2 also
// saves it per ROM.) Easy's and hard's start at 0 every time.
#define BIOS_HIGH_SCORE ((volatile char *)0xCBEB)
static unsigned char best_hi[LEVELS];
static unsigned long best_lo[LEVELS];
static unsigned char best_d[LEVELS][8], best_n[LEVELS] = { 1, 1, 1 };   // digits, first first (glyph indices)

static void best_set(unsigned char k, unsigned char hi, unsigned long lo)   // (level, score / 10)
{
    unsigned char d[7], n, i, *bd = best_d[k];

    best_hi[k] = hi;
    best_lo[k] = lo;
    n = score_digits(hi, lo, d);
    for (best_n[k] = 0, i = n; i; )
        bd[best_n[k]++] = d[--i];
    if (hi || lo)
        bd[best_n[k]++] = 0;             // (the score's trailing 0)
    if (k != LEVEL_NORMAL)
        return;
    for (i = 0; i < 6; i++)              // the BIOS slot
        BIOS_HIGH_SCORE[i] = ' ';
    if (n > 5)                           // (over 999,990: kept as 999990)
        for (i = 0; i < 5; i++)
            d[i] = 9;
    for (i = 0; i < n && i < 5; i++)
        BIOS_HIGH_SCORE[4 - i] = (char)('0' + d[i]);
    BIOS_HIGH_SCORE[5] = '0';
    BIOS_HIGH_SCORE[6] = (char)0x80;
}

static void best_update(void)
{
    if (score_hi < best_hi[level] || (score_hi == best_hi[level] && score10 <= best_lo[level]))
        return;
    best_set(level, score_hi, score10);
}

// At start: normal's high score from the BIOS slot (left by an earlier run, kept
// through the reset; "     0" after power-on). Anything but spaces and
// digits there (another program's data) counts as 0.
static void best_load(void)
{
    unsigned char b[3] = { 0, 0, 0 }, i, k, c;
    unsigned long t;

    for (i = 0; i < 6; i++) {
        c = (unsigned char)BIOS_HIGH_SCORE[i];
        if (c == ' ')
            continue;
        if (c < '0' || c > '9') {
            b[0] = b[1] = b[2] = 0;
            break;
        }
        if (i == 5)
            break;                       // (the last digit: score / 10 drops it)
        t = (unsigned char)(c - '0');    // b = b * 10 + digit, 24 bits
        for (k = 3; k--; ) {
            t += (unsigned long)b[k] * 10;
            b[k] = (unsigned char)t;
            t >>= 8;
        }
    }
    best_set(LEVEL_NORMAL, b[0], ((unsigned long)b[1] << 8) | b[2]);
}

static void integrity_update(void)
{
    struct hud_line *l;
    unsigned char v, n = 0, d[7];

    if (integ_shown != nbroken) {
        integ_shown = nbroken;
        v = nbroken >= DOME_LIMIT ? 0
            : (unsigned char)(100 - ((unsigned long)nbroken * 100 + DOME_LIMIT / 2) / DOME_LIMIT);
        integ_pct = v;
        l = &hud_lines[HUD_INTEG];
        l->y = -87;                      // level with the radar, mirroring it
        l->x = 54;
        l->g[n++] = hud_glyphs[HUD_DOME];
        if (v >= 100)
            l->g[n++] = hud_glyphs[1];
        if (v >= 10)
            l->g[n++] = hud_glyphs[(v / 10) % 10];
        l->g[n++] = hud_glyphs[v % 10];
        l->g[n++] = hud_glyphs[HUD_PCT];
        l->n = n;
    }
    if (lives_shown != lives) {
        lives_shown = lives;
        l = &hud_lines[HUD_LIVES];
        l->y = -100;
        l->x = 54;
        for (n = 0; n < lives && n < 8; n++)
            l->g[n] = hud_glyphs[HUD_SHIP];
        l->n = n;
    }
    if (score_shown != score10) {
        score_shown = score10;
        n = score_digits(score_hi, score10, d);
        l = &hud_lines[HUD_SCORE];
        l->n = n;
        if (score10 || score_hi)
            l->n++;                      // (a trailing 0 unless 0)
        l->y = -116;                     // under the dome, centred (9 per glyph)
        l->x = (signed char)-(signed char)(l->n * 9 / 2);
        for (v = 0; n; v++)
            l->g[v] = hud_glyphs[d[--n]];
        if (score10 || score_hi)
            l->g[v] = hud_glyphs[0];
    }
}

// ---- death -------------------------------------------------------------------
// The ship dies when it rests on a broken cell (a missile landed there, it
// arrived as one did, its cell collapsed) or when the dome's integrity is
// gone. It explodes, everything in flight is cleared, and after DEAD_FRAMES
// it comes back on the start cell (or the first whole one); after a dome
// death the dome is rebuilt. No lives left: GAME OVER until button 1.
#define DEAD_FRAMES 100
static unsigned char dead_t;              // > 0: frames until the ship comes back
static unsigned char dome_dead, game_over;
static void explode_at(long sx, long sy);

static void kill_ship(unsigned char dome)
{
    unsigned char i;

    // the ship rests at the front of its ring (x 0): crack_pos[ring][0]'s y
    explode_at(0, (long)(signed char)crack_pos[(unsigned long)mis_cell_ring[cell] * 62 + 1] + mis_oy);
                                         // (62: 2 bytes x 31 entries per ring)
    for (i = 0; i < NOBJ; i++)
        missiles[i].state = 0;
    move_left = 0;
    ship_lift = 0;
    if (!dome || level == LEVEL_NORMAL)
        lives--;
    else if (level == LEVEL_HARD)
        lives = 0;                       // (easy: a dome death is free)
    dead_t = DEAD_FRAMES;
    dome_dead = dome;
}

// The dome's collapse, over a dome death's DEAD_FRAMES: it shakes harder and
// rumbles (COLLAPSE_SHAKE frames), then its runs fly apart and fall as the
// position scale goes wrong, dimming (to COLLAPSE_GONE), then it's gone
// until the new one.
#define COLLAPSE_SHAKE 35
#define COLLAPSE_GONE  85

static unsigned char fall;

static unsigned char collapse_update(void)   // 0: don't draw the dome
{
    unsigned char f, g;

    dome_burst = dome_shake = dome_dim = 0;
    dome_sink = 0;
    if (!dead_t || !dome_dead)
        return 1;
    f = (unsigned char)(DEAD_FRAMES - dead_t);
    if (f >= COLLAPSE_GONE)
        return 0;
    if (f < COLLAPSE_SHAKE) {
        dome_shake = (unsigned char)(f < 8 ? 3 : f < 16 ? 7 : f < 26 ? 15 : 31);
        fall = 0;
        if (!(f & 7))
            snd_hit = 32;                // a rumble
        return 1;
    }
    g = (unsigned char)(f - COLLAPSE_SHAKE);   // 0 .. 49
    dome_shake = 31;
    dome_burst = (unsigned char)(g * 3);
    if ((unsigned char)(fall + (g >> 3)) <= 120)   // falling faster
        fall += g >> 3;
    dome_sink = (signed char)-(signed char)fall;
    dome_dim = g;
    return 1;
}

static void new_dome(void)
{
    unsigned char i;

    nbroken = 0;
    for (i = 0; i < sizeof broken_bits; i++)
        broken_bits[i] = 0;
}

static void respawn(void)
{
    unsigned char c = CELL_START;

    if (dome_dead)
        new_dome();
    while (is_broken(c))                 // the start cell, or the next whole one
        if (++c == NCELLS)
            c = 1;
    cell = c;
    dome_angle = cell_step[c];
    ship_lat = cell_lat[c];
    spawn_timer = 50;
}

static void new_game(void)
{
    lives = 3;
    score10 = 0;
    score_hi = 0;
    score_shown = 1;                     // (redraw even if the low 16 bits were 0)
    integ_shown = lives_shown = 255;     // (the title page used the HUD lines)
#ifdef SCORE_TEST
    score10 = SCORE_TEST;                // test build: start near a carry
#ifdef SCORE_TEST_HI
    score_hi = SCORE_TEST_HI;            //   or near the cap
#endif
#endif
    kills = hits = 0;
    game_over = 0;
    dome_dead = 1;
    respawn();
#ifdef CRACK_TEST                    // test build: each game starts with CRACK_TEST tiles broken
    for (nbroken = 0; nbroken < CRACK_TEST; nbroken++) {
        broken[nbroken] = (unsigned char)(nbroken * 3 % mis_ring_end[4]);
        broken_bits[broken[nbroken] >> 3] |= bit_mask[broken[nbroken] & 7];
    }
#endif
}

static void missiles_update(void)
{
    unsigned char i, live = 0;
    struct missile *m = missiles;

    missiles_step();
    collide();
    explosions_update();
    for (i = 0; i < NMIS; i++, m++) {
        if (m->state == 2) {         // hit the dome: the tile breaks
#ifndef CRACK_TEST                   // (the test keeps a fixed set)
            break_tile(m);
#endif
            m->state = 0;
        }
        if (m->state)
            live++;
    }
    if (dead_t || game_over)
        return;                          // (no launches while the ship is gone)
    if (spawn_timer) {
        spawn_timer--;
        return;
    }
    if (live >= wave_live)
        return;
    for (m = missiles; m->state; m++)
        ;
    spawn(m);
    spawn_timer = (unsigned char)(SPAWN_GAP + (rand8() & 63));
}

// Lock-on: the ship rests on the cell a missile (within radar range) is
// aimed at, so a shot now will hit it. The radar highlights that missile,
// its ellipse blinks bright, and channel B pips.

static void lock_update(void)
{
    struct missile *m = missiles;
    unsigned char i;

    locked = 0;
    radar_ring = 255;
    if (!move_left) {
        radar_ring = mis_cell_ring[cell];
        radar_phi = mis_cell_phi[cell];
        for (i = 0; i < NMIS; i++, m++)
            if (m->state == 1 && m->ring == radar_ring && m->phi == radar_phi
                && m->pos[9] < RADAR_RMAX)
                locked = 1;
    }
    if (locked)
        lock_t++;
    else
        lock_t = 0;
    radar_dim = (unsigned char)((locked && (lock_t & 4)) ? 0x7f : 0x48);   // blink: 4 frames bright, 4 dim
}

#ifdef FRAME_STATS
unsigned long frame_overruns, frame_loops;   // read them with tests/vxhost --ram
unsigned char frame_minidle = 255;          // least idle time seen, in 256 cycles
unsigned long radar_sum, radar_n;           // radar_draw's time, in 256 cycles (T2 high byte)
unsigned char radar_max;
unsigned long crack_sum, crack_n;           // cracks_draw's time, in 256 cycles
unsigned long text_sum, text_n;             // hud_draw's time
unsigned long logic_steps;                  // game_step calls (catch-up check)
#endif

// ---- title screen ------------------------------------------------------------
// Pages of BIOS text, each line centred: the title (with the dome turning,
// so calibrating has something to show), the controls, how to play, the
// credits. They turn every TITLE_PAGE_FRAMES or on button 3; button 2
// changes the level (shown on the first page, with its high score); button
// 1 starts a game; holding button 4 calibrates (the dome, no text). GAME
// OVER goes back here, to the high scores, after GAME_OVER_FRAMES.
#define TITLE_PAGE_FRAMES 250
#ifndef BEST_Y
#define BEST_Y 20                        // the high score's digits (HUD units)
#endif
#define GAME_OVER_FRAMES  250
// BIOS text size for every screen (set at start: the BIOS leaves the size of
// the header's last line, the small version line, behind). Height -8 and
// width 72 are the BIOS's defaults. Centring, measured in vecx at that size:
// a character advances ~10 x and the ink starts ~9 x right of the given x,
// so n characters are centred at x = -(5n + 9) (text_x).
#define TEXT_HEIGHT -8
#define TEXT_WIDTH  72
#define TEXT_CHAR_W 10                   // x per character (measured)
#define TEXT_INK_X  9                    // the ink's offset from the given x (measured)

static signed char text_x(unsigned char n)   // x that centres n characters
{
    return (signed char)-(signed char)(n * (TEXT_CHAR_W / 2) + TEXT_INK_X);
}
#define TEXT_ROW    -20                  // y per line
#define TITLE_Y 100
#ifndef PRESS_Y
#define PRESS_Y -124                     // clear of the dome's bottom
#endif

static const char * const page_controls[] = {
    "CONTROLS\x80", "",
    "\x01STICK  MOVE\x80",            // \x01: a column, see text_lines
    "\x01" "1      FIRE\x80",
    "\x01" "2      JUMP, LEVEL\x80",
    "\x01" "3      NEXT PAGE\x80",
    "\x01" "4 HOLD CALIBRATE\x80", 0
};
static const char * const page_play[] = {
    "DEFEND THE DOME\x80", "",
    "SHOOT MISSILES\x80",
    "BEFORE THEY HIT\x80", "",
    "HITS CRACK TILES\x80", "",
    "JUMP OVER CRACKS\x80", "",
    "AT 0% DOME COLLAPSES\x80", 0
};
// The levels' differences, over two pages (one table of both, 7 lines,
// ran at 64% of 50 Hz: flickers).
static const char * const page_levels[] = {
    "LEVELS\x80", "",
    "A TILE CRACKS WITH\x80",
    "N CRACKED NEIGHBORS\x80", "",
    "\x01" "EASY   N = 5\x80",
    "\x01" "NORMAL N = 4\x80",
    "\x01" "HARD   N = 3\x80", 0
};
static const char * const page_collapse[] = {
    "LEVELS\x80", "",
    "DOME COLLAPSE COSTS\x80", "",
    "\x01" "EASY   NOTHING\x80",
    "\x01" "NORMAL ONE LIFE\x80",
    "\x01" "HARD   THE GAME\x80", 0
};
static const char * const page_score[] = {
    "RADAR\x80", "",
    "BLINKS AND BEEPS\x80",
    "WHEN LOCKED ON\x80", "",
    "SCORE\x80", "",
    "1000 POINTS TIMES\x80",
    "DOME INTEGRITY\x80",
    "PER MISSILE\x80", 0
};
static const char * const page_credits[] = {
    "CREDITS\x80", "",
    "GAME DESIGN:\x80",
    "JOHN EMMER\x80","",
    "IMPLEMENTATION:\x80",
    "CLAUDE OPUS 5.5\x80", "",
    "(C) 2026\x80", 0
};
static const char * const page_thanks[] = {
    "BUILT WITH\x80", "",
    "GCC6809\x80",
    "ASXXXX\x80",
    "PEERC: P.JOHANNSEN\x80",
    "VIDE: MALBAN\x80", 0
};
// (the numbers: best_draw at BEST_ROWS_Y, under each level's name)
static const char name_easy[] = "EASY\x80", name_normal[] = "NORMAL\x80", name_hard[] = "HARD\x80";
static const char * const page_best[] = {
    "HIGH SCORES\x80", "",
    name_easy, "", "",
    name_normal, "", "",
    name_hard, 0
};
#define PAGE_BEST 1
#define TITLE_PAGES 9
static const char * const * const pages[TITLE_PAGES] = {
    0, page_best, page_controls, page_play, page_levels, page_collapse, page_score, page_credits, page_thanks
};
static const char * const level_name[LEVELS] = { name_easy, name_normal, name_hard };
static const signed char best_rows_y[LEVELS] = { 20, -27, -75 };   // (HUD units: BIOS y 25, -35, -95)
static char press_text[] = "PRESS 1 TO START\x80";
static char level_hint[] = "2 TO CHANGE LEVEL\x80";   // (takes turns with press_text: another line slowed the page to 78%)
static unsigned char title_on = 1, title_page, title_t, title_spin;
static char big_title[] = "E-SRG\x80";

// Prints a page's lines from y 100 down, each centred. Lines starting with
// \x01 (not printed) are left-aligned together instead, as one block centred
// on the longest of them, so columns padded with spaces line up (the font
// is fixed-width).
static unsigned char text_len(const char *c)
{
    unsigned char n = 0;

    while (*c && *c != (char)0x80) {
        c++;
        n++;
    }
    return n;
}

static void text_lines(const char * const *l)
{
    const char * const *p;
    signed char y = 100;
    unsigned char n, col = 0;

    for (p = l; *p; p++)                 // the widest column line
        if (**p == 1 && (n = text_len(*p + 1)) > col)
            col = n;
    for (; *l; l++, y = (signed char)(y + TEXT_ROW)) {
        if (**l == 1)
            Print_Str_d(y, text_x(col), (char *)*l + 1);
        else if ((n = text_len(*l)) != 0)
            Print_Str_d(y, text_x(n), (char *)*l);
    }
}

// A level's high score digits on the title pages, in hud.s's line k (the
// game's readouts' lines: new_game makes those again).
static void __attribute__((noinline)) best_draw(unsigned char k, signed char y)
{
    struct hud_line *l = &hud_lines[k];
    unsigned char i, n = best_n[k];

    l->y = y;
    l->x = (signed char)-(signed char)(n * 9 / 2);   // centred, 9 per glyph
    l->n = n;
    for (i = 0; i < n; i++)
        l->g[i] = hud_glyphs[best_d[k][i]];
}

static void title_screen(void)
{
    unsigned char cal = calibrate();

    if (Vec_Buttons & 0x01) {            // button 1: play
        title_on = 0;
        new_game();
        return;
    }
    if (Vec_Buttons & 0x02) {            // button 2: the next level
        if (++level == LEVELS)
            level = 0;
        title_page = 0;
        title_t = 0;
    }
    if ((Vec_Buttons & 0x04) || ++title_t >= TITLE_PAGE_FRAMES) {
        title_t = 0;
        if (++title_page == TITLE_PAGES)
            title_page = 0;
    }
    if (cal || title_page == 0) {
        if (!(++title_spin & 3) && ++dome_angle >= DOME_STEPS)
            dome_angle = 0;
        dome_draw(dome_angle);
    }
    if (cal)
        return;
    Intensity_a(0x7f);
    Reset0Ref();                         // (text moves from where the beam is)
    if (title_page == 0) {
        Vec_Text_Height = -12;           // the name, big
        Vec_Text_Width = 0x60;
        Print_Str_d(TITLE_Y, -45, big_title);   // (larger: centred by measuring)
        Vec_Text_Height = TEXT_HEIGHT;
        Vec_Text_Width = TEXT_WIDTH;
        if (title_t & 64)                // under the dome, each for 64 frames
            Print_Str_d(PRESS_Y, text_x(17), level_hint);
        else
            Print_Str_d(PRESS_Y, text_x(16), press_text);
        Print_Str_d(60, text_x(text_len(level_name[level])), (char *)level_name[level]);
        hud_lines[0].n = hud_lines[1].n = hud_lines[2].n = 0;
        best_draw(level, BEST_Y);
        hud_draw();
    } else {
        text_lines(pages[title_page]);
        if (title_page == PAGE_BEST) {
            unsigned char k;
            for (k = 0; k < LEVELS; k++)
                best_draw(k, best_rows_y[k]);
            hud_draw();
        }
    }
}

// Catch-up: when a loop takes longer than a 50 Hz frame (Wait_Recal returns
// late), the game's logic runs once per frame that passed, so play speed
// stays the same and only the picture updates less often (things move in
// bigger steps). The time comes from VIA timer 2, which Wait_Recal starts at
// 30,000 cycles: if it has already expired, its high byte has kept counting
// down from $FF, so $FF - T2H is the overrun in 256-cycle units. Leftover
// time carries to the next loop. (Read only T2H: reading T2L would clear
// the flag Wait_Recal waits for.)
#define FRAME_UNITS 117                  // 30,000 / 256
#define MAX_STEPS   3
static unsigned char overrun;            // carried, in 256-cycle units

static unsigned char catch_up(void)
{
    unsigned char n = 1;

#ifndef NO_CATCHUP
    while (overrun >= FRAME_UNITS && n < MAX_STEPS) {
        overrun -= FRAME_UNITS;
        n++;
    }
    if (overrun >= FRAME_UNITS)
        overrun = 0;                     // (too far behind: let it go)
#endif
    return n;
}

// One 50 Hz frame of the game's logic (cal: calibrating, the stick is busy).
static void __attribute__((noinline)) game_step(unsigned char cal)
{
#ifdef FRAME_STATS
    logic_steps++;
#endif
    if (game_over) {
        if (Vec_Buttons & 0x01)  // button 1: a new game
            new_game();
        else if (++title_t >= GAME_OVER_FRAMES) {
            title_on = 1;        // back to the title: the high scores
            title_page = PAGE_BEST;
            title_t = 0;
        }
    } else if (dead_t) {
        if (--dead_t == 0) {
            if (lives)
                respawn();
            else {
                game_over = 1;
                best_update();
                title_t = 0;
            }
        }
    } else if (!cal) {
        if (Vec_Buttons & 0x01)  // button 1 just pressed: fire
            fire_req = 1;
        if (Vec_Buttons & 0x02)  // button 2: jump (button 3: unused)
            jump_req = 1;
        ship_input();
        if (fire_req && !move_left) {  // only from a cell centre
            fire();
            fire_req = 0;
        }
    }
    missiles_update();
    if (!dead_t && !game_over) {
        if (nbroken >= DOME_LIMIT)
            kill_ship(1);            // the dome is gone
        else if (!move_left && is_broken(cell))
            kill_ship(0);            // resting on a broken cell
    }
}

int main(void)
{
    unsigned char whole, cal, s;
    Vec_Joy_Mux_1_X = 1;             // stick 1, both axes (analog read)
    Vec_Joy_Mux_1_Y = 3;
    Vec_Joy_Mux_2_X = 0;             // stick 2 off: saves cycles
    Vec_Joy_Mux_2_Y = 0;
    Vec_Joy_Resltn = 0x02;           // 6-bit analog: plenty for 32 directions
    cell = CELL_START;
    dome_angle = cell_step[CELL_START];
    ship_lat = cell_lat[CELL_START];
    missiles_calibrate();
    sound_init();
    Vec_Text_Height = TEXT_HEIGHT;       // (not the boot screen's last size)
    Vec_Text_Width = TEXT_WIDTH;
#ifdef BEST_SLOT_TEST                // test build: as if a reset left this in the slot
    {                                // (1: our 4560, 2: 999990, 3: another program's)
        const char *t = BEST_SLOT_TEST == 1 ? "  4560" : BEST_SLOT_TEST == 2 ? "999990" : "MS 123";
        unsigned char i;
        for (i = 0; i < 6; i++)
            BIOS_HIGH_SCORE[i] = t[i];
    }
#endif
    best_load();
    while (1) {
#ifdef FRAME_STATS                   // debug: count loops that overran the frame
        if (*(volatile unsigned char *)0xD00D & 0x20)   // VIA T2 already expired
            frame_overruns++;
        else if (*(volatile unsigned char *)0xD009 < frame_minidle)
            frame_minidle = *(volatile unsigned char *)0xD009;  // T2 high: idle/256
        frame_loops++;
#endif
        if (*(volatile unsigned char *)0xD00D & 0x20) {   // T2 expired: late
            unsigned char late = (unsigned char)~*(volatile unsigned char *)0xD009;   // $FF - T2H
            overrun = late > (unsigned char)~overrun ? (unsigned char)~0 : (unsigned char)(overrun + late);
        }
        Wait_Recal();
        Read_Btns();
        Vec_Misc_Count = 0;          // Joy_Analog expects it 0
        Joy_Analog();
        zero_ref_settle();           // the read leaves the zero reference off 0
        if (title_on) {
            overrun = 0;
            title_screen();
            continue;
        }
        cal = (unsigned char)(!game_over && !dead_t && calibrate());
        for (s = catch_up(); s; s--) {   // the game's logic: once per 50 Hz frame
            game_step(cal);
            Vec_Buttons = 0;             // (a press counts once)
            if (title_on)
                break;
        }
        integrity_update();
        lock_update();
        sound_update();
        stars_draw((unsigned char)-(dome_angle + (dome_angle >> 4)));   // (one turn: 255; against
                                         //  the dome's front, like its far side)
        if (collapse_update())
            dome_draw(dome_angle);
        whole = (unsigned char)(!dome_dead || !dead_t);   // (cracks hidden while it collapses)
        if (!dead_t && !game_over)
            ship_draw(ship_lat);
        if (game_over) {
            Intensity_a(0x7f);
            Reset0Ref();
            Print_Str_d(40, -64, game_over_text);
        }
#ifdef FRAME_STATS
        {
            unsigned char t0 = *(volatile unsigned char *)0xD009;
            if (whole)
                cracks_draw(dome_angle);
            if (!(*(volatile unsigned char *)0xD00D & 0x20)) {
                crack_sum += (unsigned char)(t0 - *(volatile unsigned char *)0xD009);
                crack_n++;
            }
        }
#else
        if (whole)
            cracks_draw(dome_angle);
#endif
        missiles_draw(dome_angle);
        explosions_draw();
#ifdef FRAME_STATS
        {
            unsigned char t0 = *(volatile unsigned char *)0xD009;
            hud_draw();
            if (!(*(volatile unsigned char *)0xD00D & 0x20)) {
                text_sum += (unsigned char)(t0 - *(volatile unsigned char *)0xD009);
                text_n++;
            }
        }
#else
        hud_draw();
#endif
#ifndef NO_RADAR
#ifdef FRAME_STATS
        {
            unsigned char t0 = *(volatile unsigned char *)0xD009, dt;
            radar_draw(dome_angle);
            dt = (unsigned char)(t0 - *(volatile unsigned char *)0xD009);
            if (!(*(volatile unsigned char *)0xD00D & 0x20)) {   // only within the frame
                radar_sum += dt;
                radar_n++;
                if (dt > radar_max)
                    radar_max = dt;
            }
        }
#else
        radar_draw(dome_angle);
#endif
#endif
    }
    return 0;
}
