#include "ee.h"
#include "bus.h"
#include "vu.h"
#include <cstring>

// ── Reset ─────────────────────────────────────────────────────────────────────

void EE::reset() {
    memset(gpr, 0, sizeof(gpr));
    pc = 0xBFC0'0000u;
    hi = lo = hi1 = lo1 = sa = 0;
    memset(fpr, 0, sizeof(fpr));
    fpAcc = 0.f; fcr31 = 0;
    memset(cop0, 0, sizeof(cop0));
    cop0[COP0_PRId]   = 0x2E20u;
    cop0[COP0_Status] = 0x400004u;
    cop0[COP0_Config] = 0x440u;
    inDelaySlot = false;
    nextPC = pc + 4;
    cycles = 0;
}

// ── Step ──────────────────────────────────────────────────────────────────────

void EE::step(int count) {
    for (int i = 0; i < count; i++) {
        // Check pending interrupt
        if (!(cop0[COP0_Status] & SR_EXL) &&
            !(cop0[COP0_Status] & SR_ERL) &&
             (cop0[COP0_Status] & SR_IE)  &&
             (cop0[COP0_Status] & SR_EIE)) {
            // Interrupt pending check (IM bits vs IP bits in Cause)
            u32 im = (cop0[COP0_Status] >> 8) & 0xFF;
            u32 ip = (cop0[COP0_Cause]  >> 8) & 0xFF;
            if (im & ip) {
                triggerException(0);
                continue;
            }
        }
        executeOne();
        cycles++;
    }
}

void EE::executeOne() {
    u32 instr = bus->read32(pc);
    if (inDelaySlot) {
        pc = nextPC;
        inDelaySlot = false;
    } else {
        pc += 4;
    }
    decode(instr);
}

// ── Exception ─────────────────────────────────────────────────────────────────

void EE::triggerException(int excCode, bool inBranch) {
    if (!(cop0[COP0_Status] & SR_EXL)) {
        cop0[COP0_EPC] = inBranch ? pc - 4 : pc;
        if (inBranch) cop0[COP0_Cause] |= (1u << 31);
        else          cop0[COP0_Cause] &= ~(1u << 31);
    }
    cop0[COP0_Cause] = (cop0[COP0_Cause] & ~0x7Cu) | ((u32)excCode << 2);
    cop0[COP0_Status] |= SR_EXL;
    inDelaySlot = false;
    // Exception vector
    bool bev = (cop0[COP0_Status] >> 22) & 1;
    pc = bev ? 0xBFC0'0200u : 0x8000'0080u;
    nextPC = pc + 4;
}

// ── Memory helpers ────────────────────────────────────────────────────────────

u8   EE::lb (u32 a) { return bus->read8(a); }
u16  EE::lh (u32 a) { return bus->read16(a); }
u32  EE::lw (u32 a) { return bus->read32(a); }
u64  EE::ld (u32 a) { return bus->read64(a); }
u128 EE::lq (u32 a) { return bus->read128(a & ~15u); }
void EE::sb (u32 a, u8  v) { bus->write8 (a, v); }
void EE::sh (u32 a, u16 v) { bus->write16(a, v); }
void EE::sw (u32 a, u32 v) { bus->write32(a, v); }
void EE::sd (u32 a, u64 v) { bus->write64(a, v); }
void EE::sq (u32 a, u128 v){ bus->write128(a & ~15u, v); }

// ── Instruction decode ────────────────────────────────────────────────────────

void EE::decode(u32 instr) {
    if (instr == 0) return; // NOP (SLL $0, $0, 0)
    int op    = (instr >> 26) & 0x3F;
    int rs    = (instr >> 21) & 0x1F;
    int rt    = (instr >> 16) & 0x1F;
    int rd    = (instr >> 11) & 0x1F;
    int shamt = (instr >>  6) & 0x1F;
    int funct = (instr >>  0) & 0x3F;
    i32 imm16 = (i32)(i16)(u16)(instr & 0xFFFF);
    u32 imm26 = instr & 0x03FF'FFFFu;
    u32 uimm  = instr & 0xFFFFu;

    switch (op) {
    case 0x00: decodeSpecial(instr); return;
    case 0x01: decodeRegImm(instr);  return;

    case 0x02: { // J
        u32 target = (pc & 0xF000'0000u) | (imm26 << 2);
        executeOne(); // delay slot
        pc = target; inDelaySlot = false; nextPC = pc + 4;
        return;
    }
    case 0x03: { // JAL
        u32 target = (pc & 0xF000'0000u) | (imm26 << 2);
        setGPR32(31, pc + 4);
        executeOne(); // delay slot
        pc = target; inDelaySlot = false; nextPC = pc + 4;
        return;
    }

    case 0x04: { // BEQ
        bool taken = (gpr[rs].lo == gpr[rt].lo);
        u32 target = (u32)((i32)pc + (imm16 << 2));
        if (taken) branchTo(target); return;
    }
    case 0x05: { // BNE
        bool taken = (gpr[rs].lo != gpr[rt].lo);
        u32 target = (u32)((i32)pc + (imm16 << 2));
        if (taken) branchTo(target); return;
    }
    case 0x06: { // BLEZ
        bool taken = ((i64)gpr[rs].lo <= 0);
        u32 target = (u32)((i32)pc + (imm16 << 2));
        if (taken) branchTo(target); return;
    }
    case 0x07: { // BGTZ
        bool taken = ((i64)gpr[rs].lo > 0);
        u32 target = (u32)((i32)pc + (imm16 << 2));
        if (taken) branchTo(target); return;
    }

    case 0x08: { // ADDI (trap on overflow, but most code doesn't trap)
        i32 res = (i32)getGPR32(rs) + imm16;
        setGPR32(rt, (u32)res); return;
    }
    case 0x09: { // ADDIU
        setGPR32(rt, (u32)((i32)getGPR32(rs) + imm16)); return;
    }
    case 0x0A: { // SLTI
        setGPR32(rt, (i64)gpr[rs].lo < (i64)imm16 ? 1u : 0u); return;
    }
    case 0x0B: { // SLTIU
        setGPR32(rt, gpr[rs].lo < (u64)(i64)imm16 ? 1u : 0u); return;
    }
    case 0x0C: { setGPR64(rt, gpr[rs].lo & uimm); return; }  // ANDI
    case 0x0D: { setGPR64(rt, gpr[rs].lo | uimm); return; }  // ORI
    case 0x0E: { setGPR64(rt, gpr[rs].lo ^ uimm); return; }  // XORI
    case 0x0F: { setGPR32(rt, (u32)uimm << 16);   return; }  // LUI

    case 0x10: decodeCOP0(instr); return;
    case 0x11: decodeCOP1(instr); return;
    case 0x12: decodeCOP2(instr); return;

    case 0x14: { // BEQL
        bool taken = (gpr[rs].lo == gpr[rt].lo);
        u32 target = (u32)((i32)pc + (imm16 << 2));
        if (taken) branchTo(target); else { pc += 4; } return;
    }
    case 0x15: { // BNEL
        bool taken = (gpr[rs].lo != gpr[rt].lo);
        u32 target = (u32)((i32)pc + (imm16 << 2));
        if (taken) branchTo(target); else { pc += 4; } return;
    }
    case 0x16: { // BLEZL
        bool taken = ((i64)gpr[rs].lo <= 0);
        u32 target = (u32)((i32)pc + (imm16 << 2));
        if (taken) branchTo(target); else { pc += 4; } return;
    }
    case 0x17: { // BGTZL
        bool taken = ((i64)gpr[rs].lo > 0);
        u32 target = (u32)((i32)pc + (imm16 << 2));
        if (taken) branchTo(target); else { pc += 4; } return;
    }

    case 0x18: { // DADDI
        i64 res = (i64)gpr[rs].lo + (i64)imm16;
        setGPR64(rt, (u64)res); return;
    }
    case 0x19: { // DADDIU
        setGPR64(rt, gpr[rs].lo + (u64)(i64)imm16); return;
    }
    case 0x1A: { // LDL (load doubleword left, unaligned)
        u32 a = (u32)(getGPR32(rs) + imm16);
        int sh = (a & 7) * 8;
        u64 mem = ld(a & ~7u);
        u64 mask = ~0uLL << sh;
        setGPR64(rt, (gpr[rt].lo & ~mask) | (mem << (sh & 63)));
        return;
    }
    case 0x1B: { // LDR (load doubleword right, unaligned)
        u32 a = (u32)(getGPR32(rs) + imm16);
        int sh = (7 - (a & 7)) * 8;
        u64 mem = ld(a & ~7u);
        u64 mask = ~0uLL >> sh;
        setGPR64(rt, (gpr[rt].lo & ~mask) | (mem >> (sh & 63)));
        return;
    }

    case 0x1C: decodeMMI(instr); return;
    case 0x1E: { // LQ
        u128 v = lq((u32)((i32)getGPR32(rs) + imm16));
        setGPR128(rt, v); return;
    }
    case 0x1F: { // SQ
        sq((u32)((i32)getGPR32(rs) + imm16), gpr[rt]); return;
    }

    case 0x20: { setGPR32(rt, (u32)(i32)(i8) lb((u32)((i32)getGPR32(rs)+imm16))); return; } // LB
    case 0x21: { setGPR32(rt, (u32)(i32)(i16)lh((u32)((i32)getGPR32(rs)+imm16))); return; } // LH
    case 0x22: { // LWL
        u32 a = (u32)((i32)getGPR32(rs) + imm16);
        int sh = (a & 3) * 8;
        u32 mem = lw(a & ~3u);
        u32 mask = ~0u << sh;
        setGPR32(rt, (getGPR32(rt) & ~mask) | (mem << sh));
        return;
    }
    case 0x23: { setGPR32(rt, lw((u32)((i32)getGPR32(rs)+imm16))); return; } // LW
    case 0x24: { setGPR32(rt, (u32)lb((u32)((i32)getGPR32(rs)+imm16))); return; }  // LBU
    case 0x25: { setGPR32(rt, (u32)lh((u32)((i32)getGPR32(rs)+imm16))); return; }  // LHU
    case 0x26: { // LWR
        u32 a = (u32)((i32)getGPR32(rs) + imm16);
        int sh = (3 - (a & 3)) * 8;
        u32 mem = lw(a & ~3u);
        u32 mask = ~0u >> sh;
        setGPR32(rt, (getGPR32(rt) & ~mask) | (mem >> sh));
        return;
    }
    case 0x27: { // LWU
        setGPR64(rt, (u64)lw((u32)((i32)getGPR32(rs)+imm16))); return;
    }

    case 0x28: { sb((u32)((i32)getGPR32(rs)+imm16), (u8)getGPR32(rt));  return; } // SB
    case 0x29: { sh((u32)((i32)getGPR32(rs)+imm16), (u16)getGPR32(rt)); return; } // SH
    case 0x2A: { // SWL
        u32 a = (u32)((i32)getGPR32(rs) + imm16);
        int sh = (a & 3) * 8;
        u32 mem = lw(a & ~3u);
        u32 mask = ~0u >> (24 - sh);
        sw(a & ~3u, (mem & ~mask) | (getGPR32(rt) >> (24 - sh)));
        return;
    }
    case 0x2B: { sw((u32)((i32)getGPR32(rs)+imm16), getGPR32(rt));  return; } // SW
    case 0x2C: { // SDL
        u32 a = (u32)((i32)getGPR32(rs) + imm16);
        int sh = (a & 7) * 8;
        u64 mem = ld(a & ~7u);
        u64 val = gpr[rt].lo;
        u64 mask = ~0uLL >> (56 - sh);
        sd(a & ~7u, (mem & ~mask) | (val >> (56 - sh)));
        return;
    }
    case 0x2D: { // SDR
        u32 a = (u32)((i32)getGPR32(rs) + imm16);
        int sh = (7 - (a & 7)) * 8;
        u64 mem = ld(a & ~7u);
        u64 val = gpr[rt].lo;
        u64 mask = ~0uLL << sh;
        sd(a & ~7u, (mem & ~mask) | (val << sh));
        return;
    }
    case 0x2E: { // SWR
        u32 a = (u32)((i32)getGPR32(rs) + imm16);
        int sh = (3 - (a & 3)) * 8;
        u32 mem = lw(a & ~3u);
        u32 mask = ~0u << (sh & 31);
        sw(a & ~3u, (mem & ~mask) | (getGPR32(rt) << (sh & 31)));
        return;
    }
    case 0x2F: return; // CACHE — ignored

    case 0x31: { // LWC1 (load to FPU)
        u32 v = lw((u32)((i32)getGPR32(rs)+imm16));
        memcpy(&fpr[rt & 31], &v, 4); return;
    }
    case 0x37: { setGPR64(rt, ld((u32)((i32)getGPR32(rs)+imm16))); return; } // LD
    case 0x39: { // SWC1
        u32 v; memcpy(&v, &fpr[rt & 31], 4);
        sw((u32)((i32)getGPR32(rs)+imm16), v); return;
    }
    case 0x3F: { sd((u32)((i32)getGPR32(rs)+imm16), gpr[rt].lo); return; } // SD

    default:
        // Unknown opcode — ignore
        break;
    }

    (void)shamt; (void)funct; (void)rd;
}

// ── SPECIAL (R-type) ──────────────────────────────────────────────────────────

void EE::decodeSpecial(u32 instr) {
    int rs = (instr >> 21) & 0x1F;
    int rt = (instr >> 16) & 0x1F;
    int rd = (instr >> 11) & 0x1F;
    u32 sh = (instr >>  6) & 0x1F;
    int fn = (instr >>  0) & 0x3F;

    switch (fn) {
    case 0x00: setGPR32(rd, getGPR32(rt) << sh); return; // SLL
    case 0x02: setGPR32(rd, getGPR32(rt) >> sh); return; // SRL
    case 0x03: setGPR32(rd, (u32)((i32)getGPR32(rt) >> sh)); return; // SRA
    case 0x04: setGPR32(rd, getGPR32(rt) << (gpr[rs].lo & 31)); return; // SLLV
    case 0x06: setGPR32(rd, getGPR32(rt) >> (gpr[rs].lo & 31)); return; // SRLV
    case 0x07: setGPR32(rd, (u32)((i32)getGPR32(rt) >> (gpr[rs].lo & 31))); return; // SRAV
    case 0x08: { // JR
        u32 target = getGPR32(rs);
        executeOne();
        pc = target; inDelaySlot = false; nextPC = pc + 4;
        return;
    }
    case 0x09: { // JALR
        u32 target = getGPR32(rs);
        setGPR32(rd, pc + 4);
        executeOne();
        pc = target; inDelaySlot = false; nextPC = pc + 4;
        return;
    }
    case 0x0C: triggerException(8); return; // SYSCALL
    case 0x0D: triggerException(9); return; // BREAK
    case 0x0F: return; // SYNC
    case 0x10: setGPR64(rd, hi);  return; // MFHI
    case 0x11: hi = gpr[rs].lo;   return; // MTHI
    case 0x12: setGPR64(rd, lo);  return; // MFLO
    case 0x13: lo = gpr[rs].lo;   return; // MTLO
    case 0x14: setGPR64(rd, gpr[rt].lo << (gpr[rs].lo & 63)); return; // DSLLV
    case 0x16: setGPR64(rd, gpr[rt].lo >> (gpr[rs].lo & 63)); return; // DSRLV
    case 0x17: setGPR64(rd, (u64)((i64)gpr[rt].lo >> (gpr[rs].lo & 63))); return; // DSRAV
    case 0x18: { // MULT
        i64 r = (i64)(i32)getGPR32(rs) * (i64)(i32)getGPR32(rt);
        lo = (u64)(i64)(i32)(u32)r; hi = (u64)(i64)(i32)(u32)(r >> 32);
        if (rd) setGPR64(rd, lo);
        return;
    }
    case 0x19: { // MULTU
        u64 r = (u64)getGPR32(rs) * (u64)getGPR32(rt);
        lo = (u64)(i64)(i32)(u32)r; hi = (u64)(i64)(i32)(u32)(r >> 32);
        if (rd) setGPR64(rd, lo);
        return;
    }
    case 0x1A: { // DIV
        i32 n = (i32)getGPR32(rs), d = (i32)getGPR32(rt);
        if (d) { lo = sign_extend32((u32)(n/d)); hi = sign_extend32((u32)(n%d)); }
        return;
    }
    case 0x1B: { // DIVU
        u32 n = getGPR32(rs), d = getGPR32(rt);
        if (d) { lo = sign_extend32(n/d); hi = sign_extend32(n%d); }
        return;
    }
    case 0x20: setGPR32(rd, getGPR32(rs) + getGPR32(rt)); return; // ADD
    case 0x21: setGPR32(rd, getGPR32(rs) + getGPR32(rt)); return; // ADDU
    case 0x22: setGPR32(rd, getGPR32(rs) - getGPR32(rt)); return; // SUB
    case 0x23: setGPR32(rd, getGPR32(rs) - getGPR32(rt)); return; // SUBU
    case 0x24: setGPR64(rd, gpr[rs].lo & gpr[rt].lo); return; // AND
    case 0x25: setGPR64(rd, gpr[rs].lo | gpr[rt].lo); return; // OR
    case 0x26: setGPR64(rd, gpr[rs].lo ^ gpr[rt].lo); return; // XOR
    case 0x27: setGPR64(rd, ~(gpr[rs].lo | gpr[rt].lo)); return; // NOR
    case 0x28: setGPR32(rd, sa); return; // MFSA
    case 0x29: sa = gpr[rs].lo & 0x1Fu; return; // MTSA
    case 0x2A: setGPR32(rd, (i64)gpr[rs].lo < (i64)gpr[rt].lo ? 1 : 0); return; // SLT
    case 0x2B: setGPR32(rd, gpr[rs].lo < gpr[rt].lo ? 1 : 0); return; // SLTU
    case 0x2C: setGPR64(rd, gpr[rs].lo + gpr[rt].lo); return; // DADD
    case 0x2D: setGPR64(rd, gpr[rs].lo + gpr[rt].lo); return; // DADDU
    case 0x2E: setGPR64(rd, gpr[rs].lo - gpr[rt].lo); return; // DSUB
    case 0x2F: setGPR64(rd, gpr[rs].lo - gpr[rt].lo); return; // DSUBU
    case 0x38: setGPR64(rd, gpr[rt].lo << sh); return; // DSLL
    case 0x3A: setGPR64(rd, gpr[rt].lo >> sh); return; // DSRL
    case 0x3B: setGPR64(rd, (u64)((i64)gpr[rt].lo >> sh)); return; // DSRA
    case 0x3C: setGPR64(rd, gpr[rt].lo << (sh + 32)); return; // DSLL32
    case 0x3E: setGPR64(rd, gpr[rt].lo >> (sh + 32)); return; // DSRL32
    case 0x3F: setGPR64(rd, (u64)((i64)gpr[rt].lo >> (sh + 32))); return; // DSRA32
    default: break;
    }
}

// ── REGIMM ────────────────────────────────────────────────────────────────────

void EE::decodeRegImm(u32 instr) {
    int rs = (instr >> 21) & 0x1F;
    int rt = (instr >> 16) & 0x1F;
    i32 off = (i32)(i16)(instr & 0xFFFF);
    u32 target = (u32)((i32)pc + (off << 2));
    i64 rsv = (i64)gpr[rs].lo;

    switch (rt) {
    case 0x00: if (rsv < 0)  branchTo(target); return; // BLTZ
    case 0x01: if (rsv >= 0) branchTo(target); return; // BGEZ
    case 0x02: if (rsv < 0)  branchTo(target); else pc += 4; return; // BLTZL
    case 0x03: if (rsv >= 0) branchTo(target); else pc += 4; return; // BGEZL
    case 0x10: setGPR32(31, pc); if (rsv < 0)  branchTo(target); return; // BLTZAL
    case 0x11: setGPR32(31, pc); if (rsv >= 0) branchTo(target); return; // BGEZAL
    case 0x12: setGPR32(31, pc); if (rsv < 0)  branchTo(target); else pc += 4; return; // BLTZALL
    case 0x13: setGPR32(31, pc); if (rsv >= 0) branchTo(target); else pc += 4; return; // BGEZALL
    case 0x18: sa = (u32)(((u64)(i64)gpr[rs].lo >> 32) & 0x1Fu); return; // MTSAB
    case 0x19: sa = (u32)(((u64)(i64)gpr[rs].lo >> 16) & 0x1Fu); return; // MTSAH
    default: break;
    }
}

// ── COP0 ─────────────────────────────────────────────────────────────────────

void EE::decodeCOP0(u32 instr) {
    int rs = (instr >> 21) & 0x1F;
    int rt = (instr >> 16) & 0x1F;
    int rd = (instr >> 11) & 0x1F;
    int fn = instr & 0x3F;

    switch (rs) {
    case 0x00: // MFC0
        setGPR32(rt, cop0[rd & 31]);
        return;
    case 0x04: // MTC0
        if (rd == COP0_Status) cop0[COP0_Status] = getGPR32(rt);
        else if (rd == COP0_Cause) cop0[COP0_Cause] = getGPR32(rt) & 0xB00u;
        else if (rd == COP0_Count) cop0[COP0_Count] = getGPR32(rt);
        else if (rd == COP0_Compare) cop0[COP0_Compare] = getGPR32(rt);
        else cop0[rd & 31] = getGPR32(rt);
        return;
    case 0x10: // CO instructions
        switch (fn) {
        case 0x02: return; // TLBWI (stub)
        case 0x06: return; // TLBWR (stub)
        case 0x08: return; // TLBP  (stub)
        case 0x18: { // ERET
            if (cop0[COP0_Status] & SR_ERL) {
                pc = 0xBFC0'0000u; // ErrorEPC stub
                cop0[COP0_Status] &= ~SR_ERL;
            } else {
                pc = cop0[COP0_EPC];
                cop0[COP0_Status] &= ~SR_EXL;
            }
            inDelaySlot = false;
            nextPC = pc + 4;
            return;
        }
        case 0x38: cop0[COP0_Status] |= SR_EIE; return; // EI
        case 0x39: cop0[COP0_Status] &= ~SR_EIE; return; // DI
        default: return;
        }
    default: return;
    }
    (void)rt;
}

// ── COP1 (FPU) ───────────────────────────────────────────────────────────────

void EE::decodeCOP1(u32 instr) {
    int rs = (instr >> 21) & 0x1F;
    int rt = (instr >> 16) & 0x1F;
    int rd = (instr >> 11) & 0x1F; // fs field for FPU
    int fn = instr & 0x3F;
    int fs = (instr >> 11) & 0x1F;
    int ft = rt;
    int fd = (instr >>  6) & 0x1F;

    switch (rs) {
    case 0x00: { u32 v; memcpy(&v, &fpr[rd], 4); setGPR32(rt, v); return; } // MFC1
    case 0x04: { u32 v = getGPR32(rt); memcpy(&fpr[rd], &v, 4); return; }   // MTC1
    case 0x08: { // BC1
        bool nd   = (instr >> 17) & 1;
        bool tf   = (instr >> 16) & 1;
        bool cond = (fcr31 >> 23) & 1;
        bool taken = (tf ? cond : !cond);
        i32  off = (i32)(i16)(instr & 0xFFFF);
        u32  target = (u32)((i32)pc + (off << 2));
        if (taken) branchTo(target); else if (nd) pc += 4;
        return;
    }
    case 0x10: // S format (single)
        switch (fn) {
        case 0x00: fpr[fd] = fpr[fs] + fpr[ft]; return; // ADD.S
        case 0x01: fpr[fd] = fpr[fs] - fpr[ft]; return; // SUB.S
        case 0x02: fpr[fd] = fpr[fs] * fpr[ft]; return; // MUL.S
        case 0x03: fpr[fd] = (fpr[ft] != 0.f) ? fpr[fs] / fpr[ft] : 0.f; return; // DIV.S
        case 0x04: fpr[fd] = std::sqrt(std::abs(fpr[fs])); return; // SQRT.S
        case 0x05: fpr[fd] = std::abs(fpr[fs]); return; // ABS.S
        case 0x06: fpr[fd] = fpr[fs]; return; // MOV.S
        case 0x07: fpr[fd] = -fpr[fs]; return; // NEG.S
        case 0x16: fpr[fd] = std::sqrt(std::abs(fpr[fs])); return; // RSQRT.S
        case 0x18: fpAcc = fpr[fs] * fpr[ft]; return; // ADDA.S
        case 0x19: fpAcc = fpr[fs] - fpr[ft]; return; // SUBA.S
        case 0x1A: fpAcc = fpr[fs] * fpr[ft]; return; // MULA.S
        case 0x1C: fpAcc += fpr[fs] * fpr[ft]; return; // MADD.S (ACC += FS*FT)
        case 0x1D: fpAcc -= fpr[fs] * fpr[ft]; return; // MSUB.S
        case 0x1E: fpr[fd] = fpAcc + fpr[fs] * fpr[ft]; return; // MADDA.S
        case 0x1F: fpr[fd] = fpAcc - fpr[fs] * fpr[ft]; return; // MSUBA.S
        case 0x24: { // CVT.W.S
            i32 v = fpr[fs] != fpr[fs] ? 0 : (i32)clampf(fpr[fs], -2147483648.f, 2147483647.f);
            memcpy(&fpr[fd], &v, 4); return;
        }
        case 0x28: { // C.F.S (false)
            fcr31 &= ~(1u << 23); return;
        }
        case 0x29: { // C.UN.S
            bool r = fpr[fs] != fpr[fs] || fpr[ft] != fpr[ft];
            if (r) fcr31 |= (1u<<23); else fcr31 &= ~(1u<<23); return;
        }
        case 0x2A: { // C.EQ.S
            bool r = fpr[fs] == fpr[ft];
            if (r) fcr31 |= (1u<<23); else fcr31 &= ~(1u<<23); return;
        }
        case 0x2C: { // C.LT.S
            bool r = fpr[fs] < fpr[ft];
            if (r) fcr31 |= (1u<<23); else fcr31 &= ~(1u<<23); return;
        }
        case 0x2E: { // C.LE.S
            bool r = fpr[fs] <= fpr[ft];
            if (r) fcr31 |= (1u<<23); else fcr31 &= ~(1u<<23); return;
        }
        default: break;
        }
        return;
    case 0x14: // W format (integer to float)
        switch (fn) {
        case 0x20: { i32 v; memcpy(&v, &fpr[fs], 4); fpr[fd] = (f32)v; return; } // CVT.S.W
        default: break;
        }
        return;
    default: return;
    }
    (void)rt;
}

// ── COP2 (VU0 macro mode) ─────────────────────────────────────────────────────

void EE::decodeCOP2(u32 instr) {
    if (!vu0) return;
    int rs = (instr >> 21) & 0x1F;
    int rt = (instr >> 16) & 0x1F;
    int id = (instr >> 11) & 0x1F; // VF register index

    switch (rs) {
    case 0x01: { // QMFC2
        u128 v;
        v.lo = ((u64)vu0->vf[id & 31].x) | ((u64)vu0->vf[id & 31].y << 32);
        u32 xi, yi, zi, wi;
        memcpy(&xi, &vu0->vf[id&31].x, 4);
        memcpy(&yi, &vu0->vf[id&31].y, 4);
        memcpy(&zi, &vu0->vf[id&31].z, 4);
        memcpy(&wi, &vu0->vf[id&31].w, 4);
        v.lo = (u64)xi | ((u64)yi << 32);
        v.hi = (u64)zi | ((u64)wi << 32);
        setGPR128(rt, v);
        return;
    }
    case 0x05: { // QMTC2
        u32 xi = getGPR32(rt); // simplified: lower 32 bits
        vu0->vf[id&31].x = *(f32*)&xi;
        return;
    }
    default:
        // Forward upper+lower encoded VU0 micro instructions
        vu0->executeUpper(instr); // private but we call run() instead
        break;
    }
}

// ── MMI ──────────────────────────────────────────────────────────────────────

void EE::decodeMMI(u32 instr) {
    int rs    = (instr >> 21) & 0x1F;
    int rt    = (instr >> 16) & 0x1F;
    int rd    = (instr >> 11) & 0x1F;
    int shamt = (instr >>  6) & 0x1F;
    int fn    = instr & 0x3F;

    switch (fn) {
    case 0x00: { // MADD
        i64 r = (i64)(i32)getGPR32(rs) * (i64)(i32)getGPR32(rt);
        i64 acc = (i64)(((u64)(u32)lo) | ((u64)(u32)hi << 32));
        acc += r;
        lo = sign_extend32((u32)acc); hi = sign_extend32((u32)(acc >> 32));
        if (rd) setGPR64(rd, lo); return;
    }
    case 0x01: { // MADDU
        u64 r = (u64)getGPR32(rs) * (u64)getGPR32(rt);
        u64 acc = ((u64)(u32)lo) | ((u64)(u32)hi << 32);
        acc += r;
        lo = sign_extend32((u32)acc); hi = sign_extend32((u32)(acc >> 32));
        if (rd) setGPR64(rd, lo); return;
    }
    case 0x04: { // PLZCW
        u32 v0 = getGPR32(rs), v1 = (u32)(gpr[rs].lo >> 32);
        u32 r0 = count_leading_zeros(v0); if (r0 == 0) r0 = count_leading_zeros(~v0);
        u32 r1 = count_leading_zeros(v1); if (r1 == 0) r1 = count_leading_zeros(~v1);
        if (rd) { gpr[rd].lo = (u64)r0 | ((u64)r1 << 32); gpr[rd].hi = 0; }
        return;
    }
    case 0x08: decodeMMI0(instr); return;
    case 0x09: decodeMMI2(instr); return;
    case 0x10: if (rd) setGPR64(rd, hi1); return; // MFHI1
    case 0x11: hi1 = gpr[rs].lo; return; // MTHI1
    case 0x12: if (rd) setGPR64(rd, lo1); return; // MFLO1
    case 0x13: lo1 = gpr[rs].lo; return; // MTLO1
    case 0x18: { // MULT1
        i64 r = (i64)(i32)getGPR32(rs) * (i64)(i32)getGPR32(rt);
        lo1 = sign_extend32((u32)r); hi1 = sign_extend32((u32)(r >> 32));
        if (rd) setGPR64(rd, lo1); return;
    }
    case 0x19: { // MULTU1
        u64 r = (u64)getGPR32(rs) * (u64)getGPR32(rt);
        lo1 = sign_extend32((u32)r); hi1 = sign_extend32((u32)(r >> 32));
        if (rd) setGPR64(rd, lo1); return;
    }
    case 0x1A: { // DIV1
        i32 n = (i32)getGPR32(rs), d = (i32)getGPR32(rt);
        if (d) { lo1 = sign_extend32((u32)(n/d)); hi1 = sign_extend32((u32)(n%d)); }
        return;
    }
    case 0x1B: { // DIVU1
        u32 n = getGPR32(rs), d = getGPR32(rt);
        if (d) { lo1 = sign_extend32(n/d); hi1 = sign_extend32(n%d); }
        return;
    }
    case 0x28: decodeMMI1(instr); return;
    case 0x29: decodeMMI3(instr); return;
    case 0x30: { // PMFHL (various sub)
        u32 sub = (instr >> 6) & 0x1F;
        if (!rd) return;
        switch (sub) {
        case 0: gpr[rd] = u128(lo | (hi << 32), lo1 | (hi1 << 32)); break; // LW
        case 1: gpr[rd] = u128((u64)(u32)lo, (u64)(u32)hi); break; // UW
        default: break;
        }
        return;
    }
    case 0x31: { // PMTHL.LW
        lo = gpr[rs].lo & 0xFFFF'FFFFu;
        hi = (gpr[rs].lo >> 32) & 0xFFFF'FFFFu;
        return;
    }
    case 0x34: { // PSLLH
        u128 r{};
        for (int i = 0; i < 8; i++) {
            u64& half = (i < 4) ? r.lo : r.hi;
            u64 src   = (i < 4) ? gpr[rt].lo : gpr[rt].hi;
            int off = (i & 3) * 16;
            u16 v = (u16)(src >> off) << (shamt & 15);
            half |= (u64)v << off;
        }
        setGPR128(rd, r); return;
    }
    case 0x36: { // PSRLH
        u128 r{};
        for (int i = 0; i < 8; i++) {
            u64& half = (i < 4) ? r.lo : r.hi;
            u64 src   = (i < 4) ? gpr[rt].lo : gpr[rt].hi;
            int off = (i & 3) * 16;
            u16 v = (u16)(src >> off) >> (shamt & 15);
            half |= (u64)v << off;
        }
        setGPR128(rd, r); return;
    }
    case 0x37: { // PSRAH
        u128 r{};
        for (int i = 0; i < 8; i++) {
            u64& half = (i < 4) ? r.lo : r.hi;
            u64 src   = (i < 4) ? gpr[rt].lo : gpr[rt].hi;
            int off = (i & 3) * 16;
            i16 v = (i16)(src >> off) >> (shamt & 15);
            half |= (u64)(u16)v << off;
        }
        setGPR128(rd, r); return;
    }
    case 0x3C: { // PSLLW
        u128 r{ gpr[rt].lo << (shamt & 31), gpr[rt].hi << (shamt & 31) };
        setGPR128(rd, r); return;
    }
    case 0x3E: { // PSRLW
        u128 r{ gpr[rt].lo >> (shamt & 31), gpr[rt].hi >> (shamt & 31) };
        setGPR128(rd, r); return;
    }
    case 0x3F: { // PSRAW
        u128 r{
            (u64)((i64)gpr[rt].lo >> (shamt & 31)),
            (u64)((i64)gpr[rt].hi >> (shamt & 31))
        };
        setGPR128(rd, r); return;
    }
    default: break;
    }
    (void)shamt;
}

void EE::decodeMMI0(u32 instr) {
    int rs = (instr >> 21) & 0x1F, rt = (instr >> 16) & 0x1F, rd = (instr >> 11) & 0x1F;
    int sub = (instr >> 6) & 0x1F;
    if (!rd) return;
    const u128& a = gpr[rs]; const u128& b = gpr[rt];

    auto pw = [](u64 a, u64 b, auto op) -> u64 {
        return (u64)(u32)op((u32)a, (u32)b) | ((u64)(u32)op((u32)(a>>32), (u32)(b>>32)) << 32);
    };
    auto ph = [](u64 a, u64 b, auto op) -> u64 {
        u64 r = 0;
        for (int i = 0; i < 4; i++) {
            u16 av = (u16)(a >> (i*16)), bv = (u16)(b >> (i*16));
            r |= (u64)(u16)op(av, bv) << (i*16);
        }
        return r;
    };
    auto pb = [](u64 a, u64 b, auto op) -> u64 {
        u64 r = 0;
        for (int i = 0; i < 8; i++) {
            u8 av = (u8)(a >> (i*8)), bv = (u8)(b >> (i*8));
            r |= (u64)(u8)op(av, bv) << (i*8);
        }
        return r;
    };
    auto satw = [](i64 v) -> u32 { return (u32)(v > 2147483647LL ? 2147483647LL : v < -2147483648LL ? -2147483648LL : v); };
    auto sath = [](i32 v) -> u16 { return (u16)(v > 32767 ? 32767 : v < -32768 ? -32768 : v); };
    auto satb = [](i16 v) -> u8  { return (u8) (v > 127  ? 127  : v < -128  ? -128  : v); };

    switch (sub) {
    case 0x00: setGPR128(rd, u128(pw(a.lo,b.lo,[](u32 x,u32 y){return x+y;}), pw(a.hi,b.hi,[](u32 x,u32 y){return x+y;}))); return; // PADDW
    case 0x01: setGPR128(rd, u128(pw(a.lo,b.lo,[](u32 x,u32 y){return x-y;}), pw(a.hi,b.hi,[](u32 x,u32 y){return x-y;}))); return; // PSUBW
    case 0x02: { // PCGTW
        u128 r{};
        for (int i=0;i<2;i++) { u64 al=(i?a.hi:a.lo),bl=(i?b.hi:b.lo),rl=0;
            for(int j=0;j<2;j++){i32 av=(i32)(al>>(j*32)),bv=(i32)(bl>>(j*32)); rl|=(u64)(av>bv?0xFFFFFFFFu:0u)<<(j*32);} if(i)r.hi=rl; else r.lo=rl; }
        setGPR128(rd,r); return;
    }
    case 0x03: { u128 r{pw(a.lo,b.lo,[](u32 x,u32 y){return std::max(x,y);}),pw(a.hi,b.hi,[](u32 x,u32 y){return std::max(x,y);})}; setGPR128(rd,r); return; } // PMAXW
    case 0x04: setGPR128(rd, u128(ph(a.lo,b.lo,[](u16 x,u16 y){return (u16)(x+y);}), ph(a.hi,b.hi,[](u16 x,u16 y){return (u16)(x+y);}))); return; // PADDH
    case 0x05: setGPR128(rd, u128(ph(a.lo,b.lo,[](u16 x,u16 y){return (u16)(x-y);}), ph(a.hi,b.hi,[](u16 x,u16 y){return (u16)(x-y);}))); return; // PSUBH
    case 0x08: setGPR128(rd, u128(pb(a.lo,b.lo,[](u8 x,u8 y){return (u8)(x+y);}), pb(a.hi,b.hi,[](u8 x,u8 y){return (u8)(x+y);}))); return; // PADDB
    case 0x09: setGPR128(rd, u128(pb(a.lo,b.lo,[](u8 x,u8 y){return (u8)(x-y);}), pb(a.hi,b.hi,[](u8 x,u8 y){return (u8)(x-y);}))); return; // PSUBB
    case 0x10: { // PADDSW (saturate)
        u128 r{};
        auto doHalf = [&](u64 al, u64 bl) -> u64 {
            u64 rl = 0;
            for (int j=0;j<2;j++) {i64 v=(i64)(i32)(al>>(j*32))+(i64)(i32)(bl>>(j*32)); rl|=(u64)satw(v)<<(j*32);}
            return rl;
        };
        r.lo = doHalf(a.lo, b.lo); r.hi = doHalf(a.hi, b.hi);
        setGPR128(rd,r); return;
    }
    case 0x11: { // PSUBSW
        u128 r{}; auto doHalf=[&](u64 al,u64 bl)->u64{ u64 rl=0; for(int j=0;j<2;j++){i64 v=(i64)(i32)(al>>(j*32))-(i64)(i32)(bl>>(j*32)); rl|=(u64)satw(v)<<(j*32);} return rl; };
        r.lo=doHalf(a.lo,b.lo); r.hi=doHalf(a.hi,b.hi); setGPR128(rd,r); return;
    }
    case 0x12: { // PEXTLW: rd = {rt_hi_w1, rs_hi_w1, rt_lo_w0, rs_lo_w0}
        u128 r{ (u64)(u32)a.lo | ((u64)(u32)b.lo << 32), (u64)(u32)(a.lo>>32) | ((u64)(u32)(b.lo>>32) << 32) };
        setGPR128(rd,r); return;
    }
    case 0x13: { // PPACW: pack even words
        u128 r{ (u64)(u32)a.lo | ((u64)(u32)(a.hi) << 32), (u64)(u32)b.lo | ((u64)(u32)(b.hi) << 32) };
        setGPR128(rd,r); return;
    }
    case 0x14: { // PADDSH
        u128 r{}; auto doHalf=[&](u64 al,u64 bl)->u64{ u64 rl=0; for(int j=0;j<4;j++){i32 v=(i32)(i16)(al>>(j*16))+(i32)(i16)(bl>>(j*16)); rl|=(u64)(u16)sath(v)<<(j*16);} return rl; };
        r.lo=doHalf(a.lo,b.lo); r.hi=doHalf(a.hi,b.hi); setGPR128(rd,r); return;
    }
    case 0x15: { // PSUBSH
        u128 r{}; auto doHalf=[&](u64 al,u64 bl)->u64{ u64 rl=0; for(int j=0;j<4;j++){i32 v=(i32)(i16)(al>>(j*16))-(i32)(i16)(bl>>(j*16)); rl|=(u64)(u16)sath(v)<<(j*16);} return rl; };
        r.lo=doHalf(a.lo,b.lo); r.hi=doHalf(a.hi,b.hi); setGPR128(rd,r); return;
    }
    case 0x16: { // PEXTLH
        u128 r{ (u64)(u16)a.lo|((u64)(u16)b.lo<<16)|((u64)(u16)(a.lo>>16)<<32)|((u64)(u16)(b.lo>>16)<<48),
                (u64)(u16)(a.lo>>32)|((u64)(u16)(b.lo>>32)<<16)|((u64)(u16)(a.lo>>48)<<32)|((u64)(u16)(b.lo>>48)<<48) };
        setGPR128(rd,r); return;
    }
    case 0x17: { // PPACH
        u128 r{}; u64 rl=0,rh=0;
        for(int i=0;i<4;i++){rl|=(u64)(u16)(a.lo>>(i*16))<<(i*16);} // wrong, fix below
        rl = (u64)(u16)a.lo | ((u64)(u16)(a.lo>>32)<<16) | ((u64)(u16)a.hi<<32) | ((u64)(u16)(a.hi>>32)<<48);
        rh = (u64)(u16)b.lo | ((u64)(u16)(b.lo>>32)<<16) | ((u64)(u16)b.hi<<32) | ((u64)(u16)(b.hi>>32)<<48);
        r = {rl,rh}; setGPR128(rd,r); return;
    }
    case 0x18: { // PADDSB
        u128 r{}; auto doHalf=[&](u64 al,u64 bl)->u64{ u64 rl=0; for(int j=0;j<8;j++){i16 v=(i16)(i8)(al>>(j*8))+(i16)(i8)(bl>>(j*8)); rl|=(u64)(u8)satb(v)<<(j*8);} return rl; };
        r.lo=doHalf(a.lo,b.lo); r.hi=doHalf(a.hi,b.hi); setGPR128(rd,r); return;
    }
    case 0x19: { // PSUBSB
        u128 r{}; auto doHalf=[&](u64 al,u64 bl)->u64{ u64 rl=0; for(int j=0;j<8;j++){i16 v=(i16)(i8)(al>>(j*8))-(i16)(i8)(bl>>(j*8)); rl|=(u64)(u8)satb(v)<<(j*8);} return rl; };
        r.lo=doHalf(a.lo,b.lo); r.hi=doHalf(a.hi,b.hi); setGPR128(rd,r); return;
    }
    case 0x1A: { // PEXTLB
        u128 r{ (u64)(u8)a.lo|((u64)(u8)b.lo<<8)|((u64)(u8)(a.lo>>8)<<16)|((u64)(u8)(b.lo>>8)<<24)|
                ((u64)(u8)(a.lo>>16)<<32)|((u64)(u8)(b.lo>>16)<<40)|((u64)(u8)(a.lo>>24)<<48)|((u64)(u8)(b.lo>>24)<<56),
                (u64)(u8)(a.lo>>32)|((u64)(u8)(b.lo>>32)<<8)|((u64)(u8)(a.lo>>40)<<16)|((u64)(u8)(b.lo>>40)<<24)|
                ((u64)(u8)(a.lo>>48)<<32)|((u64)(u8)(b.lo>>48)<<40)|((u64)(u8)(a.lo>>56)<<48)|((u64)(u8)(b.lo>>56)<<56) };
        setGPR128(rd,r); return;
    }
    case 0x1B: { // PPACB — pack low bytes
        u64 rl=0,rh=0;
        for(int i=0;i<8;i++) rl|=(u64)(u8)(a.lo>>(i*8))<<(i*8); // wrong but close
        rl=0; for(int i=0;i<4;i++) rl|=(u64)(u8)(a.lo>>(i*16))<<(i*8);
        rl|=(u64)(u8)(a.hi>>(0*16))<<(4*8); rl|=(u64)(u8)(a.hi>>(1*16))<<(5*8);
        rl|=(u64)(u8)(a.hi>>(2*16))<<(6*8); rl|=(u64)(u8)(a.hi>>(3*16))<<(7*8);
        rh=0; for(int i=0;i<4;i++) rh|=(u64)(u8)(b.lo>>(i*16))<<(i*8);
        rh|=(u64)(u8)(b.hi>>(0*16))<<(4*8); rh|=(u64)(u8)(b.hi>>(1*16))<<(5*8);
        rh|=(u64)(u8)(b.hi>>(2*16))<<(6*8); rh|=(u64)(u8)(b.hi>>(3*16))<<(7*8);
        setGPR128(rd,u128(rl,rh)); return;
    }
    default: break;
    }
}

void EE::decodeMMI1(u32 instr) {
    int rs = (instr>>21)&0x1F, rt=(instr>>16)&0x1F, rd=(instr>>11)&0x1F;
    int sub = (instr>>6)&0x1F;
    if (!rd) return;
    const u128& a=gpr[rs]; const u128& b=gpr[rt];

    switch (sub) {
    case 0x01: { // PABSW
        u128 r{};
        for(int i=0;i<2;i++){u64& rl=(i?r.hi:r.lo);u64 sl=(i?a.hi:a.lo);
            for(int j=0;j<2;j++){i32 v=(i32)(sl>>(j*32)); rl|=(u64)(u32)std::abs(v)<<(j*32);}}
        setGPR128(rd,r); return;
    }
    case 0x03: { // PMINW (signed)
        u128 r{};
        auto pw=[](u64 a,u64 b)->u64{ return (u64)(u32)std::min((i32)(u32)a,(i32)(u32)b)|((u64)(u32)std::min((i32)(u32)(a>>32),(i32)(u32)(b>>32))<<32); };
        r.lo=pw(a.lo,b.lo); r.hi=pw(a.hi,b.hi); setGPR128(rd,r); return;
    }
    case 0x05: { // PABSH
        u128 r{};
        for(int k=0;k<2;k++){u64& rl=(k?r.hi:r.lo);u64 sl=(k?a.hi:a.lo);
            for(int j=0;j<4;j++){i16 v=(i16)(sl>>(j*16));rl|=(u64)(u16)std::abs((int)v)<<(j*16);}}
        setGPR128(rd,r); return;
    }
    case 0x07: { // PMINH (signed)
        u128 r{};
        auto ph=[](u64 a,u64 b)->u64{ u64 r=0; for(int j=0;j<4;j++){i16 av=(i16)(a>>(j*16)),bv=(i16)(b>>(j*16)); r|=(u64)(u16)std::min(av,bv)<<(j*16);} return r; };
        r.lo=ph(a.lo,b.lo); r.hi=ph(a.hi,b.hi); setGPR128(rd,r); return;
    }
    case 0x10: { // PCEQW
        u128 r{};
        auto pw=[](u64 a,u64 b)->u64{ return ((u32)a==(u32)b?0xFFFFFFFFull:0ull)|(((u32)(a>>32)==(u32)(b>>32)?0xFFFFFFFFull:0ull)<<32); };
        r.lo=pw(a.lo,b.lo); r.hi=pw(a.hi,b.hi); setGPR128(rd,r); return;
    }
    case 0x11: { // PEXTRW
        u128 r{ (u64)(u32)(a.lo>>32)|((u64)(u32)(a.hi>>32)<<32), (u64)(u32)b.lo|((u64)(u32)(b.hi)<<32) };
        setGPR128(rd,r); return;
    }
    case 0x14: { // PCEQH
        u128 r{};
        auto ph=[](u64 a,u64 b)->u64{ u64 r=0; for(int j=0;j<4;j++){bool eq=(u16)(a>>(j*16))==(u16)(b>>(j*16)); r|=(u64)(eq?0xFFFFull:0ull)<<(j*16);} return r; };
        r.lo=ph(a.lo,b.lo); r.hi=ph(a.hi,b.hi); setGPR128(rd,r); return;
    }
    case 0x18: { // PCEQB
        u128 r{};
        auto pb=[](u64 a,u64 b)->u64{ u64 r=0; for(int j=0;j<8;j++){bool eq=(u8)(a>>(j*8))==(u8)(b>>(j*8)); r|=(u64)(eq?0xFFull:0ull)<<(j*8);} return r; };
        r.lo=pb(a.lo,b.lo); r.hi=pb(a.hi,b.hi); setGPR128(rd,r); return;
    }
    default: break;
    }
    (void)a; (void)b;
}

void EE::decodeMMI2(u32 instr) {
    int rs=(instr>>21)&0x1F, rt=(instr>>16)&0x1F, rd=(instr>>11)&0x1F;
    int sub=(instr>>6)&0x1F;
    const u128& a=gpr[rs]; const u128& b=gpr[rt];

    switch (sub) {
    case 0x00: { // PMADDW
        i64 r0=(i64)(i32)(u32)a.lo*(i64)(i32)(u32)b.lo;
        i64 r1=(i64)(i32)(u32)(a.hi)*(i64)(i32)(u32)(b.hi);
        lo=(u64)(i64)(i32)(u32)(lo)+(u64)r0; hi=(u64)(i64)(i32)(u32)(hi)+(u64)r1;
        if(rd) setGPR128(rd,u128(lo,hi)); return;
    }
    case 0x02: { // PSRLVW
        u32 sh0=b.lo&0x1F, sh1=(u32)(b.lo>>32)&0x1F;
        if(rd) setGPR128(rd,u128((u64)(u32)(a.lo>>sh0)|((u64)(u32)((u32)(a.hi)>>sh1)<<32),0)); return;
    }
    case 0x03: { // PSRAVW
        u32 sh0=b.lo&0x1F, sh1=(u32)(b.lo>>32)&0x1F;
        if(rd) setGPR128(rd,u128((u64)(u32)((i32)(u32)a.lo>>sh0)|((u64)(u32)((i32)(u32)(a.hi)>>sh1)<<32),0)); return;
    }
    case 0x04: { // PMSUBW
        i64 r0=(i64)(i32)(u32)a.lo*(i64)(i32)(u32)b.lo;
        i64 r1=(i64)(i32)(u32)(a.hi)*(i64)(i32)(u32)(b.hi);
        lo=(u64)((i64)(u64)(u32)lo-r0); hi=(u64)((i64)(u64)(u32)hi-r1);
        if(rd) setGPR128(rd,u128(lo,hi)); return;
    }
    case 0x08: if(rd) setGPR128(rd,u128(hi,hi1)); return; // PMFHI
    case 0x09: if(rd) setGPR128(rd,u128(lo,lo1)); return; // PMFLO
    case 0x0A: { // PINTH
        u16 s0=(u16)a.lo,s1=(u16)(a.lo>>32),t0=(u16)b.lo,t1=(u16)(b.lo>>32);
        u64 rl=(u64)t0|((u64)s0<<16)|((u64)t1<<32)|((u64)s1<<48);
        if(rd) setGPR128(rd,u128(rl,0)); return;
    }
    case 0x0C: { // PMULTW
        i64 r0=(i64)(i32)(u32)a.lo*(i64)(i32)(u32)b.lo;
        i64 r1=(i64)(i32)(u32)(a.hi)*(i64)(i32)(u32)(b.hi);
        lo=(u64)r0; hi=(u64)r1;
        if(rd) setGPR128(rd,u128(lo,hi)); return;
    }
    case 0x0D: { // PDIVW
        i32 d=(i32)(u32)b.lo; if(d){lo=sign_extend32((u32)((i32)(u32)a.lo/d)); hi=sign_extend32((u32)((i32)(u32)a.lo%d));} return;
    }
    case 0x0E: if(rd) setGPR128(rd,u128(b.lo,a.lo)); return; // PCPYLD
    case 0x12: { // PEXEH: swap halfwords 1 and 2 of each word
        auto do64=[](u64 v)->u64{
            return (v&0xFFFF0000'FFFF0000uLL)|(((v&0xFFFF'0000uLL)>>16)<<0)|(((v&0xFFFFuLL)<<16));
        };
        if(rd) setGPR128(rd,u128(do64(b.lo),do64(b.hi))); return;
    }
    case 0x13: { // PREVH: reverse halfwords
        auto do64=[](u64 v)->u64{
            u16 h0=(v),h1=(v>>16),h2=(v>>32),h3=(v>>48);
            return (u64)h3|((u64)h2<<16)|((u64)h1<<32)|((u64)h0<<48);
        };
        if(rd) setGPR128(rd,u128(do64(b.lo),do64(b.hi))); return;
    }
    case 0x14: { // PMULTH (multiply halfwords, pack to 32-bit results)
        u128 r{};
        for(int i=0;i<4;i++){
            i32 av=(i32)(i16)(a.lo>>(i*16)),bv=(i32)(i16)(b.lo>>(i*16));
            u64 rv=(u64)(u32)(av*bv);
            if(i<2) r.lo|=rv<<(i*32); else r.hi|=rv<<((i-2)*32);
        }
        if(rd) setGPR128(rd,r); return;
    }
    case 0x16: { // PEXEW: swap words 1 and 2 (lo32 ↔ lo32 of hi half)
        if(rd) setGPR128(rd,u128((u64)(u32)(b.hi)|((u64)(u32)(b.lo>>32)<<32),(u64)(u32)(b.lo)|((u64)(u32)(b.hi>>32)<<32))); return;
    }
    case 0x17: { // PROT3W: rotate three 32-bit words
        u32 w0=(u32)b.lo,w1=(u32)(b.lo>>32),w2=(u32)b.hi,w3=(u32)(b.hi>>32);
        if(rd) setGPR128(rd,u128((u64)w3|((u64)w0<<32),(u64)w1|((u64)w2<<32))); return;
    }
    default: break;
    }
    (void)a; (void)b; (void)rd;
}

void EE::decodeMMI3(u32 instr) {
    int rs=(instr>>21)&0x1F, rt=(instr>>16)&0x1F, rd=(instr>>11)&0x1F;
    int sub=(instr>>6)&0x1F;
    const u128& a=gpr[rs]; const u128& b=gpr[rt];

    switch (sub) {
    case 0x00: { // PMADDUW
        u64 r0=(u64)(u32)a.lo*(u64)(u32)b.lo; u64 r1=(u64)(u32)a.hi*(u64)(u32)b.hi;
        lo=sign_extend32((u32)lo)+(u64)r0; hi=sign_extend32((u32)hi)+(u64)r1;
        if(rd) setGPR128(rd,u128(lo,hi)); return;
    }
    case 0x08: hi  = gpr[rs].lo; hi1 = gpr[rs].hi; return; // PMTHI
    case 0x09: lo  = gpr[rs].lo; lo1 = gpr[rs].hi; return; // PMTLO
    case 0x0A: { // PINTEH: interleave halfwords (alternate)
        if(rd){ u64 rl=(u64)(u16)a.lo|((u64)(u16)b.lo<<16)|((u64)(u16)(a.lo>>16)<<32)|((u64)(u16)(b.lo>>16)<<48);
            setGPR128(rd,u128(rl,0)); } return;
    }
    case 0x0C: { // PMULTUW
        u64 r0=(u64)(u32)a.lo*(u64)(u32)b.lo; u64 r1=(u64)(u32)a.hi*(u64)(u32)b.hi;
        lo=(u64)r0; hi=(u64)r1; if(rd) setGPR128(rd,u128(lo,hi)); return;
    }
    case 0x0D: { // PDIVUW
        u32 d=(u32)b.lo; if(d){lo=sign_extend32((u32)a.lo/d); hi=sign_extend32((u32)a.lo%d);} return;
    }
    case 0x0E: if(rd) setGPR128(rd,u128(b.hi,a.hi)); return; // PCPYUD
    case 0x12: { // PEXCH: swap halfwords 1 and 3 of each doubleword
        auto do64=[](u64 v)->u64{
            u16 h0=v,h1=v>>16,h2=v>>32,h3=v>>48;
            return (u64)h0|((u64)h3<<16)|((u64)h2<<32)|((u64)h1<<48);
        };
        if(rd) setGPR128(rd,u128(do64(b.lo),do64(b.hi))); return;
    }
    case 0x13: { // PCPYH: copy halfword 0 to all 4 positions in each doubleword
        auto do64=[](u64 v)->u64{ u16 h=(u16)v; return (u64)h|((u64)h<<16)|((u64)h<<32)|((u64)h<<48); };
        if(rd) setGPR128(rd,u128(do64(b.lo),do64(b.hi))); return;
    }
    case 0x16: { // PEXCW: swap words 0 and 2, 1 and 3
        if(rd) setGPR128(rd,u128((u64)(u32)b.hi|((u64)(u32)(b.hi>>32)<<32),(u64)(u32)b.lo|((u64)(u32)(b.lo>>32)<<32))); return;
    }
    default: break;
    }
    (void)a; (void)b; (void)rs; (void)rt;
}
