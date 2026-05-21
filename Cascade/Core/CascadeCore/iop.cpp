#include "iop.h"
#include "spu2.h"
#include "cdvd.h"
#include <cstdlib>
#include <cstring>

// ── A minimal CDVD forward declaration ───────────────────────────────────────
// Full CDVD is handled in Swift; this stub satisfies the linker.
struct CDVD {
    u32 readIO (u32 offset) { return 0; (void)offset; }
    void writeIO(u32 offset, u32 value) { (void)offset; (void)value; }
};

IOP::IOP() {
    ram = (u8*)calloc(IOP_RAM_SIZE, 1);
    reset();
}

IOP::~IOP() {
    free(ram);
}

void IOP::reset() {
    memset(gpr, 0, sizeof(gpr));
    pc = 0xBFC0'0000u;
    hi = lo = 0;
    cop0_Status = cop0_Cause = cop0_EPC = cop0_BadVA = 0;
    inDelaySlot = false;
    nextPC = pc + 4;
    cycles = 0;
}

// ── Step ──────────────────────────────────────────────────────────────────────

void IOP::step(int count) {
    for (int i = 0; i < count; i++) {
        u32 instr = read32(pc);
        if (inDelaySlot) {
            pc = nextPC;
            inDelaySlot = false;
        } else {
            pc += 4;
        }
        decode(instr);
        cycles++;
        if (spu2) spu2->tick();
    }
}

// ── Exception ─────────────────────────────────────────────────────────────────

void IOP::triggerException(int excCode) {
    cop0_EPC = pc - 4; // EPC = faulting instruction
    cop0_Cause = (cop0_Cause & ~0x7Cu) | ((u32)excCode << 2);
    cop0_Status |= (1u << 1); // EXL
    inDelaySlot = false;
    pc = (cop0_Status & (1u << 22)) ? 0xBFC0'0100u : 0x8000'0080u;
    nextPC = pc + 4;
}

// ── Memory ────────────────────────────────────────────────────────────────────

u8 IOP::read8(u32 addr) {
    u32 p = physAddr(addr);
    if (p < IOP_RAM_SIZE) return ram[p];
    return (u8)(readIO(p) >> ((p & 3) * 8));
}

u16 IOP::read16(u32 addr) {
    u32 p = physAddr(addr);
    if (p + 1 < IOP_RAM_SIZE) return read_le<u16>(ram + p);
    return (u16)read8(addr) | ((u16)read8(addr+1) << 8);
}

u32 IOP::read32(u32 addr) {
    u32 p = physAddr(addr);
    if (p + 3 < IOP_RAM_SIZE) return read_le<u32>(ram + p);
    return readIO(p);
}

void IOP::write8(u32 addr, u8 v) {
    u32 p = physAddr(addr);
    if (p < IOP_RAM_SIZE) { ram[p] = v; return; }
    u32 aligned = p & ~3u;
    u32 old = readIO(aligned);
    int sh = (p & 3) * 8;
    old = (old & ~(0xFFu << sh)) | ((u32)v << sh);
    writeIO(aligned, old);
}

void IOP::write16(u32 addr, u16 v) {
    u32 p = physAddr(addr);
    if (p + 1 < IOP_RAM_SIZE) { write_le<u16>(ram + p, v); return; }
    write8(addr, (u8)v); write8(addr+1, (u8)(v>>8));
}

void IOP::write32(u32 addr, u32 v) {
    u32 p = physAddr(addr);
    if (p + 3 < IOP_RAM_SIZE) { write_le<u32>(ram + p, v); return; }
    writeIO(p, v);
}

// ── I/O routing ───────────────────────────────────────────────────────────────

u32 IOP::readIO(u32 phys) {
    // BIOS ROM
    if (phys >= 0x1FC0'0000u && phys < 0x2000'0000u) {
        // Mirror BIOS from IOP RAM (loaded there on BIOS load)
        u32 off = phys - 0x1FC0'0000u;
        if (off + 3 < IOP_RAM_SIZE) return read_le<u32>(ram + off);
        return 0;
    }
    // SPU2: 0x1F80'1C00 – 0x1F80'1DFF
    if (phys >= 0x1F80'1C00u && phys < 0x1F80'1E00u)
        return spu2 ? spu2->readIO(phys - 0x1F80'1C00u) : 0u;
    // CDVD: 0x1F40'2000 – 0x1F40'20FF
    if (phys >= 0x1F40'2000u && phys < 0x1F40'2100u)
        return cdvd ? cdvd->readIO(phys - 0x1F40'2000u) : 0u;
    // SIF2 FIFO placeholder
    if (phys == 0x1D000040u) return 0;
    // INTC / DMAC (IOP side) — stub as idle
    if (phys >= 0x1F80'1070u && phys < 0x1F80'1080u) return 0;
    if (phys >= 0x1F80'10F0u && phys < 0x1F80'10FFu) return 0;
    if (phys >= 0x1F80'1080u && phys < 0x1F80'1100u) return 0;
    // DMA control / DICR
    if (phys == 0x1F80'1088u) return 0;
    if (phys == 0x1F80'10F4u) return 0;
    // IOP timers
    if (phys >= 0x1F80'1100u && phys < 0x1F80'1140u) return 0;
    if (phys >= 0x1F80'1480u && phys < 0x1F80'14C0u) return 0;
    // Hardware registers that return non-zero to unblock BIOS
    if (phys == 0x1F80'1814u) return 0x14802000u; // GPU stat
    if (phys == 0x1F80'1040u) return 0;
    if (phys == 0x1F80'1044u) return 0;
    // Post registers (IOP → EE SIF0)
    if (phys >= 0x1F80'2070u && phys < 0x1F80'2080u) return 0;
    return 0u;
}

void IOP::writeIO(u32 phys, u32 v) {
    if (phys >= 0x1F80'1C00u && phys < 0x1F80'1E00u)
        { if (spu2) spu2->writeIO(phys - 0x1F80'1C00u, v); return; }
    if (phys >= 0x1F40'2000u && phys < 0x1F40'2100u)
        { if (cdvd) cdvd->writeIO(phys - 0x1F40'2000u, v); return; }
    // All other IOP I/O writes are accepted silently (timers, DMA, INTC)
}

// ── Decode ────────────────────────────────────────────────────────────────────

void IOP::decode(u32 instr) {
    if (!instr) return;
    int op  = (instr >> 26) & 0x3F;
    int rs  = (instr >> 21) & 0x1F;
    int rt  = (instr >> 16) & 0x1F;
    int rd  = (instr >> 11) & 0x1F;
    u32 sh  = (instr >>  6) & 0x1F;
    int fn  = instr & 0x3F;
    i32 imm = (i32)(i16)(u16)(instr & 0xFFFF);
    u32 uim = instr & 0xFFFFu;
    u32 im26= instr & 0x03FF'FFFFu;

    auto ea = [&]() -> u32 { return (u32)((i32)gpr[rs] + imm); };

    switch (op) {
    case 0x00: decodeSpecial(instr); return;
    case 0x01: // REGIMM
        switch (rt) {
        case 0x00: if ((i32)gpr[rs] < 0)  branchOffset(imm); return; // BLTZ
        case 0x01: if ((i32)gpr[rs] >= 0) branchOffset(imm); return; // BGEZ
        case 0x10: setGPR(31,pc); if ((i32)gpr[rs] < 0)  branchOffset(imm); return; // BLTZAL
        case 0x11: setGPR(31,pc); if ((i32)gpr[rs] >= 0) branchOffset(imm); return; // BGEZAL
        default: return;
        }
    case 0x02: jumpAbsolute(im26); return; // J
    case 0x03: setGPR(31, pc); jumpAbsolute(im26); return; // JAL
    case 0x04: if (gpr[rs] == gpr[rt]) branchOffset(imm); return; // BEQ
    case 0x05: if (gpr[rs] != gpr[rt]) branchOffset(imm); return; // BNE
    case 0x06: if ((i32)gpr[rs] <= 0)  branchOffset(imm); return; // BLEZ
    case 0x07: if ((i32)gpr[rs] > 0)   branchOffset(imm); return; // BGTZ
    case 0x08: setGPR(rt, (u32)((i32)gpr[rs] + imm)); return; // ADDI
    case 0x09: setGPR(rt, (u32)((i32)gpr[rs] + imm)); return; // ADDIU
    case 0x0A: setGPR(rt, (i32)gpr[rs] < imm ? 1u : 0u); return; // SLTI
    case 0x0B: setGPR(rt, gpr[rs] < (u32)(i32)imm ? 1u : 0u); return; // SLTIU
    case 0x0C: setGPR(rt, gpr[rs] & uim); return; // ANDI
    case 0x0D: setGPR(rt, gpr[rs] | uim); return; // ORI
    case 0x0E: setGPR(rt, gpr[rs] ^ uim); return; // XORI
    case 0x0F: setGPR(rt, uim << 16); return; // LUI
    case 0x10: // COP0
        switch (rs) {
        case 0x00: setGPR(rt, cop0_Status); return; // MFC0 (simplified: only Status)
        case 0x04: // MTC0
            switch (rd) {
            case 12: cop0_Status = gpr[rt]; return;
            case 13: cop0_Cause  = gpr[rt] & 0x300u; return;
            default: return;
            }
        case 0x10:
            switch (fn) {
            case 0x10: // RFE
                cop0_Status = (cop0_Status & ~0xFu) | ((cop0_Status >> 2) & 0x3Fu);
                return;
            default: return;
            }
        default: return;
        }
    case 0x20: setGPR(rt, (u32)(i32)(i8) read8 (ea())); return; // LB
    case 0x21: setGPR(rt, (u32)(i32)(i16)read16(ea())); return; // LH
    case 0x22: { // LWL
        u32 a=(u32)((i32)gpr[rs]+imm); int s=(a&3)*8;
        u32 m=read32(a&~3u); u32 mask=~0u<<s;
        setGPR(rt,(gpr[rt]&~mask)|(m<<s)); return;
    }
    case 0x23: setGPR(rt, read32(ea())); return; // LW
    case 0x24: setGPR(rt, (u32)read8 (ea())); return; // LBU
    case 0x25: setGPR(rt, (u32)read16(ea())); return; // LHU
    case 0x26: { // LWR
        u32 a=(u32)((i32)gpr[rs]+imm); int s=(3-(a&3))*8;
        u32 m=read32(a&~3u); u32 mask=~0u>>s;
        setGPR(rt,(gpr[rt]&~mask)|(m>>s)); return;
    }
    case 0x28: write8 (ea(), (u8)gpr[rt]);        return; // SB
    case 0x29: write16(ea(), (u16)gpr[rt]);       return; // SH
    case 0x2A: { // SWL
        u32 a=(u32)((i32)gpr[rs]+imm); int s=(a&3)*8;
        u32 m=read32(a&~3u); u32 mask=~0u>>(24-s);
        write32(a&~3u,(m&~mask)|(gpr[rt]>>(24-s))); return;
    }
    case 0x2B: write32(ea(), gpr[rt]);            return; // SW
    case 0x2E: { // SWR
        u32 a=(u32)((i32)gpr[rs]+imm); int s=(3-(a&3))*8;
        u32 m=read32(a&~3u); u32 mask=~0u<<s;
        write32(a&~3u,(m&~mask)|(gpr[rt]<<s)); return;
    }
    case 0x32: { u32 v=read32(ea()); setGPR(rt,v|(1u<<31)); return; } // LWC2 (COP2 load — treat as regular)
    case 0x3A: write32(ea(), gpr[rt]); return; // SWC2
    default: return;
    }
    (void)sh; (void)rd;
}

void IOP::decodeSpecial(u32 instr) {
    int rs=(instr>>21)&0x1F, rt=(instr>>16)&0x1F, rd=(instr>>11)&0x1F;
    u32 sh=(instr>>6)&0x1F; int fn=instr&0x3F;

    switch (fn) {
    case 0x00: setGPR(rd, gpr[rt] << sh); return; // SLL
    case 0x02: setGPR(rd, gpr[rt] >> sh); return; // SRL
    case 0x03: setGPR(rd, (u32)((i32)gpr[rt] >> sh)); return; // SRA
    case 0x04: setGPR(rd, gpr[rt] << (gpr[rs] & 31)); return; // SLLV
    case 0x06: setGPR(rd, gpr[rt] >> (gpr[rs] & 31)); return; // SRLV
    case 0x07: setGPR(rd, (u32)((i32)gpr[rt] >> (gpr[rs] & 31))); return; // SRAV
    case 0x08: { u32 t=gpr[rs]; branchTo(t); return; } // JR
    case 0x09: { u32 t=gpr[rs]; setGPR(rd,pc); branchTo(t); return; } // JALR
    case 0x0C: triggerException(8); return; // SYSCALL
    case 0x0D: triggerException(9); return; // BREAK
    case 0x10: setGPR(rd, hi); return; // MFHI
    case 0x11: hi = gpr[rs]; return; // MTHI
    case 0x12: setGPR(rd, lo); return; // MFLO
    case 0x13: lo = gpr[rs]; return; // MTLO
    case 0x18: { i64 r=(i64)(i32)gpr[rs]*(i64)(i32)gpr[rt]; lo=(u32)r; hi=(u32)(r>>32); return; } // MULT
    case 0x19: { u64 r=(u64)gpr[rs]*(u64)gpr[rt]; lo=(u32)r; hi=(u32)(r>>32); return; } // MULTU
    case 0x1A: { i32 d=(i32)gpr[rt]; if(d){lo=(u32)((i32)gpr[rs]/d); hi=(u32)((i32)gpr[rs]%d);} return; } // DIV
    case 0x1B: { u32 d=gpr[rt]; if(d){lo=gpr[rs]/d; hi=gpr[rs]%d;} return; } // DIVU
    case 0x20: setGPR(rd, gpr[rs] + gpr[rt]); return; // ADD
    case 0x21: setGPR(rd, gpr[rs] + gpr[rt]); return; // ADDU
    case 0x22: setGPR(rd, gpr[rs] - gpr[rt]); return; // SUB
    case 0x23: setGPR(rd, gpr[rs] - gpr[rt]); return; // SUBU
    case 0x24: setGPR(rd, gpr[rs] & gpr[rt]); return; // AND
    case 0x25: setGPR(rd, gpr[rs] | gpr[rt]); return; // OR
    case 0x26: setGPR(rd, gpr[rs] ^ gpr[rt]); return; // XOR
    case 0x27: setGPR(rd, ~(gpr[rs] | gpr[rt])); return; // NOR
    case 0x2A: setGPR(rd, (i32)gpr[rs] < (i32)gpr[rt] ? 1u : 0u); return; // SLT
    case 0x2B: setGPR(rd, gpr[rs] < gpr[rt] ? 1u : 0u); return; // SLTU
    default: return;
    }
    (void)sh;
}
