#include "dmac.h"
#include "bus.h"
#include "gs.h"
#include "vu.h"
#include "intc.h"
#include "spu2.h"
#include "iop.h"
#include <cstring>
#include <algorithm>

void DMAC::reset() {
    memset(ch, 0, sizeof(ch));
    ctrl   = 0;
    stat   = 0;
    pcr    = 0;
    sqwc   = 0;
    rbsr   = 0;
    rbor   = 0;
    stadr  = 0;
    enableR = enableW = 0;
}

// ── Read/Write ────────────────────────────────────────────────────────────────
// Channel layout (relative to 0x8000 base):
//   VIF0=0x0000, VIF1=0x1000, GIF=0x2000, IPUFROM=0x3000, IPUTO=0x4000
//   SIF0=0x5000, SIF1=0x6000, SIF2=0x7000, SPRFROM=0x8000, SPRTO=0x9000
//
// Within each channel (4-byte stride):
//   +0x00 = CHCR, +0x10 = MADR, +0x20 = QWC, +0x30 = TADR, +0x40 = ASR0, +0x50 = ASR1

static int channelFromOffset(u32 off, u32& regOff) {
    // Try channel-sized slots at 0x8000 + id*0x1000
    if (off >= 0x8000 && off < 0x9000) { regOff = off & 0xFF; return DMA_VIF0; }
    if (off >= 0x9000 && off < 0xA000) { regOff = off & 0xFF; return DMA_VIF1; }
    if (off >= 0xA000 && off < 0xB000) { regOff = off & 0xFF; return DMA_GIF;  }
    if (off >= 0xB000 && off < 0xB400) { regOff = off & 0xFF; return DMA_IPUFROM; }
    if (off >= 0xB400 && off < 0xC000) { regOff = off & 0xFF; return DMA_IPUTO;   }
    if (off >= 0xC000 && off < 0xC800) { regOff = off & 0xFF; return DMA_SIF0;    }
    if (off >= 0xC800 && off < 0xD000) { regOff = off & 0xFF; return DMA_SIF1;    }
    if (off >= 0xD000 && off < 0xD400) { regOff = off & 0xFF; return DMA_SIF2;    }
    if (off >= 0xD400 && off < 0xD800) { regOff = off & 0xFF; return DMA_SPRFROM; }
    if (off >= 0xD800 && off < 0xE000) { regOff = off & 0xFF; return DMA_SPRTO;   }
    regOff = off;
    return -1;
}

u32 DMAC::read(u32 offset) {
    u32 regOff = 0;
    int id = channelFromOffset(offset, regOff);
    if (id >= 0 && id < DMA_CHAN_COUNT) {
        DmaChannel& c = ch[id];
        switch (regOff & ~3u) {
        case 0x00: return c.chcr;
        case 0x10: return c.madr;
        case 0x20: return c.qwc;
        case 0x30: return c.tadr;
        case 0x40: return c.asr[0];
        case 0x50: return c.asr[1];
        default:   return 0;
        }
    }

    // Global DMAC registers (relative to 0xE000 or passed raw)
    u32 gOff = (offset >= 0xE000) ? offset : offset;
    switch (gOff) {
    case 0xE000: return ctrl;
    case 0xE010: return stat;
    case 0xE020: return pcr;
    case 0xE030: return sqwc;
    case 0xE040: return rbsr;
    case 0xE050: return rbor;
    case 0xE060: return stadr;
    case 0xF520: return enableR; // D_ENABLER
    case 0xF590: return enableW; // D_ENABLEW
    default:     return 0;
    }
}

void DMAC::write(u32 offset, u32 value) {
    u32 regOff = 0;
    int id = channelFromOffset(offset, regOff);
    if (id >= 0 && id < DMA_CHAN_COUNT) {
        DmaChannel& c = ch[id];
        switch (regOff & ~3u) {
        case 0x00: c.chcr = value; break;
        case 0x10: c.madr = value & 0x1FFF'FFF0u; break; // QW-aligned
        case 0x20: c.qwc  = value & 0xFFFFu; break;
        case 0x30: c.tadr = value & 0x1FFF'FFF0u; break;
        case 0x40: c.asr[0] = value; break;
        case 0x50: c.asr[1] = value; break;
        default:   break;
        }
        return;
    }

    u32 gOff = offset;
    switch (gOff) {
    case 0xE000: ctrl  = value; break;
    case 0xE010:
        // Writing 1 to a stat bit clears it (acknowledge)
        stat &= ~(value & 0xFFFFu);
        // Upper 16 bits control DMAC channel enable mask
        stat = (stat & 0xFFFFu) | (value & 0xFFFF'0000u);
        break;
    case 0xE020: pcr   = value; break;
    case 0xE030: sqwc  = value; break;
    case 0xE040: rbsr  = value; break;
    case 0xE050: rbor  = value; break;
    case 0xE060: stadr = value; break;
    case 0xF520: enableR = value; break;
    case 0xF590: enableW = value; break;
    default: break;
    }
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
    case DMA_GIF:     runGIF (ch[DMA_GIF]);     break;
    case DMA_VIF1:    runVIF1(ch[DMA_VIF1]);    break;
    case DMA_SIF0:    runSIF0(ch[DMA_SIF0]);    break;
    case DMA_SIF1:    runSIF1(ch[DMA_SIF1]);    break;
    case DMA_IPUFROM: finishTransfer(id);        break; // IPU → EE: stub drain
    default: {
        // Generic normal-mode: drain QWC
        DmaChannel& c = ch[id];
        u32 drain = std::min(c.qwc, 16u);
        c.madr += drain * 16;
        c.qwc  -= drain;
        if (c.qwc == 0) finishTransfer(id);
        break;
    }
    }
}

// ── GIF DMA (channel 2: EE RAM → GS via GIF) ─────────────────────────────────

void DMAC::runGIF(DmaChannel& c) {
    if (!gs || !bus) { c.chcr &= ~0x100u; return; }

    static constexpr int MAX_QW_PER_STEP = 64;

    int mod = c.mod();
    if (mod == 1) { // Chain mode
        if (c.qwc == 0) {
            // Fetch next tag from TADR
            if (!bus) { finishTransfer(DMA_GIF); return; }
            u64 tag  = bus->read64(c.tadr);
            u32 qwc  = (u32)(tag & 0x7FFF);
            u32 id2  = (u32)((tag >> 28) & 7);
            bool irq = (tag >> 31) & 1;
            c.qwc    = qwc;
            // Optionally propagate tag fields to CHCR[31:16]
            c.chcr = (c.chcr & 0x0000'FFFFu) | (u32)((tag >> 16) & 0xFFFF) << 16;

            switch (id2) {
            case 0: // refe — transfer from addr in tag, then stop
                c.madr = (u32)((tag >> 32) & 0x1FFF'FFF0u);
                // Don't update TADR; will stop after transfer
                break;
            case 1: // cnt — transfer from MADR, TADR = MADR+qwc*16 after
                c.madr = c.tadr + 16;
                c.tadr = c.madr + qwc * 16;
                break;
            case 2: // next — transfer from MADR, TADR = addr in tag
                c.madr = c.tadr + 16;
                c.tadr = (u32)((tag >> 32) & 0x1FFF'FFF0u);
                break;
            case 3: // ref — transfer from addr in tag, TADR advances past tag
                c.madr = (u32)((tag >> 32) & 0x1FFF'FFF0u);
                c.tadr += 16;
                break;
            case 4: // refs — same as ref for us
                c.madr = (u32)((tag >> 32) & 0x1FFF'FFF0u);
                c.tadr += 16;
                break;
            case 7: // end — transfer from MADR, stop after
                c.madr = c.tadr + 16;
                c.tadr = 0;
                c.chcr &= ~0x100u; // pre-mark done; we'll really stop after transfer
                break;
            default:
                finishTransfer(DMA_GIF);
                return;
            }

            if (irq) {
                finishTransfer(DMA_GIF);
                return;
            }
        }
    }

    if (c.qwc == 0) { finishTransfer(DMA_GIF); return; }

    int batch = std::min((int)c.qwc, MAX_QW_PER_STEP);

    // Read QWs from EE RAM and feed to GS
    static u64 qwbuf[MAX_QW_PER_STEP * 2];
    for (int i = 0; i < batch * 2; i++)
        qwbuf[i] = bus->read64(c.madr + (u32)(i * 8));
    gs->processGIF(qwbuf, batch * 2);

    c.madr += (u32)(batch * 16);
    c.qwc  -= (u32)batch;

    if (c.qwc == 0 && mod != 1) {
        finishTransfer(DMA_GIF);
    }
    // In chain mode, we loop back next step to fetch new tag
}

// ── VIF1 DMA (channel 1: EE RAM → VU1 via VIF1) ──────────────────────────────

void DMAC::runVIF1(DmaChannel& c) {
    if (!bus) { finishTransfer(DMA_VIF1); return; }
    // VIF1 would decode VIF opcodes; for now just drain
    u32 drain = std::min(c.qwc, 16u);
    c.madr += drain * 16;
    c.qwc  -= drain;
    if (c.qwc == 0) finishTransfer(DMA_VIF1);
}

// ── SIF0 DMA (IOP→EE) ────────────────────────────────────────────────────────

void DMAC::runSIF0(DmaChannel& c) {
    if (!iop || !bus) { finishTransfer(DMA_SIF0); return; }
    // Copy a 32-byte chunk from IOP RAM to EE RAM
    if (c.qwc == 0) { finishTransfer(DMA_SIF0); return; }

    u32 drain = std::min(c.qwc, 4u); // 4 QW per step
    for (u32 i = 0; i < drain; i++) {
        // Read 16 bytes from IOP RAM via SADR
        u32 iopOff = c.sadr + i * 16;
        for (int b = 0; b < 16; b++) {
            u8 byte = (iopOff + b < IOP_RAM_SIZE && iop->ram) ? iop->ram[iopOff + b] : 0;
            bus->write8(c.madr + i * 16 + b, byte);
        }
    }
    c.sadr += drain * 16;
    c.madr += drain * 16;
    c.qwc  -= drain;
    if (c.qwc == 0) finishTransfer(DMA_SIF0);
}

// ── SIF1 DMA (EE→IOP) ────────────────────────────────────────────────────────

void DMAC::runSIF1(DmaChannel& c) {
    if (!iop || !bus) { finishTransfer(DMA_SIF1); return; }
    if (c.qwc == 0) { finishTransfer(DMA_SIF1); return; }

    u32 drain = std::min(c.qwc, 4u);
    for (u32 i = 0; i < drain; i++) {
        u32 iopOff = c.sadr + i * 16;
        for (int b = 0; b < 16; b++) {
            u8 byte = bus->read8(c.madr + i * 16 + b);
            if (iopOff + b < IOP_RAM_SIZE && iop->ram)
                iop->ram[iopOff + b] = byte;
        }
    }
    c.sadr += drain * 16;
    c.madr += drain * 16;
    c.qwc  -= drain;
    if (c.qwc == 0) finishTransfer(DMA_SIF1);
}

// ── Finish transfer ────────────────────────────────────────────────────────────

void DMAC::finishTransfer(int id) {
    DmaChannel& c = ch[id];
    c.chcr &= ~0x100u; // clear STR bit
    c.qwc   = 0;

    // Set DMAC_STAT bit for this channel and raise INTC IRQ if enabled
    stat |= (1u << id);

    // DMAC raises INTC bit 3 (DMA) when any channel completes and its
    // PCR channel-priority bit is set for interrupt generation.
    // Simplified: always raise INTC DMAC interrupt (bit 3 = VBLANK_E conflicts;
    // use bit 8+id range for DMA bits 8–17 per DMAC_STAT layout).
    // INTC bit for DMAC channel id: bits 8–17 in DMAC_STAT map to INTC?
    // Actually, DMAC channels generate an INTC bit 0 (GS) or route through DMAC_STAT.
    // On real hardware, the DMAC IRQ fires into INTC bit 3 (DMAC).
    if (intc) {
        // Check if this channel's interrupt mask bit in DMAC STAT is enabled
        bool chEnabled = (stat >> (16 + id)) & 1;
        if (!chEnabled) {
            // Channel interrupt mask not set → raise anyway for correctness
        }
        // Raise INTC DMAC interrupt line (bit 3 on EE)
        intc->assertIRQ(3);
    }
}
