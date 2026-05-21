#include "timer.h"
#include "intc.h"

void EETimer::reset() {
    for (auto& c : ch) {
        c.count = c.mode = c.comp = c.hold = 0;
        c.subCycles = 0;
    }
}

void EETimer::tick(u64 busCycles) {
    // Divisors for each clock selection
    static const u64 divs[4] = {1, 16, 256, 0 /* HBLANK — handle separately */};

    for (int i = 0; i < 4; i++) {
        Channel& c = ch[i];
        if (!c.enabled()) continue;

        int cs = c.clockSel();
        if (cs == 3) continue; // HBLANK — not driven by bus cycles here

        u64 div = divs[cs];
        c.subCycles += busCycles;

        while (c.subCycles >= div) {
            c.subCycles -= div;

            // Advance count
            u32 prev = c.count;
            c.count++;

            // Check compare
            if (c.count == c.comp && c.cmpIntrEn()) {
                int irqBit = 8 + i; // Timer 0-3 → INTC bits 8-11
                if (intc) intc->assertIRQ(irqBit);
                if (c.zeroReturn()) c.count = 0;
                c.mode |= (1u << 9); // EQUF flag
            }

            // Check overflow (32-bit wrap)
            if (prev == 0xFFFF'FFFFu && c.count == 0) {
                if (c.ovfIntrEn()) {
                    int irqBit = 8 + i;
                    if (intc) intc->assertIRQ(irqBit);
                }
                c.mode |= (1u << 10); // OVFF flag
            }
        }
    }
}

u32 EETimer::read(u32 offset) {
    // offset is relative to 0x1000'0800
    // Channel n is at n * 0x800, register at offset within channel
    int n  = (int)(offset / 0x800) & 3;
    int reg = (int)(offset % 0x800) & 0x30;
    switch (reg) {
    case 0x00: return ch[n].count;
    case 0x10: return ch[n].mode;
    case 0x20: return ch[n].comp;
    case 0x30: return ch[n].hold;
    default:   return 0;
    }
}

void EETimer::write(u32 offset, u32 value) {
    int n  = (int)(offset / 0x800) & 3;
    int reg = (int)(offset % 0x800) & 0x30;
    switch (reg) {
    case 0x00:
        ch[n].count = value; break;
    case 0x10:
        // Writing MODE: clear EQUF+OVFF bits (bits 9 and 10)
        ch[n].mode = (u16)(value & 0x3FF);
        break;
    case 0x20:
        ch[n].comp = value;
        break;
    default:
        break;
    }
}
