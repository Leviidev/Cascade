#pragma once
#include "types.h"
#include <vector>
#include <functional>

// ── Pixel Format identifiers ──────────────────────────────────────────────────
enum PSM : u8 {
    PSMCT32  = 0x00,
    PSMCT24  = 0x01,
    PSMCT16  = 0x02,
    PSMCT16S = 0x0A,
    PSMT8    = 0x13,
    PSMT4    = 0x14,
    PSMT8H   = 0x1B,
    PSMT4HL  = 0x24,
    PSMT4HH  = 0x2C,
    PSMZ32   = 0x30,
    PSMZ24   = 0x31,
    PSMZ16   = 0x32,
    PSMZ16S  = 0x3A,
};

static constexpr int GS_VRAM_SIZE = 4 * 1024 * 1024;

struct GS {
    u8 vram[GS_VRAM_SIZE] = {};

    // ── Privileged registers ─────────────────────────────────────────────────
    u64 pmode   = 0;
    u64 smode1  = 0;
    u64 smode2  = 0;
    u64 dispfb[2] = {};
    u64 display[2] = {};
    u64 bgcolor = 0;
    u64 csr     = 0x1BAu;
    u64 imr     = 0xFF00u;

    // ── GS internal registers (written via GIF) ──────────────────────────────
    u64 reg_PRIM      = 0;
    u64 reg_RGBAQ     = 0x00000000'3F80'0000uLL; // RGBA=0,0,0,0 Q=1.0f
    u64 reg_ST        = 0;
    u64 reg_UV        = 0;
    u64 reg_XYZF2     = 0;
    u64 reg_XYZ2      = 0;
    u64 reg_TEX0[2]   = {};
    u64 reg_TEX1[2]   = {};
    u64 reg_CLAMP[2]  = {};
    u64 reg_FOG       = 0;
    u64 reg_TEXFLUSH  = 0;
    u64 reg_SCISSOR[2]= {0x07FF'07FFull, 0x07FF'07FFull};
    u64 reg_ALPHA[2]  = {};
    u64 reg_DIMX      = 0;
    u64 reg_DTHE      = 0;
    u64 reg_COLCLAMP  = 0xFFFFFFFFull;
    u64 reg_TEST[2]   = {};
    u64 reg_PABE      = 0;
    u64 reg_FBA[2]    = {};
    u64 reg_FRAME[2]  = {};
    u64 reg_ZBUF[2]   = {};
    u64 reg_BITBLTBUF = 0;
    u64 reg_TRXPOS    = 0;
    u64 reg_TRXREG    = 0;
    u64 reg_TRXDIR    = 0;
    u64 reg_SIGNAL    = 0;
    u64 reg_FINISH    = 0;
    u64 reg_LABEL     = 0;

    // ── Primitive vertex queue ───────────────────────────────────────────────
    struct Vertex {
        i32 x = 0, y = 0;   // 12.4 fixed-point screen coords
        u32 z = 0;
        u8  r = 0, g = 0, b = 0, a = 0;
        f32 s = 0.f, t = 0.f, q = 1.f;
        u16 u = 0, v = 0;
        u8  fog = 0;
    };
    Vertex vtxQ[4] = {};
    int    vtxCount = 0;

    // Current vertex attributes (built up from RGBAQ, ST, UV, FOG writes)
    Vertex cur;

    // ── Image transfer state ──────────────────────────────────────────────────
    struct TrxState {
        u32 dstBP = 0, dstBW = 0;
        PSM dstPSM = PSMCT32;
        i32 dstX = 0, dstY = 0;
        u32 rrW = 0, rrH = 0;
        u32 wordsLeft = 0;
        u8  partial[8] = {};
        int partialBytes = 0;
    } trx;

    // ── Output ───────────────────────────────────────────────────────────────
    int outputWidth  = 640;
    int outputHeight = 448;

    // Framebuffer scratch (RGBA8) — filled by getFrameBuffer()
    std::vector<u8> fbScratch;

    // ── XGKICK callback (VU1 → GS) ───────────────────────────────────────────
    // Called by VU1 when XGKICK fires
    std::function<void(const u8*, u32)> onXGKICK;

    // ── Public API ────────────────────────────────────────────────────────────
    GS() { fbScratch.resize(640 * 448 * 4, 0); }

    u32  readPriv (u32 offset);
    void writePriv(u32 offset, u32 value);

    // Process a complete GIF packet (raw qwords array, length in qwords)
    void processGIF(const u64* qwords, int nQwords);
    void writeGSReg(int reg, u64 value);
    void writeGSRegPacked(int reg, u64 lo, u64 hi);

    // Called at end of frame to build RGBA framebuffer
    void getFrameBuffer(u8* out_rgba, int* out_w, int* out_h);

    // Image transfer data feed (from DMAC/GIF IMAGE mode)
    void feedImageData(const u8* data, u32 bytes);

private:
    // Rasterizer helpers
    void submitVertex(bool kick);
    void rasterize();
    void drawPoint();
    void drawLine();
    void drawLineStrip();
    void drawTriangle();
    void drawTriangleStrip();
    void drawTriangleFan();
    void drawSprite();

    void fillTriangle(const Vertex& v0, const Vertex& v1, const Vertex& v2);
    void bresenhamLine(const Vertex& v0, const Vertex& v1);

    // Pixel operations
    void plotPixel(i32 x, i32 y, u8 r, u8 g, u8 b, u8 a, u32 z, int ctx);
    u32  readPixel32 (u32 base, u32 bw, i32 x, i32 y) const;
    void writePixel32(u32 base, u32 bw, i32 x, i32 y, u32 rgba32);
    u32  readPixel16 (u32 base, u32 bw, i32 x, i32 y) const;
    void writePixel16(u32 base, u32 bw, i32 x, i32 y, u32 rgba16);
    u32  readZ32(u32 base, u32 bw, i32 x, i32 y) const;
    void writeZ32(u32 base, u32 bw, i32 x, i32 y, u32 z);

    // Texture sampling
    u32 sampleTexture(f32 s, f32 t, int ctx) const;
    u32 sampleTexture16(u32 tp, u32 tw, u32 th, int px, int py) const;
    u32 sampleTexture8 (u32 tp, u32 tw, u32 th, int px, int py, u32 cbp, int cpsm) const;

    // Alpha blend
    u32 alphaBlend(u32 src, u32 dst, u32 fix, int ctx) const;

    // Transfer helpers
    void flushTrxPixel(i32 x, i32 y, u32 rgba32);
    i32  trxCurX = 0, trxCurY = 0;
};
