/*
 * vxhost.c — headless Vectrex runner: boot a cart in the vecx libretro core,
 * run N frames, write the last frame as PPM, optionally dump the 1 KB RAM.
 *
 * Built and driven by tests/smoke.sh (make test). Standalone usage:
 *   tests/vxhost <core.so> <rom.bin> [options]
 *     --frames N          frames to run (default 700; the stock BIOS intro
 *                         alone takes ~512 frames, carts start ~frame 600-650)
 *     --ppm FILE          write the last frame as binary PPM
 *     --persist K         ...as the per-pixel max over the last K frames
 *                         (phosphor-like; default 1). Use it when the game
 *                         loop overruns a frame: the final 30k-cycle slice
 *                         may then contain no vectors at all.
 *     --series DIR EVERY  also write every EVERY-th frame to DIR/fNNNN.ppm
 *     --ram               print $C800-$CBFF hex dump after the run
 *     --hold SPEC         hold player-1 input for a frame range; repeatable.
 *                         SPEC = keys@START-END[/PERIOD], keys = comma list of
 *                         1,2,3,4,up,down,left,right   e.g. --hold 1@650-660
 *                         /PERIOD: press for the first half of every PERIOD
 *                         frames (repeated presses), e.g. --hold 2@800-3000/10
 *     --wav FILE          write the sound (16-bit stereo) to FILE
 * Also reports the game's frame rate: BIOS Wait_Recal increments
 * Vec_Loop_Count ($C825) once per game-loop iteration, so its delta over the
 * last 100 frames vs 100 shows whether the loop fits the 30,000-cycle frame.
 * Exit status: 0 if video was produced AND cart code ran, 1 otherwise.
 */
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>

#include "libretro.h"

#define MAX_HOLDS 64
struct hold { unsigned mask, start, end, period; };
static struct hold holds[MAX_HOLDS];
static int n_holds = 0;

static unsigned frame_no = 0, video_frames = 0, vw = 0, vh = 0;
static int pixfmt = RETRO_PIXEL_FORMAT_0RGB1555;
static unsigned char *last = NULL;
static size_t last_pitch = 0;
static unsigned char *acc = NULL;      /* RGB888 max over the persist window */
static unsigned persist = 1, persist_from = 0;
static const char *series_dir = NULL;
static unsigned series_every = 0;

/* bit order matches RETRO_DEVICE_ID_JOYPAD_* used by vecx:
 * A=btn1, B=btn2, X=btn3, Y=btn4 */
static unsigned key_bit(const char *k)
{
    if (!strcmp(k, "1")) return 1u << RETRO_DEVICE_ID_JOYPAD_A;
    if (!strcmp(k, "2")) return 1u << RETRO_DEVICE_ID_JOYPAD_B;
    if (!strcmp(k, "3")) return 1u << RETRO_DEVICE_ID_JOYPAD_X;
    if (!strcmp(k, "4")) return 1u << RETRO_DEVICE_ID_JOYPAD_Y;
    if (!strcmp(k, "up")) return 1u << RETRO_DEVICE_ID_JOYPAD_UP;
    if (!strcmp(k, "down")) return 1u << RETRO_DEVICE_ID_JOYPAD_DOWN;
    if (!strcmp(k, "left")) return 1u << RETRO_DEVICE_ID_JOYPAD_LEFT;
    if (!strcmp(k, "right")) return 1u << RETRO_DEVICE_ID_JOYPAD_RIGHT;
    fprintf(stderr, "unknown key '%s'\n", k);
    exit(2);
}

static void parse_hold(char *spec)
{
    char *at = strchr(spec, '@');
    if (!at || n_holds >= MAX_HOLDS) { fprintf(stderr, "bad --hold %s\n", spec); exit(2); }
    *at = 0;
    struct hold *h = &holds[n_holds++];
    h->mask = 0;
    for (char *k = strtok(spec, ","); k; k = strtok(NULL, ","))
        h->mask |= key_bit(k);
    h->period = 0;
    if (sscanf(at + 1, "%u-%u/%u", &h->start, &h->end, &h->period) < 2) { fprintf(stderr, "bad range\n"); exit(2); }
}

static void pixel_rgb(const unsigned char *px, size_t pitch, unsigned x, unsigned y,
                      unsigned char rgb[3])
{
    if (pixfmt == RETRO_PIXEL_FORMAT_XRGB8888) {
        const unsigned char *q = px + y * pitch + x * 4;
        rgb[0] = q[2]; rgb[1] = q[1]; rgb[2] = q[0];
        return;
    }
    unsigned short p = ((const unsigned short *)(px + y * pitch))[x];
    if (pixfmt == RETRO_PIXEL_FORMAT_RGB565) {
        rgb[0] = ((p >> 11) & 31) * 255 / 31;
        rgb[1] = ((p >> 5) & 63) * 255 / 63;
    } else {
        rgb[0] = ((p >> 10) & 31) * 255 / 31;
        rgb[1] = ((p >> 5) & 31) * 255 / 31;
    }
    rgb[2] = (p & 31) * 255 / 31;
}

static void write_ppm(const char *path, const unsigned char *px, size_t pitch)
{
    FILE *o = fopen(path, "wb");
    if (!o) { perror(path); return; }
    fprintf(o, "P6\n%u %u\n255\n", vw, vh);
    for (unsigned y = 0; y < vh; y++)
        for (unsigned x = 0; x < vw; x++) {
            unsigned char rgb[3];
            pixel_rgb(px, pitch, x, y, rgb);
            fwrite(rgb, 1, 3, o);
        }
    fclose(o);
}

static void write_acc_ppm(const char *path)
{
    FILE *o = fopen(path, "wb");
    if (!o) { perror(path); return; }
    fprintf(o, "P6\n%u %u\n255\n", vw, vh);
    fwrite(acc, 3, (size_t)vw * vh, o);
    fclose(o);
}

static void video_cb(const void *data, unsigned w, unsigned h, size_t pitch)
{
    if (!data) return;
    video_frames++;
    if (!last || w != vw || h != vh || pitch != last_pitch) {
        free(last);
        last = malloc(h * pitch);
    }
    vw = w; vh = h; last_pitch = pitch;
    memcpy(last, data, h * pitch);
    if (persist > 1 && frame_no >= persist_from) {
        if (!acc) acc = calloc((size_t)w * h, 3);
        for (unsigned y = 0; acc && y < h; y++)
            for (unsigned x = 0; x < w; x++) {
                unsigned char rgb[3], *a = acc + ((size_t)y * w + x) * 3;
                pixel_rgb(last, pitch, x, y, rgb);
                for (int c = 0; c < 3; c++) if (rgb[c] > a[c]) a[c] = rgb[c];
            }
    }
    if (series_dir && series_every && frame_no % series_every == 0) {
        char p[1024];
        snprintf(p, sizeof p, "%s/f%04u.ppm", series_dir, frame_no);
        write_ppm(p, last, pitch);
    }
}

/* sound capture for --wav: interleaved stereo samples */
static int16_t *snd = NULL;
static size_t snd_n = 0, snd_cap = 0;
static bool snd_on = false;

static void snd_put(const int16_t *d, size_t frames)
{
    if (!snd_on) return;
    if (snd_n + frames * 2 > snd_cap) {
        snd_cap = (snd_n + frames * 2) * 2 + 4096;
        snd = realloc(snd, snd_cap * sizeof *snd);
    }
    memcpy(snd + snd_n, d, frames * 2 * sizeof *snd);
    snd_n += frames * 2;
}

static void audio_cb(int16_t l, int16_t r) { int16_t d[2] = { l, r }; snd_put(d, 1); }
static size_t audio_batch_cb(const int16_t *d, size_t n) { snd_put(d, n); return n; }

static void put32(FILE *f, unsigned v) { for (int i = 0; i < 4; i++) fputc((v >> (8 * i)) & 255, f); }
static void put16(FILE *f, unsigned v) { fputc(v & 255, f); fputc((v >> 8) & 255, f); }

static void write_wav(const char *path, unsigned rate)
{
    FILE *f = fopen(path, "wb");
    if (!f) { perror(path); return; }
    unsigned bytes = (unsigned)(snd_n * 2);
    fwrite("RIFF", 1, 4, f); put32(f, 36 + bytes); fwrite("WAVEfmt ", 1, 8, f);
    put32(f, 16); put16(f, 1); put16(f, 2); put32(f, rate); put32(f, rate * 4);
    put16(f, 4); put16(f, 16); fwrite("data", 1, 4, f); put32(f, bytes);
    fwrite(snd, 2, snd_n, f);
    fclose(f);
}
static void input_poll_cb(void) { }

static int16_t input_state_cb(unsigned port, unsigned device, unsigned index, unsigned id)
{
    (void)index;
    if (port != 0 || device != RETRO_DEVICE_JOYPAD) return 0; /* analog -> centered */
    for (int i = 0; i < n_holds; i++)
        if (frame_no >= holds[i].start && frame_no <= holds[i].end &&
            (holds[i].mask & (1u << id)) &&
            (!holds[i].period ||
             (frame_no - holds[i].start) % holds[i].period < (holds[i].period + 1) / 2))
            return 1;
    return 0;
}

/* Must return bool: a void env callback leaves garbage in the return
 * register and the core may mis-initialize (the old template vxhost bug). */
static bool env_cb(unsigned cmd, void *data)
{
    if (cmd == RETRO_ENVIRONMENT_SET_PIXEL_FORMAT && data) {
        pixfmt = *(int *)data;
        return true;
    }
    return false; /* no HW render, no variables -> software renderer */
}

typedef void (*fn_env)(retro_environment_t);
typedef void (*fn_video)(retro_video_refresh_t);
typedef void (*fn_audio)(retro_audio_sample_t);
typedef void (*fn_audio_batch)(retro_audio_sample_batch_t);
typedef void (*fn_poll)(retro_input_poll_t);
typedef void (*fn_state)(retro_input_state_t);
typedef void (*fn_void)(void);
typedef bool (*fn_load)(const struct retro_game_info *);
typedef void *(*fn_mem)(unsigned);
typedef size_t (*fn_ssize)(void);
typedef bool (*fn_ser)(void *, size_t);
typedef void (*fn_avinfo)(struct retro_system_av_info *);

#define SYM(T, name) T name = (T)dlsym(core, "retro_" #name); \
    if (!name) { fprintf(stderr, "core lacks retro_%s\n", #name); return 1; }

int main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(stderr, "usage: %s <core.so> <rom.bin> [--frames N] [--ppm F] "
                "[--series DIR EVERY] [--ram] [--wav F] [--hold keys@A-B[/P]]...\n", argv[0]);
        return 2;
    }
    unsigned frames = 700;
    const char *ppm = NULL;
    bool dump_ram = false;
    const char *wav = NULL;
    for (int a = 3; a < argc; a++) {
        if (!strcmp(argv[a], "--frames") && a + 1 < argc) frames = (unsigned)atoi(argv[++a]);
        else if (!strcmp(argv[a], "--ppm") && a + 1 < argc) ppm = argv[++a];
        else if (!strcmp(argv[a], "--series") && a + 2 < argc) {
            series_dir = argv[++a]; series_every = (unsigned)atoi(argv[++a]);
        }
        else if (!strcmp(argv[a], "--ram")) dump_ram = true;
        else if (!strcmp(argv[a], "--wav") && a + 1 < argc) { wav = argv[++a]; snd_on = true; }
        else if (!strcmp(argv[a], "--persist") && a + 1 < argc) persist = (unsigned)atoi(argv[++a]);
        else if (!strcmp(argv[a], "--hold") && a + 1 < argc) parse_hold(argv[++a]);
        else { fprintf(stderr, "unknown arg %s\n", argv[a]); return 2; }
    }

    void *core = dlopen(argv[1], RTLD_NOW);
    if (!core) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 1; }
    SYM(fn_env, set_environment)
    SYM(fn_video, set_video_refresh)
    SYM(fn_audio, set_audio_sample)
    SYM(fn_audio_batch, set_audio_sample_batch)
    SYM(fn_poll, set_input_poll)
    SYM(fn_state, set_input_state)
    SYM(fn_void, init)
    SYM(fn_void, deinit)
    SYM(fn_void, run)
    SYM(fn_load, load_game)
    SYM(fn_mem, get_memory_data)
    SYM(fn_ssize, serialize_size)
    SYM(fn_ser, serialize)
    SYM(fn_avinfo, get_system_av_info)

    set_environment(env_cb);
    set_video_refresh(video_cb);
    set_audio_sample(audio_cb);
    set_audio_sample_batch(audio_batch_cb);
    set_input_poll(input_poll_cb);
    set_input_state(input_state_cb);
    init();

    FILE *f = fopen(argv[2], "rb");
    if (!f) { perror(argv[2]); return 1; }
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    unsigned char *rom = malloc(sz > 0 ? (size_t)sz : 1);
    if (fread(rom, 1, (size_t)sz, f) != (size_t)sz) { fprintf(stderr, "read error\n"); return 1; }
    fclose(f);

    struct retro_game_info info = { .path = argv[2], .data = rom, .size = (size_t)sz };
    if (!load_game(&info)) { fprintf(stderr, "retro_load_game failed\n"); return 1; }

    /* Detect when the cart takes over from the BIOS intro: the 6809 S
     * register is in the save state (vecx: x,y,u,s,pc,... as ints) and the
     * return address on top of the stack points into cart ROM (< $8000) once
     * cart code is calling BIOS routines such as Wait_Recal. */
    size_t ssz = serialize_size();
    unsigned char *state = malloc(ssz);
    const unsigned char *ram = get_memory_data(RETRO_MEMORY_SYSTEM_RAM);
    int cart_frame = -1;
    persist_from = frames > persist ? frames - persist : 0;
    unsigned *loops = calloc(frames + 1, sizeof *loops);  /* Vec_Loop_Count per frame */
    for (frame_no = 0; frame_no < frames; frame_no++) {
        run();
        if (ram) loops[frame_no + 1] = (unsigned)ram[0x25] << 8 | ram[0x26];
        if (cart_frame < 0 && ram && serialize(state, ssz)) {
            unsigned sp = ((unsigned *)state)[3];
            if (sp >= 0xC800 && sp < 0xCBFE) {
                unsigned ret = (unsigned)ram[sp - 0xC800] << 8 | ram[sp - 0xC800 + 1];
                if (ret < 0x8000) cart_frame = (int)frame_no;
            }
        }
    }

    printf("frames run: %u, video frames: %u, size %ux%u\n", frames, video_frames, vw, vh);
    if (cart_frame >= 0) printf("cart code running from frame %d\n", cart_frame);
    else printf("CART NEVER STARTED (still in BIOS) - run more frames (>=700) or check the header\n");
    if (cart_frame >= 0 && ram) {
        /* measure after the cart's first frames, over at most the last 100 */
        unsigned from = (unsigned)cart_frame + 5;
        if (frames > 100 && frames - 100 > from) from = frames - 100;
        if (from + 10 <= frames) {
            unsigned n = frames - from;
            unsigned calls = (loops[frames] - loops[from]) & 0xFFFF;
            printf("game loop: %u Wait_Recal calls in the last %u frames%s\n", calls, n,
                   calls * 100 >= n * 95 ? " (fits the frame budget)"
                   : "  << OVER BUDGET: one loop takes more than a 30,000-cycle frame");
        }
    }
    if (ppm && persist > 1 && acc) {
        write_acc_ppm(ppm);
        printf("last %u frames (max) -> %s\n", persist, ppm);
    } else if (ppm && last) {
        write_ppm(ppm, last, last_pitch);
        printf("last frame -> %s\n", ppm);
    }
    if (wav) {
        struct retro_system_av_info av;
        memset(&av, 0, sizeof av);
        get_system_av_info(&av);
        write_wav(wav, av.timing.sample_rate > 0 ? (unsigned)(av.timing.sample_rate + 0.5) : 44100);
        printf("sound: %zu samples at %.0f Hz -> %s\n", snd_n / 2, av.timing.sample_rate, wav);
    }
    if (dump_ram) {
        const unsigned char *r = get_memory_data(RETRO_MEMORY_SYSTEM_RAM);
        for (int i = 0; r && i < 1024; i++) {
            if (i % 16 == 0) printf("\n%04X:", 0xC800 + i);
            printf(" %02X", r[i]);
        }
        printf("\n");
    }
    deinit();
    dlclose(core);
    return (video_frames && cart_frame >= 0) ? 0 : 1;
}
