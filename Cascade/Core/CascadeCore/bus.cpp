#include "bus.h"
#include "gs.h"
#include "dmac.h"
#include "intc.h"
#include "timer.h"
#include "iop.h"
#include "spu2.h"
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
    if (p >= 0x1C00'0000u && p < 0x1C20'0000u && iopRam) return iopRam[p - 0x1C00'0000u];
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
    if (p >= 0x1C00'0000u && p + 1 < 0x1C20'0000u && iopRam)
        return read_le<u16>(iopRam + (p - 0x1C00'0000u));
    if (p >= 0x7000'0000u && p + 1 < 0x7000'4000u)
        return read_le<u16>(scratch + (p - 0x7000'0000u));
    return (u16)read8(addr) | ((u16)read8(addr + 1) << 8);
}

u32 Bus::read32(u32 addr) {
    u32 p = toPhysical(addr);
    if (p + 3 < EE_RAM_SIZE)
        return read_le<u32>(ram + p);
    if (p >= 0x1FC0'0000u && p + 3 < 0x2000'0000u)
        return read_le<u32>(bios + (p - 0x1FC0'0000u));
    if (p >= 0x1C00'0000u && p + 3 < 0x1C20'0000u && iopRam)
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
    u32 p = toPhysical(addr);
    if (p + 7 < EE_RAM_SIZE)
        return read_le<u64>(ram + p);
    if (p >= 0x1FC0'0000u && p + 7 < 0x2000'0000u)
        return read_le<u64>(bios + (p - 0x1FC0'0000u));
    u32 lo = read32(addr);
    u32 hi = read32(addr + 4);
    return (u64)lo | ((u64)hi << 32);
}

u128 Bus::read128(u32 addr) {
    u32 p = toPhysical(addr);
    if (p + 15 < EE_RAM_SIZE) {
        u128 v;
        v.lo = read_le<u64>(ram + p);
        v.hi = read_le<u64>(ram + p + 8);
        return v;
    }
    u128 v;
    v.lo = read64(addr);
    v.hi = read64(addr + 8);
    return v;
}

// ── Write helpers ─────────────────────────────────────────────────────────────

void Bus::write8(u32 addr, u8 v) {
    u32 p = toPhysical(addr);
    if (p < EE_RAM_SIZE)                        { ram[p] = v; return; }
    if (p >= 0x1C00'0000u && p < 0x1C20'0000u && iopRam) { iopRam[p - 0x1C00'0000u] = v; return; }
    if (p >= 0x7000'0000u && p < 0x7000'4000u) { scratch[p - 0x7000'0000u] = v; return; }
    if (p >= 0x1000'0000u && p < 0x1001'0000u) {
        u32 off = p - 0x1000'0000u;
        u32 shift = (off & 3) * 8;
        u32 old = readIO32(off & ~3u);
        writeIO32(off & ~3u, (old & ~(0xFFu << shift)) | ((u32)v << shift));
    }
}

void Bus::write16(u32 addr, u16 v) {
    u32 p = toPhysical(addr);
    if (p + 1 < EE_RAM_SIZE)                        { write_le<u16>(ram + p, v); return; }
    if (p >= 0x1C00'0000u && p + 1 < 0x1C20'0000u && iopRam) { write_le<u16>(iopRam + (p - 0x1C00'0000u), v); return; }
    if (p >= 0x7000'0000u && p + 1 < 0x7000'4000u) { write_le<u16>(scratch + (p - 0x7000'0000u), v); return; }
    write8(addr,     (u8)(v & 0xFF));
    write8(addr + 1, (u8)(v >> 8));
}

void Bus::write32(u32 addr, u32 v) {
    u32 p = toPhysical(addr);
    if (p + 3 < EE_RAM_SIZE)                        { write_le<u32>(ram + p, v); return; }
    if (p >= 0x1C00'0000u && p + 3 < 0x1C20'0000u && iopRam) { write_le<u32>(iopRam + (p - 0x1C00'0000u), v); return; }
    if (p >= 0x7000'0000u && p + 3 < 0x7000'4000u) { write_le<u32>(scratch + (p - 0x7000'0000u), v); return; }
    if (p >= 0x1000'0000u && p < 0x1001'0000u)      { writeIO32(p - 0x1000'0000u, v); return; }
    if (p >= 0x1200'0000u && p < 0x1201'0000u && gs) { gs->writePriv(p - 0x1200'0000u, v); return; }
}

void Bus::write64(u32 addr, u64 v) {
    u32 p = toPhysical(addr);
    if (p + 7 < EE_RAM_SIZE) { write_le<u64>(ram + p, v); return; }
    write32(addr,     (u32)(v & 0xFFFF'FFFFu));
    write32(addr + 4, (u32)(v >> 32));
}

void Bus::write128(u32 addr, u128 v) {
    u32 p = toPhysical(addr);
    if (p + 15 < EE_RAM_SIZE) {
        write_le<u64>(ram + p,     v.lo);
        write_le<u64>(ram + p + 8, v.hi);
        return;
    }
    write64(addr,     v.lo);
    write64(addr + 8, v.hi);
}

// ── IO register map ──────────────────────────────────────────────────────────
// Offsets relative to 0x1000'0000
//
//  0x0000'xxxx  DMAC channel registers
//  0x000F'0000  DMAC global registers
//  0x000E'0020  INTC stat/mask
//  0x000F'0000  DMAC D_CTRL
//  0x0008'00xx  Timer 0-3
//  0x000F'E000  ???
//
// Layout (abridged):
//  0x1000'0000  D0_CHCR (VIF0)   Timer: 0x1000'0800
//  0x1000'F000  INTC_STAT         0x1000'F010 INTC_MASK
//  0x1000'E000  DMAC D_CTRL
//  0x1200'xxxx  GS priv regs (handled separately in read32/write32)
//  0x1001'C000  VIF0 FIFO
//  0x1001'D000  VIF1 FIFO
//  0x1001'E000  GIF FIFO

// DMAC channel base addresses (each channel is 0x10 apart at 0x1000'8000+id*0x10)
// Full layout: each DMA channel n is at 0x1000'8000 + n*0x10

static u32 dmaChannelOffset(u32 off) {
    // Channels 0-9 each use 0x10 bytes
    // VIF0=0x8000, VIF1=0x9000, GIF=0xA000, IPUFROM=0xB000, IPUTO=0xC000
    // SIF0=0xC800, SIF1=0xC900, SIF2=0xCA00, SPRFROM=0xD000, SPRTO=0xD400
    return off;
}

u32 Bus::readIO32(u32 offset) {
    // Timer channels: 0x0800 – 0x0BFF (T0–T3)
    if (offset >= 0x0800 && offset < 0x1000) {
        return timer ? timer->read(offset - 0x0800) : 0u;
    }

    // GIF FIFO area — return 0
    if (offset >= 0x6000 && offset < 0x7000) return 0u;

    // IPU registers
    if (offset >= 0x2000 && offset < 0x3000) return 0u;

    // VIF0/VIF1 — 0x3800 and 0x3C00
    if (offset >= 0x3800 && offset < 0x4000) return 0u;

    // DMAC channels: 0x8000 – 0xD7FF
    if (offset >= 0x8000 && offset <= 0xD7FF) {
        return dmac ? dmac->read(offset - 0x8000) : 0u;
    }

    // DMAC globals: 0xE000 – 0xEFFF
    if (offset >= 0xE000 && offset < 0xF000) {
        return dmac ? dmac->read(offset) : 0u;
    }

    // INTC
    if (offset >= 0xF000 && offset < 0xF020) {
        return intc ? intc->read(offset - 0xF000) : 0u;
    }

    // SPU2 IO (0x1000'A000 – 0x1000'BFFF) — forward to SPU2
    if (offset >= 0xA000 && offset < 0xC000) {
        return spu2 ? spu2->readIO(offset - 0xA000) : 0u;
    }

    // SIF control registers (0x1000'F200 – 0x1000'F2FF)
    if (offset >= 0xF200 && offset < 0xF300) {
        // SIF: return SIFBIOS flag = 0xF (BIOS ready) for SIF0/SIF1/SIF2
        if ((offset - 0xF200) == 0x00) return 0xFu; // SIF_CTRL
        if ((offset - 0xF200) == 0x20) return 0xFu; // SIF_SMFLAG
        if ((offset - 0xF200) == 0x30) return 0x10000u; // SIF_BD6
        return 0u;
    }

    // MCH (RDRAM controller) — stub
    if (offset >= 0xF400 && offset < 0xF800) return 0u;

    // RTC/misc — stub
    return 0u;
}

void Bus::writeIO32(u32 offset, u32 value) {
    // Timer
    if (offset >= 0x0800 && offset < 0x1000) {
        if (timer) timer->write(offset - 0x0800, value);
        return;
    }

    // DMAC channels
    if (offset >= 0x8000 && offset <= 0xD7FF) {
        if (dmac) dmac->write(offset - 0x8000, value);
        return;
    }

    // DMAC globals
    if (offset >= 0xE000 && offset < 0xF000) {
        if (dmac) dmac->write(offset, value);
        return;
    }

    // INTC
    if (offset >= 0xF000 && offset < 0xF020) {
        if (intc) intc->write(offset - 0xF000, value);
        return;
    }

    // SPU2 IO
    if (offset >= 0xA000 && offset < 0xC000) {
        if (spu2) spu2->writeIO(offset - 0xA000, value);
        return;
    }

    // GIF FIFO: data sent directly to GS
    if (offset >= 0x6000 && offset < 0x7000) {
        if (gs) {
            u8 buf[4]; write_le<u32>(buf, value);
            gs->feedImageData(buf, 4);
        }
        return;
    }

    // SIF / MCH / misc — ignore
}
