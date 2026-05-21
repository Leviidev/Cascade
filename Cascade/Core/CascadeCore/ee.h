#pragma once
#include "types.h"

struct Bus;
struct VU;

// ── COP0 register indices ────────────────────────────────────────────────────
enum : int {
    COP0_Index   =  0,
    COP0_EntryLo0=  2,
    COP0_EntryLo1=  3,
    COP0_Context =  4,
    COP0_PageMask=  5,
    COP0_Wired   =  6,
    COP0_EntryHi =  10,
    COP0_Count   =  9,
    COP0_Compare = 11,
    COP0_Status  = 12,
    COP0_Cause   = 13,
    COP0_EPC     = 14,
    COP0_PRId    = 15,
    COP0_Config  = 16,
    COP0_BadVAddr= 8,
    COP0_TagLo   = 28,
    COP0_TagHi   = 29,
    COP0_ErrorEPC= 30,
    COP0_PCCR    = 25,
};

// COP0 Status register bits
static constexpr u32 SR_IE  = (1u << 0);
static constexpr u32 SR_EXL = (1u << 1);
static constexpr u32 SR_ERL = (1u << 2);
static constexpr u32 SR_EIE = (1u << 16);

// EE CPU (MIPS R5900)
struct EE {
    u128 gpr[32];
    u32  pc       = 0xBFC0'0000u;
    u64  hi       = 0, lo = 0;
    u64  hi1      = 0, lo1 = 0;
    u32  sa       = 0;

    f32  fpr[32]  = {};
    f32  fpAcc    = 0.f;
    u32  fcr31    = 0;

    u32  cop0[32] = {};

    bool inDelaySlot = false;
    u32  nextPC      = 0xBFC0'0004u;

    u64  cycles   = 0;

    // References (not owned)
    Bus* bus  = nullptr;
    VU*  vu0  = nullptr;
    VU*  vu1  = nullptr;

    EE() {
        cop0[COP0_PRId]   = 0x2E20u;
        cop0[COP0_Status] = 0x400004u;
        cop0[COP0_Config] = 0x440u;
    }

    void reset();
    void step(int count);

    // Execute a single instruction (fetched from bus at current pc)
    void executeOne();

    // Helpers for branch delay slot
    void branchTo(u32 target) {
        inDelaySlot = true;
        nextPC = target;
    }

    void setGPR(int i, u64 v64) {
        if (i) { gpr[i].lo = v64; gpr[i].hi = (u64)(i64)v64 >> 63; }
    }
    void setGPR32(int i, u32 v32) {
        if (i) { gpr[i].lo = (u64)(i64)(i32)v32; gpr[i].hi = gpr[i].lo >> 63; }
    }
    void setGPR64(int i, u64 v64) {
        if (i) { gpr[i].lo = v64; gpr[i].hi = (v64 >> 63); }
    }
    void setGPR128(int i, u128 v) {
        if (i) gpr[i] = v;
    }
    u32 getGPR32(int i) const { return (u32)gpr[i].lo; }
    u64 getGPR64(int i) const { return gpr[i].lo; }
    i64 getGPR64s(int i) const { return (i64)gpr[i].lo; }

private:
    void decode(u32 instr);
    void decodeSpecial(u32 instr);
    void decodeRegImm(u32 instr);
    void decodeCOP0(u32 instr);
    void decodeCOP1(u32 instr);
    void decodeCOP2(u32 instr);
    void decodeMMI(u32 instr);
    void decodeMMI0(u32 instr);
    void decodeMMI1(u32 instr);
    void decodeMMI2(u32 instr);
    void decodeMMI3(u32 instr);

    void triggerException(int excCode, bool inBranch = false);
    void raiseReservedInstruction();

    // Memory helpers
    u8   lb (u32 a);
    u16  lh (u32 a);
    u32  lw (u32 a);
    u64  ld (u32 a);
    u128 lq (u32 a);
    void sb (u32 a, u8  v);
    void sh (u32 a, u16 v);
    void sw (u32 a, u32 v);
    void sd (u32 a, u64 v);
    void sq (u32 a, u128 v);
};
