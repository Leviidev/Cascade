#pragma once
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque handle to a PS2 instance
typedef void* PS2Handle;

// ── Lifecycle ──────────────────────────────────────────────────────────────────
PS2Handle cascade_create(void);
void      cascade_destroy(PS2Handle h);
void      cascade_reset(PS2Handle h);

// ── BIOS / Disc ────────────────────────────────────────────────────────────────
// Returns 1 on success, 0 on failure.
int  cascade_load_bios(PS2Handle h, const uint8_t* data, size_t size);
int  cascade_load_disc(PS2Handle h, const char* path);
void cascade_eject_disc(PS2Handle h);

// ── Emulation ─────────────────────────────────────────────────────────────────
// Run one video frame. fps should be 50.0 (PAL) or 60.0 (NTSC).
void cascade_run_frame(PS2Handle h, double fps);

// ── Video ─────────────────────────────────────────────────────────────────────
// Fills out_rgba with width×height RGBA8 pixels.
// out_rgba must be large enough (use 640×480×4 = 1,228,800 bytes max).
// Returns 1 on success.
int cascade_get_framebuffer(PS2Handle h, uint8_t* out_rgba,
                            int* out_width, int* out_height);

// ── Audio ─────────────────────────────────────────────────────────────────────
// Returns the number of stereo sample-pairs actually written to out[].
// Each pair is 2 × int16_t (L, R). Call at 44100 Hz.
int cascade_get_audio(PS2Handle h, int16_t* out, int max_pairs);

// Returns the SPU2 output sample rate in Hz (always 44100).
int cascade_get_audio_sample_rate(void);

// ── Input ─────────────────────────────────────────────────────────────────────
// pad:     0 or 1
// button:  bitmask (see PS2Button enum below)
// pressed: 1 = pressed, 0 = released
void cascade_set_button(PS2Handle h, int pad, uint32_t button, int pressed);

// PS2 DualShock 2 button bitmasks (active-low on hardware; we use active-high here)
typedef enum {
    PS2_SELECT    = (1u <<  0),
    PS2_L3        = (1u <<  1),
    PS2_R3        = (1u <<  2),
    PS2_START     = (1u <<  3),
    PS2_UP        = (1u <<  4),
    PS2_RIGHT     = (1u <<  5),
    PS2_DOWN      = (1u <<  6),
    PS2_LEFT      = (1u <<  7),
    PS2_L2        = (1u <<  8),
    PS2_R2        = (1u <<  9),
    PS2_L1        = (1u << 10),
    PS2_R1        = (1u << 11),
    PS2_TRIANGLE  = (1u << 12),
    PS2_CIRCLE    = (1u << 13),
    PS2_CROSS     = (1u << 14),
    PS2_SQUARE    = (1u << 15),
} PS2Button;

// ── Save / Load state ─────────────────────────────────────────────────────────
// cascade_save_state: allocates a buffer via malloc and sets *out.
// Caller must free it with cascade_free_state_buffer().
// Returns the number of bytes written, or 0 on failure.
size_t cascade_save_state(PS2Handle h, uint8_t** out);
void   cascade_free_state_buffer(uint8_t* buf);
// Returns 1 on success.
int    cascade_load_state(PS2Handle h, const uint8_t* data, size_t size);

// ── Diagnostics ───────────────────────────────────────────────────────────────
uint32_t cascade_get_ee_pc(PS2Handle h);
uint32_t cascade_get_iop_pc(PS2Handle h);
uint64_t cascade_get_frame_count(PS2Handle h);
uint32_t cascade_get_ee_gpr(PS2Handle h, int reg);   // reg 0-31
uint32_t cascade_get_iop_gpr(PS2Handle h, int reg);  // reg 0-31

#ifdef __cplusplus
}
#endif
