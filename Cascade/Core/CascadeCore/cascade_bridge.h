#pragma once

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void* PS2Handle;

// ── Lifecycle ────────────────────────────────────────────────────────────────
PS2Handle cascade_create(void);
void      cascade_destroy(PS2Handle h);

// ── BIOS ──────────────────────────────────────────────────────────────────────
// Returns 1 on success, 0 on failure
int cascade_load_bios(PS2Handle h, const uint8_t* data, size_t size);

// ── Disc ──────────────────────────────────────────────────────────────────────
// path must be a valid filesystem path
int  cascade_load_disc(PS2Handle h, const char* path);
void cascade_eject_disc(PS2Handle h);

// ── Emulation control ────────────────────────────────────────────────────────
void cascade_reset(PS2Handle h);
// Run exactly one video frame. fps should be 50 (PAL) or 60 (NTSC).
void cascade_run_frame(PS2Handle h, double fps);

// ── Video output ─────────────────────────────────────────────────────────────
// Copies RGBA8 framebuffer into caller-provided buffer.
// Returns 0 if no frame ready, 1 if frame copied.
int cascade_get_framebuffer(PS2Handle h, uint8_t* out_rgba,
                            int* out_width, int* out_height);

// ── Audio output ─────────────────────────────────────────────────────────────
// Returns number of stereo sample-pairs (i16 L, i16 R) written.
int cascade_get_audio(PS2Handle h, int16_t* out, int max_pairs);

// ── Input ────────────────────────────────────────────────────────────────────
// pad:    0 or 1
// button: bitmask using PS2 button codes (see PadManager.swift)
// pressed: 1 = down, 0 = up
void cascade_set_button(PS2Handle h, int pad, uint32_t button, int pressed);

// ── Save / Load state ────────────────────────────────────────────────────────
// Save: writes state to *out (caller must free with cascade_free_state_buffer)
// Returns byte-count on success, 0 on failure.
size_t cascade_save_state(PS2Handle h, uint8_t** out);
void   cascade_free_state_buffer(uint8_t* buf);
// Load: returns 1 on success, 0 on failure.
int    cascade_load_state(PS2Handle h, const uint8_t* data, size_t size);

// ── Diagnostics ──────────────────────────────────────────────────────────────
uint32_t cascade_get_ee_pc(PS2Handle h);
uint32_t cascade_get_iop_pc(PS2Handle h);
uint64_t cascade_get_frame_count(PS2Handle h);

#ifdef __cplusplus
}
#endif
