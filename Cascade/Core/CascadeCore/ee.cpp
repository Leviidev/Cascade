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
// COP0 Count increments every 2 EE bus cycles.

void EE::step(int count) {
    for (int i = 0; i < count; i++) {
        // Increment COP0 Count every 2 cycles
        if ((cycles & 1) == 0) {
            cop0[COP0_Count]++;
            // Timer-compare interrupt (COP0 bit 7 in IM/IP = IP7)
            if (cop0[COP0_Count] == cop0[COP0_Compare]) {
                cop0[COP0_Cause] |= (1u << 15); // IP7 (timer)
            }
        }

        // Check pending interrupts (IE && !EXL && !ERL && EIE)
        if ((cop0[COP0_Status] & (SR_IE | SR_EXL | SR_ERL | SR_EIE)) == (SR_IE | SR_EIE)) {
            u32 im = (cop0[COP0_Status] >> 8) & 0xFF;
            u32 ip = (cop0[COP0_Cause]  >> 8) & 0xFF;
            if (im & ip) {
                triggerException(0);
                cycles++;
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
        cop0[COP0_EPC] = inBranch ? (pc - 8) : (pc - 4);
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

void EE::raiseReservedInstruction() {
    triggerException(10); // RI
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

// ── Branch helpers ────────────────────────────────────────────────────────────
// All branches use the delay-slot mechanism: set inDelaySlot + nextPC,
// then fall through; the NEXT call to executeOne() will run the delay-slot
// instruction and then advance pc → nextPC.

// Jump/branch absolute — execute delay slot inline then set PC
void EE::jumpAbsolute(u32 target) {
    inDelaySlot = false;
    // Fetch + run the delay-slot instruction at the current pc
    u32 dsInstr = bus->read32(pc);
    pc += 4;
    decode(dsInstr);
    // Now commit the jump
    pc     = target;
    nextPC = target + 4;
}

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

    (void)shamt; (void)funct; (void)rd;

    switch (op) {
    case 0x00: decodeSpecial(instr); return;
    case 0x01: decodeRegImm(instr);  return;

    case 0x02: { // J
        u32 target = (pc & 0xF000'0000u) | (imm26 << 2);
        jumpAbsolute(target);
        return;
    }
    case 0x03: { // JAL
        u32 target = (pc & 0xF000'0000u) | (imm26 << 2);
        u32 retAddr = pc + 4; // return addr = instruction after delay slot
        setGPR32(31, retAddr);
        jumpAbsolute(target);
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

    case 0x08: { // ADDI (trap on overflow — we skip trap for performance)
        setGPR32(rt, (u32)((i32)getGPR32(rs) + imm16)); return;
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

    case 0x14: { // BEQL (branch-likely)
        bool taken = (gpr[rs].lo == gpr[rt].lo);
        u32 target = (u32)((i32)pc + (imm16 << 2));
        if (taken) branchTo(target); else pc += 4; return;
    }
    case 0x15: { // BNEL
        bool taken = (gpr[rs].lo != gpr[rt].lo);
        u32 target = (u32)((i32)pc + (imm16 << 2));
        if (taken) branchTo(target); else pc += 4; return;
    }
    case 0x16: { // BLEZL
        bool taken = ((i64)gpr[rs].lo <= 0);
        u32 target = (u32)((i32)pc + (imm16 << 2));
        if (taken) branchTo(target); else pc += 4; return;
    }
    case 0x17: { // BGTZL
        bool taken = ((i64)gpr[rs].lo > 0);
        u32 target = (u32)((i32)pc + (imm16 << 2));
        if (taken) branchTo(target); else pc += 4; return;
    }

    case 0x18: { // DADDI
        setGPR64(rt, (u64)((i64)gpr[rs].lo + (i64)imm16)); return;
    }
    case 0x19: { // DADDIU
        setGPR64(rt, gpr[rs].lo + (u64)(i64)imm16); return;
    }
    case 0x1A: { // LDL (load doubleword left)
        u32 a = (u32)((i32)getGPR32(rs) + imm16);
        int sh = (a & 7) * 8;
        u64 mem = ld(a & ~7u);
        u64 mask = ~0uLL << sh;
        setGPR64(rt, (gpr[rt].lo & ~mask) | (mem << (sh & 63)));
        return;
    }
    case 0x1B: { // LDR (load doubleword right)
        u32 a = (u32)((i32)getGPR32(rs) + imm16);
        int sh = (7 - (a & 7)) * 8;
        u64 mem = ld(a & ~7u);
        u64 mask = ~0uLL >> (sh & 63);
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
        u32 mask = ~0u >> (sh & 31);
        setGPR32(rt, (getGPR32(rt) & ~mask) | (mem >> (sh & 31)));
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

    case 0x31: { // LWC1
        u32 v = lw((u32)((i32)getGPR32(rs)+imm16));
        memcpy(&fpr[rt & 31], &v, 4); return;
    }
    case 0x36: { // LQC2 (load 128-bit to VU0 VF register)
        if (vu0) {
            u128 v = lq((u32)((i32)getGPR32(rs) + imm16));
            u32 x, y, z, w;
            x = (u32)(v.lo & 0xFFFF'FFFFu);
            y = (u32)(v.lo >> 32);
            z = (u32)(v.hi & 0xFFFF'FFFFu);
            w = (u32)(v.hi >> 32);
            memcpy(&vu0->vf[rt & 31].x, &x, 4);
            memcpy(&vu0->vf[rt & 31].y, &y, 4);
            memcpy(&vu0->vf[rt & 31].z, &z, 4);
            memcpy(&vu0->vf[rt & 31].w, &w, 4);
        }
        return;
    }
    case 0x37: { setGPR64(rt, ld((u32)((i32)getGPR32(rs)+imm16))); return; } // LD
    case 0x39: { // SWC1
        u32 v; memcpy(&v, &fpr[rt & 31], 4);
        sw((u32)((i32)getGPR32(rs)+imm16), v); return;
    }
    case 0x3E: { // SQC2 (store 128-bit from VU0 VF register)
        if (vu0) {
            u32 x, y, z, w;
            memcpy(&x, &vu0->vf[rt & 31].x, 4);
            memcpy(&y, &vu0->vf[rt & 31].y, 4);
            memcpy(&z, &vu0->vf[rt & 31].z, 4);
            memcpy(&w, &vu0->vf[rt & 31].w, 4);
            u128 v;
            v.lo = (u64)x | ((u64)y << 32);
            v.hi = (u64)z | ((u64)w << 32);
            sq((u32)((i32)getGPR32(rs) + imm16), v);
        }
        return;
    }
    case 0x3F: { sd((u32)((i32)getGPR32(rs)+imm16), gpr[rt].lo); return; } // SD

    default:
        break;
    }
}

// ── SPECIAL (R-type) ──────────────────────────────────────────────────────────

void EE::decodeSpecial(u32 instr) {
    int rs    = (instr >> 21) & 0x1F;
    int rt    = (instr >> 16) & 0x1F;
    int rd    = (instr >> 11) & 0x1F;
    u32 sh    = (instr >>  6) & 0x1F;
    int fn    = (instr >>  0) & 0x3F;

    switch (fn) {
    case 0x00: setGPR32(rd, getGPR32(rt) << sh); return; // SLL
    case 0x02: setGPR32(rd, getGPR32(rt) >> sh); return; // SRL
    case 0x03: setGPR32(rd, (u32)((i32)getGPR32(rt) >> sh)); return; // SRA
    case 0x04: setGPR32(rd, getGPR32(rt) << (gpr[rs].lo & 31)); return; // SLLV
    case 0x06: setGPR32(rd, getGPR32(rt) >> (gpr[rs].lo & 31)); return; // SRLV
    case 0x07: setGPR32(rd, (u32)((i32)getGPR32(rt) >> (gpr[rs].lo & 31))); return; // SRAV
    case 0x08: { // JR
        u32 target = getGPR32(rs);
        jumpAbsolute(target);
        return;
    }
    case 0x09: { // JALR
        u32 target = getGPR32(rs);
        u32 retAddr = pc + 4;
        setGPR32(rd ? rd : 31, retAddr);
        jumpAbsolute(target);
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
        if (d != 0 && !(n == (i32)0x80000000u && d == -1)) {
            lo = sign_extend32((u32)(n / d));
            hi = sign_extend32((u32)(n % d));
        } else if (d == 0) {
            lo = n < 0 ? 1u : (u64)(i64)-1LL;
            hi = sign_extend32((u32)n);
        }
        return;
    }
    case 0x1B: { // DIVU
        u32 n = getGPR32(rs), d = getGPR32(rt);
        if (d) { lo = sign_extend32(n / d); hi = sign_extend32(n % d); }
        else   { lo = 0xFFFF'FFFFu; hi = sign_extend32(n); }
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
    case 0x28: if (rd) setGPR64(rd, sa); return; // MFSA
    case 0x29: sa = gpr[rs].lo & 0x1Fu; return; // MTSA
    case 0x2A: setGPR32(rd, (i64)gpr[rs].lo < (i64)gpr[rt].lo ? 1 : 0); return; // SLT
    case 0x2B: setGPR32(rd, gpr[rs].lo < gpr[rt].lo ? 1 : 0); return; // SLTU
    case 0x2C: setGPR64(rd, gpr[rs].lo + gpr[rt].lo); return; // DADD
    case 0x2D: setGPR64(rd, gpr[rs].lo + gpr[rt].lo); return; // DADDU
    case 0x2E: setGPR64(rd, gpr[rs].lo - gpr[rt].lo); return; // DSUB
    case 0x2F: setGPR64(rd, gpr[rs].lo - gpr[rt].lo); return; // DSUBU
    case 0x30: triggerException(0x20); return; // TGE — trap
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
        switch (rd) {
        case COP0_Status:  cop0[COP0_Status]  = getGPR32(rt); break;
        case COP0_Cause:   cop0[COP0_Cause]   = getGPR32(rt) & 0x0000'B300u; break;
        case COP0_Count:   cop0[COP0_Count]   = getGPR32(rt); break;
        case COP0_Compare:
            cop0[COP0_Compare] = getGPR32(rt);
            // Clear timer interrupt when Compare is written
            cop0[COP0_Cause] &= ~(1u << 15);
            break;
        case COP0_EntryHi:
        case COP0_EntryLo0:
        case COP0_EntryLo1:
        case COP0_PageMask:
        case COP0_Index:
        case COP0_Wired:
        case COP0_Context:
            cop0[rd & 31] = getGPR32(rt); break;
        default:
            cop0[rd & 31] = getGPR32(rt); break;
        }
        return;
    case 0x10: // CO instructions
        switch (fn) {
        case 0x01: return; // TLBR  (stub)
        case 0x02: return; // TLBWI (stub)
        case 0x06: return; // TLBWR (stub)
        case 0x08: return; // TLBP  (stub)
        case 0x18: { // ERET
            if (cop0[COP0_Status] & SR_ERL) {
                pc = cop0[COP0_ErrorEPC];
                if (pc == 0) pc = 0xBFC0'0000u;
                cop0[COP0_Status] &= ~SR_ERL;
            } else {
                pc = cop0[COP0_EPC];
                cop0[COP0_Status] &= ~SR_EXL;
            }
            inDelaySlot = false;
            nextPC = pc + 4;
            // GPR 0 always 0
            gpr[0] = u128{};
            return;
        }
        case 0x38: cop0[COP0_Status] |=  SR_EIE; return; // EI
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
    int rd = (instr >> 11) & 0x1F;
    int fn = instr & 0x3F;
    int fs = (instr >> 11) & 0x1F;
    int ft = rt;
    int fd = (instr >>  6) & 0x1F;

    switch (rs) {
    case 0x00: { u32 v; memcpy(&v, &fpr[rd], 4); setGPR32(rt, v); return; } // MFC1
    case 0x04: { u32 v = getGPR32(rt); memcpy(&fpr[rd], &v, 4); return; }   // MTC1
    case 0x02: { // CFC1
        if (rd == 31) setGPR32(rt, fcr31);
        else setGPR32(rt, 0);
        return;
    }
    case 0x06: { // CTC1
        if (rd == 31) fcr31 = getGPR32(rt);
        return;
    }
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
        case 0x03: fpr[fd] = (fpr[ft] != 0.f) ? fpr[fs] / fpr[ft] : (fpr[fs] >= 0.f ? 3.402823466e+38f : -3.402823466e+38f); return; // DIV.S
        case 0x04: fpr[fd] = std::sqrt(std::abs(fpr[fs])); return; // SQRT.S
        case 0x05: fpr[fd] = std::abs(fpr[fs]); return; // ABS.S
        case 0x06: fpr[fd] = fpr[fs]; return; // MOV.S
        case 0x07: fpr[fd] = -fpr[fs]; return; // NEG.S
        case 0x16: { // RSQRT.S
            f32 s = std::abs(fpr[ft]);
            fpr[fd] = (s > 0.f) ? fpr[fs] / std::sqrt(s) : 0.f;
            return;
        }
        case 0x18: fpAcc = fpr[fs] * fpr[ft]; return; // ADDA.S
        case 0x19: fpAcc = fpr[fs] - fpr[ft]; return; // SUBA.S
        case 0x1A: fpAcc = fpr[fs] * fpr[ft]; return; // MULA.S
        case 0x1C: fpr[fd] = fpAcc + fpr[fs] * fpr[ft]; return; // MADD.S
        case 0x1D: fpr[fd] = fpAcc - fpr[fs] * fpr[ft]; return; // MSUB.S
        case 0x1E: fpAcc += fpr[fs] * fpr[ft]; return; // MADDA.S
        case 0x1F: fpAcc -= fpr[fs] * fpr[ft]; return; // MSUBA.S
        case 0x24: { // CVT.W.S
            i32 v = (fpr[fs] != fpr[fs]) ? 0 : (i32)clampf(fpr[fs], -2147483648.f, 2147483647.f);
            memcpy(&fpr[fd], &v, 4); return;
        }
        case 0x28: fcr31 &= ~(1u << 23); return; // C.F.S
        case 0x29: { bool r = (fpr[fs] != fpr[fs] || fpr[ft] != fpr[ft]); if (r) fcr31 |= (1u<<23); else fcr31 &= ~(1u<<23); return; } // C.UN.S
        case 0x2A: { bool r = (fpr[fs] == fpr[ft]); if (r) fcr31 |= (1u<<23); else fcr31 &= ~(1u<<23); return; } // C.EQ.S
        case 0x2C: { bool r = (fpr[fs] < fpr[ft]);  if (r) fcr31 |= (1u<<23); else fcr31 &= ~(1u<<23); return; } // C.LT.S
        case 0x2E: { bool r = (fpr[fs] <= fpr[ft]); if (r) fcr31 |= (1u<<23); else fcr31 &= ~(1u<<23); return; } // C.LE.S
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
    int id = (instr >> 11) & 0x1F;

    switch (rs) {
    case 0x01: { // QMFC2 — read 128-bit VF into GPR
        u32 xi, yi, zi, wi;
        memcpy(&xi, &vu0->vf[id&31].x, 4);
        memcpy(&yi, &vu0->vf[id&31].y, 4);
        memcpy(&zi, &vu0->vf[id&31].z, 4);
        memcpy(&wi, &vu0->vf[id&31].w, 4);
        u128 v;
        v.lo = (u64)xi | ((u64)yi << 32);
        v.hi = (u64)zi | ((u64)wi << 32);
        setGPR128(rt, v);
        return;
    }
    case 0x05: { // QMTC2 — write 128-bit GPR into VF
        u32 xi = (u32)(gpr[rt].lo & 0xFFFF'FFFFu);
        u32 yi = (u32)(gpr[rt].lo >> 32);
        u32 zi = (u32)(gpr[rt].hi & 0xFFFF'FFFFu);
        u32 wi = (u32)(gpr[rt].hi >> 32);
        memcpy(&vu0->vf[id&31].x, &xi, 4);
        memcpy(&vu0->vf[id&31].y, &yi, 4);
        memcpy(&vu0->vf[id&31].z, &zi, 4);
        memcpy(&vu0->vf[id&31].w, &wi, 4);
        return;
    }
    case 0x02: { // CFC2 — read VU0 control register into GPR
        u32 val = 0;
        switch (id & 31) {
        case 16: val = vu0->statusFlag; break;
        case 17: val = vu0->macFlag;    break;
        case 18: val = vu0->clipFlag;   break;
        case 20: { u32 Ib; memcpy(&Ib, &vu0->I, 4); val = Ib; break; }
        case 21: { u32 qb; memcpy(&qb, &vu0->q, 4); val = qb; break; }
        default: break;
        }
        setGPR32(rt, val);
        return;
    }
    case 0x06: { // CTC2 — write GPR to VU0 control register
        u32 val = getGPR32(rt);
        switch (id & 31) {
        case 16: vu0->statusFlag = val; break;
        case 17: vu0->macFlag    = val; break;
        case 18: vu0->clipFlag   = val; break;
        case 20: memcpy(&vu0->I, &val, 4); break;
        case 21: memcpy(&vu0->q, &val, 4); break;
        default: break;
        }
        return;
    }
    default:
        // Execute as VU0 macro-mode upper instruction
        vu0->executeUpper(instr);
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
        if (d != 0 && !(n == (i32)0x80000000u && d == -1)) {
            lo1 = sign_extend32((u32)(n / d));
            hi1 = sign_extend32((u32)(n % d));
        }
        return;
    }
    case 0x1B: { // DIVU1
        u32 n = getGPR32(rs), d = getGPR32(rt);
        if (d) { lo1 = sign_extend32(n / d); hi1 = sign_extend32(n % d); }
        return;
    }
    case 0x28: decodeMMI1(instr); return;
    case 0x29: decodeMMI3(instr); return;
    case 0x30: { // PMFHL
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
            u16 v = (u16)((u16)(src >> off) << (shamt & 15));
            half |= (u64)v << off;
        }
        if (rd) setGPR128(rd, r); return;
    }
    case 0x36: { // PSRLH
        u128 r{};
        for (int i = 0; i < 8; i++) {
            u64& half = (i < 4) ? r.lo : r.hi;
            u64 src   = (i < 4) ? gpr[rt].lo : gpr[rt].hi;
            int off = (i & 3) * 16;
            u16 v = (u16)((u16)(src >> off) >> (shamt & 15));
            half |= (u64)v << off;
        }
        if (rd) setGPR128(rd, r); return;
    }
    case 0x37: { // PSRAH
        u128 r{};
        for (int i = 0; i < 8; i++) {
            u64& half = (i < 4) ? r.lo : r.hi;
            u64 src   = (i < 4) ? gpr[rt].lo : gpr[rt].hi;
            int off = (i & 3) * 16;
            i16 v = (i16)((i16)(src >> off) >> (shamt & 15));
            half |= (u64)(u16)v << off;
        }
        if (rd) setGPR128(rd, r); return;
    }
    case 0x3C: { // PSLLW
        u128 r{ gpr[rt].lo << (shamt & 31), gpr[rt].hi << (shamt & 31) };
        if (rd) setGPR128(rd, r); return;
    }
    case 0x3E: { // PSRLW
        u128 r{ gpr[rt].lo >> (shamt & 31), gpr[rt].hi >> (shamt & 31) };
        if (rd) setGPR128(rd, r); return;
    }
    case 0x3F: { // PSRAW
        u128 r{
            (u64)((i64)gpr[rt].lo >> (shamt & 31)),
            (u64)((i64)gpr[rt].hi >> (shamt & 31))
        };
        if (rd) setGPR128(rd, r); return;
    }
    default: break;
    }
}

// ── MMI0 ──────────────────────────────────────────────────────────────────────

void EE::decodeMMI0(u32 instr) {
    int rs    = (instr >> 21) & 0x1F;
    int rt    = (instr >> 16) & 0x1F;
    int rd    = (instr >> 11) & 0x1F;
    int sub   = (instr >>  6) & 0x1F;

    switch (sub) {
    case 0x00: { // PADDW
        u128 r;
        r.lo = (u64)(u32)((u32)(gpr[rs].lo) + (u32)(gpr[rt].lo))
             | ((u64)(u32)((u32)(gpr[rs].lo >> 32) + (u32)(gpr[rt].lo >> 32)) << 32);
        r.hi = (u64)(u32)((u32)(gpr[rs].hi) + (u32)(gpr[rt].hi))
             | ((u64)(u32)((u32)(gpr[rs].hi >> 32) + (u32)(gpr[rt].hi >> 32)) << 32);
        if (rd) setGPR128(rd, r); return;
    }
    case 0x01: { // PSUBW
        u128 r;
        r.lo = (u64)(u32)((u32)(gpr[rs].lo) - (u32)(gpr[rt].lo))
             | ((u64)(u32)((u32)(gpr[rs].lo >> 32) - (u32)(gpr[rt].lo >> 32)) << 32);
        r.hi = (u64)(u32)((u32)(gpr[rs].hi) - (u32)(gpr[rt].hi))
             | ((u64)(u32)((u32)(gpr[rs].hi >> 32) - (u32)(gpr[rt].hi >> 32)) << 32);
        if (rd) setGPR128(rd, r); return;
    }
    case 0x02: { // PCGTW
        u128 r{};
        for (int i = 0; i < 4; i++) {
            int off = (i & 1) * 32;
            u64& rhalf = (i < 2) ? r.lo : r.hi;
            u64 sh = (i < 2) ? gpr[rs].lo : gpr[rs].hi;
            u64 th = (i < 2) ? gpr[rt].lo : gpr[rt].hi;
            i32 sv = (i32)(sh >> off), tv = (i32)(th >> off);
            rhalf |= (u64)(sv > tv ? 0xFFFF'FFFFu : 0u) << off;
        }
        if (rd) setGPR128(rd, r); return;
    }
    case 0x03: { // PMAXW
        u128 r{};
        for (int i = 0; i < 4; i++) {
            int off = (i & 1) * 32;
            u64& rhalf = (i < 2) ? r.lo : r.hi;
            u64 sh = (i < 2) ? gpr[rs].lo : gpr[rs].hi;
            u64 th = (i < 2) ? gpr[rt].lo : gpr[rt].hi;
            i32 sv = (i32)(sh >> off), tv = (i32)(th >> off);
            rhalf |= (u64)(u32)(sv > tv ? sv : tv) << off;
        }
        if (rd) setGPR128(rd, r); return;
    }
    case 0x08: { // PADDH (packed add halfword)
        u128 r{};
        for (int i = 0; i < 8; i++) {
            int off = (i & 3) * 16;
            u64& rhalf = (i < 4) ? r.lo : r.hi;
            u64 sh = (i < 4) ? gpr[rs].lo : gpr[rs].hi;
            u64 th = (i < 4) ? gpr[rt].lo : gpr[rt].hi;
            u16 sum = (u16)(sh >> off) + (u16)(th >> off);
            rhalf |= (u64)sum << off;
        }
        if (rd) setGPR128(rd, r); return;
    }
    case 0x09: { // PSUBH
        u128 r{};
        for (int i = 0; i < 8; i++) {
            int off = (i & 3) * 16;
            u64& rhalf = (i < 4) ? r.lo : r.hi;
            u64 sh = (i < 4) ? gpr[rs].lo : gpr[rs].hi;
            u64 th = (i < 4) ? gpr[rt].lo : gpr[rt].hi;
            u16 dif = (u16)(sh >> off) - (u16)(th >> off);
            rhalf |= (u64)dif << off;
        }
        if (rd) setGPR128(rd, r); return;
    }
    case 0x0A: { // PCGTH
        u128 r{};
        for (int i = 0; i < 8; i++) {
            int off = (i & 3) * 16;
            u64& rhalf = (i < 4) ? r.lo : r.hi;
            u64 sh = (i < 4) ? gpr[rs].lo : gpr[rs].hi;
            u64 th = (i < 4) ? gpr[rt].lo : gpr[rt].hi;
            i16 sv = (i16)(sh >> off), tv = (i16)(th >> off);
            rhalf |= (u64)(u16)(sv > tv ? 0xFFFF : 0) << off;
        }
        if (rd) setGPR128(rd, r); return;
    }
    case 0x0B: { // PMAXH
        u128 r{};
        for (int i = 0; i < 8; i++) {
            int off = (i & 3) * 16;
            u64& rhalf = (i < 4) ? r.lo : r.hi;
            u64 sh = (i < 4) ? gpr[rs].lo : gpr[rs].hi;
            u64 th = (i < 4) ? gpr[rt].lo : gpr[rt].hi;
            i16 sv = (i16)(sh >> off), tv = (i16)(th >> off);
            rhalf |= (u64)(u16)(sv > tv ? sv : tv) << off;
        }
        if (rd) setGPR128(rd, r); return;
    }
    case 0x10: { // PADDB
        u128 r{};
        for (int i = 0; i < 16; i++) {
            int off = (i & 7) * 8;
            u64& rhalf = (i < 8) ? r.lo : r.hi;
            u64 sh = (i < 8) ? gpr[rs].lo : gpr[rs].hi;
            u64 th = (i < 8) ? gpr[rt].lo : gpr[rt].hi;
            u8 sum = (u8)(sh >> off) + (u8)(th >> off);
            rhalf |= (u64)sum << off;
        }
        if (rd) setGPR128(rd, r); return;
    }
    case 0x11: { // PSUBB
        u128 r{};
        for (int i = 0; i < 16; i++) {
            int off = (i & 7) * 8;
            u64& rhalf = (i < 8) ? r.lo : r.hi;
            u64 sh = (i < 8) ? gpr[rs].lo : gpr[rs].hi;
            u64 th = (i < 8) ? gpr[rt].lo : gpr[rt].hi;
            u8 dif = (u8)(sh >> off) - (u8)(th >> off);
            rhalf |= (u64)dif << off;
        }
        if (rd) setGPR128(rd, r); return;
    }
    case 0x18: { // PAND
        if (rd) setGPR128(rd, gpr[rs] & gpr[rt]); return;
    }
    case 0x19: { // POR
        if (rd) setGPR128(rd, gpr[rs] | gpr[rt]); return;
    }
    case 0x1A: { // PXOR
        if (rd) setGPR128(rd, gpr[rs] ^ gpr[rt]); return;
    }
    case 0x1B: { // PNOR
        if (rd) setGPR128(rd, ~(gpr[rs] | gpr[rt])); return;
    }
    default: break;
    }
}

// ── MMI1 ──────────────────────────────────────────────────────────────────────

void EE::decodeMMI1(u32 instr) {
    int rs  = (instr >> 21) & 0x1F;
    int rt  = (instr >> 16) & 0x1F;
    int rd  = (instr >> 11) & 0x1F;
    int sub = (instr >>  6) & 0x1F;

    switch (sub) {
    case 0x01: { // PABSW
        u128 r{};
        for (int i = 0; i < 4; i++) {
            int off = (i & 1) * 32;
            u64& rhalf = (i < 2) ? r.lo : r.hi;
            u64 sh = (i < 2) ? gpr[rt].lo : gpr[rt].hi;
            i32 v = (i32)(sh >> off);
            rhalf |= (u64)(u32)(v < 0 ? -v : v) << off;
        }
        if (rd) setGPR128(rd, r); return;
    }
    case 0x02: { // PCEQW
        u128 r{};
        for (int i = 0; i < 4; i++) {
            int off = (i & 1) * 32;
            u64& rhalf = (i < 2) ? r.lo : r.hi;
            u64 sh = (i < 2) ? gpr[rs].lo : gpr[rs].hi;
            u64 th = (i < 2) ? gpr[rt].lo : gpr[rt].hi;
            bool eq = ((u32)(sh >> off) == (u32)(th >> off));
            rhalf |= (u64)(eq ? 0xFFFF'FFFFu : 0u) << off;
        }
        if (rd) setGPR128(rd, r); return;
    }
    case 0x03: { // PMINW
        u128 r{};
        for (int i = 0; i < 4; i++) {
            int off = (i & 1) * 32;
            u64& rhalf = (i < 2) ? r.lo : r.hi;
            u64 sh = (i < 2) ? gpr[rs].lo : gpr[rs].hi;
            u64 th = (i < 2) ? gpr[rt].lo : gpr[rt].hi;
            i32 sv = (i32)(sh >> off), tv = (i32)(th >> off);
            rhalf |= (u64)(u32)(sv < tv ? sv : tv) << off;
        }
        if (rd) setGPR128(rd, r); return;
    }
    case 0x09: { // PABSH
        u128 r{};
        for (int i = 0; i < 8; i++) {
            int off = (i & 3) * 16;
            u64& rhalf = (i < 4) ? r.lo : r.hi;
            u64 sh = (i < 4) ? gpr[rt].lo : gpr[rt].hi;
            i16 v = (i16)(sh >> off);
            rhalf |= (u64)(u16)(v < 0 ? -v : v) << off;
        }
        if (rd) setGPR128(rd, r); return;
    }
    case 0x0A: { // PCEQH
        u128 r{};
        for (int i = 0; i < 8; i++) {
            int off = (i & 3) * 16;
            u64& rhalf = (i < 4) ? r.lo : r.hi;
            u64 sh = (i < 4) ? gpr[rs].lo : gpr[rs].hi;
            u64 th = (i < 4) ? gpr[rt].lo : gpr[rt].hi;
            bool eq = ((u16)(sh >> off) == (u16)(th >> off));
            rhalf |= (u64)(u16)(eq ? 0xFFFF : 0) << off;
        }
        if (rd) setGPR128(rd, r); return;
    }
    case 0x0B: { // PMINH
        u128 r{};
        for (int i = 0; i < 8; i++) {
            int off = (i & 3) * 16;
            u64& rhalf = (i < 4) ? r.lo : r.hi;
            u64 sh = (i < 4) ? gpr[rs].lo : gpr[rs].hi;
            u64 th = (i < 4) ? gpr[rt].lo : gpr[rt].hi;
            i16 sv = (i16)(sh >> off), tv = (i16)(th >> off);
            rhalf |= (u64)(u16)(sv < tv ? sv : tv) << off;
        }
        if (rd) setGPR128(rd, r); return;
    }
    case 0x12: { // PCEQB
        u128 r{};
        for (int i = 0; i < 16; i++) {
            int off = (i & 7) * 8;
            u64& rhalf = (i < 8) ? r.lo : r.hi;
            u64 sh = (i < 8) ? gpr[rs].lo : gpr[rs].hi;
            u64 th = (i < 8) ? gpr[rt].lo : gpr[rt].hi;
            bool eq = ((u8)(sh >> off) == (u8)(th >> off));
            rhalf |= (u64)(u8)(eq ? 0xFF : 0) << off;
        }
        if (rd) setGPR128(rd, r); return;
    }
    case 0x1A: { // PEXEW — extend even words
        if (!rd) return;
        gpr[rd].lo = (u64)(u32)(gpr[rt].lo) | ((u64)(u32)(gpr[rt].hi) << 32);
        gpr[rd].hi = 0;
        return;
    }
    case 0x1B: { // PROT3W
        if (!rd) return;
        u32 w0 = (u32)(gpr[rt].lo);
        u32 w1 = (u32)(gpr[rt].lo >> 32);
        u32 w2 = (u32)(gpr[rt].hi);
        u32 w3 = (u32)(gpr[rt].hi >> 32);
        gpr[rd].lo = (u64)w1 | ((u64)w2 << 32);
        gpr[rd].hi = (u64)w3 | ((u64)w0 << 32);
        return;
    }
    default: break;
    }
    (void)rs; (void)rt; (void)rd; (void)sub;
}

// ── MMI2 ──────────────────────────────────────────────────────────────────────

void EE::decodeMMI2(u32 instr) {
    int rs  = (instr >> 21) & 0x1F;
    int rt  = (instr >> 16) & 0x1F;
    int rd  = (instr >> 11) & 0x1F;
    int sub = (instr >>  6) & 0x1F;

    switch (sub) {
    case 0x00: { // PMADDW
        u128 r{};
        for (int i = 0; i < 2; i++) {
            u64 sh = i == 0 ? gpr[rs].lo : gpr[rs].hi;
            u64 th = i == 0 ? gpr[rt].lo : gpr[rt].hi;
            i64 hi_w = (i64)(i32)(u32)(sh >> 32);
            i64 lo_w = (i64)(i32)(u32)(sh);
            i64 hi_t = (i64)(i32)(u32)(th >> 32);
            i64 lo_t = (i64)(i32)(u32)(th);
            i64 prod_hi = hi_w * hi_t;
            i64 prod_lo = lo_w * lo_t;
            if (i == 0) {
                i64 acc_hi = (i64)(hi << 32 | (u32)hi);
                i64 acc_lo = (i64)(lo << 32 | (u32)lo);
                r.hi = (u64)(prod_hi + acc_hi);
                r.lo = (u64)(prod_lo + acc_lo);
            }
        }
        if (rd) { hi = (u64)(i64)(i32)(u32)(r.lo >> 32); lo = sign_extend32((u32)r.lo); setGPR128(rd, r); }
        return;
    }
    case 0x02: { // PSRLVW
        u128 r{};
        u32 sh0 = gpr[rs].lo & 31, sh1 = (gpr[rs].lo >> 32) & 31;
        r.lo = (u64)(u32)(gpr[rt].lo) >> sh0;
        r.hi = (u64)(u32)(gpr[rt].hi) >> sh1;
        if (rd) setGPR128(rd, r); return;
    }
    case 0x03: { // PSRAVW
        u128 r{};
        u32 sh0 = gpr[rs].lo & 31, sh1 = (gpr[rs].lo >> 32) & 31;
        r.lo = (u64)(u32)((i32)(gpr[rt].lo) >> sh0);
        r.hi = (u64)(u32)((i32)(gpr[rt].hi) >> sh1);
        if (rd) setGPR128(rd, r); return;
    }
    case 0x08: { // PMFHI
        if (rd) { gpr[rd].lo = hi; gpr[rd].hi = hi1; } return;
    }
    case 0x09: { // PMFLO
        if (rd) { gpr[rd].lo = lo; gpr[rd].hi = lo1; } return;
    }
    case 0x0A: { // PINTH
        if (!rd) return;
        gpr[rd].lo = (gpr[rs].lo & 0xFFFF'0000'FFFF'0000uLL) | (gpr[rt].hi & 0x0000'FFFF'0000'FFFFuLL);
        gpr[rd].hi = (gpr[rs].hi & 0xFFFF'0000'FFFF'0000uLL) | (gpr[rt].lo & 0x0000'FFFF'0000'FFFFuLL);
        return;
    }
    case 0x0D: { // PCPYH
        if (!rd) return;
        u16 h = (u16)(gpr[rt].lo);
        u64 rep = (u64)h | ((u64)h << 16) | ((u64)h << 32) | ((u64)h << 48);
        u16 h2 = (u16)(gpr[rt].hi);
        u64 rep2 = (u64)h2 | ((u64)h2 << 16) | ((u64)h2 << 32) | ((u64)h2 << 48);
        gpr[rd].lo = rep; gpr[rd].hi = rep2;
        return;
    }
    case 0x0E: { // PEXEH
        if (!rd) return;
        u64 v = gpr[rt].lo;
        gpr[rd].lo = (v & 0xFFFF'0000'FFFF'0000uLL) | ((v >> 16) & 0xFFFF) | (((v & 0xFFFF) << 16));
        v = gpr[rt].hi;
        gpr[rd].hi = (v & 0xFFFF'0000'FFFF'0000uLL) | ((v >> 16) & 0xFFFF) | (((v & 0xFFFF) << 16));
        return;
    }
    case 0x0F: { // PREVH
        if (!rd) return;
        auto rev4h = [](u64 v) -> u64 {
            return ((v & 0xFFFF) << 48) | (((v >> 16) & 0xFFFF) << 32) |
                   (((v >> 32) & 0xFFFF) << 16) | ((v >> 48) & 0xFFFF);
        };
        gpr[rd].lo = rev4h(gpr[rt].lo);
        gpr[rd].hi = rev4h(gpr[rt].hi);
        return;
    }
    case 0x10: { // PMULTW
        if (!rd) return;
        i64 r0 = (i64)(i32)(u32)(gpr[rs].lo) * (i64)(i32)(u32)(gpr[rt].lo);
        i64 r1 = (i64)(i32)(u32)(gpr[rs].hi) * (i64)(i32)(u32)(gpr[rt].hi);
        lo = sign_extend32((u32)r0); hi = sign_extend32((u32)(r0 >> 32));
        lo1 = sign_extend32((u32)r1); hi1 = sign_extend32((u32)(r1 >> 32));
        gpr[rd].lo = (u64)(u32)r0 | ((u64)(u32)(r0 >> 32) << 32);
        gpr[rd].hi = (u64)(u32)r1 | ((u64)(u32)(r1 >> 32) << 32);
        return;
    }
    case 0x11: { // PDIVW
        i32 n = (i32)(u32)(gpr[rs].lo), d = (i32)(u32)(gpr[rt].lo);
        i32 n2 = (i32)(u32)(gpr[rs].hi), d2 = (i32)(u32)(gpr[rt].hi);
        if (d)  { lo = sign_extend32((u32)(n  / d));  hi  = sign_extend32((u32)(n  % d));  }
        if (d2) { lo1 = sign_extend32((u32)(n2 / d2)); hi1 = sign_extend32((u32)(n2 % d2)); }
        return;
    }
    case 0x13: { // PCOPYH (alias of PCPYH for lower half)
        if (!rd) return;
        u16 h = (u16)(gpr[rt].lo);
        u64 rep = (u64)h | ((u64)h<<16) | ((u64)h<<32) | ((u64)h<<48);
        gpr[rd].lo = rep; gpr[rd].hi = rep;
        return;
    }
    case 0x1B: { // PCPYUD — copy upper dword to both
        if (!rd) return;
        gpr[rd].lo = gpr[rs].hi; gpr[rd].hi = gpr[rt].hi;
        return;
    }
    default: break;
    }
    (void)rs; (void)rt; (void)rd; (void)sub;
}

// ── MMI3 ──────────────────────────────────────────────────────────────────────

void EE::decodeMMI3(u32 instr) {
    int rs  = (instr >> 21) & 0x1F;
    int rt  = (instr >> 16) & 0x1F;
    int rd  = (instr >> 11) & 0x1F;
    int sub = (instr >>  6) & 0x1F;

    switch (sub) {
    case 0x03: { // PAND — packed AND
        if (rd) setGPR128(rd, gpr[rs] & gpr[rt]); return;
    }
    case 0x08: { // PMTHI
        hi  = gpr[rs].lo; hi1 = gpr[rs].hi; return;
    }
    case 0x09: { // PMTLO
        lo  = gpr[rs].lo; lo1 = gpr[rs].hi; return;
    }
    case 0x0C: { // PINTEH
        if (!rd) return;
        gpr[rd].lo = (gpr[rs].lo & 0xFFFF'0000'FFFF'0000uLL) | (gpr[rt].lo & 0x0000'FFFF'0000'FFFFuLL);
        gpr[rd].hi = (gpr[rs].hi & 0xFFFF'0000'FFFF'0000uLL) | (gpr[rt].hi & 0x0000'FFFF'0000'FFFFuLL);
        return;
    }
    case 0x12: { // PEXEW
        if (!rd) return;
        u32 w0 = (u32)(gpr[rt].lo), w2 = (u32)(gpr[rt].hi);
        gpr[rd].lo = (u64)w0; gpr[rd].hi = (u64)w2;
        return;
    }
    case 0x1B: { // PCPYLD
        if (!rd) return;
        gpr[rd].lo = gpr[rt].lo; gpr[rd].hi = gpr[rs].lo;
        return;
    }
    default: break;
    }
    (void)rs; (void)rt; (void)rd; (void)sub;
}
