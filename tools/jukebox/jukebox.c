// jukebox.c: plays the 14 tunes in the Vectrex BIOS, to pick one for a
// cartridge header (.music) or a game. Build: make jukebox (build/jukebox.bin).
//
// Stick left/right: choose (the BIOS boot screen says JUKEBOX; the page
// keeps to 5 text lines so every loop fits a frame and tunes keep tempo).
// Button 1: play. Button 2: stop.
// Button 3: play all, from the chosen one on.
//
// The BIOS music player, the way PeerC's sample games drive it: each frame,
// Init_Music_chk (DP = $C8) with the tune, then Wait_Recal, then Do_Sound.
// Setting Vec_Music_Flag = 1 starts the tune; the BIOS clears it at the end.

#include <vectrex.h>

struct cartridge_t
{
    char copyright[11];
    const void *music;
    signed int title_height;
    unsigned int title_width;
    int title_y;
    int title_x;
    char title[];
};

const struct cartridge_t game_header
    __attribute__((section(".cartridge"), used)) =
{
    .copyright    = "g GCE 2026\x80",
    .music        = &Vec_Music_1,
    .title_height = -8,
    .title_width  = 80,
    .title_y      = -16,
    .title_x      = -64,
    .title        = "JUKEBOX\x80"
};

#define NTUNES 14
// BIOS addresses (PeerC's Vec_Music_0..d) and names; the second line shows
// the symbol to use, e.g. .music = &Vec_Music_5 in the cartridge header.
static const unsigned long tune_addr[NTUNES] = {   // (long: 16 bits under -mint8)
    0xED77, 0xFD0D, 0xFD1D, 0xFD81, 0xFDD3, 0xFE38, 0xFE76,
    0xFEC6, 0xFEF8, 0xFF26, 0xFF44, 0xFF62, 0xFF7A, 0xFF8F
};
static const char * const tune_name[NTUNES] = {
    "MINE STORM\x80", "VECTREX OPENING\x80", "BERZERK\x80", "ARMOR ATTACK\x80",
    "SCRAMBLE\x80", "SOLAR QUEST\x80", "CLEAN SWEEP\x80", "STAR TREK\x80",
    "FANFARE 1\x80", "FANFARE 2\x80", "FANFARE 3 BERZERK\x80", "FANFARE 3A\x80",
    "FANFARE 4\x80", "FANFARE 5\x80"
};
static const char hexdig[] = "0123456789ABCDEF";

static char sym_text[] = "VEC_MUSIC_0  $0000\x80";
static char play_text[] = "PLAYING\x80";
static char all_text[] = "PLAYING ALL\x80";
static char help1[] = "1 PLAY  2 STOP\x80";
static char help2[] = "3 PLAY ALL\x80";

static unsigned char len(const char *s)
{
    unsigned char n = 0;

    while (*s != (char)0x80) {
        s++;
        n++;
    }
    return n;
}

static void centred(signed char y, const char *s)
{
    Print_Str_d(y, (signed char)-(signed char)(len(s) * 6), (char *)s);
}

int main(void)
{
    unsigned char sel = 1, playing = 0, all = 0, rep = 0, i;
    unsigned long a;
    const void *tune = (const void *)tune_addr[1];

    Vec_Joy_Mux_1_X = 1;
    Vec_Joy_Mux_1_Y = 0;
    Vec_Joy_Mux_2_X = 0;
    Vec_Joy_Mux_2_Y = 0;
    Vec_Music_Flag = 0;
    while (1) {
        DP_to_C8();
        Init_Music_chk(tune);
        Wait_Recal();
        Do_Sound();
        Read_Btns();
        Joy_Digital();

        if (playing && Vec_Music_Flag == 0) {   // the tune ended
            playing = 0;
            if (all && sel + 1 < NTUNES) {
                sel++;
                tune = (const void *)tune_addr[sel];
                Vec_Music_Flag = 1;
                playing = 1;
            } else {
                all = 0;
            }
        }
        if (Vec_Joy_1_X == 0) {
            rep = 0;
        } else if (rep == 0 || --rep == 0) {   // step now, then every 12 frames
            if (Vec_Joy_1_X > 0 && sel + 1 < NTUNES)
                sel++;
            else if (Vec_Joy_1_X < 0 && sel)
                sel--;
            rep = 12;
        }
        if (Vec_Buttons & 0x01) {               // play the chosen tune
            tune = (const void *)tune_addr[sel];
            Vec_Music_Flag = 1;
            playing = 1;
            all = 0;
        }
        if (Vec_Buttons & 0x02) {               // stop
            Vec_Music_Flag = 0;
            Init_Music_Buf();
            playing = all = 0;
        }
        if (Vec_Buttons & 0x04) {               // play all from here
            tune = (const void *)tune_addr[sel];
            Vec_Music_Flag = 1;
            playing = all = 1;
        }

        sym_text[10] = hexdig[sel];
        a = tune_addr[sel];
        for (i = 0; i < 4; i++)
            sym_text[17 - i] = hexdig[(a >> (4 * i)) & 15];

        Intensity_a(0x7f);
        centred(60, tune_name[sel]);          // (few lines: BIOS text is slow,
        centred(40, sym_text);                // and the tunes play one step
        if (playing)                          // per frame, so a slow frame
            centred(0, all ? all_text : play_text);   // slows the music)
        centred(-70, help1);
        centred(-90, help2);
    }
    return 0;
}
