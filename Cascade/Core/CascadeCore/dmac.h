#pragma once
#include "types.h"

struct Bus;
struct GS;
struct VU;
struct INTC;
struct SPU2;
struct IOP;

// ── DMAC: 10-channel DMA controller ──────────────────────────────────────────
// Channel IDs:
//  0 = VIF0    5 = SIF0 (IOP→EE)
//  1 = VIF1    6 = SIF1 (EE→IOP)
//  2 = GIF     7 = SIF2
//  3 = IPUFROM 8 = SPR from
//  4 = IPUTO   9 = SPR to

enum DmaChId : int {
    DMA_VIF0 = 0, DMA_VIF1 = 1, DMA_GIF  = 2,
    DMA_IPUFROM = 3, DMA_IPUTO = 4,
    DMA_SIF0 = 5, DMA_SIF1 = 6, DMA_SIF2 = 7,
    DMA_SPRFROM = 8, DMA_SPRTO = 9,
    DMA_CHAN_COUNT = 10
};

struct DmaChannel {
    u32 chcr = 0;  // control
    u32 madr = 0;  // memory address
    u32 qwc  = 0;  // quadword count
    u32 tadr = 0;  // tag address
    u32 asr[2] = {};
    u32 sadr = 0;

    bool active() const { return (chcr & 0x100) != 0; }
    bool tte()    const { return (chcr & 0x40) != 0; }
    int  dir()    const { return (chcr >> 1) & 1; }
    int  mod()    const { return (chcr >> 2) & 3; }
};

struct DMAC {
    DmaChannel ch[DMA_CHAN_COUNT] = {};
    u32 ctrl   = 0;
    u32 stat   = 0;
    u32 pcr    = 0;
    u32 sqwc   = 0;
    u32 rbsr   = 0;
    u32 rbor   = 0;
    u32 stadr  = 0;
    u32 enableR = 0, enableW = 0;

    Bus*   bus  = nullptr;
    GS*    gs   = nullptr;
    INTC*  intc = nullptr;
    SPU2*  spu2 = nullptr;
    IOP*   iop  = nullptr;

    void reset();
    void step();

    u32  read (u32 offset);
    void write(u32 offset, u32 value);

private:
    void runChannel(int id);
    void runGIF(DmaChannel& ch);
    void runVIF1(DmaChannel& ch);
    void runSIF0(DmaChannel& ch);
    void runSIF1(DmaChannel& ch);
    void finishTransfer(int id);
};
