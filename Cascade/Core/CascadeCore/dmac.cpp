#include "dmac.h"
#include "bus.h"
#include "gs.h"
#include "vu.h"
#include "intc.h"
#include "spu2.h"
#include "iop.h"
#include <cstring>

void DMAC::reset() {
    memset(ch, 0, sizeof(ch));
    ctrl = stat = pcr = sqwc = rbsr = rbor = stadr = 0;
    enableR = enableW = 0;
}

// ── Main step ─────────────────────────────────────────────────────────────────

void DMAC::step() {
    if (!(ctrl & 1)) return; // DMA master enable

    for (int id = 0; id < DMA_CHAN_COUNT; id++) {
        if (ch[id].active()) {
            runChannel(id);
        }
    }
}

void DMAC::runChannel(int id) {
    switch (id) {
    case DMA_GIF:  runGIF (ch[DMA_GIF]);  break;
    case DMA_VIF1: runVIF1(ch[DMA_VIF1]); break;
    case DMA_SIF0: runSIF0(ch[DMA_SIF0]); break;
    case DMA_SIF1: runSIF1(ch[DMA_SIF1]); break;
    default: {
        // Generic: drain QWC words
        DmaChannel& c = ch[id];
        if (c.qwc > 0) c.qwc--;
        if (c.qwc == 0) finishTransfer(id);
        break;
    }
    }
}

// ── GIF DMA (channel 2: EE RAM → GS via GIF) ─────────────────────────────────

void DMAC::runGIF(DmaChannel& c) {
    if (!gs || !bus) { c.chcr &= ~0x100u; return; }

    int mod = c.mod();
    if (mod == 0 || mod == 3) { // normal / chain
        // Transfer up to 64 QWs per step
        int batch = std::min((int)c.qwc, 64);
        if (batch == 0) { finishTransfer(DMA_GIF); return; }

        // Read QWs from EE RAM and feed to GS
        static u64 qwbuf[64 * 2];
        int toRead = batch * 2;
        for (int i = 0; i < toRead; i++) {
            qwbuf[i] = bus->read64(c.madr + (u32)(i * 8));
        }
        gs->processGIF(qwbuf, batch * 2);
        c.madr += (u32)(batch * 16);
        c.qwc  -= (u32)batch;

        if (c.qwc == 0) {
            if (mod == 1) {
                // Chain mode: fetch next tag
                u32 tagAddr = c.tadr;
                u64 tag = bus->read64(tagAddr);
                u32 qwc  = (u32)(tag & 0x7FFF);
                u32 pce  = (u32)((tag >> 26) & 3);
                u32 id2  = (u32)((tag >> 28) & 7);
                (void)pce;
                c.qwc  = qwc;
                c.chcr = (c.chcr & ~(0xFF << 16)) | ((u32)(tag >> 16) & 0xFF) << 16;

                switch (id2) {
                case 0: // refe — transfer, then stop
                    c.madr = (u32)((tag >> 32) & 0x7FFF'FFFCu);
                    finishTransfer(DMA_GIF);
                    break;
                case 1: // cnt — next comes after tag
                    c.madr = tagAddr + 16;
                    c.tadr = tagAddr + 16;
                    break;
                case 2: // next — next tag at addr field, data starts after
                    c.madr = tagAddr + 16;
                    c.tadr = (u32)((tag >> 32) & 0x7FFF'FFFCu);
                    break;
                case 3: // ref — data at addr, next tag after current
                    c.madr = (u32)((tag >> 32) & 0x7FFF'FFFCu);
                    c.tadr = tagAddr + 16;
                    break;
                case 7: // end
                    c.madr = tagAddr + 16;
                    finishTransfer(DMA_GIF);
                    break;
                default:
                    finishTransfer(DMA_GIF);
                    break;
                }
            } else {
                finishTransfer(DMA_GIF);
            }
        }
    }
}

// ── VIF1 DMA (channel 1: EE RAM → VIF1 → VU1/GS) ────────────────────────────

void DMAC::runVIF1(DmaChannel& c) {
    // Simplified: just drain the transfer (VIF unpacking is complex)
    if (!bus) { c.chcr &= ~0x100u; return; }
    int batch = std::min((int)c.qwc, 64);
    c.madr += (u32)(batch * 16);
    c.qwc  -= (u32)batch;
    if (c.qwc == 0) finishTransfer(DMA_VIF1);
}

// ── SIF0 DMA (IOP → EE: transfers IOP data to EE RAM) ────────────────────────

void DMAC::runSIF0(DmaChannel& c) {
    // SIF0 transfers data from IOP FIFO to EE RAM
    // Simplified: just drain
    if (c.qwc == 0) { finishTransfer(DMA_SIF0); return; }
    c.qwc = 0;
    finishTransfer(DMA_SIF0);
}

// ── SIF1 DMA (EE → IOP) ───────────────────────────────────────────────────────

void DMAC::runSIF1(DmaChannel& c) {
    if (c.qwc == 0) { finishTransfer(DMA_SIF1); return; }
    c.qwc = 0;
    finishTransfer(DMA_SIF1);
}

// ── Transfer completion ────────────────────────────────────────────────────────

void DMAC::finishTransfer(int id) {
    ch[id].chcr &= ~0x100u; // clear STR bit
    stat |= (1u << id);     // set interrupt bit
    if (intc) intc->assertIRQ(3); // DMAC → INTC bit 3
}

// ── Register access ────────────────────────────────────────────────────────────
// Base offset passed in is 0x8000-relative

u32 DMAC::read(u32 offset) {
    // Channel registers: each channel occupies 0x80 bytes
    if (offset < 0xA00u) {
        int cid = (int)(offset / 0x80);
        int reg = (int)(offset % 0x80);
        if (cid < DMA_CHAN_COUNT) {
            switch (reg) {
            case 0x00: return ch[cid].chcr;
            case 0x10: return ch[cid].madr;
            case 0x20: return ch[cid].qwc;
            case 0x30: return ch[cid].tadr;
            case 0x40: return ch[cid].asr[0];
            case 0x50: return ch[cid].asr[1];
            default:   return 0;
            }
        }
    }
    // Global registers
    switch (offset) {
    case 0xE000: return ctrl;
    case 0xE010: return stat;
    case 0xE020: return pcr;
    case 0xE030: return sqwc;
    case 0xE040: return rbsr;
    case 0xE050: return rbor;
    case 0xE060: return stadr;
    case 0xF500: return enableR;
    case 0xF590: return enableW;
    default:     return 0;
    }
}

void DMAC::write(u32 offset, u32 value) {
    if (offset < 0xA00u) {
        int cid = (int)(offset / 0x80);
        int reg = (int)(offset % 0x80);
        if (cid < DMA_CHAN_COUNT) {
            switch (reg) {
            case 0x00:
                ch[cid].chcr = value;
                if (value & 0x100u) step(); // kick immediately on start
                break;
            case 0x10: ch[cid].madr = value & ~0xFu; break;
            case 0x20: ch[cid].qwc  = value & 0xFFFFu; break;
            case 0x30: ch[cid].tadr = value & ~0xFu; break;
            case 0x40: ch[cid].asr[0] = value; break;
            case 0x50: ch[cid].asr[1] = value; break;
            default: break;
            }
            return;
        }
    }
    switch (offset) {
    case 0xE000: ctrl = value; break;
    case 0xE010: stat &= ~value; break; // write 1 to clear
    case 0xE020: pcr  = value; break;
    case 0xE030: sqwc = value; break;
    case 0xE040: rbsr = value; break;
    case 0xE050: rbor = value; break;
    case 0xE060: stadr= value; break;
    case 0xF500: enableR = value; break;
    case 0xF590: enableW = value; break;
    default: break;
    }
}
