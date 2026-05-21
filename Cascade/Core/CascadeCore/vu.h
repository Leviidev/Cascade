#pragma once
#include "types.h"
#include <functional>

struct GS;

// ── VU0 / VU1 Vector Unit ─────────────────────────────────────────────────────
// VU0: 4 KB data/micro memory — macro mode (COP2) and micro mode
// VU1: 16 KB data/micro memory — vertex transform, XGKICK → GS
struct VU {
    int  index = 0;

    // ── Registers ────────────────────────────────────────────────────────────
    vec4f vf[32];          // VF[0] = const {0,0,0,1}
    u16   vi[16] = {};     // VI[0] = const 0
    vec4f acc    = {};
    f32   q = 0.f;         // Quotient (DIV/SQRT/RSQRT)
    f32   p = 0.f;         // EFU result (ESIN/ECOS/EEXP/ESUM/ESQRT/ERSQRT/ERCPR/ELENG/ELENGTHR/ESADD/EATAN)
    f32   I = 0.f;         // I register (holds immediate scalar)
    u32   r = 0x00411117u; // PRNG state (RINIT/RGET/RXOR/RNEXT)

    // Status / MAC / Clip flag pipeline (last 3 entries)
    u32 statusFlag = 0;
    u32 macFlag    = 0;
    u32 clipFlag   = 0;

    // ── Memory ───────────────────────────────────────────────────────────────
    static constexpr int VU0_MEM  = 4  * 1024;
    static constexpr int VU1_MEM  = 16 * 1024;
    u8*  dataMem  = nullptr;
    u8*  microMem = nullptr;
    int  dataSize = 0, microSize = 0;

    // ── Execution state ───────────────────────────────────────────────────────
    u32  microPC  = 0;
    bool running  = false;
    u64  cycles   = 0;

    // ── XGKICK (VU1 only) ─────────────────────────────────────────────────────
    std::function<void(const u8*, u32)> onXGKICK;

    // ── Init / reset ─────────────────────────────────────────────────────────
    VU(int idx);
    ~VU();
    void reset();

    // ── Run micro-program ─────────────────────────────────────────────────────
    void run(int maxCycles = 4096);

    // ── Data memory access ────────────────────────────────────────────────────
    vec4f readDataQ  (u16 qwAddr) const;
    void  writeDataQ (u16 qwAddr, const vec4f& v);
    u32   readData32 (u32 byteOff) const;
    void  writeData32(u32 byteOff, u32 v);
    void  writeData128(u32 byteOff, const vec4f& v);

    // ── Micro memory access ───────────────────────────────────────────────────
    u64  readMicro64 (u32 qwIdx) const;
    void writeMicro  (u32 byteOff, const u8* src, u32 len);

    // ── Getters / setters with hardwired registers ────────────────────────────
    vec4f getVF(int i) const { return i == 0 ? vec4f{0,0,0,1} : vf[i & 31]; }
    void  setVF(int i, const vec4f& v) { if (i) vf[i & 31] = v; }
    u16   getVI(int i) const { return i == 0 ? 0 : vi[i & 15]; }
    void  setVI(int i, u16 v) { if (i) vi[i & 15] = v; }

    // ── Dest mask helpers ─────────────────────────────────────────────────────
    static vec4f applyDest(int dest, const vec4f& old_, const vec4f& new_) {
        return {
            (dest & 8) ? new_.x : old_.x,
            (dest & 4) ? new_.y : old_.y,
            (dest & 2) ? new_.z : old_.z,
            (dest & 1) ? new_.w : old_.w
        };
    }
    static vec4f broadcast(const vec4f& v, int bc) {
        f32 s = v[bc & 3];
        return {s, s, s, s};
    }

private:
    void executeUpper(u32 raw);
    void executeLower(u32 raw);
    void executeUpperSpecial(u32 raw);

    void updateMAC(vec4f& result);
    void rnextStep();
};
