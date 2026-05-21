#include "ps2.h"
#include <cstring>
#include <vector>

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

    // EE → Bus, VU0, VU1
    ee.bus  = &bus;
    ee.vu0  = &vu0;
    ee.vu1  = &vu1;

    // IOP → SPU2
    iop.spu2 = &spu2;

    // DMAC → Bus, GS, INTC, SPU2
    dmac.bus  = &bus;
    dmac.gs   = &gs;
    dmac.intc = &intc;
    dmac.spu2 = &spu2;
    dmac.iop  = &iop;

    // Timer → INTC
    timer.intc = &intc;

    // VU1 XGKICK → GS GIF path
    vu1.onXGKICK = [this](const u8* data, u32 bytes) {
        // Parse GIF packets from VU1 data memory
        int nQwords = (int)(bytes / 16);
        if (nQwords < 2) return;
        std::vector<u64> qwBuf((size_t)nQwords * 2);
        for (int i = 0; i < nQwords * 2; i++) {
            qwBuf[(size_t)i] = read_le<u64>(data + i * 8);
        }
        gs.processGIF(qwBuf.data(), (int)qwBuf.size());
    };
}

// ── Reset ─────────────────────────────────────────────────────────────────────

void PS2::reset() {
    ee.reset();
    iop.reset();
    gs = GS();  // reinit GS state
    vu0.reset(); vu1.reset();
    spu2.reset();
    dmac.reset();
    intc = INTC{};
    timer.reset();
    frameCount = 0;
    wireComponents(); // re-wire after re-inits
}

// ── BIOS load ─────────────────────────────────────────────────────────────────

bool PS2::loadBIOS(const u8* data, size_t size) {
    if (!data || size == 0) return false;
    if (!bus.loadBIOS(data, size)) return false;

    // Also mirror BIOS into IOP RAM at offset 0 (so IOP can boot from 0xBFC00000)
    size_t copySize = std::min(size, (size_t)IOP_RAM_SIZE);
    if (iop.ram) memcpy(iop.ram, data, copySize);

    biosLoaded = true;
    return true;
}

// ── Disc load ─────────────────────────────────────────────────────────────────

bool PS2::loadDisc(const std::string& path) {
    (void)path;
    // CDVD implementation is in Swift; this signals success
    return true;
}

void PS2::ejectDisc() {
    // CDVD handled in Swift
}

// ── Frame execution ───────────────────────────────────────────────────────────

static constexpr u64 EE_HZ  = 294912000ULL; // 294.912 MHz
static constexpr u64 IOP_HZ =  36864000ULL; //  36.864 MHz

void PS2::runFrame(double fps) {
    if (!biosLoaded) return;

    double period = 1.0 / fps;
    u64 eeCycles  = (u64)(EE_HZ  * period);
    u64 iopCycles = (u64)(IOP_HZ * period);

    executeEEFrame((int)eeCycles);
    executeIOPFrame((int)iopCycles);

    signalVBlank();
    frameCount++;
}

void PS2::executeEEFrame(int cycles) {
    // Run EE in slices, interleaving DMAC steps
    static constexpr int SLICE = 4096;
    while (cycles > 0) {
        int run = std::min(cycles, SLICE);
        ee.step(run);
        timer.tick((u64)run);
        dmac.step();
        cycles -= run;
    }
}

void PS2::executeIOPFrame(int cycles) {
    static constexpr int SLICE = 512;
    while (cycles > 0) {
        int run = std::min(cycles, SLICE);
        iop.step(run);
        cycles -= run;
    }
}

void PS2::signalVBlank() {
    // Assert VBlank-start IRQ (INTC bit 2 = VBlankStart, bit 3 = VBlankEnd)
    intc.assertIRQ(2);
    // Raise IP bit in EE COP0 Cause register (IP bit 2 = hardware interrupt 0)
    ee.cop0[COP0_Cause] |= (1u << 10); // IP2
    // VBlank end
    intc.assertIRQ(3);
}

// ── Save / Load state (simplified) ───────────────────────────────────────────

std::vector<u8> PS2::saveState() const {
    // Minimal state: EE registers + RAM header
    std::vector<u8> out;
    // EE PC and GPRs
    out.resize(sizeof(ee.pc) + sizeof(ee.gpr) + sizeof(ee.cop0));
    size_t off = 0;
    memcpy(out.data() + off, &ee.pc,   sizeof(ee.pc));   off += sizeof(ee.pc);
    memcpy(out.data() + off, &ee.gpr,  sizeof(ee.gpr));  off += sizeof(ee.gpr);
    memcpy(out.data() + off, &ee.cop0, sizeof(ee.cop0)); off += sizeof(ee.cop0);
    return out;
}

bool PS2::loadState(const u8* data, size_t size) {
    size_t needed = sizeof(ee.pc) + sizeof(ee.gpr) + sizeof(ee.cop0);
    if (size < needed || !data) return false;
    size_t off = 0;
    memcpy(&ee.pc,   data + off, sizeof(ee.pc));   off += sizeof(ee.pc);
    memcpy(&ee.gpr,  data + off, sizeof(ee.gpr));  off += sizeof(ee.gpr);
    memcpy(&ee.cop0, data + off, sizeof(ee.cop0)); off += sizeof(ee.cop0);
    return true;
}
