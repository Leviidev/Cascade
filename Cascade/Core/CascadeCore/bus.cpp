#include "bus.h"
#include "gs.h"
#include "dmac.h"
#include "intc.h"
#include "timer.h"
#include "iop.h"
#include <cstdlib>
#include <cstring>

Bus::Bus() {
    ram     = (u8*)calloc(EE_RAM_SIZE,  1);
    bios    = (u8*)calloc(BIOS_SIZE,    1);
    iopRam  = (u8*)calloc(IOP_RAM_SIZE, 1);
    scratch = (u8*)calloc(SCRATCH_SIZE, 1);
}

Bus::~Bus() {
    free(ram);
    free(bios);
    free(iopRam);
    free(scratch);
}

bool Bus::loadBIOS(const u8* data, size_t size) {
    if (!data || size == 0 || size > BIOS_SIZE) return false;
    memcpy(bios, data, size);
    return true;
}

// ── Read helpers ─────────────────────────────────────────────────────────────

u8 Bus::read8(u32 addr) {
    u32 p = toPhysical(addr);
    if (p < EE_RAM_SIZE)                         return ram[p];
    if (p >= 0x1FC0'0000u && p < 0x2000'0000u)  return bios[p - 0x1FC0'0000u];
    if (p >= 0x1C00'0000u && p < 0x1C20'0000u)  return iopRam[p - 0x1C00'0000u];
    if (p >= 0x7000'0000u && p < 0x7000'4000u)  return scratch[p - 0x7000'0000u];
    if (p >= 0x1000'0000u && p < 0x1001'0000u)  return (u8)(readIO32(p - 0x1000'0000u) >> ((p & 3) * 8));
    return 0xFFu;
}

u16 Bus::read16(u32 addr) {
    u32 p = toPhysical(addr);
    if (p + 1 < EE_RAM_SIZE)
        return read_le<u16>(ram + p);
    if (p >= 0x1FC0'0000u && p + 1 < 0x2000'0000u)
        return read_le<u16>(bios + (p - 0x1FC0'0000u));
    if (p >= 0x7000'0000u && p + 1 < 0x7000'4000u)
        return read_le<u16>(scratch + (p - 0x7000'0000u));
    return (u16)read8(addr) | ((u16)read8(addr+1) << 8);
}

u32 Bus::read32(u32 addr) {
    u32 p = toPhysical(addr);
    if (p + 3 < EE_RAM_SIZE)
        return read_le<u32>(ram + p);
    if (p >= 0x1FC0'0000u && p + 3 < 0x2000'0000u)
        return read_le<u32>(bios + (p - 0x1FC0'0000u));
    if (p >= 0x1C00'0000u && p + 3 < 0x1C20'0000u)
        return read_le<u32>(iopRam + (p - 0x1C00'0000u));
    if (p >= 0x7000'0000u && p + 3 < 0x7000'4000u)
        return read_le<u32>(scratch + (p - 0x7000'0000u));
    if (p >= 0x1000'0000u && p < 0x1001'0000u)
        return readIO32(p - 0x1000'0000u);
    // GS privileged regs
    if (p >= 0x1200'0000u && p < 0x1201'0000u)
        return gs ? gs->readPriv(p - 0x1200'0000u) : 0u;
    return 0xFFFF'FFFFu;
}

u64 Bus::read64(u32 addr) {
    u32 lo = read32(addr);
    u32 hi = read32(addr + 4);
    return (u64)lo | ((u64)hi << 32);
}

u128 Bus::read128(u32 addr) {
    u128 v;
    v.lo = read64(addr);
    v.hi = read64(addr + 8);
    return v;
}

// ── Write helpers ─────────────────────────────────────────────────────────────

void Bus::write8(u32 addr, u8 v) {
    u32 p = toPhysical(addr);
    if (p < EE_RAM_SIZE)                          { ram[p] = v; return; }
    if (p >= 0x1C00'0000u && p < 0x1C20'0000u)   { iopRam[p - 0x1C00'0000u] = v; return; }
    if (p >= 0x7000'0000u && p < 0x7000'4000u)   { scratch[p - 0x7000'0000u] = v; return; }
    if (p >= 0x1000'0000u && p < 0x1001'0000u) {
        u32 aligned = p & ~3u;
        u32 old = readIO32(aligned - 0x1000'0000u);
        int sh = (p & 3) * 8;
        old = (old & ~(0xFFu << sh)) | ((u32)v << sh);
        writeIO32(aligned - 0x1000'0000u, old);
    }
}

void Bus::write16(u32 addr, u16 v) {
    u32 p = toPhysical(addr);
    if (p + 1 < EE_RAM_SIZE)                     { write_le<u16>(ram + p, v); return; }
    if (p >= 0x7000'0000u && p + 1 < 0x7000'4000u) { write_le<u16>(scratch + (p-0x7000'0000u), v); return; }
    write8(addr,   (u8)v);
    write8(addr+1, (u8)(v >> 8));
}

void Bus::write32(u32 addr, u32 v) {
    u32 p = toPhysical(addr);
    if (p + 3 < EE_RAM_SIZE)                     { write_le<u32>(ram + p, v); return; }
    if (p >= 0x1C00'0000u && p + 3 < 0x1C20'0000u) { write_le<u32>(iopRam + (p - 0x1C00'0000u), v); return; }
    if (p >= 0x7000'0000u && p + 3 < 0x7000'4000u) { write_le<u32>(scratch + (p - 0x7000'0000u), v); return; }
    if (p >= 0x1000'0000u && p < 0x1001'0000u)  { writeIO32(p - 0x1000'0000u, v); return; }
    if (p >= 0x1200'0000u && p < 0x1201'0000u)  { if (gs) gs->writePriv(p - 0x1200'0000u, v); return; }
}

void Bus::write64(u32 addr, u64 v) {
    write32(addr,   (u32)v);
    write32(addr+4, (u32)(v >> 32));
}

void Bus::write128(u32 addr, u128 v) {
    write64(addr,    v.lo);
    write64(addr+8,  v.hi);
}

// ── I/O Register routing ──────────────────────────────────────────────────────

u32 Bus::readIO32(u32 offset) {
    // Timer 0-3: 0x0800-0x0BFF (each 0x80 bytes)
    if (offset >= 0x0800u && offset < 0x0C00u) {
        return timer ? timer->read(offset - 0x0800u) : 0u;
    }
    // INTC: 0xF000-0xF01F
    if (offset >= 0xF000u && offset < 0xF020u) {
        return intc ? intc->read(offset - 0xF000u) : 0u;
    }
    // DMAC: 0x8000-0x8FFF (simplified: channel regs + global regs)
    if (offset >= 0x8000u && offset < 0x9000u) {
        return dmac ? dmac->read(offset - 0x8000u) : 0u;
    }
    // GS privileged (also reachable via I/O range in some games)
    if (offset < 0x0800u) {
        return gs ? gs->readPriv(offset) : 0u;
    }
    // SIF control
    if (offset == 0xD000u) return 0; // SIF_MSCOM
    if (offset == 0xD010u) return 0; // SIF_SMCOM
    if (offset == 0xD020u) return 0x10000u; // SIF_MSFLAG (BIOS handshake)
    if (offset == 0xD030u) return 0;
    if (offset == 0xD040u) return 0; // BD register
    return 0u;
}

void Bus::writeIO32(u32 offset, u32 value) {
    if (offset >= 0x0800u && offset < 0x0C00u) {
        if (timer) timer->write(offset - 0x0800u, value);
        return;
    }
    if (offset >= 0xF000u && offset < 0xF020u) {
        if (intc) intc->write(offset - 0xF000u, value);
        return;
    }
    if (offset >= 0x8000u && offset < 0x9000u) {
        if (dmac) dmac->write(offset - 0x8000u, value);
        return;
    }
    if (offset < 0x0800u) {
        if (gs) gs->writePriv(offset, value);
        return;
    }
    // SIF writes (ignored safely)
}
