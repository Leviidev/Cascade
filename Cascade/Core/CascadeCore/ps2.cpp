#include "ps2.h"
#include <cstring>
#include <vector>
#include <algorithm>

PS2::PS2() : vu0(0), vu1(1) {
    wireComponents();
    reset();
}

// ── Wire all inter-component pointers ──────────────────────────────────────────

void PS2::wireComponents() {
    // Bus → GS, DMAC, INTC, Timer, IOP
    bus.gs    = &gs;
    bus.dmac  = &dmac;
    bus.intc  = &intc;
    bus.timer = &timer;
    bus.iop   = &iop;
    bus.spu2  = &spu2;

    // EE → Bus, VU0, VU1
    ee.bus  = &bus;
    ee.vu0  = &vu0;
    ee.vu1  = &vu1;

    // IOP → SPU2
    iop.spu2 = &spu2;

    // DMAC → Bus, GS, INTC, SPU2, IOP
    dmac.bus  = &bus;
    dmac.gs   = &gs;
    dmac.intc = &intc;
    dmac.spu2 = &spu2;
    dmac.iop  = &iop;

    // Timer → INTC
    timer.intc = &intc;

    // VU1 XGKICK → GS GIF path
    vu1.onXGKICK = [this](const u8* data, u32 bytes) {
        int nQwords = (int)(bytes / 16);
        if (nQwords < 2) return;
        std::vector<u64> qwBuf((size_t)nQwords * 2);
        for (int i = 0; i < nQwords * 2; i++)
            qwBuf[(size_t)i] = read_le<u64>(data + i * 8);
        gs.processGIF(qwBuf.data(), (int)qwBuf.size());
    };

    // INTC → EE: when any unmasked IRQ fires, raise IP2 in EE COP0 Cause
    // (IP2 = bit 10 of Cause = INTC hardware interrupt line 0)
    intc.onPending = [this]() {
        ee.cop0[COP0_Cause] |= (1u << 10); // IP2
    };
}

// ── Reset ─────────────────────────────────────────────────────────────────────

void PS2::reset() {
    ee.reset();
    iop.reset();
    gs    = GS();
    vu0.reset(); vu1.reset();
    spu2.reset();
    dmac.reset();
    intc  = INTC{};
    timer.reset();
    frameCount = 0;
    wireComponents(); // re-wire after reinit (lambdas capture 'this')
}

// ── BIOS load ─────────────────────────────────────────────────────────────────

bool PS2::loadBIOS(const u8* data, size_t size) {
    if (!data || size == 0) return false;
    if (!bus.loadBIOS(data, size)) return false;
    // Mirror BIOS into IOP RAM at 0xBFC0'0000 offset so IOP can boot
    if (iop.ram) {
        size_t copySize = std::min(size, (size_t)IOP_RAM_SIZE);
        memcpy(iop.ram, data, copySize);
    }
    biosLoaded = true;
    return true;
}

// ── Disc load ─────────────────────────────────────────────────────────────────

bool PS2::loadDisc(const std::string& path) {
    (void)path;
    return true;
}

void PS2::ejectDisc() {}

// ── Helpers ───────────────────────────────────────────────────────────────────

// Keep EE COP0 Cause IP2 in sync with INTC pending state
void PS2::updateINTCPending() {
    if (intc.pending())
        ee.cop0[COP0_Cause] |= (1u << 10);
    else
        ee.cop0[COP0_Cause] &= ~(1u << 10);
}

// ── Frame execution ───────────────────────────────────────────────────────────
// EE: 294.912 MHz  IOP: 36.864 MHz  Ratio: 8:1
// We interleave them in fine slices so neither starves the other.

static constexpr u64 EE_HZ   = 294912000ULL;
static constexpr u64 IOP_HZ  =  36864000ULL;
// EE cycles per IOP cycle (exact ratio: 8)
static constexpr int EE_IOP_RATIO = 8;

// Slice size in EE cycles — small enough for responsive INTC delivery
static constexpr int EE_SLICE   = 512;
static constexpr int IOP_SLICE  = EE_SLICE / EE_IOP_RATIO; // 64

void PS2::runFrame(double fps) {
    if (!biosLoaded) return;

    if (fps <= 0.0 || fps > 120.0) fps = 60.0;
    double period     = 1.0 / fps;
    int    eeCycles   = (int)(EE_HZ  * period);
    int    iopCycles  = (int)(IOP_HZ * period);

    // VBlank-start fires at ~93.75% into the frame (after active display lines)
    int vblankStartAt = (int)(eeCycles * 0.9375);
    bool vblankStartFired = false;

    int eeRemain  = eeCycles;
    int iopRemain = iopCycles;

    while (eeRemain > 0 || iopRemain > 0) {
        // EE slice
        if (eeRemain > 0) {
            int run = std::min(eeRemain, EE_SLICE);
            executeEESlice(run);
            eeRemain -= run;

            // Check VBlank-start threshold
            if (!vblankStartFired && (eeCycles - eeRemain) >= vblankStartAt) {
                signalVBlankStart();
                vblankStartFired = true;
            }
        }
        // IOP slice (scaled to stay in sync)
        if (iopRemain > 0) {
            int run = std::min(iopRemain, IOP_SLICE);
            executeIOPSlice(run);
            iopRemain -= run;
        }
    }

    // VBlank-end at frame boundary
    signalVBlankEnd();
    frameCount++;
}

void PS2::executeEESlice(int cycles) {
    updateINTCPending();
    ee.step(cycles);
    timer.tick((u64)cycles);
    dmac.step();
    updateINTCPending();
}

void PS2::executeIOPSlice(int cycles) {
    iop.step(cycles);
}

// ── VBlank signalling ─────────────────────────────────────────────────────────
// INTC bit 2 = VBlank-start, bit 3 = VBlank-end
// EE COP0 Cause IP2 (bit 10) is the INTC line.

void PS2::signalVBlankStart() {
    intc.assertIRQ(2); // VBlankStart
    // GS CSR: set VSINT (bit 3) to signal the display is entering VBlank
    gs.csr |= (1uLL << 3);
}

void PS2::signalVBlankEnd() {
    intc.assertIRQ(3); // VBlankEnd
    gs.csr &= ~(1uLL << 3); // clear VSINT
}

// ── Save / Load state ─────────────────────────────────────────────────────────

struct StateHeader {
    u32 magic;    // 0x43535432 = 'CST2'
    u32 version;  // 1
    u32 eeSize;
    u32 iopSize;
    u32 ramSize;
    u32 spu2Size;
};

std::vector<u8> PS2::saveState() const {
    static constexpr u32 MAGIC   = 0x43535432u;
    static constexpr u32 VERSION = 1u;

    // EE state blob
    std::vector<u8> eeBlob;
    eeBlob.resize(sizeof(ee.gpr) + sizeof(ee.pc) + sizeof(ee.hi) + sizeof(ee.lo) +
                  sizeof(ee.hi1) + sizeof(ee.lo1) + sizeof(ee.sa) +
                  sizeof(ee.fpr) + sizeof(ee.fpAcc) + sizeof(ee.fcr31) +
                  sizeof(ee.cop0));
    size_t off = 0;
    auto appendEE = [&](const void* src, size_t n) {
        memcpy(eeBlob.data() + off, src, n); off += n;
    };
    appendEE(ee.gpr,   sizeof(ee.gpr));
    appendEE(&ee.pc,   sizeof(ee.pc));
    appendEE(&ee.hi,   sizeof(ee.hi));
    appendEE(&ee.lo,   sizeof(ee.lo));
    appendEE(&ee.hi1,  sizeof(ee.hi1));
    appendEE(&ee.lo1,  sizeof(ee.lo1));
    appendEE(&ee.sa,   sizeof(ee.sa));
    appendEE(ee.fpr,   sizeof(ee.fpr));
    appendEE(&ee.fpAcc,sizeof(ee.fpAcc));
    appendEE(&ee.fcr31,sizeof(ee.fcr31));
    appendEE(ee.cop0,  sizeof(ee.cop0));

    // IOP state blob
    std::vector<u8> iopBlob;
    iopBlob.resize(sizeof(iop.gpr) + sizeof(iop.pc) + sizeof(iop.hi) + sizeof(iop.lo) +
                   sizeof(iop.cop0_Status) + sizeof(iop.cop0_Cause) + sizeof(iop.cop0_EPC));
    size_t io = 0;
    auto appendIOP = [&](const void* src, size_t n) {
        memcpy(iopBlob.data() + io, src, n); io += n;
    };
    appendIOP(iop.gpr,           sizeof(iop.gpr));
    appendIOP(&iop.pc,           sizeof(iop.pc));
    appendIOP(&iop.hi,           sizeof(iop.hi));
    appendIOP(&iop.lo,           sizeof(iop.lo));
    appendIOP(&iop.cop0_Status,  sizeof(iop.cop0_Status));
    appendIOP(&iop.cop0_Cause,   sizeof(iop.cop0_Cause));
    appendIOP(&iop.cop0_EPC,     sizeof(iop.cop0_EPC));

    StateHeader hdr{};
    hdr.magic    = MAGIC;
    hdr.version  = VERSION;
    hdr.eeSize   = (u32)eeBlob.size();
    hdr.iopSize  = (u32)iopBlob.size();
    hdr.ramSize  = EE_RAM_SIZE;
    hdr.spu2Size = SPU2_SRAM_SIZE;

    size_t total = sizeof(hdr) + eeBlob.size() + iopBlob.size() +
                   EE_RAM_SIZE + IOP_RAM_SIZE + SPU2_SRAM_SIZE;
    std::vector<u8> out(total);
    size_t p = 0;
    auto append = [&](const void* src, size_t n) {
        memcpy(out.data() + p, src, n); p += n;
    };
    append(&hdr,          sizeof(hdr));
    append(eeBlob.data(), eeBlob.size());
    append(iopBlob.data(),iopBlob.size());
    append(bus.ram,       EE_RAM_SIZE);
    append(iop.ram,       IOP_RAM_SIZE);
    append(spu2.sram,     SPU2_SRAM_SIZE);
    return out;
}

bool PS2::loadState(const u8* data, size_t size) {
    if (!data || size < sizeof(StateHeader)) return false;

    StateHeader hdr{};
    memcpy(&hdr, data, sizeof(hdr));
    if (hdr.magic != 0x43535432u || hdr.version != 1u) return false;

    size_t needed = sizeof(hdr) + hdr.eeSize + hdr.iopSize +
                    EE_RAM_SIZE + IOP_RAM_SIZE + SPU2_SRAM_SIZE;
    if (size < needed) return false;

    const u8* p = data + sizeof(hdr);

    // EE
    size_t eo = 0;
    auto rdEE = [&](void* dst, size_t n) { memcpy(dst, p + eo, n); eo += n; };
    rdEE(ee.gpr,    sizeof(ee.gpr));
    rdEE(&ee.pc,    sizeof(ee.pc));
    rdEE(&ee.hi,    sizeof(ee.hi));
    rdEE(&ee.lo,    sizeof(ee.lo));
    rdEE(&ee.hi1,   sizeof(ee.hi1));
    rdEE(&ee.lo1,   sizeof(ee.lo1));
    rdEE(&ee.sa,    sizeof(ee.sa));
    rdEE(ee.fpr,    sizeof(ee.fpr));
    rdEE(&ee.fpAcc, sizeof(ee.fpAcc));
    rdEE(&ee.fcr31, sizeof(ee.fcr31));
    rdEE(ee.cop0,   sizeof(ee.cop0));
    p += hdr.eeSize;

    // IOP
    size_t io = 0;
    auto rdIOP = [&](void* dst, size_t n) { memcpy(dst, p + io, n); io += n; };
    rdIOP(iop.gpr,          sizeof(iop.gpr));
    rdIOP(&iop.pc,          sizeof(iop.pc));
    rdIOP(&iop.hi,          sizeof(iop.hi));
    rdIOP(&iop.lo,          sizeof(iop.lo));
    rdIOP(&iop.cop0_Status, sizeof(iop.cop0_Status));
    rdIOP(&iop.cop0_Cause,  sizeof(iop.cop0_Cause));
    rdIOP(&iop.cop0_EPC,    sizeof(iop.cop0_EPC));
    p += hdr.iopSize;

    memcpy(bus.ram,   p, EE_RAM_SIZE);   p += EE_RAM_SIZE;
    memcpy(iop.ram,   p, IOP_RAM_SIZE);  p += IOP_RAM_SIZE;
    memcpy(spu2.sram, p, SPU2_SRAM_SIZE);

    ee.inDelaySlot = false;
    ee.nextPC      = ee.pc + 4;
    iop.inDelaySlot = false;
    iop.nextPC      = iop.pc + 4;
    return true;
}
