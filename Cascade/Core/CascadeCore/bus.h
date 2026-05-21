#pragma once
#include "types.h"

struct GS;
struct DMAC;
struct INTC;
struct EETimer;
struct IOP;
struct SPU2;

// ── PS2 Physical Memory Map ──────────────────────────────────────────────────
//  0x0000'0000 – 0x01FF'FFFF   EE Main RAM  (32 MB)
//  0x1000'0000 – 0x1000'FFFF   Hardware I/O (DMAC, INTC, Timer, GS priv, etc.)
//  0x1C00'0000 – 0x1C1F'FFFF   IOP RAM      (2 MB, visible from EE bus)
//  0x1FC0'0000 – 0x1FFF'FFFF   BIOS ROM     (4 MB)
//  0x7000'0000 – 0x7000'3FFF   Scratch-Pad  (16 KB)
//  KSEG0 mirror: 0x8000'0000 → strip bit 31
//  KSEG1 mirror: 0xA000'0000 → strip bits 31:29

static constexpr u32 EE_RAM_SIZE    = 32 * 1024 * 1024;
static constexpr u32 BIOS_SIZE      =  4 * 1024 * 1024;
static constexpr u32 IOP_RAM_SIZE   =  2 * 1024 * 1024;
static constexpr u32 SCRATCH_SIZE   = 16 * 1024;

struct Bus {
    u8* ram     = nullptr;
    u8* bios    = nullptr;
    u8* iopRam  = nullptr;
    u8* scratch = nullptr;

    GS*      gs    = nullptr;
    DMAC*    dmac  = nullptr;
    INTC*    intc  = nullptr;
    EETimer* timer = nullptr;
    IOP*     iop   = nullptr;
    SPU2*    spu2  = nullptr;

    Bus();
    ~Bus();

    bool loadBIOS(const u8* data, size_t size);

    // Virtual → physical address translation
    static u32 toPhysical(u32 vaddr) {
        u32 seg = vaddr >> 29;
        // KSEG0 (4) and KSEG1 (5): strip top 3 bits
        if (seg == 4 || seg == 5) return vaddr & 0x1FFF'FFFFu;
        // KUSEG and KSEG2 pass through (or truncate to 29 bits)
        return vaddr & 0x1FFF'FFFFu;
    }

    u8   read8  (u32 addr);
    u16  read16 (u32 addr);
    u32  read32 (u32 addr);
    u64  read64 (u32 addr);
    u128 read128(u32 addr);

    void write8  (u32 addr, u8   v);
    void write16 (u32 addr, u16  v);
    void write32 (u32 addr, u32  v);
    void write64 (u32 addr, u64  v);
    void write128(u32 addr, u128 v);

    u32  readIO32 (u32 offset);
    void writeIO32(u32 offset, u32 value);
};
