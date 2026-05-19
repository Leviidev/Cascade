import Foundation

// MARK: - MIPS R5900 Emotion Engine CPU
// The PS2's main CPU: 128-bit MIPS with custom SIMD (MMI) extensions

public final class EmotionEngine {

    // MARK: - Registers

    /// 32 general-purpose 128-bit registers (GPR)
    var gpr: [UInt128] = Array(repeating: UInt128(hi: 0, lo: 0), count: 32)
    /// Program Counter
    var pc: UInt32 = 0xBFC00000
    /// HI / LO multiply result registers (each 64-bit)
    var hi: UInt64 = 0
    var lo: UInt64 = 0
    var hi1: UInt64 = 0
    var lo1: UInt64 = 0
    /// Shift Amount (SA) register for MIPS funnel shifts
    var sa: UInt32 = 0
    /// COP0 system control registers
    var cop0: COP0Registers = COP0Registers()
    /// 32 floating-point registers (COP1 FPU)
    var fpr: [Float] = Array(repeating: 0, count: 32)
    var fpAcc: Float = 0
    /// Branch delay slot state
    var inDelaySlot: Bool = false
    var nextPC: UInt32 = 0

    // MARK: - Cycle Counter
    var cycles: UInt64 = 0
    var targetCycles: UInt64 = 0

    // MARK: - References
    weak var bus: MemoryBus?

    // MARK: - Init

    init(bus: MemoryBus) {
        self.bus = bus
        reset()
    }

    func reset() {
        gpr = Array(repeating: UInt128(hi: 0, lo: 0), count: 32)
        pc = 0xBFC00000
        hi = 0; lo = 0; hi1 = 0; lo1 = 0
        cycles = 0
        cop0.reset()
        inDelaySlot = false
        nextPC = pc &+ 4
    }

    // MARK: - Step

    func step(count: Int) {
        for _ in 0..<count {
            executeOne()
            cycles &+= 1
        }
    }

    private func executeOne() {
        guard let bus = bus else { return }
        let instruction = bus.read32(address: pc)

        if inDelaySlot {
            pc = nextPC
            inDelaySlot = false
        } else {
            pc &+= 4
        }

        decode(instruction: instruction)
    }

    // MARK: - Decode

    private func decode(instruction: UInt32) {
        let op    = (instruction >> 26) & 0x3F
        let rs    = Int((instruction >> 21) & 0x1F)
        let rt    = Int((instruction >> 16) & 0x1F)
        let rd    = Int((instruction >> 11) & 0x1F)
        let shamt = (instruction >> 6) & 0x1F
        let funct = instruction & 0x3F
        let imm16 = Int32(Int16(bitPattern: UInt16(instruction & 0xFFFF)))
        let imm26 = instruction & 0x03FF_FFFF

        switch op {
        case 0x00: decodeSpecial(funct: funct, rs: rs, rt: rt, rd: rd, shamt: shamt)
        case 0x01: decodeRegImm(rt: rt, rs: rs, offset: imm16)
        case 0x02: executeJ(imm26: imm26)
        case 0x03: executeJAL(imm26: imm26)
        case 0x04: executeBEQ(rs: rs, rt: rt, offset: imm16)
        case 0x05: executeBNE(rs: rs, rt: rt, offset: imm16)
        case 0x06: executeBLEZ(rs: rs, offset: imm16)
        case 0x07: executeBGTZ(rs: rs, offset: imm16)
        case 0x08: executeADDI(rt: rt, rs: rs, imm: imm16)
        case 0x09: executeADDIU(rt: rt, rs: rs, imm: imm16)
        case 0x0A: executeSLTI(rt: rt, rs: rs, imm: imm16)
        case 0x0B: executeSLTIU(rt: rt, rs: rs, imm: imm16)
        case 0x0C: executeANDI(rt: rt, rs: rs, imm: UInt16(instruction & 0xFFFF))
        case 0x0D: executeORI(rt: rt, rs: rs, imm: UInt16(instruction & 0xFFFF))
        case 0x0E: executeXORI(rt: rt, rs: rs, imm: UInt16(instruction & 0xFFFF))
        case 0x0F: executeLUI(rt: rt, imm: UInt16(instruction & 0xFFFF))
        case 0x10: decodeCOP0(rs: rs, rt: rt, rd: rd, instruction: instruction)
        case 0x11: decodeCOP1(rs: rs, rt: rt, rd: rd, funct: funct, instruction: instruction)
        case 0x14: executeBEQL(rs: rs, rt: rt, offset: imm16)
        case 0x15: executeBNEL(rs: rs, rt: rt, offset: imm16)
        case 0x18: executeDDIVI(rt: rt, rs: rs, imm: imm16)
        case 0x19: executeDADDIU(rt: rt, rs: rs, imm: imm16)
        case 0x1C: decodeMMI(instruction: instruction)
        case 0x1E: executeLQ(rt: rt, base: rs, offset: imm16)
        case 0x1F: executeSQ(rt: rt, base: rs, offset: imm16)
        case 0x20: executeLB(rt: rt, base: rs, offset: imm16)
        case 0x21: executeLH(rt: rt, base: rs, offset: imm16)
        case 0x22: executeLWL(rt: rt, base: rs, offset: imm16)
        case 0x23: executeLW(rt: rt, base: rs, offset: imm16)
        case 0x24: executeLBU(rt: rt, base: rs, offset: imm16)
        case 0x25: executeLHU(rt: rt, base: rs, offset: imm16)
        case 0x26: executeLWR(rt: rt, base: rs, offset: imm16)
        case 0x27: executeLWU(rt: rt, base: rs, offset: imm16)
        case 0x28: executeSB(rt: rt, base: rs, offset: imm16)
        case 0x29: executeSH(rt: rt, base: rs, offset: imm16)
        case 0x2B: executeSW(rt: rt, base: rs, offset: imm16)
        case 0x2F: executeSD(rt: rt, base: rs, offset: imm16)
        case 0x37: executeLD(rt: rt, base: rs, offset: imm16)
        case 0x3F: executeSD(rt: rt, base: rs, offset: imm16)
        default:
            handleUnknownInstruction(op: op)
        }
    }

    // MARK: - Special (R-type)

    private func decodeSpecial(funct: UInt32, rs: Int, rt: Int, rd: Int, shamt: UInt32) {
        switch funct {
        case 0x00: executeSLL(rd: rd, rt: rt, shamt: shamt)
        case 0x02: executeSRL(rd: rd, rt: rt, shamt: shamt)
        case 0x03: executeSRA(rd: rd, rt: rt, shamt: shamt)
        case 0x04: executeSLLV(rd: rd, rt: rt, rs: rs)
        case 0x06: executeSRLV(rd: rd, rt: rt, rs: rs)
        case 0x07: executeSRAV(rd: rd, rt: rt, rs: rs)
        case 0x08: executeJR(rs: rs)
        case 0x09: executeJALR(rd: rd, rs: rs)
        case 0x0C: executeSYSCALL()
        case 0x0F: executeSYNC()
        case 0x10: executeMFHI(rd: rd)
        case 0x11: executeMTHI(rs: rs)
        case 0x12: executeMFLO(rd: rd)
        case 0x13: executeMTLO(rs: rs)
        case 0x14: executeDSLLV(rd: rd, rt: rt, rs: rs)
        case 0x16: executeDSRLV(rd: rd, rt: rt, rs: rs)
        case 0x17: executeDSRAV(rd: rd, rt: rt, rs: rs)
        case 0x18: executeMULT(rs: rs, rt: rt)
        case 0x19: executeMULTU(rs: rs, rt: rt)
        case 0x1A: executeDIV(rs: rs, rt: rt)
        case 0x1B: executeDIVU(rs: rs, rt: rt)
        case 0x20: executeADD(rd: rd, rs: rs, rt: rt)
        case 0x21: executeADDU(rd: rd, rs: rs, rt: rt)
        case 0x22: executeSUB(rd: rd, rs: rs, rt: rt)
        case 0x23: executeSUBU(rd: rd, rs: rs, rt: rt)
        case 0x24: executeAND(rd: rd, rs: rs, rt: rt)
        case 0x25: executeOR(rd: rd, rs: rs, rt: rt)
        case 0x26: executeXOR(rd: rd, rs: rs, rt: rt)
        case 0x27: executeNOR(rd: rd, rs: rs, rt: rt)
        case 0x28: executeMFSA(rd: rd)
        case 0x29: executeMTSA(rs: rs)
        case 0x2A: executeSLT(rd: rd, rs: rs, rt: rt)
        case 0x2B: executeSLTU(rd: rd, rs: rs, rt: rt)
        case 0x2C: executeDADD(rd: rd, rs: rs, rt: rt)
        case 0x2D: executeDADDU(rd: rd, rs: rs, rt: rt)
        case 0x2E: executeDSUB(rd: rd, rs: rs, rt: rt)
        case 0x2F: executeDSUBU(rd: rd, rs: rs, rt: rt)
        case 0x38: executeDSLL(rd: rd, rt: rt, shamt: shamt)
        case 0x3A: executeDSRL(rd: rd, rt: rt, shamt: shamt)
        case 0x3B: executeDSRA(rd: rd, rt: rt, shamt: shamt)
        case 0x3C: executeDSLL32(rd: rd, rt: rt, shamt: shamt)
        case 0x3E: executeDSRL32(rd: rd, rt: rt, shamt: shamt)
        case 0x3F: executeDSRA32(rd: rd, rt: rt, shamt: shamt)
        default:
            handleUnknownInstruction(op: 0xFF, extra: funct)
        }
    }

    // MARK: - RegImm

    private func decodeRegImm(rt: Int, rs: Int, offset: Int32) {
        switch rt {
        case 0x00: executeBLTZ(rs: rs, offset: offset)
        case 0x01: executeBGEZ(rs: rs, offset: offset)
        case 0x02: executeBLTZL(rs: rs, offset: offset)
        case 0x03: executeBGEZL(rs: rs, offset: offset)
        case 0x10: executeBLTZAL(rs: rs, offset: offset)
        case 0x11: executeBGEZAL(rs: rs, offset: offset)
        default: break
        }
    }

    // MARK: - COP0

    private func decodeCOP0(rs: Int, rt: Int, rd: Int, instruction: UInt32) {
        switch rs {
        case 0x00: executeMFC0(rt: rt, rd: rd)
        case 0x04: executeMTC0(rt: rt, rd: rd)
        case 0x10:
            switch instruction & 0x3F {
            case 0x02: executeTLBWI()
            case 0x06: executeTLBWR()
            case 0x08: executeTLBP()
            case 0x18: executeERET()
            case 0x38: executeEI()
            case 0x39: executeDI()
            default: break
            }
        default: break
        }
    }

    // MARK: - COP1 (FPU)

    private func decodeCOP1(rs: Int, rt: Int, rd: Int, funct: UInt32, instruction: UInt32) {
        switch rs {
        case 0x00: executeMFC1(rt: rt, fs: rd)
        case 0x04: executeMTC1(rt: rt, fs: rd)
        case 0x08:
            let cc = (instruction >> 18) & 0x7
            let nd = (instruction >> 17) & 0x1
            let tf = (instruction >> 16) & 0x1
            executeFPUBranch(cc: cc, nd: nd, tf: tf, offset: Int32(Int16(bitPattern: UInt16(instruction & 0xFFFF))))
        case 0x10:
            decodeFPUArith(funct: funct, fd: rd, fs: Int((instruction >> 11) & 0x1F), ft: rt)
        default: break
        }
    }

    private func decodeFPUArith(funct: UInt32, fd: Int, fs: Int, ft: Int) {
        switch funct {
        case 0x00: fpr[fd] = fpr[fs] + fpr[ft]
        case 0x01: fpr[fd] = fpr[fs] - fpr[ft]
        case 0x02: fpr[fd] = fpr[fs] * fpr[ft]
        case 0x03: fpr[fd] = fpr[fs] / fpr[ft]
        case 0x04: fpr[fd] = sqrtf(fpr[fs])
        case 0x05: fpr[fd] = abs(fpr[fs])
        case 0x06: fpr[fd] = fpr[fs]
        case 0x07: fpr[fd] = -fpr[fs]
        case 0x18: fpAcc = fpr[fs] * fpr[ft]
        case 0x1C: fpAcc += fpr[fs] * fpr[ft]
        case 0x1D: fpAcc -= fpr[fs] * fpr[ft]
        case 0x1E: fpr[fd] = fpAcc + fpr[fs] * fpr[ft]
        case 0x1F: fpr[fd] = fpAcc - fpr[fs] * fpr[ft]
        case 0x24: fpr[fd] = Float(Int32(bitPattern: UInt32(gpr[fs].lo32)))
        case 0x28: cop0.fcr31_cond = fpr[fs] < fpr[ft]
        case 0x32: cop0.fcr31_cond = fpr[fs] == fpr[ft]
        default: break
        }
    }

    // MARK: - MMI (Multimedia Instructions — PS2 SIMD)

    private func decodeMMI(instruction: UInt32) {
        // MMI extends MIPS with 128-bit SIMD operations across the 128-bit GPRs
        // Subset implementation
        let funct = instruction & 0x3F
        let rs    = Int((instruction >> 21) & 0x1F)
        let rt    = Int((instruction >> 16) & 0x1F)
        let rd    = Int((instruction >> 11) & 0x1F)
        switch funct {
        case 0x08: // MMI0
            decodeMMI0(instruction: instruction, rs: rs, rt: rt, rd: rd)
        case 0x09: // MMI2
            decodeMMI2(instruction: instruction, rs: rs, rt: rt, rd: rd)
        case 0x28: // MMI1
            decodeMMI1(instruction: instruction, rs: rs, rt: rt, rd: rd)
        case 0x29: // MMI3
            decodeMMI3(instruction: instruction, rs: rs, rt: rt, rd: rd)
        case 0x18: // MULT1
            let a = Int64(Int32(truncatingIfNeeded: gpr[rs].lo64))
            let b = Int64(Int32(truncatingIfNeeded: gpr[rt].lo64))
            let r = a &* b
            lo1 = UInt64(bitPattern: r) & 0xFFFFFFFF
            hi1 = UInt64(bitPattern: r >> 32)
            if rd != 0 { gpr[rd] = UInt128(hi: 0, lo: lo1) }
        case 0x19: // MULTU1
            let a = UInt64(gpr[rs].lo32)
            let b = UInt64(gpr[rt].lo32)
            let r = a * b
            lo1 = r & 0xFFFFFFFF
            hi1 = r >> 32
            if rd != 0 { gpr[rd] = UInt128(hi: 0, lo: lo1) }
        case 0x1A: // DIV1
            let a = Int32(bitPattern: gpr[rs].lo32)
            let b = Int32(bitPattern: gpr[rt].lo32)
            if b != 0 { lo1 = UInt64(bitPattern: Int64(a / b)); hi1 = UInt64(bitPattern: Int64(a % b)) }
        case 0x1B: // DIVU1
            let a = gpr[rs].lo32; let b = gpr[rt].lo32
            if b != 0 { lo1 = UInt64(a / b); hi1 = UInt64(a % b) }
        case 0x10: // MFHI1
            if rd != 0 { gpr[rd] = UInt128(hi: 0, lo: hi1) }
        case 0x12: // MFLO1
            if rd != 0 { gpr[rd] = UInt128(hi: 0, lo: lo1) }
        case 0x11: // MTHI1
            hi1 = gpr[rs].lo64
        case 0x13: // MTLO1
            lo1 = gpr[rs].lo64
        default:
            break
        }
    }

    private func decodeMMI0(instruction: UInt32, rs: Int, rt: Int, rd: Int) {
        let subfunc = (instruction >> 6) & 0x1F
        switch subfunc {
        case 0x00: // PADDW — add 32-bit words in parallel
            let a = gpr[rs]; let b = gpr[rt]
            gpr[rd] = UInt128(
                hi: (a.hi &+ b.hi),
                lo: (a.lo &+ b.lo)
            )
        case 0x04: // PADDH — add 16-bit halfwords in parallel
            var result = UInt128(hi: 0, lo: 0)
            for i in 0..<8 {
                let shift = i * 16
                let av = UInt16(truncatingIfNeeded: (i < 4 ? gpr[rs].lo : gpr[rs].hi) >> ((i % 4) * 16))
                let bv = UInt16(truncatingIfNeeded: (i < 4 ? gpr[rt].lo : gpr[rt].hi) >> ((i % 4) * 16))
                let rv = UInt64(av &+ bv) << UInt64((i % 4) * 16)
                if i < 4 { result.lo |= rv } else { result.hi |= rv }
                _ = shift
            }
            gpr[rd] = result
        default: break
        }
    }

    private func decodeMMI1(instruction: UInt32, rs: Int, rt: Int, rd: Int) {
        let subfunc = (instruction >> 6) & 0x1F
        switch subfunc {
        case 0x00: // PSUBW — subtract 32-bit words
            gpr[rd] = UInt128(hi: gpr[rs].hi &- gpr[rt].hi, lo: gpr[rs].lo &- gpr[rt].lo)
        default: break
        }
    }

    private func decodeMMI2(instruction: UInt32, rs: Int, rt: Int, rd: Int) { }
    private func decodeMMI3(instruction: UInt32, rs: Int, rt: Int, rd: Int) { }

    // MARK: - Instruction Implementations

    private func gpr64(_ i: Int) -> UInt64 { gpr[i].lo64 }
    private func gpr32(_ i: Int) -> UInt32 { gpr[i].lo32 }
    private func setGPR(_ i: Int, value: UInt64) {
        guard i != 0 else { return }
        gpr[i] = UInt128(hi: value >> 63 == 0 ? 0 : 0xFFFF_FFFF_FFFF_FFFF, lo: value)
    }
    private func setGPR32(_ i: Int, value: Int32) {
        guard i != 0 else { return }
        gpr[i] = UInt128(hi: value < 0 ? 0xFFFF_FFFF_FFFF_FFFF : 0, lo: UInt64(bitPattern: Int64(value)))
    }
    private func setGPR64(_ i: Int, value: Int64) {
        guard i != 0 else { return }
        gpr[i] = UInt128(hi: value < 0 ? 0xFFFF_FFFF_FFFF_FFFF : 0, lo: UInt64(bitPattern: value))
    }

    private func branchTo(offset: Int32) {
        inDelaySlot = true
        nextPC = UInt32(bitPattern: Int32(bitPattern: pc) &+ (offset << 2))
    }
    private func branchIfFalse() { pc &+= 4 }

    // Jumps
    private func executeJ(imm26: UInt32) {
        inDelaySlot = true
        nextPC = (pc & 0xF000_0000) | (imm26 << 2)
    }
    private func executeJAL(imm26: UInt32) {
        setGPR(31, value: UInt64(pc &+ 4))
        executeJ(imm26: imm26)
    }
    private func executeJR(rs: Int) {
        inDelaySlot = true
        nextPC = gpr32(rs)
    }
    private func executeJALR(rd: Int, rs: Int) {
        let ret = UInt64(pc &+ 4)
        inDelaySlot = true
        nextPC = gpr32(rs)
        setGPR(rd, value: ret)
    }

    // Branches
    private func executeBEQ(rs: Int, rt: Int, offset: Int32) {
        if gpr64(rs) == gpr64(rt) { branchTo(offset: offset) }
    }
    private func executeBNE(rs: Int, rt: Int, offset: Int32) {
        if gpr64(rs) != gpr64(rt) { branchTo(offset: offset) }
    }
    private func executeBLEZ(rs: Int, offset: Int32) {
        if Int64(bitPattern: gpr64(rs)) <= 0 { branchTo(offset: offset) }
    }
    private func executeBGTZ(rs: Int, offset: Int32) {
        if Int64(bitPattern: gpr64(rs)) > 0 { branchTo(offset: offset) }
    }
    private func executeBEQL(rs: Int, rt: Int, offset: Int32) {
        if gpr64(rs) == gpr64(rt) { branchTo(offset: offset) } else { pc &+= 4 }
    }
    private func executeBNEL(rs: Int, rt: Int, offset: Int32) {
        if gpr64(rs) != gpr64(rt) { branchTo(offset: offset) } else { pc &+= 4 }
    }
    private func executeBLTZ(rs: Int, offset: Int32) {
        if Int64(bitPattern: gpr64(rs)) < 0 { branchTo(offset: offset) }
    }
    private func executeBGEZ(rs: Int, offset: Int32) {
        if Int64(bitPattern: gpr64(rs)) >= 0 { branchTo(offset: offset) }
    }
    private func executeBLTZL(rs: Int, offset: Int32) {
        if Int64(bitPattern: gpr64(rs)) < 0 { branchTo(offset: offset) } else { pc &+= 4 }
    }
    private func executeBGEZL(rs: Int, offset: Int32) {
        if Int64(bitPattern: gpr64(rs)) >= 0 { branchTo(offset: offset) } else { pc &+= 4 }
    }
    private func executeBLTZAL(rs: Int, offset: Int32) {
        setGPR(31, value: UInt64(pc &+ 4))
        if Int64(bitPattern: gpr64(rs)) < 0 { branchTo(offset: offset) }
    }
    private func executeBGEZAL(rs: Int, offset: Int32) {
        setGPR(31, value: UInt64(pc &+ 4))
        if Int64(bitPattern: gpr64(rs)) >= 0 { branchTo(offset: offset) }
    }
    private func executeFPUBranch(cc: UInt32, nd: UInt32, tf: UInt32, offset: Int32) {
        let cond = cop0.fcr31_cond
        let take = tf == 1 ? cond : !cond
        if take { branchTo(offset: offset) }
        else if nd == 1 { pc &+= 4 }
    }

    // Arithmetic immediate
    private func executeADDI(rt: Int, rs: Int, imm: Int32) { setGPR32(rt, value: Int32(bitPattern: gpr32(rs)) &+ imm) }
    private func executeADDIU(rt: Int, rs: Int, imm: Int32) { setGPR32(rt, value: Int32(bitPattern: gpr32(rs)) &+ imm) }
    private func executeSLTI(rt: Int, rs: Int, imm: Int32) { setGPR(rt, value: Int64(bitPattern: gpr64(rs)) < Int64(imm) ? 1 : 0) }
    private func executeSLTIU(rt: Int, rs: Int, imm: Int32) { setGPR(rt, value: gpr64(rs) < UInt64(bitPattern: Int64(imm)) ? 1 : 0) }
    private func executeANDI(rt: Int, rs: Int, imm: UInt16) { setGPR(rt, value: gpr64(rs) & UInt64(imm)) }
    private func executeORI(rt: Int, rs: Int, imm: UInt16) { setGPR(rt, value: gpr64(rs) | UInt64(imm)) }
    private func executeXORI(rt: Int, rs: Int, imm: UInt16) { setGPR(rt, value: gpr64(rs) ^ UInt64(imm)) }
    private func executeLUI(rt: Int, imm: UInt16) { setGPR32(rt, value: Int32(bitPattern: UInt32(imm) << 16)) }
    private func executeDADDIU(rt: Int, rs: Int, imm: Int32) { setGPR64(rt, value: Int64(bitPattern: gpr64(rs)) &+ Int64(imm)) }
    private func executeDDIVI(rt: Int, rs: Int, imm: Int32) { executeDADDIU(rt: rt, rs: rs, imm: imm) }

    // ALU R-type
    private func executeADD(rd: Int, rs: Int, rt: Int) { setGPR32(rd, value: Int32(bitPattern: gpr32(rs)) &+ Int32(bitPattern: gpr32(rt))) }
    private func executeADDU(rd: Int, rs: Int, rt: Int) { setGPR32(rd, value: Int32(bitPattern: gpr32(rs) &+ gpr32(rt))) }
    private func executeSUB(rd: Int, rs: Int, rt: Int) { setGPR32(rd, value: Int32(bitPattern: gpr32(rs)) &- Int32(bitPattern: gpr32(rt))) }
    private func executeSUBU(rd: Int, rs: Int, rt: Int) { setGPR32(rd, value: Int32(bitPattern: gpr32(rs) &- gpr32(rt))) }
    private func executeAND(rd: Int, rs: Int, rt: Int) { setGPR(rd, value: gpr64(rs) & gpr64(rt)) }
    private func executeOR(rd: Int, rs: Int, rt: Int) { setGPR(rd, value: gpr64(rs) | gpr64(rt)) }
    private func executeXOR(rd: Int, rs: Int, rt: Int) { setGPR(rd, value: gpr64(rs) ^ gpr64(rt)) }
    private func executeNOR(rd: Int, rs: Int, rt: Int) { setGPR(rd, value: ~(gpr64(rs) | gpr64(rt))) }
    private func executeSLT(rd: Int, rs: Int, rt: Int) { setGPR(rd, value: Int64(bitPattern: gpr64(rs)) < Int64(bitPattern: gpr64(rt)) ? 1 : 0) }
    private func executeSLTU(rd: Int, rs: Int, rt: Int) { setGPR(rd, value: gpr64(rs) < gpr64(rt) ? 1 : 0) }
    private func executeDADD(rd: Int, rs: Int, rt: Int) { setGPR64(rd, value: Int64(bitPattern: gpr64(rs)) &+ Int64(bitPattern: gpr64(rt))) }
    private func executeDADDU(rd: Int, rs: Int, rt: Int) { setGPR(rd, value: gpr64(rs) &+ gpr64(rt)) }
    private func executeDSUB(rd: Int, rs: Int, rt: Int) { setGPR64(rd, value: Int64(bitPattern: gpr64(rs)) &- Int64(bitPattern: gpr64(rt))) }
    private func executeDSUBU(rd: Int, rs: Int, rt: Int) { setGPR(rd, value: gpr64(rs) &- gpr64(rt)) }

    // Shifts
    private func executeSLL(rd: Int, rt: Int, shamt: UInt32) { setGPR32(rd, value: Int32(bitPattern: gpr32(rt) << shamt)) }
    private func executeSRL(rd: Int, rt: Int, shamt: UInt32) { setGPR32(rd, value: Int32(bitPattern: gpr32(rt) >> shamt)) }
    private func executeSRA(rd: Int, rt: Int, shamt: UInt32) { setGPR32(rd, value: Int32(bitPattern: gpr32(rt)) >> shamt) }
    private func executeSLLV(rd: Int, rt: Int, rs: Int) { setGPR32(rd, value: Int32(bitPattern: gpr32(rt) << (gpr32(rs) & 0x1F))) }
    private func executeSRLV(rd: Int, rt: Int, rs: Int) { setGPR32(rd, value: Int32(bitPattern: gpr32(rt) >> (gpr32(rs) & 0x1F))) }
    private func executeSRAV(rd: Int, rt: Int, rs: Int) { setGPR32(rd, value: Int32(bitPattern: gpr32(rt)) >> (gpr32(rs) & 0x1F)) }
    private func executeDSLL(rd: Int, rt: Int, shamt: UInt32) { setGPR(rd, value: gpr64(rt) << shamt) }
    private func executeDSRL(rd: Int, rt: Int, shamt: UInt32) { setGPR(rd, value: gpr64(rt) >> shamt) }
    private func executeDSRA(rd: Int, rt: Int, shamt: UInt32) { setGPR64(rd, value: Int64(bitPattern: gpr64(rt)) >> shamt) }
    private func executeDSLL32(rd: Int, rt: Int, shamt: UInt32) { setGPR(rd, value: gpr64(rt) << (32 + shamt)) }
    private func executeDSRL32(rd: Int, rt: Int, shamt: UInt32) { setGPR(rd, value: gpr64(rt) >> (32 + shamt)) }
    private func executeDSRA32(rd: Int, rt: Int, shamt: UInt32) { setGPR64(rd, value: Int64(bitPattern: gpr64(rt)) >> (32 + shamt)) }
    private func executeDSLLV(rd: Int, rt: Int, rs: Int) { setGPR(rd, value: gpr64(rt) << (gpr64(rs) & 0x3F)) }
    private func executeDSRLV(rd: Int, rt: Int, rs: Int) { setGPR(rd, value: gpr64(rt) >> (gpr64(rs) & 0x3F)) }
    private func executeDSRAV(rd: Int, rt: Int, rs: Int) { setGPR64(rd, value: Int64(bitPattern: gpr64(rt)) >> (gpr64(rs) & 0x3F)) }

    // Multiply / Divide
    private func executeMULT(rs: Int, rt: Int) {
        let a = Int64(Int32(bitPattern: gpr32(rs))); let b = Int64(Int32(bitPattern: gpr32(rt)))
        let r = a &* b; lo = UInt64(bitPattern: r) & 0xFFFFFFFF; hi = UInt64(bitPattern: r) >> 32
    }
    private func executeMULTU(rs: Int, rt: Int) {
        let r = UInt64(gpr32(rs)) * UInt64(gpr32(rt)); lo = r & 0xFFFFFFFF; hi = r >> 32
    }
    private func executeDIV(rs: Int, rt: Int) {
        let a = Int32(bitPattern: gpr32(rs)); let b = Int32(bitPattern: gpr32(rt))
        guard b != 0 else { return }
        lo = UInt64(bitPattern: Int64(a / b)); hi = UInt64(bitPattern: Int64(a % b))
    }
    private func executeDIVU(rs: Int, rt: Int) {
        let b = gpr32(rt); guard b != 0 else { return }
        lo = UInt64(gpr32(rs) / b); hi = UInt64(gpr32(rs) % b)
    }

    // HI/LO / SA moves
    private func executeMFHI(rd: Int) { setGPR64(rd, value: Int64(bitPattern: hi)) }
    private func executeMTHI(rs: Int) { hi = gpr64(rs) }
    private func executeMFLO(rd: Int) { setGPR64(rd, value: Int64(bitPattern: lo)) }
    private func executeMTLO(rs: Int) { lo = gpr64(rs) }
    private func executeMFSA(rd: Int) { setGPR(rd, value: UInt64(sa)) }
    private func executeMTSA(rs: Int) { sa = gpr32(rs) & 0xF }

    // Memory access
    private func ea(base: Int, offset: Int32) -> UInt32 { UInt32(bitPattern: Int32(bitPattern: gpr32(base)) &+ offset) }
    private func executeLB(rt: Int, base: Int, offset: Int32) { setGPR32(rt, value: Int32(Int8(bitPattern: bus!.read8(address: ea(base: base, offset: offset))))) }
    private func executeLBU(rt: Int, base: Int, offset: Int32) { setGPR(rt, value: UInt64(bus!.read8(address: ea(base: base, offset: offset)))) }
    private func executeLH(rt: Int, base: Int, offset: Int32) { setGPR32(rt, value: Int32(Int16(bitPattern: bus!.read16(address: ea(base: base, offset: offset))))) }
    private func executeLHU(rt: Int, base: Int, offset: Int32) { setGPR(rt, value: UInt64(bus!.read16(address: ea(base: base, offset: offset)))) }
    private func executeLW(rt: Int, base: Int, offset: Int32) { setGPR32(rt, value: Int32(bitPattern: bus!.read32(address: ea(base: base, offset: offset)))) }
    private func executeLWU(rt: Int, base: Int, offset: Int32) { setGPR(rt, value: UInt64(bus!.read32(address: ea(base: base, offset: offset)))) }
    private func executeLD(rt: Int, base: Int, offset: Int32) { setGPR(rt, value: bus!.read64(address: ea(base: base, offset: offset))) }
    private func executeLQ(rt: Int, base: Int, offset: Int32) { gpr[rt] = bus!.read128(address: ea(base: base, offset: offset) & ~0xF) }
    private func executeLWL(rt: Int, base: Int, offset: Int32) { /* Unaligned load left — simplified */ executeLW(rt: rt, base: base, offset: offset) }
    private func executeLWR(rt: Int, base: Int, offset: Int32) { /* Unaligned load right — simplified */ }
    private func executeSB(rt: Int, base: Int, offset: Int32) { bus!.write8(address: ea(base: base, offset: offset), value: UInt8(gpr32(rt) & 0xFF)) }
    private func executeSH(rt: Int, base: Int, offset: Int32) { bus!.write16(address: ea(base: base, offset: offset), value: UInt16(gpr32(rt) & 0xFFFF)) }
    private func executeSW(rt: Int, base: Int, offset: Int32) { bus!.write32(address: ea(base: base, offset: offset), value: gpr32(rt)) }
    private func executeSD(rt: Int, base: Int, offset: Int32) { bus!.write64(address: ea(base: base, offset: offset), value: gpr64(rt)) }
    private func executeSQ(rt: Int, base: Int, offset: Int32) { bus!.write128(address: ea(base: base, offset: offset) & ~0xF, value: gpr[rt]) }

    // COP0
    private func executeMFC0(rt: Int, rd: Int) { setGPR32(rt, value: Int32(bitPattern: cop0.read(register: rd))) }
    private func executeMTC0(rt: Int, rd: Int) { cop0.write(register: rd, value: gpr32(rt)) }
    private func executeTLBWI() { cop0.tlbWriteIndexed() }
    private func executeTLBWR() { cop0.tlbWriteRandom() }
    private func executeTLBP() { cop0.tlbProbe() }
    private func executeERET() { pc = cop0.epc; cop0.status &= ~(UInt32(1) << 1) }
    private func executeEI() { cop0.status |= (1 << 16) }
    private func executeDI() { cop0.status &= ~(1 << 16) }

    // COP1
    private func executeMFC1(rt: Int, fs: Int) { setGPR32(rt, value: Int32(bitPattern: fpr[fs].bitPattern)) }
    private func executeMTC1(rt: Int, fs: Int) { fpr[fs] = Float(bitPattern: gpr32(rt)) }

    // System
    private func executeSYSCALL() { cop0.triggerException(type: .syscall) }
    private func executeSYNC() { /* memory barrier — no-op in interpreter */ }

    private func handleUnknownInstruction(op: UInt32, extra: UInt32 = 0) {
        // In a real emulator, trigger a reserved instruction exception
        cop0.triggerException(type: .reservedInstruction)
    }
}

// MARK: - UInt128 helper

struct UInt128 {
    var hi: UInt64
    var lo: UInt64

    var lo64: UInt64 { lo }
    var lo32: UInt32 { UInt32(lo & 0xFFFF_FFFF) }
}
