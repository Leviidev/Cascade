#include "gs.h"
#include <cstring>
#include <algorithm>
#include <cmath>

// ── Privileged register access ────────────────────────────────────────────────

u32 GS::readPriv(u32 offset) {
    switch (offset >> 4) {
    case 0xA: return (u32)(csr & 0xFFFF'FFFFu);
    case 0xB: return (u32)(imr & 0xFFFF'FFFFu);
    default:  return 0u;
    }
}

void GS::writePriv(u32 offset, u32 value) {
    switch (offset >> 4) {
    case 0x0: { int sh=((offset&4)?32:0); pmode=(pmode&~(0xFFFF'FFFFuLL<<sh))|((u64)value<<sh); break; }
    case 0xA: csr = (u64)value; break;
    case 0xB: imr = (u64)value; break;
    default:  break;
    }
}

// ── GIF packet processing ─────────────────────────────────────────────────────

void GS::processGIF(const u64* qwords, int nQwords) {
    int off = 0;
    while (off < nQwords) {
        if (off + 1 >= nQwords) break;
        u64 tag = qwords[off++];
        u64 regsField = qwords[off++];

        int nloop = (int)(tag & 0x7FFF);
        bool eop  = (tag >> 15) & 1;
        bool pre  = (tag >> 46) & 1;
        u64 prim  = (tag >> 47) & 0x7FF;
        int flg   = (int)((tag >> 58) & 3);
        int nreg  = (int)((tag >> 60) & 0xF);
        if (nreg == 0) nreg = 16;

        if (pre) writeGSReg(0x00, prim); // PRIM

        int regs[16];
        for (int i = 0; i < nreg; i++)
            regs[i] = (int)((regsField >> (i * 4)) & 0xF);

        for (int loop = 0; loop < nloop && off < nQwords; loop++) {
            switch (flg) {
            case 0: // PACKED: each reg gets 2 qwords (128-bit)
                for (int r = 0; r < nreg && off + 1 < nQwords; r++) {
                    u64 lo2 = qwords[off++];
                    u64 hi2 = qwords[off++];
                    writeGSRegPacked(regs[r], lo2, hi2);
                }
                break;
            case 1: // REGLIST: each reg gets 1 qword (64-bit)
                for (int r = 0; r < nreg && off < nQwords; r++)
                    writeGSReg(regs[r], qwords[off++]);
                break;
            case 2: // IMAGE: raw pixel data → transfer
                for (int r = 0; r < nreg && off + 1 < nQwords; r++) {
                    u64 w0 = qwords[off++];
                    u64 w1 = qwords[off++];
                    u8 buf[16];
                    memcpy(buf,   &w0, 8);
                    memcpy(buf+8, &w1, 8);
                    feedImageData(buf, 16);
                }
                break;
            default:
                off += nreg * 2;
                break;
            }
        }
        if (eop) break;
    }
}

// ── GS Register write (REGLIST / direct) ──────────────────────────────────────

void GS::writeGSReg(int reg, u64 value) {
    switch (reg) {
    case 0x00: reg_PRIM = value & 0x7FF; break;
    case 0x01: reg_RGBAQ = value; break;
    case 0x02: reg_ST    = value; break;
    case 0x03: reg_UV    = value; break;
    case 0x05: case 0x0D: { // XYZ2 / XYZ3
        cur.x = (i32)(value & 0xFFFF);
        cur.y = (i32)((value >> 16) & 0xFFFF);
        cur.z = (u32)((value >> 32) & 0xFFFF'FFFFu);
        submitVertex(reg == 0x05);
        break;
    }
    case 0x06: reg_TEX0[0] = value; break;
    case 0x07: reg_TEX0[1] = value; break;
    case 0x08: reg_CLAMP[0] = value; break;
    case 0x09: reg_CLAMP[1] = value; break;
    case 0x18: reg_ALPHA[0] = value; break;
    case 0x19: reg_ALPHA[1] = value; break;
    case 0x40: reg_SCISSOR[0] = value; break;
    case 0x41: reg_SCISSOR[1] = value; break;
    case 0x4C: reg_FRAME[0]   = value; break;
    case 0x4D: reg_FRAME[1]   = value; break;
    case 0x4E: reg_ZBUF[0]    = value; break;
    case 0x4F: reg_ZBUF[1]    = value; break;
    case 0x50: reg_BITBLTBUF  = value; break;
    case 0x51: reg_TRXPOS     = value; break;
    case 0x52: {
        reg_TRXREG = value;
        u32 w = (u32)(value & 0xFFF) + 1;
        u32 h = (u32)((value >> 32) & 0xFFF) + 1;
        trx.rrW = w; trx.rrH = h;
        trx.wordsLeft = w * h;
        trx.dstBP  = (u32)((reg_BITBLTBUF >> 32) & 0x3FFF) << 6;
        trx.dstBW  = (u32)((reg_BITBLTBUF >> 48) & 0x3F) * 64;
        trx.dstPSM = (PSM)((reg_BITBLTBUF >> 56) & 0x3F);
        trx.dstX   = (i32)(reg_TRXPOS & 0x7FF);
        trx.dstY   = (i32)((reg_TRXPOS >> 16) & 0x7FF);
        trxCurX = trx.dstX; trxCurY = trx.dstY;
        trx.partialBytes = 0;
        break;
    }
    case 0x53: reg_TRXDIR = value; break;
    case 0x54: { u8 b[8]; memcpy(b, &value, 8); feedImageData(b, 8); break; }
    case 0x60: reg_SIGNAL  = value; break;
    case 0x61: reg_FINISH  = value; break;
    case 0x62: reg_LABEL   = value; break;
    default: break;
    }
}

// ── GS Register write (PACKED — 128-bit) ─────────────────────────────────────

void GS::writeGSRegPacked(int reg, u64 lo, u64 hi) {
    switch (reg) {
    case 0x00: reg_PRIM = lo & 0x7FF; break;
    case 0x01: { // RGBAQ
        cur.r = (u8)(lo & 0xFF);
        cur.g = (u8)((lo >> 8) & 0xFF);
        cur.b = (u8)((lo >> 16) & 0xFF);
        cur.a = (u8)((lo >> 24) & 0xFF);
        u32 qi; u32 qf = (u32)(hi & 0xFFFF'FFFFu);
        memcpy(&qi, &qf, 4);
        (void)qi;
        break;
    }
    case 0x02: { // ST
        u32 sf = (u32)(lo & 0xFFFF'FFFFu);
        u32 tf = (u32)((lo >> 32) & 0xFFFF'FFFFu);
        memcpy(&cur.s, &sf, 4);
        memcpy(&cur.t, &tf, 4);
        break;
    }
    case 0x03: { // UV
        cur.u = (u16)(lo & 0x3FFF);
        cur.v = (u16)((lo >> 16) & 0x3FFF);
        break;
    }
    case 0x04: case 0x0C: { // XYZF2 / XYZF3
        cur.x = (i32)(lo & 0xFFFF);
        cur.y = (i32)((lo >> 16) & 0xFFFF);
        cur.z = (u32)((lo >> 32) & 0x00FF'FFFFu);
        cur.fog = (u8)((hi >> 36) & 0xFF);
        submitVertex(reg == 0x04);
        break;
    }
    case 0x05: case 0x0D: { // XYZ2 / XYZ3
        cur.x = (i32)(lo & 0xFFFF);
        cur.y = (i32)((lo >> 16) & 0xFFFF);
        cur.z = (u32)((lo >> 32) & 0xFFFF'FFFFu);
        submitVertex(reg == 0x05);
        break;
    }
    case 0x06: reg_TEX0[0] = lo; break;
    case 0x07: reg_TEX0[1] = lo; break;
    case 0x08: reg_CLAMP[0] = lo; break;
    case 0x09: reg_CLAMP[1] = lo; break;
    case 0x0A: cur.fog = (u8)(lo & 0xFF); break;
    case 0x0E: writeGSReg((int)(lo & 0xFF), hi); break; // A+D
    case 0x0F: break; // NOP
    default: break;
    }
}

// ── Vertex submission & rasterize trigger ─────────────────────────────────────

void GS::submitVertex(bool kick) {
    // Copy current attribute state into vertex queue
    // Apply RGBAQ from reg
    Vertex v = cur;
    v.r = (u8)(reg_RGBAQ & 0xFF);
    v.g = (u8)((reg_RGBAQ >> 8) & 0xFF);
    v.b = (u8)((reg_RGBAQ >> 16) & 0xFF);
    v.a = (u8)((reg_RGBAQ >> 24) & 0xFF);
    // Keep XYZ and fog from cur (set by XYZF2/XYZ2)
    v.x   = cur.x; v.y = cur.y; v.z = cur.z; v.fog = cur.fog;

    if (vtxCount < 4) vtxQ[vtxCount++] = v;

    if (!kick) return;
    rasterize();
}

void GS::rasterize() {
    int primType = (int)(reg_PRIM & 7);
    switch (primType) {
    case 0: drawPoint();        break;
    case 1: drawLine();         break;
    case 2: drawLineStrip();    break;
    case 3: drawTriangle();     break;
    case 4: drawTriangleStrip();break;
    case 5: drawTriangleFan();  break;
    case 6: drawSprite();       break;
    default: break;
    }
}

// ── Primitive drawing ─────────────────────────────────────────────────────────

static inline i32 fixedToScreen(i32 fp) { return fp >> 4; } // 12.4 → integer pixel

void GS::drawPoint() {
    if (vtxCount < 1) return;
    const Vertex& v = vtxQ[0];
    plotPixel(fixedToScreen(v.x), fixedToScreen(v.y), v.r, v.g, v.b, v.a, v.z, 0);
    vtxCount = 0;
}

void GS::drawLine() {
    if (vtxCount < 2) return;
    bresenhamLine(vtxQ[0], vtxQ[1]);
    vtxCount = 0;
}

void GS::drawLineStrip() {
    if (vtxCount < 2) return;
    bresenhamLine(vtxQ[vtxCount-2], vtxQ[vtxCount-1]);
    if (vtxCount >= 2) vtxQ[0] = vtxQ[vtxCount-1], vtxCount = 1;
}

void GS::drawTriangle() {
    if (vtxCount < 3) return;
    fillTriangle(vtxQ[0], vtxQ[1], vtxQ[2]);
    vtxCount = 0;
}

void GS::drawTriangleStrip() {
    if (vtxCount < 3) return;
    int i = vtxCount - 3;
    if ((vtxCount & 1) == 1)
        fillTriangle(vtxQ[i], vtxQ[i+1], vtxQ[i+2]);
    else
        fillTriangle(vtxQ[i+1], vtxQ[i], vtxQ[i+2]); // flip winding for even tris
    if (vtxCount > 3) { vtxQ[0]=vtxQ[vtxCount-2]; vtxQ[1]=vtxQ[vtxCount-1]; vtxCount=2; }
}

void GS::drawTriangleFan() {
    if (vtxCount < 3) return;
    fillTriangle(vtxQ[0], vtxQ[vtxCount-2], vtxQ[vtxCount-1]);
    Vertex keep0 = vtxQ[0], keepLast = vtxQ[vtxCount-1];
    vtxQ[0] = keep0; vtxQ[1] = keepLast; vtxCount = 2;
}

void GS::drawSprite() {
    if (vtxCount < 2) return;
    const Vertex& v0 = vtxQ[0];
    const Vertex& v1 = vtxQ[1];
    i32 x0 = fixedToScreen(std::min(v0.x, v1.x));
    i32 y0 = fixedToScreen(std::min(v0.y, v1.y));
    i32 x1 = fixedToScreen(std::max(v0.x, v1.x));
    i32 y1 = fixedToScreen(std::max(v0.y, v1.y));
    for (i32 y = y0; y < y1; y++)
        for (i32 x = x0; x < x1; x++)
            plotPixel(x, y, v0.r, v0.g, v0.b, v0.a, v0.z, 0);
    vtxCount = 0;
}

// ── Triangle rasterizer ───────────────────────────────────────────────────────

void GS::fillTriangle(const Vertex& va, const Vertex& vb, const Vertex& vc) {
    Vertex a = va, b = vb, c = vc;
    // Sort by Y (12.4 fixed point)
    if (a.y > b.y) std::swap(a, b);
    if (a.y > c.y) std::swap(a, c);
    if (b.y > c.y) std::swap(b, c);

    i32 yA = fixedToScreen(a.y), yB = fixedToScreen(b.y), yC = fixedToScreen(c.y);
    f32 totalH = (f32)(c.y - a.y);
    if (totalH <= 0.f) return;

    for (i32 y = yA; y <= yC; y++) {
        bool lowerHalf = (y >= yB);
        f32 fy = (f32)(y * 16 - a.y);
        f32 segH = lowerHalf ? (f32)(c.y - b.y) : (f32)(b.y - a.y);
        if (segH <= 0.f) continue;

        f32 alpha = fy / totalH;
        f32 beta  = lowerHalf ? (f32)(y * 16 - b.y) / segH : fy / segH;

        // Left edge (A→C always), right edge (A→B or B→C)
        f32 xL = a.x + (c.x - a.x) * alpha;
        f32 xR = lowerHalf
            ? (f32)b.x + (c.x - b.x) * beta
            : (f32)a.x + (b.x - a.x) * beta;
        if (xL > xR) std::swap(xL, xR);

        // Interpolate color
        u8 r = (u8)((f32)a.r + ((f32)c.r - a.r) * alpha);
        u8 g = (u8)((f32)a.g + ((f32)c.g - a.g) * alpha);
        u8 bv= (u8)((f32)a.b + ((f32)c.b - a.b) * alpha);
        u8 av= (u8)((f32)a.a + ((f32)c.a - a.a) * alpha);
        u32 z = a.z + (u32)(((f32)c.z - (f32)a.z) * alpha);

        i32 x0 = (i32)(xL / 16.f), x1 = (i32)(xR / 16.f);
        for (i32 x = x0; x <= x1; x++)
            plotPixel(x, y, r, g, bv, av, z, 0);
    }
}

// ── Bresenham line ─────────────────────────────────────────────────────────────

void GS::bresenhamLine(const Vertex& v0, const Vertex& v1) {
    i32 x0=fixedToScreen(v0.x), y0=fixedToScreen(v0.y);
    i32 x1=fixedToScreen(v1.x), y1=fixedToScreen(v1.y);
    int dx=std::abs(x1-x0), dy=std::abs(y1-y0);
    int sx=x0<x1?1:-1, sy=y0<y1?1:-1;
    int err=dx-dy;
    while (true) {
        plotPixel(x0, y0, v0.r, v0.g, v0.b, v0.a, v0.z, 0);
        if (x0==x1 && y0==y1) break;
        int e2=2*err;
        if (e2>-dy){err-=dy; x0+=sx;}
        if (e2<dx) {err+=dx; y0+=sy;}
    }
}

// ── Pixel operations ──────────────────────────────────────────────────────────

void GS::plotPixel(i32 x, i32 y, u8 r, u8 g, u8 b, u8 a, u32 z, int ctx) {
    // Scissor test
    u32 scis = reg_SCISSOR[ctx & 1];
    i32 scx0 = (i32)(scis & 0x7FF);
    i32 scx1 = (i32)((scis >> 16) & 0x7FF);
    i32 scy0 = (i32)((scis >> 32) & 0x7FF);
    i32 scy1 = (i32)((scis >> 48) & 0x7FF);
    if (x < scx0 || x > scx1 || y < scy0 || y > scy1) return;
    if (x < 0 || y < 0 || x >= outputWidth || y >= outputHeight) return;

    // Frame buffer info
    u64 frame = reg_FRAME[ctx & 1];
    u32 fbp   = (u32)((frame & 0x1FF) << 11); // base pointer in words × 64
    u32 fbw   = (u32)((frame >> 16) & 0x3F) * 64; // width in pixels
    if (fbw == 0) fbw = (u32)outputWidth;

    // Z buffer info & depth test
    u64 zbuf = reg_ZBUF[ctx & 1];
    u64 test  = reg_TEST[ctx & 1];
    bool zTest = (test >> 4) & 1;
    int  zFunc  = (int)((test >> 5) & 7);
    if (zTest) {
        u32 zbp = (u32)((zbuf & 0x1FF) << 11);
        u32 zbw = fbw;
        u32 oldZ = readZ32(zbp, zbw, x, y);
        bool pass = false;
        switch (zFunc) {
        case 1: pass = false;       break; // NEVER
        case 2: pass = z < oldZ;    break; // LESS
        case 3: pass = z == oldZ;   break; // EQUAL
        case 4: pass = z <= oldZ;   break; // LEQUAL
        case 5: pass = z > oldZ;    break; // GREATER
        case 6: pass = z != oldZ;   break; // NOTEQUAL
        case 7: pass = z >= oldZ;   break; // GEQUAL
        default: pass = true; break;       // ALWAYS
        }
        if (!pass) return;
        // Write Z
        bool zWrite = !((zbuf >> 32) & 1);
        if (zWrite) writeZ32(zbp, zbw, x, y, z);
    }

    // Alpha blending
    u64 alphaReg = reg_ALPHA[ctx & 1];
    bool abe = (reg_PRIM >> 6) & 1;
    u32 srcColor = ((u32)r) | ((u32)g<<8) | ((u32)b<<16) | ((u32)a<<24);
    if (abe) {
        u32 dstColor = readPixel32(fbp, fbw, x, y);
        u32 fix = (u32)((alphaReg >> 32) & 0xFF);
        srcColor = alphaBlend(srcColor, dstColor, fix, ctx);
    }

    writePixel32(fbp, fbw, x, y, srcColor);
}

// ── VRAM pixel format access ──────────────────────────────────────────────────

u32 GS::readPixel32(u32 base, u32 bw, i32 x, i32 y) const {
    if (bw == 0) bw = 640;
    u32 off = base + ((u32)y * bw + (u32)x) * 4;
    if (off + 3 >= (u32)GS_VRAM_SIZE) return 0;
    return read_le<u32>(vram + off);
}

void GS::writePixel32(u32 base, u32 bw, i32 x, i32 y, u32 rgba32) {
    if (bw == 0) bw = 640;
    u32 off = base + ((u32)y * bw + (u32)x) * 4;
    if (off + 3 >= (u32)GS_VRAM_SIZE) return;
    write_le<u32>(vram + off, rgba32);
}

u32 GS::readZ32(u32 base, u32 bw, i32 x, i32 y) const {
    if (bw == 0) bw = 640;
    u32 off = base + ((u32)y * bw + (u32)x) * 4;
    if (off + 3 >= (u32)GS_VRAM_SIZE) return 0xFFFF'FFFFu;
    return read_le<u32>(vram + off);
}

void GS::writeZ32(u32 base, u32 bw, i32 x, i32 y, u32 z) {
    if (bw == 0) bw = 640;
    u32 off = base + ((u32)y * bw + (u32)x) * 4;
    if (off + 3 >= (u32)GS_VRAM_SIZE) return;
    write_le<u32>(vram + off, z);
}

// ── Alpha blending ────────────────────────────────────────────────────────────
// ALPHA register: A[1:0] B[3:2] C[5:4] D[7:6] FIX[31:24]
// output = (A - B) * C >> 7 + D
// A,B,D selectors: 0=Cs, 1=Cd, 2=0
// C selector:      0=As, 1=Ad, 2=FIX

u32 GS::alphaBlend(u32 src, u32 dst, u32 fix, int ctx) const {
    u64 ar = reg_ALPHA[ctx & 1];
    int A = (int)(ar & 3), B = (int)((ar>>2) & 3), C = (int)((ar>>4) & 3), D = (int)((ar>>6) & 3);

    auto getC = [&](int sel, u32 s, u32 d) -> u32 {
        switch (sel) {
        case 0: return s;
        case 1: return d;
        default: return 0;
        }
    };

    auto getAlpha = [&]() -> u32 {
        switch (C) {
        case 0: return (src >> 24) & 0xFF;
        case 1: return (dst >> 24) & 0xFF;
        default: return fix & 0xFF;
        }
    };

    u32 Cv = getAlpha();

    auto blend1 = [&](int comp) -> u32 {
        auto extract = [](u32 c, int sh) { return (i32)((c >> sh) & 0xFF); };
        i32 a_v = extract(getC(A, src, dst), comp);
        i32 b_v = extract(getC(B, src, dst), comp);
        i32 d_v = extract(getC(D, src, dst), comp);
        i32 r = ((a_v - b_v) * (i32)Cv >> 7) + d_v;
        return (u32)clampi(r, 0, 255);
    };

    return blend1(0) | (blend1(8) << 8) | (blend1(16) << 16) | (((src >> 24) & 0xFF) << 24);
}

// ── Image transfer (HWREG / DMAC IMAGE mode) ──────────────────────────────────

void GS::feedImageData(const u8* data, u32 bytes) {
    if (trx.wordsLeft == 0) return;

    u32 i = 0;
    // Flush any leftover partial bytes
    if (trx.partialBytes > 0) {
        while (i < bytes && trx.partialBytes < 4) {
            trx.partial[trx.partialBytes++] = data[i++];
        }
        if (trx.partialBytes == 4) {
            u32 pixel = read_le<u32>(trx.partial);
            flushTrxPixel(trxCurX, trxCurY, pixel);
            trxCurX++;
            if (trxCurX >= trx.dstX + (i32)trx.rrW) {
                trxCurX = trx.dstX;
                trxCurY++;
            }
            trx.wordsLeft--;
            trx.partialBytes = 0;
        }
    }

    while (i + 4 <= bytes && trx.wordsLeft > 0) {
        u32 pixel = read_le<u32>(data + i); i += 4;
        flushTrxPixel(trxCurX, trxCurY, pixel);
        trxCurX++;
        if (trxCurX >= trx.dstX + (i32)trx.rrW) {
            trxCurX = trx.dstX;
            trxCurY++;
        }
        trx.wordsLeft--;
    }

    while (i < bytes && trx.wordsLeft > 0) {
        trx.partial[trx.partialBytes++] = data[i++];
    }
}

void GS::flushTrxPixel(i32 x, i32 y, u32 rgba32) {
    u32 fbp = trx.dstBP;
    u32 fbw = trx.dstBW;
    if (fbw == 0) fbw = (u32)outputWidth;
    if (x < 0 || y < 0) return;
    switch (trx.dstPSM) {
    case PSMCT32:
    case PSMZ32:
        writePixel32(fbp, fbw, x, y, rgba32);
        break;
    case PSMCT16:
    case PSMZ16: {
        u16 r = (rgba32 >> 3) & 0x1F;
        u16 g = (rgba32 >> 11) & 0x1F;
        u16 b = (rgba32 >> 19) & 0x1F;
        u16 a = (rgba32 >> 31) & 1;
        u16 v16 = (u16)(r | (g<<5) | (b<<10) | (a<<15));
        u32 off = fbp + ((u32)y * fbw + (u32)x) * 2;
        if (off + 1 < (u32)GS_VRAM_SIZE) write_le<u16>(vram + off, v16);
        break;
    }
    case PSMT8: {
        u32 off = fbp + (u32)y * fbw + (u32)x;
        if (off < (u32)GS_VRAM_SIZE) vram[off] = (u8)rgba32;
        break;
    }
    default:
        writePixel32(fbp, fbw, x, y, rgba32);
        break;
    }
}

// ── Frame buffer readback ─────────────────────────────────────────────────────

void GS::getFrameBuffer(u8* out_rgba, int* out_w, int* out_h) {
    u64 dispfbReg = dispfb[0] ? dispfb[0] : dispfb[1];
    u32 fbp  = (u32)((dispfbReg & 0x1FF) << 11);
    u32 fbw  = (u32)((dispfbReg >> 9) & 0x3F) * 64;
    if (fbw == 0) fbw = (u32)outputWidth;
    int w = outputWidth, h = outputHeight;

    // Detect output size from DISPLAY register
    if (display[0]) {
        int dw = (int)(((display[0] >> 32) & 0xFFF) / 4) + 1;
        int dh = (int)((display[0] >> 44) & 0x7FF) + 1;
        if (dw > 0 && dh > 0) { w = dw; h = dh; outputWidth = w; outputHeight = h; }
    }
    *out_w = w; *out_h = h;

    // Ensure scratch is big enough
    if ((int)fbScratch.size() < w * h * 4)
        fbScratch.resize((size_t)w * h * 4, 0);

    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            u32 px = readPixel32(fbp, fbw, x, y);
            // RGBA swap: GS stores as RGBA internally (same as what we write)
            fbScratch[(y * w + x) * 4 + 0] = (u8)(px & 0xFF);
            fbScratch[(y * w + x) * 4 + 1] = (u8)((px >> 8) & 0xFF);
            fbScratch[(y * w + x) * 4 + 2] = (u8)((px >> 16) & 0xFF);
            fbScratch[(y * w + x) * 4 + 3] = 0xFF;
        }
    }

    if (out_rgba) memcpy(out_rgba, fbScratch.data(), (size_t)w * h * 4);
}
