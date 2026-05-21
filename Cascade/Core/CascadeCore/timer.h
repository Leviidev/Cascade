#pragma once
#include "types.h"

struct INTC;

// ── EE Timer unit: 4 x 32-bit timers ────────────────────────────────────────
// Registers per timer (base = 0x1000'0800 + n*0x800):
//  +0x00 COUNT   (32-bit, RW)
//  +0x10 MODE    (16-bit, RW)
//  +0x20 COMP    (32-bit, RW — comparator)
//  +0x30 HOLD    (32-bit, RO — for timer 0/1 only)
//
// MODE bits:
//  [1:0] CLKS   clock selection (0=bus/1=16th bus/2=256th bus/3=HBLANK)
//  [2]   GATE   gate enable
//  [3]   GATS   gate source (0=HBLANK/1=VBLANK)
//  [4]   GATM   gate mode (0=reset on lo→hi/1=on hi→lo/2=on both)
//  [5]   ZRET   zero-return on compare-equal
//  [6]   CUE    count enable
//  [7]   CMPE   compare interrupt enable
//  [8]   OVFE   overflow interrupt enable
//  [9]   EQUF   compare flag
//  [10]  OVFF   overflow flag

struct EETimer {
    struct Channel {
        u32 count = 0;
        u16 mode  = 0;
        u32 comp  = 0;
        u32 hold  = 0;
        u64 subCycles = 0;

        bool enabled()    const { return (mode >> 6) & 1; }
        int  clockSel()   const { return mode & 3; }
        bool cmpIntrEn()  const { return (mode >> 7) & 1; }
        bool ovfIntrEn()  const { return (mode >> 8) & 1; }
        bool zeroReturn() const { return (mode >> 5) & 1; }
    } ch[4];

    INTC* intc = nullptr;

    // busHz: EE bus clock Hz (used to derive timer ticks)
    static constexpr u64 BUS_HZ = 147456000;

    void reset();
    // tickBusCycles: number of EE bus cycles elapsed since last call
    void tick(u64 busCycles = 256);

    u32  read (u32 offset);
    void write(u32 offset, u32 value);
};
