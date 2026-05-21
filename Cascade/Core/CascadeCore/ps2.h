#pragma once
#include "types.h"
#include "bus.h"
#include "ee.h"
#include "iop.h"
#include "gs.h"
#include "vu.h"
#include "spu2.h"
#include "dmac.h"
#include "intc.h"
#include "timer.h"
#include <string>
#include <vector>

// ── PS2 system — top-level orchestrator ──────────────────────────────────────
struct PS2 {
    Bus      bus;
    EE       ee;
    IOP      iop;
    GS       gs;
    VU       vu0{0}, vu1{1};
    SPU2     spu2;
    DMAC     dmac;
    INTC     intc;
    EETimer  timer;

    bool biosLoaded = false;
    u64  frameCount = 0;

    // Gamepad state: 2 pads, 32-bit button bitmask each (1 = pressed)
    u32 padState[2] = {};

    PS2();
    ~PS2() = default;

    void reset();
    bool loadBIOS(const u8* data, size_t size);
    bool loadDisc(const std::string& path);
    void ejectDisc();

    // Run one video frame (fps = 50 or 60)
    void runFrame(double fps);

    // Framebuffer
    void getFrameBuffer(u8* out_rgba, int* out_w, int* out_h) {
        gs.getFrameBuffer(out_rgba, out_w, out_h);
    }

    // Audio
    int getAudio(i16* out, int maxPairs) {
        return spu2.getAudioSamples(out, maxPairs);
    }

    // Input
    void setButton(int pad, u32 btn, bool pressed) {
        if (pad < 0 || pad > 1) return;
        if (pressed) padState[pad] |=  btn;
        else         padState[pad] &= ~btn;
    }

    // Save / load state (very simplified)
    std::vector<u8> saveState() const;
    bool            loadState(const u8* data, size_t size);

private:
    void wireComponents();
    void signalVBlank();
    void executeEEFrame(int cycles);
    void executeIOPFrame(int cycles);
};
