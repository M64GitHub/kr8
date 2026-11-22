/* shim.c - kr8's whole audio surface: miniaudio compiled once, here, as C.
 *
 * Same pattern as DUET's ma_shim.c: the 4 MB header never goes through
 * translate-c; Zig declares the handful of kr8_* functions below as
 * externs (src/audio/audio.zig).
 *
 * PLAYBACK is miniaudio's high-level engine: an ma_sound in STREAM mode
 * reads the file from disk page by page (a five-minute break costs no
 * RAM), decodes every WAV flavour dr_wav knows (PCM 8/16/24/32, float,
 * WAVE_FORMAT_EXTENSIBLE), converts to the device rate, loops, and
 * reports its cursor.
 *
 * TWO VOICE SLOTS, so a stop never clicks: stopping fades the current
 * voice out over a few milliseconds and leaves it to finish in its slot;
 * the next play takes the other slot. kr8_tick() (once a UI frame) frees
 * a faded voice. Every function here is called from the UI thread only.
 *
 * PEAKS run on kr8's peaks worker thread through an ma_decoder of their
 * own - no shared state with playback.
 */
#ifdef __APPLE__
#define MA_NO_RUNTIME_LINKING /* link CoreAudio & friends directly (build.zig) */
#endif
#define MA_NO_ENCODING
#define MA_NO_GENERATION
#define MA_IMPLEMENTATION
#include "miniaudio.h"

#include <stdlib.h>
#include "shim.h"

#define FADE_MS 6

typedef struct {
    ma_sound sound;
    int live;     /* initialised: must be uninit'ed */
    int retiring; /* fading out after a stop */
} Voice;

static ma_engine g_engine;
static int g_engine_ok = 0;
static Voice g_voice[2];
static int g_cur = -1; /* the voice the UI talks about, -1 = none */

static void voice_free(Voice *v)
{
    if (v->live) {
        ma_sound_uninit(&v->sound);
        v->live = 0;
    }
    v->retiring = 0;
}

int kr8_audio_init(void)
{
    ma_engine_config cfg;
    if (g_engine_ok)
        return 0;
    cfg = ma_engine_config_init();
    if (ma_engine_init(&cfg, &g_engine) != MA_SUCCESS)
        return -1;
    g_engine_ok = 1;
    return 0;
}

void kr8_audio_uninit(void)
{
    voice_free(&g_voice[0]);
    voice_free(&g_voice[1]);
    g_cur = -1;
    if (g_engine_ok) {
        ma_engine_uninit(&g_engine);
        g_engine_ok = 0;
    }
}

void kr8_stop(void)
{
    Voice *v;
    if (g_cur < 0)
        return;
    v = &g_voice[g_cur];
    if (v->live && ma_sound_is_playing(&v->sound)) {
        ma_sound_stop_with_fade_in_milliseconds(&v->sound, FADE_MS);
        v->retiring = 1;
    } else {
        voice_free(v);
    }
    g_cur = -1;
}

int kr8_play(const char *path, int loop, uint64_t loop_start, uint64_t loop_end)
{
    int slot;
    Voice *v;
    if (!g_engine_ok)
        return -1;
    kr8_stop();
    /* the slot that is NOT fading; if both are busy, cut the older fade */
    slot = g_voice[0].live ? 1 : 0;
    v = &g_voice[slot];
    voice_free(v);
    if (ma_sound_init_from_file(&g_engine, path,
                                MA_SOUND_FLAG_STREAM | MA_SOUND_FLAG_NO_SPATIALIZATION,
                                NULL, NULL, &v->sound) != MA_SUCCESS)
        return -2;
    v->live = 1;
    if (loop_end > loop_start)
        ma_data_source_set_loop_point_in_pcm_frames(ma_sound_get_data_source(&v->sound),
                                                    loop_start, loop_end);
    ma_sound_set_looping(&v->sound, loop ? MA_TRUE : MA_FALSE);
    if (ma_sound_start(&v->sound) != MA_SUCCESS) {
        voice_free(v);
        return -3;
    }
    g_cur = slot;
    return 0;
}

void kr8_tick(void)
{
    int i;
    for (i = 0; i < 2; i++) {
        Voice *v = &g_voice[i];
        if (i == g_cur || !v->live)
            continue;
        if (!ma_sound_is_playing(&v->sound))
            voice_free(v);
    }
}

void kr8_set_loop(int loop)
{
    if (g_cur >= 0)
        ma_sound_set_looping(&g_voice[g_cur].sound, loop ? MA_TRUE : MA_FALSE);
}

int kr8_is_playing(void)
{
    Voice *v;
    if (g_cur < 0)
        return 0;
    v = &g_voice[g_cur];
    return v->live && ma_sound_is_playing(&v->sound) && !ma_sound_at_end(&v->sound);
}

uint64_t kr8_cursor(void)
{
    ma_uint64 c = 0;
    if (g_cur >= 0)
        ma_sound_get_cursor_in_pcm_frames(&g_voice[g_cur].sound, &c);
    return c;
}

uint64_t kr8_length(void)
{
    ma_uint64 n = 0;
    if (g_cur >= 0)
        ma_sound_get_length_in_pcm_frames(&g_voice[g_cur].sound, &n);
    return n;
}

void kr8_set_volume(float v)
{
    if (g_engine_ok)
        ma_engine_set_volume(&g_engine, v);
}

/* ---------------------------------------------------------------- peaks */

#define CHUNK 4096

int kr8_peaks(const char *path, float *mins, float *maxs, uint32_t buckets,
              uint64_t *out_frames, volatile int *cancel)
{
    ma_decoder_config cfg = ma_decoder_config_init(ma_format_f32, 0, 0);
    ma_decoder dec;
    ma_uint64 total = 0, pos = 0;
    ma_uint32 ch, b;
    float *buf;

    *out_frames = 0;
    if (buckets == 0)
        return -1;
    if (ma_decoder_init_file(path, &cfg, &dec) != MA_SUCCESS)
        return -1;
    ch = dec.outputChannels;
    if (ma_decoder_get_length_in_pcm_frames(&dec, &total) != MA_SUCCESS || total == 0 || ch == 0) {
        ma_decoder_uninit(&dec);
        return -2;
    }
    buf = (float *)malloc(sizeof(float) * CHUNK * ch);
    if (!buf) {
        ma_decoder_uninit(&dec);
        return -3;
    }
    for (b = 0; b < buckets; b++) {
        mins[b] = 0.0f;
        maxs[b] = 0.0f;
    }
    for (;;) {
        ma_uint64 got = 0, i;
        if (cancel && *cancel)
            break;
        if (ma_decoder_read_pcm_frames(&dec, buf, CHUNK, &got) != MA_SUCCESS || got == 0)
            break;
        for (i = 0; i < got; i++) {
            ma_uint64 at = pos + i;
            ma_uint32 k = (ma_uint32)((at * buckets) / total);
            ma_uint32 c;
            if (k >= buckets)
                k = buckets - 1;
            for (c = 0; c < ch; c++) {
                float s = buf[i * ch + c];
                if (s < mins[k]) mins[k] = s;
                if (s > maxs[k]) maxs[k] = s;
            }
        }
        pos += got;
    }
    free(buf);
    ma_decoder_uninit(&dec);
    *out_frames = pos;
    if (cancel && *cancel)
        return 1;
    return 0;
}
