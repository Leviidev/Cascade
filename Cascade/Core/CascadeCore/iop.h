#pragma once
#include "types.h"

struct SPU2;
struct CDVD;

// IOP (MIPS R3000A) — secondary CPU running at ~36.864 MHz
// Handles CD/DVD, SPU2, controllers, memory cards, USB, etc.

struct IOP {
    u32 gpr[32] = {};
    u32 pc  = 0xBFC0'0000u;
    u32 hi  = 0, lo = 0;

    // COP0
    u32 cop0_Status = 0;
    u32 cop0_Cause  = 0;
    u32 cop0_EPC    = 0;
    u32 cop0_BadVA  = 0;

    bool inDelaySlot = false;
    u32  nextPC      = 0xBFC0'0004u;

    u64  cycles = 0;

    // 2 MB IOP RAM
    u8*  ram = nullptr;

    // Peripheral references (not owned)
    SPU2* spu2 = nullptr;
    CDVD* cdvd = nullptr;

    IOP();
    ~IOP();

    void reset();
    void step(int count);

    // Memory access
    u8   read8 (u32 addr);
    u16  read16(u32 addr);
    u32  read32(u32 addr);
    void write8 (u32 addr, u8  v);
    void write16(u32 addr, u16 v);
    void write32(u32 addr, u32 v);

    void setGPR(int i, u32 v) { if (i) gpr[i] = v; }

private:
    void decode(u32 instr);
    void decodeSpecial(u32 instr);
    u32  physAddr(u32 v) const { return v & 0x1FFF'FFFFu; }
    void branchTo(u32 target) { inDelaySlot = true; nextPC = target; }
    void branchOffset(i32 off) {
        inDelaySlot = true;
        nextPC = (u32)((i32)pc + (off << 2));
    }
    void jumpAbsolute(u32 imm26) {
        inDelaySlot = true;
        nextPC = (pc & 0xF000'0000u) | (imm26 << 2);
    }
    void triggerException(int excCode);

    u32  readIO (u32 phys);
    void writeIO(u32 phys, u32 v);
};
