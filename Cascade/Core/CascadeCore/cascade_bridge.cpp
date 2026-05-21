#include "cascade_bridge.h"
#include "ps2.h"
#include <cstdlib>
#include <cstring>

// ── Lifecycle ─────────────────────────────────────────────────────────────────

PS2Handle cascade_create(void) {
    PS2* sys = new PS2();
    return (PS2Handle)sys;
}

void cascade_destroy(PS2Handle h) {
    if (h) delete (PS2*)h;
}

// ── BIOS ──────────────────────────────────────────────────────────────────────

int cascade_load_bios(PS2Handle h, const uint8_t* data, size_t size) {
    if (!h || !data || size == 0) return 0;
    PS2* sys = (PS2*)h;
    return sys->loadBIOS(data, size) ? 1 : 0;
}

// ── Disc ──────────────────────────────────────────────────────────────────────

int cascade_load_disc(PS2Handle h, const char* path) {
    if (!h || !path) return 0;
    PS2* sys = (PS2*)h;
    return sys->loadDisc(path) ? 1 : 0;
}

void cascade_eject_disc(PS2Handle h) {
    if (!h) return;
    ((PS2*)h)->ejectDisc();
}

// ── Control ───────────────────────────────────────────────────────────────────

void cascade_reset(PS2Handle h) {
    if (!h) return;
    ((PS2*)h)->reset();
}

void cascade_run_frame(PS2Handle h, double fps) {
    if (!h) return;
    ((PS2*)h)->runFrame((fps > 0.0 && fps <= 120.0) ? fps : 60.0);
}

// ── Video ─────────────────────────────────────────────────────────────────────

int cascade_get_framebuffer(PS2Handle h, uint8_t* out_rgba,
                            int* out_width, int* out_height) {
    if (!h) return 0;
    PS2* sys = (PS2*)h;
    int w = 640, ht = 448;
    sys->getFrameBuffer(out_rgba, &w, &ht);
    if (out_width)  *out_width  = w;
    if (out_height) *out_height = ht;
    return 1;
}

// ── Audio ─────────────────────────────────────────────────────────────────────

int cascade_get_audio(PS2Handle h, int16_t* out, int max_pairs) {
    if (!h || !out || max_pairs <= 0) return 0;
    return ((PS2*)h)->getAudio(out, max_pairs);
}

// ── Input ─────────────────────────────────────────────────────────────────────

void cascade_set_button(PS2Handle h, int pad, uint32_t button, int pressed) {
    if (!h) return;
    ((PS2*)h)->setButton(pad, button, pressed != 0);
}

// ── Save / Load state ─────────────────────────────────────────────────────────

size_t cascade_save_state(PS2Handle h, uint8_t** out) {
    if (!h || !out) return 0;
    PS2* sys = (PS2*)h;
    auto v = sys->saveState();
    if (v.empty()) { *out = nullptr; return 0; }
    uint8_t* buf = (uint8_t*)malloc(v.size());
    if (!buf) { *out = nullptr; return 0; }
    memcpy(buf, v.data(), v.size());
    *out = buf;
    return v.size();
}

void cascade_free_state_buffer(uint8_t* buf) {
    free(buf);
}

int cascade_load_state(PS2Handle h, const uint8_t* data, size_t size) {
    if (!h || !data || size == 0) return 0;
    return ((PS2*)h)->loadState(data, size) ? 1 : 0;
}

// ── Diagnostics ───────────────────────────────────────────────────────────────

uint32_t cascade_get_ee_pc(PS2Handle h) {
    if (!h) return 0;
    return ((PS2*)h)->ee.pc;
}

uint32_t cascade_get_iop_pc(PS2Handle h) {
    if (!h) return 0;
    return ((PS2*)h)->iop.pc;
}

uint64_t cascade_get_frame_count(PS2Handle h) {
    if (!h) return 0;
    return ((PS2*)h)->frameCount;
}
