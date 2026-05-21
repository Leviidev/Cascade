#pragma once
#include "types.h"
#include <functional>

// PS2 EE Interrupt Controller
// INTC_STAT @ 0x1000'F000
// INTC_MASK @ 0x1000'F010
//
// Bit assignments (INTC_STAT / INTC_MASK):
//  0  GS      7  IPU     14 DMAC_13
//  1  SBUS    8  Timer0  15 DMAC_14
//  2  VBlankS 9  Timer1  16 DMAC_15
//  3  VBlankE 10 Timer2
//  4  VIF0    11 Timer3
//  5  VIF1    12 SFIFO
//  6  VU0     13 VU1

struct INTC {
    u32 stat = 0;
    u32 mask = 0;

    // Called whenever pending() transitions to true — wires into EE COP0.
    // Set by PS2::wireComponents().
    std::function<void()> onPending;

    void assertIRQ(int bit) {
        stat |= (1u << bit);
        if (pending() && onPending) onPending();
    }
    void clearIRQ(int bit)  { stat &= ~(1u << bit); }
    bool pending() const    { return (stat & mask) != 0; }

    u32 read(u32 offset) const {
        switch (offset & 0x1F) {
        case 0x00: return stat;
        case 0x10: return mask;
        default:   return 0;
        }
    }

    void write(u32 offset, u32 value) {
        switch (offset & 0x1F) {
        case 0x00:
            stat &= ~value;   // writing 1 clears the bit
            break;
        case 0x10:
            mask ^= value;    // writing 1 toggles mask
            if (pending() && onPending) onPending();
            break;
        default:
            break;
        }
    }
};
