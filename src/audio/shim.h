/* shim.h - kr8's audio surface (keeps miniaudio.h out of translate-c).
 * Zig mirrors these as externs in src/audio/audio.zig. */
#ifndef KR8_SHIM_H
#define KR8_SHIM_H

#include <stdint.h>

int kr8_audio_init(void); /* 0 = ok */
void kr8_audio_uninit(void);

/* Stream `path` from its start; loop_end > loop_start sets the loop span
 * (frames, end exclusive). 0 = ok. */
int kr8_play(const char *path, int loop, uint64_t loop_start, uint64_t loop_end);
void kr8_stop(void);  /* short fade, never a click */
void kr8_tick(void);  /* once a UI frame: free faded voices */
void kr8_set_loop(int loop);
int kr8_is_playing(void);
uint64_t kr8_cursor(void); /* frames, in the file's own rate */
uint64_t kr8_length(void);
void kr8_set_volume(float v);

/* Decode `path` into `buckets` min/max pairs (all channels). Returns 0 ok,
 * 1 cancelled (*cancel went non-zero), negative on failure. */
int kr8_peaks(const char *path, float *mins, float *maxs, uint32_t buckets,
              uint64_t *out_frames, volatile int *cancel);

#endif
