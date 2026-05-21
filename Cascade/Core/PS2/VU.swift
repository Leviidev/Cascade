import Foundation
import simd

// MARK: - Vector Unit (VU0 / VU1)
//
// VU0: 4 KB data mem, 4 KB micro mem — used in macro mode (COP2) and micro mode
// VU1: 16 KB data mem, 16 KB micro mem — used for vertex transformation, XGKICK feeds GS
//
// Each VU has:
//   VF[0..31]  128-bit FMAC registers (float4, VF[0] = const 0,0,0,1)
//   VI[0..15]  16-bit integer registers (VI[0] = const 0)
//   ACC        128-bit FMAC accumulator
//   Q          quotient from DIV / SQRT / RSQRT
//   P          EFU result
//   R          random number state
//   CMSAR0/1   micro subroutine address

public final class VectorUnit {

    // MARK: - Identity

    let index: Int   // 0 = VU0, 1 = VU1

    // MARK: - Registers

    var vf: [SIMD4<Float>]          // 32 VF registers
    var vi: [UInt16]                 // 16 VI registers (VI[0] always 0)
    var acc: SIMD4<Float>
    var q: Float        // quotient
    var p: Float        // EFU result
    var r: UInt32       // PRNG state

    // MARK: - Memory

    var dataMem: [UInt8]             // VU0: 4 KB, VU1: 16 KB
    var microMem: [UInt8]            // VU0: 4 KB, VU1: 16 KB
    let dataSize: Int
    let microSize: Int

    // MARK: - Execution State

    var pc: UInt32 = 0
    var running: Bool = false
    var cycles: UInt64 = 0

    // MARK: - Status / Clip / MAC flags

    var statusFlag: UInt32 = 0
    var macFlag: UInt32 = 0
    var clipFlag: UInt32 = 0

    // MARK: - Callback to GS (VU1 XGKICK)

    var onXGKICK: (([UInt8], Int) -> Void)?

    // MARK: - Init

    init(index: Int) {
        self.index = index
        dataSize  = index == 0 ? 4 * 1024  : 16 * 1024
        microSize = index == 0 ? 4 * 1024  : 16 * 1024
        dataMem   = [UInt8](repeating: 0, count: dataSize)
        microMem  = [UInt8](repeating: 0, count: microSize)
        vf  = Array(repeating: .zero, count: 32)
        vi  = Array(repeating: 0,     count: 16)
        acc = .zero
        q   = 0; p = 0; r = 0x00411117
        vf[0] = SIMD4<Float>(0, 0, 0, 1)  // VF[0] hardwired
    }

    func reset() {
        pc = 0; running = false; cycles = 0
        vf  = Array(repeating: .zero, count: 32)
        vi  = Array(repeating: 0,     count: 16)
        acc = .zero
        vf[0] = SIMD4<Float>(0, 0, 0, 1)
        statusFlag = 0; macFlag = 0; clipFlag = 0
        q = 0; p = 0
    }

    // MARK: - Data Memory Access

    func readDataFloat(_ addr: UInt16) -> SIMD4<Float> {
        let off = Int(addr) * 16 % dataSize
        guard off + 16 <= dataMem.count else { return .zero }
        var result = SIMD4<Float>()
        for i in 0..<4 {
            let bits = dataMem.withUnsafeBytes { $0.load(fromByteOffset: off + i * 4, as: UInt32.self).littleEndian }
            result[i] = Float(bitPattern: bits)
        }
        return result
    }

    func writeDataFloat(_ addr: UInt16, value: SIMD4<Float>) {
        let off = Int(addr) * 16 % dataSize
        guard off + 16 <= dataMem.count else { return }
        for i in 0..<4 {
            let bits = value[i].bitPattern.littleEndian
            dataMem.withUnsafeMutableBytes { $0.storeBytes(of: bits, toByteOffset: off + i * 4, as: UInt32.self) }
        }
    }

    func readData32(_ byteOffset: Int) -> UInt32 {
        let off = byteOffset % dataSize
        guard off + 4 <= dataMem.count else { return 0 }
        return dataMem.withUnsafeBytes { $0.load(fromByteOffset: off, as: UInt32.self).littleEndian }
    }

    func writeData32(_ byteOffset: Int, value: UInt32) {
        let off = byteOffset % dataSize
        guard off + 4 <= dataMem.count else { return }
        dataMem.withUnsafeMutableBytes { $0.storeBytes(of: value.littleEndian, toByteOffset: off, as: UInt32.self) }
    }

    func writeData128Bytes(_ byteOffset: Int, bytes: [UInt8]) {
        let off = byteOffset % dataSize
        let len = min(16, dataMem.count - off)
        guard len > 0 else { return }
        for i in 0..<min(len, bytes.count) {
            dataMem[off + i] = bytes[i]
        }
    }

    // MARK: - Micro Memory Access

    func readMicro64(at index: Int) -> UInt64 {
        let off = (index * 8) % microSize
        guard off + 8 <= microMem.count else { return 0 }
        return microMem.withUnsafeBytes { $0.load(fromByteOffset: off, as: UInt64.self).littleEndian }
    }

    func writeMicro(at byteOffset: Int, words: [UInt64]) {
        var off = byteOffset % microSize
        for w in words {
            guard off + 8 <= microMem.count else { break }
            microMem.withUnsafeMutableBytes { $0.storeBytes(of: w.littleEndian, toByteOffset: off, as: UInt64.self) }
            off += 8
        }
    }

    // MARK: - Run Microprogram

    func run(maxCycles: Int = 256) {
        running = true
        var n = 0
        while running && n < maxCycles {
            let qword = readMicro64(at: Int(pc))
            let upper = UInt32(qword >> 32)
            let lower = UInt32(qword & 0xFFFF_FFFF)
            let eop   = (upper >> 30) & 1      // End-of-Program bit
            let ibit  = (upper >> 31) & 1      // I-bit: lower is immediate

            pc += 1
            executeUpper(upper)
            if ibit != 0 {
                // Lower slot is a 32-bit immediate loaded into I register (ignored here)
            } else {
                executeLower(lower)
            }

            cycles += 1
            n += 1
            if eop != 0 { running = false }
        }
    }

    // MARK: - Register Helpers

    private func getVF(_ idx: Int) -> SIMD4<Float> {
        idx == 0 ? SIMD4<Float>(0, 0, 0, 1) : vf[idx & 31]
    }
    private func setVF(_ idx: Int, _ val: SIMD4<Float>) {
        guard idx != 0 else { return }
        vf[idx & 31] = val
    }
    private func getVI(_ idx: Int) -> UInt16 { idx == 0 ? 0 : vi[idx & 15] }
    private func setVI(_ idx: Int, _ val: UInt16) { guard idx != 0 else { return }; vi[idx & 15] = val }

    // Dest mask: bit3=X, bit2=Y, bit1=Z, bit0=W
    private func applyDest(_ dest: Int, old: SIMD4<Float>, new: SIMD4<Float>) -> SIMD4<Float> {
        SIMD4<Float>(
            (dest & 8) != 0 ? new.x : old.x,
            (dest & 4) != 0 ? new.y : old.y,
            (dest & 2) != 0 ? new.z : old.z,
            (dest & 1) != 0 ? new.w : old.w
        )
    }

    // Broadcast component from BC field (0=x, 1=y, 2=z, 3=w)
    private func broadcast(_ v: SIMD4<Float>, bc: Int) -> SIMD4<Float> {
        let s: Float
        switch bc & 3 {
        case 0: s = v.x
        case 1: s = v.y
        case 2: s = v.z
        default: s = v.w
        }
        return SIMD4<Float>(s, s, s, s)
    }

    // MARK: - Upper Instruction Execution
    //
    // Upper word (bits 25:0 of the raw upper word after stripping I/E/M/D/T):
    //   bits [11:6]  = opcode
    //   bits [5:2]   = DEST mask
    //   bits [1:0]   = BC or sub-type
    //   bits [25:21] = FT
    //   bits [20:16] = FS
    //   bits [15:11] = FD (upper instructions)
    //   Actually: bits[15:11] = FD for most; for some it's part of opcode

    private func executeUpper(_ raw: UInt32) {
        // Strip flag bits [31:27]
        let instr  = raw & 0x07FF_FFFF
        let opcode = (instr >> 2) & 0x3F      // bits [7:2]
        let dest   = Int(instr & 0xF)          // bits [3:0] after opcode shift... 

        // Standard upper encoding:
        // [25:21] ft, [20:16] fs, [15:11] fd, [5:2] DEST, [1:0] BC
        let ft   = Int((raw >> 16) & 0x1F)
        let fs   = Int((raw >> 11) & 0x1F)
        let fd   = Int((raw >>  6) & 0x1F)
        let destf = Int((raw >>  2) & 0xF)   // XYZW dest mask after stripping I/E flags
        let bc   = Int(raw & 0x3)
        // opcode occupies bits [12:6] after removing flags
        let opc  = (raw >> 2) & 0x3F

        switch opc {
        case 0x00, 0x01, 0x02, 0x03: // ADDbc.x/y/z/w
            let bcComp = Int(raw & 3)
            let result = getVF(fd)
            let r = getVF(fs) + broadcast(getVF(ft), bc: bcComp)
            setVF(fd, applyDest(destf, old: result, new: r))
        case 0x04, 0x05, 0x06, 0x07: // SUBbc
            let bcComp = Int(raw & 3)
            let result = getVF(fd)
            let r = getVF(fs) - broadcast(getVF(ft), bc: bcComp)
            setVF(fd, applyDest(destf, old: result, new: r))
        case 0x08, 0x09, 0x0A, 0x0B: // MADDbc
            let bcComp = Int(raw & 3)
            let old = getVF(fd)
            let r = acc + getVF(fs) * broadcast(getVF(ft), bc: bcComp)
            setVF(fd, applyDest(destf, old: old, new: r))
        case 0x0C, 0x0D, 0x0E, 0x0F: // MSUBbc
            let bcComp = Int(raw & 3)
            let old = getVF(fd)
            let r = acc - getVF(fs) * broadcast(getVF(ft), bc: bcComp)
            setVF(fd, applyDest(destf, old: old, new: r))
        case 0x10, 0x11, 0x12, 0x13: // MAXbc
            let bcComp = Int(raw & 3)
            let old = getVF(fd)
            let r = simd_max(getVF(fs), broadcast(getVF(ft), bc: bcComp))
            setVF(fd, applyDest(destf, old: old, new: r))
        case 0x14, 0x15, 0x16, 0x17: // MINIbc
            let bcComp = Int(raw & 3)
            let old = getVF(fd)
            let r = simd_min(getVF(fs), broadcast(getVF(ft), bc: bcComp))
            setVF(fd, applyDest(destf, old: old, new: r))
        case 0x18, 0x19, 0x1A, 0x1B: // MULbc
            let bcComp = Int(raw & 3)
            let old = getVF(fd)
            let r = getVF(fs) * broadcast(getVF(ft), bc: bcComp)
            setVF(fd, applyDest(destf, old: old, new: r))
        case 0x1C: // MULq
            let old = getVF(fd)
            let r = getVF(fs) * SIMD4<Float>(q, q, q, q)
            setVF(fd, applyDest(destf, old: old, new: r))
        case 0x1D: // MAXi
            let old = getVF(fd); let iv = p  // I register (treated as P here)
            let r = simd_max(getVF(fs), SIMD4<Float>(iv, iv, iv, iv))
            setVF(fd, applyDest(destf, old: old, new: r))
        case 0x1E: // MULi
            let iv = p
            let old = getVF(fd)
            let r = getVF(fs) * SIMD4<Float>(iv, iv, iv, iv)
            setVF(fd, applyDest(destf, old: old, new: r))
        case 0x1F: // MINIi
            let iv = p; let old = getVF(fd)
            let r = simd_min(getVF(fs), SIMD4<Float>(iv, iv, iv, iv))
            setVF(fd, applyDest(destf, old: old, new: r))
        case 0x20: // ADDq
            let old = getVF(fd)
            let r = getVF(fs) + SIMD4<Float>(q, q, q, q)
            setVF(fd, applyDest(destf, old: old, new: r))
        case 0x21: // MADDq
            let old = getVF(fd)
            let r = acc + getVF(fs) * SIMD4<Float>(q, q, q, q)
            setVF(fd, applyDest(destf, old: old, new: r))
        case 0x22: // ADDi
            let iv = p; let old = getVF(fd)
            let r = getVF(fs) + SIMD4<Float>(iv, iv, iv, iv)
            setVF(fd, applyDest(destf, old: old, new: r))
        case 0x23: // MADDi
            let iv = p; let old = getVF(fd)
            let r = acc + getVF(fs) * SIMD4<Float>(iv, iv, iv, iv)
            setVF(fd, applyDest(destf, old: old, new: r))
        case 0x24: // SUBq
            let old = getVF(fd)
            let r = getVF(fs) - SIMD4<Float>(q, q, q, q)
            setVF(fd, applyDest(destf, old: old, new: r))
        case 0x25: // MSUBq
            let old = getVF(fd)
            let r = acc - getVF(fs) * SIMD4<Float>(q, q, q, q)
            setVF(fd, applyDest(destf, old: old, new: r))
        case 0x26: // SUBi
            let iv = p; let old = getVF(fd)
            let r = getVF(fs) - SIMD4<Float>(iv, iv, iv, iv)
            setVF(fd, applyDest(destf, old: old, new: r))
        case 0x27: // MSUBi
            let iv = p; let old = getVF(fd)
            let r = acc - getVF(fs) * SIMD4<Float>(iv, iv, iv, iv)
            setVF(fd, applyDest(destf, old: old, new: r))
        case 0x28: // ADD
            let old = getVF(fd)
            let r = getVF(fs) + getVF(ft)
            setVF(fd, applyDest(destf, old: old, new: r))
        case 0x29: // MADD
            let old = getVF(fd)
            let r = acc + getVF(fs) * getVF(ft)
            setVF(fd, applyDest(destf, old: old, new: r))
        case 0x2A: // MUL
            let old = getVF(fd)
            let r = getVF(fs) * getVF(ft)
            setVF(fd, applyDest(destf, old: old, new: r))
        case 0x2B: // MAX
            let old = getVF(fd)
            let r = simd_max(getVF(fs), getVF(ft))
            setVF(fd, applyDest(destf, old: old, new: r))
        case 0x2C: // SUB
            let old = getVF(fd)
            let r = getVF(fs) - getVF(ft)
            setVF(fd, applyDest(destf, old: old, new: r))
        case 0x2D: // MSUB
            let old = getVF(fd)
            let r = acc - getVF(fs) * getVF(ft)
            setVF(fd, applyDest(destf, old: old, new: r))
        case 0x2E: // OPMSUB — cross product style: FD.xyz = ACC.xyz - FS.xyz × FT.xyz (cyclic)
            let s = getVF(fs); let t = getVF(ft)
            let rx = acc.x - s.y * t.z
            let ry = acc.y - s.z * t.x
            let rz = acc.z - s.x * t.y
            let old = getVF(fd)
            setVF(fd, applyDest(destf & 0xE, old: old, new: SIMD4<Float>(rx, ry, rz, old.w)))
        case 0x2F: // MINI
            let old = getVF(fd)
            let r = simd_min(getVF(fs), getVF(ft))
            setVF(fd, applyDest(destf, old: old, new: r))
        case 0x3C: // Upper-special group (bits[5:2] encode sub-opcode)
            executeUpperSpecial(raw)
        case 0x3D, 0x3E, 0x3F:
            executeUpperSpecial(raw)
        default:
            break
        }
        _ = (ft, fs, fd, dest, bc, opcode)
    }

    private func executeUpperSpecial(_ raw: UInt32) {
        let ft    = Int((raw >> 16) & 0x1F)
        let fs    = Int((raw >> 11) & 0x1F)
        let fd    = Int((raw >>  6) & 0x1F)
        let destf = Int((raw >>  2) & 0xF)
        let sub   = (raw) & 0x3F

        switch sub {
        case 0x00: // ADDABC.x
            acc = applyDest(destf, old: acc, new: acc + broadcast(getVF(ft), bc: 0))
        case 0x01: // ADDABC.y
            acc = applyDest(destf, old: acc, new: acc + broadcast(getVF(ft), bc: 1))
        case 0x02: // ADDABC.z
            acc = applyDest(destf, old: acc, new: acc + broadcast(getVF(ft), bc: 2))
        case 0x03: // ADDABC.w
            acc = applyDest(destf, old: acc, new: acc + broadcast(getVF(ft), bc: 3))
        case 0x04, 0x05, 0x06, 0x07: // SUBAbc
            let bcComp = Int(sub & 3)
            acc = applyDest(destf, old: acc, new: getVF(fs) - broadcast(getVF(ft), bc: bcComp))
        case 0x08, 0x09, 0x0A, 0x0B: // MADDAbc
            let bcComp = Int(sub & 3)
            acc = applyDest(destf, old: acc, new: acc + getVF(fs) * broadcast(getVF(ft), bc: bcComp))
        case 0x0C, 0x0D, 0x0E, 0x0F: // MSUBAbc
            let bcComp = Int(sub & 3)
            acc = applyDest(destf, old: acc, new: acc - getVF(fs) * broadcast(getVF(ft), bc: bcComp))
        case 0x10: // ITOF0
            let r = SIMD4<Float>(
                Float(Int32(bitPattern: UInt32(getVF(fs).x.bitPattern))),
                Float(Int32(bitPattern: UInt32(getVF(fs).y.bitPattern))),
                Float(Int32(bitPattern: UInt32(getVF(fs).z.bitPattern))),
                Float(Int32(bitPattern: UInt32(getVF(fs).w.bitPattern)))
            )
            setVF(fd, applyDest(destf, old: getVF(fd), new: r))
        case 0x11: // ITOF4
            let scale: Float = 1.0 / 16.0
            let r = SIMD4<Float>(
                Float(Int32(bitPattern: UInt32(getVF(fs).x.bitPattern))) * scale,
                Float(Int32(bitPattern: UInt32(getVF(fs).y.bitPattern))) * scale,
                Float(Int32(bitPattern: UInt32(getVF(fs).z.bitPattern))) * scale,
                Float(Int32(bitPattern: UInt32(getVF(fs).w.bitPattern))) * scale
            )
            setVF(fd, applyDest(destf, old: getVF(fd), new: r))
        case 0x12: // ITOF12
            let scale: Float = 1.0 / 4096.0
            let r = SIMD4<Float>(
                Float(Int32(bitPattern: UInt32(getVF(fs).x.bitPattern))) * scale,
                Float(Int32(bitPattern: UInt32(getVF(fs).y.bitPattern))) * scale,
                Float(Int32(bitPattern: UInt32(getVF(fs).z.bitPattern))) * scale,
                Float(Int32(bitPattern: UInt32(getVF(fs).w.bitPattern))) * scale
            )
            setVF(fd, applyDest(destf, old: getVF(fd), new: r))
        case 0x13: // ITOF15
            let scale: Float = 1.0 / 32768.0
            let r = SIMD4<Float>(
                Float(Int32(bitPattern: UInt32(getVF(fs).x.bitPattern))) * scale,
                Float(Int32(bitPattern: UInt32(getVF(fs).y.bitPattern))) * scale,
                Float(Int32(bitPattern: UInt32(getVF(fs).z.bitPattern))) * scale,
                Float(Int32(bitPattern: UInt32(getVF(fs).w.bitPattern))) * scale
            )
            setVF(fd, applyDest(destf, old: getVF(fd), new: r))
        case 0x14: // FTOI0
            let s = getVF(fs)
            let r = SIMD4<Float>(
                Float(bitPattern: UInt32(bitPattern: Int32(s.x.isNaN ? 0 : max(-2147483648, min(2147483647, s.x))))),
                Float(bitPattern: UInt32(bitPattern: Int32(s.y.isNaN ? 0 : max(-2147483648, min(2147483647, s.y))))),
                Float(bitPattern: UInt32(bitPattern: Int32(s.z.isNaN ? 0 : max(-2147483648, min(2147483647, s.z))))),
                Float(bitPattern: UInt32(bitPattern: Int32(s.w.isNaN ? 0 : max(-2147483648, min(2147483647, s.w)))))
            )
            setVF(fd, applyDest(destf, old: getVF(fd), new: r))
        case 0x15: // FTOI4
            let scale: Float = 16.0; let s = getVF(fs) * SIMD4<Float>(scale, scale, scale, scale)
            let r = SIMD4<Float>(
                Float(bitPattern: UInt32(bitPattern: Int32(s.x.isNaN ? 0 : max(-2147483648, min(2147483647, s.x))))),
                Float(bitPattern: UInt32(bitPattern: Int32(s.y.isNaN ? 0 : max(-2147483648, min(2147483647, s.y))))),
                Float(bitPattern: UInt32(bitPattern: Int32(s.z.isNaN ? 0 : max(-2147483648, min(2147483647, s.z))))),
                Float(bitPattern: UInt32(bitPattern: Int32(s.w.isNaN ? 0 : max(-2147483648, min(2147483647, s.w)))))
            )
            setVF(fd, applyDest(destf, old: getVF(fd), new: r))
        case 0x17: // FTOI15
            let scale: Float = 32768.0; let s = getVF(fs) * SIMD4<Float>(scale, scale, scale, scale)
            let r = SIMD4<Float>(
                Float(bitPattern: UInt32(bitPattern: Int32(s.x.isNaN ? 0 : max(-2147483648, min(2147483647, s.x))))),
                Float(bitPattern: UInt32(bitPattern: Int32(s.y.isNaN ? 0 : max(-2147483648, min(2147483647, s.y))))),
                Float(bitPattern: UInt32(bitPattern: Int32(s.z.isNaN ? 0 : max(-2147483648, min(2147483647, s.z))))),
                Float(bitPattern: UInt32(bitPattern: Int32(s.w.isNaN ? 0 : max(-2147483648, min(2147483647, s.w)))))
            )
            setVF(fd, applyDest(destf, old: getVF(fd), new: r))
        case 0x18: // MULAq
            acc = applyDest(destf, old: acc, new: getVF(fs) * SIMD4<Float>(q, q, q, q))
        case 0x19: // ABS
            setVF(ft, applyDest(destf, old: getVF(ft), new: abs(getVF(fs))))
        case 0x1A: // MULAi
            let iv = p
            acc = applyDest(destf, old: acc, new: getVF(fs) * SIMD4<Float>(iv, iv, iv, iv))
        case 0x1B: // CLIP — compare fs against |w| of ft, update clipFlag
            let s = getVF(fs); let w = abs(getVF(ft).w)
            var cf: UInt32 = (clipFlag << 6) & 0x00FF_FFC0
            if s.x >  w  { cf |= 0x01 }; if s.x < -w  { cf |= 0x02 }
            if s.y >  w  { cf |= 0x04 }; if s.y < -w  { cf |= 0x08 }
            if s.z >  w  { cf |= 0x10 }; if s.z < -w  { cf |= 0x20 }
            clipFlag = cf
        case 0x1C: // MADDAq
            acc = applyDest(destf, old: acc, new: acc + getVF(fs) * SIMD4<Float>(q, q, q, q))
        case 0x1D: // MULAi (alt)
            acc = applyDest(destf, old: acc, new: getVF(fs) * getVF(ft))
        case 0x1E: // MADDAi
            let iv = p
            acc = applyDest(destf, old: acc, new: acc + getVF(fs) * SIMD4<Float>(iv, iv, iv, iv))
        case 0x1F: // MSUBAi
            let iv = p
            acc = applyDest(destf, old: acc, new: acc - getVF(fs) * SIMD4<Float>(iv, iv, iv, iv))
        case 0x20: // ADDA
            acc = applyDest(destf, old: acc, new: getVF(fs) + getVF(ft))
        case 0x21: // MADDA
            acc = applyDest(destf, old: acc, new: acc + getVF(fs) * getVF(ft))
        case 0x22: // MULA
            acc = applyDest(destf, old: acc, new: getVF(fs) * getVF(ft))
        case 0x24: // SUBA
            acc = applyDest(destf, old: acc, new: getVF(fs) - getVF(ft))
        case 0x25: // MSUBA
            acc = applyDest(destf, old: acc, new: acc - getVF(fs) * getVF(ft))
        case 0x27: // MINI (alt encoding)
            setVF(fd, applyDest(destf, old: getVF(fd), new: simd_min(getVF(fs), getVF(ft))))
        case 0x28: // OPMULA — ACC.xyz = FS.yzx × FT.zxy
            let s = getVF(fs); let t = getVF(ft)
            let nx = s.y * t.z; let ny = s.z * t.x; let nz = s.x * t.y
            acc = applyDest(destf & 0xE, old: acc, new: SIMD4<Float>(nx, ny, nz, acc.w))
        case 0x29: // NOP
            break
        case 0x2F: // NOP alt
            break
        default:
            break
        }
        _ = (ft, fs, fd, destf, sub)
    }

    // MARK: - Lower Instruction Execution
    //
    // Lower word [31:0]:
    //   bits [31:25]: opcode
    //   bits [24:0]:  operands (vary by instruction)

    private func executeLower(_ raw: UInt32) {
        let opc  = (raw >> 25) & 0x7F
        let it   = Int((raw >> 16) & 0xF)    // VI destination/target (4-bit)
        let is_  = Int((raw >> 11) & 0xF)    // VI source
        let id   = Int((raw >>  6) & 0xF)    // VI index/data
        let ft   = Int((raw >> 16) & 0x1F)   // VF ft (for LQ/SQ)
        let fs   = Int((raw >> 11) & 0x1F)   // VF fs
        let dest = Int((raw >>  2) & 0xF)    // DEST
        let imm11 = Int32(bitPattern: (UInt32((raw & 0x7FF)) | ((raw & (1 << 10)) != 0 ? 0xFFFF_F800 : 0)))
        let imm15 = Int32(bitPattern: (raw & 0x7FFF) | ((raw & (1 << 14)) != 0 ? 0xFFFF_8000 : 0))

        switch opc {
        case 0x00: // LQ — load VF from VU memory: FT = VUmem[IS + imm11]
            let addr = (Int(getVI(is_)) + Int(imm11)) & ((dataSize / 16) - 1)
            let old = getVF(ft)
            setVF(ft, applyDest(dest, old: old, new: readDataFloat(UInt16(addr))))
        case 0x01: // SQ — store VF to VU memory: VUmem[IT + imm11] = FS
            let addr = (Int(getVI(it)) + Int(imm11)) & ((dataSize / 16) - 1)
            let old = readDataFloat(UInt16(addr))
            writeDataFloat(UInt16(addr), value: applyDest(dest, old: old, new: getVF(fs)))
        case 0x04: // ILW — load VI: IT = VUmem[IS + imm11].element
            let addr = UInt16((Int(getVI(is_)) + Int(imm11)) & ((dataSize / 16) - 1))
            let qw = readDataFloat(addr)
            let field = (raw >> 21) & 0xF
            let val: Float = (field & 8) != 0 ? qw.x : (field & 4) != 0 ? qw.y : (field & 2) != 0 ? qw.z : qw.w
            setVI(it, UInt16(bitPattern: Int16(val.isNaN ? 0 : Int32(val))))
        case 0x05: // ISW — store VI: VUmem[IS + imm11] (partial)
            break
        case 0x08: // IADDIU — IT = IS + imm15
            setVI(it, UInt16(bitPattern: Int16(bitPattern: UInt16(bitPattern: Int16(Int(getVI(is_))) &+ Int16(imm15 & 0x7FFF)))))
        case 0x09: // ISUBIU — IT = IS - imm15
            setVI(it, UInt16(bitPattern: Int16(Int(getVI(is_)) - Int(imm15 & 0x7FFF))))
        case 0x10: // FCEQ — compare clip flag
            vi[1] = (clipFlag == (raw & 0xFFFFFF)) ? 1 : 0
        case 0x11: // FCSET — set clip flag
            clipFlag = raw & 0xFFFFFF
        case 0x12: // FCAND — AND clip flag
            vi[1] = (clipFlag & (raw & 0xFFFFFF)) != 0 ? 1 : 0
        case 0x13: // FCOR — OR clip flag
            vi[1] = ((clipFlag | (raw & 0xFFFFFF)) == 0xFFFFFF) ? 1 : 0
        case 0x14: // FSEQ — compare status flag
            vi[1] = (statusFlag == (raw & 0xFFF)) ? 1 : 0
        case 0x15: // FSSET — set status flag bits
            statusFlag = (statusFlag & ~0xFC0) | ((raw & 0xFC0))
        case 0x16: // FSAND — AND status flag
            vi[1] = UInt16(statusFlag & (raw & 0xFFF))
        case 0x17: // FSOR
            vi[1] = UInt16(statusFlag | (raw & 0xFFF))
        case 0x18: // FMEQ
            vi[1] = (macFlag == (raw & 0xFFFF)) ? 1 : 0
        case 0x1A: // FMAND
            vi[1] = UInt16(macFlag & (raw & 0xFFFF))
        case 0x1B: // FMOR
            vi[1] = UInt16(macFlag | (raw & 0xFFFF))
        case 0x1C: // FCGET — get clip flag lower 12 bits into IT
            setVI(it, UInt16(clipFlag & 0xFFF))
        case 0x20: // B — unconditional branch
            let offset = imm11
            pc = UInt32(Int(pc) + Int(offset) - 1)   // -1 because pc already incremented
        case 0x21: // BAL — branch and link
            let offset = imm11
            setVI(it, UInt16(pc + 1))
            pc = UInt32(Int(pc) + Int(offset) - 1)
        case 0x24: // JR — jump register
            pc = UInt32(getVI(is_))
        case 0x25: // JALR — jump and link register
            setVI(it, UInt16(pc))
            pc = UInt32(getVI(is_))
        case 0x28: // IBEQ — branch if VI[IS] == VI[IT]
            if getVI(is_) == getVI(it) { pc = UInt32(Int(pc) + Int(imm11) - 1) }
        case 0x29: // IBNE — branch if VI[IS] != VI[IT]
            if getVI(is_) != getVI(it) { pc = UInt32(Int(pc) + Int(imm11) - 1) }
        case 0x2C: // IBLTZ — branch if VI[IS] < 0
            if Int16(bitPattern: getVI(is_)) < 0 { pc = UInt32(Int(pc) + Int(imm11) - 1) }
        case 0x2D: // IBGTZ — branch if VI[IS] > 0
            if Int16(bitPattern: getVI(is_)) > 0 { pc = UInt32(Int(pc) + Int(imm11) - 1) }
        case 0x2E: // IBLEZ
            if Int16(bitPattern: getVI(is_)) <= 0 { pc = UInt32(Int(pc) + Int(imm11) - 1) }
        case 0x2F: // IBGEZ
            if Int16(bitPattern: getVI(is_)) >= 0 { pc = UInt32(Int(pc) + Int(imm11) - 1) }
        // ── VU lower special instructions ──────────────────────────────────────
        // DIV / SQRT / RSQRT / WAITQ (opcode 0x38–0x3B in PS2 VU manual)
        case 0x38: // DIV — Q = VF[FS].fsf / VF[FT].ftf
            let fsf = (raw >> 21) & 0x3; let ftf = (raw >> 23) & 0x3
            let num = componentOf(getVF(fs), idx: Int(fsf))
            let den = componentOf(getVF(ft), idx: Int(ftf))
            q = den != 0 ? num / den : (num >= 0 ? Float.infinity : -Float.infinity)
        case 0x39: // SQRT — Q = sqrt(VF[FT].ftf)
            let ftf2 = (raw >> 23) & 0x3
            let val2 = componentOf(getVF(ft), idx: Int(ftf2))
            q = val2 >= 0 ? sqrtf(val2) : 0
        case 0x3A: // RSQRT — Q = VF[FS].fsf / sqrt(VF[FT].ftf)
            let fsf3 = (raw >> 21) & 0x3; let ftf3 = (raw >> 23) & 0x3
            let num3 = componentOf(getVF(fs), idx: Int(fsf3))
            let den3 = sqrtf(max(0, componentOf(getVF(ft), idx: Int(ftf3))))
            q = den3 != 0 ? num3 / den3 : (num3 >= 0 ? Float.infinity : -Float.infinity)
        case 0x3B: // WAITQ — stall until Q ready (no-op in interpreter)
            break
        case 0x3C: // MTIR — VI[IT] = VF[FS].fsf (as integer bits)
            let fsf4 = (raw >> 21) & 0x3
            let val4 = componentOf(getVF(fs), idx: Int(fsf4))
            setVI(it, UInt16(bitPattern: Int16(val4.isNaN ? 0 : max(-32768, min(32767, val4)))))
        case 0x3D: // MFIR — VF[FT] = float(VI[IS])
            let old3D = getVF(ft)
            let fval3D = Float(Int16(bitPattern: getVI(is_)))
            setVF(ft, applyDest(dest, old: old3D, new: SIMD4<Float>(fval3D, fval3D, fval3D, fval3D)))
        case 0x3E: // ILWR — load VI from VU mem (indirect)
            let addr3E = UInt16(Int(getVI(is_)) & ((dataSize / 16) - 1))
            let qw3E = readDataFloat(addr3E)
            let field3E = (raw >> 21) & 0xF
            let val3E: Float = (field3E & 8) != 0 ? qw3E.x : (field3E & 4) != 0 ? qw3E.y : (field3E & 2) != 0 ? qw3E.z : qw3E.w
            setVI(it, UInt16(bitPattern: Int16(val3E.isNaN ? 0 : Int32(val3E))))
        case 0x3F: // ISWR — store VI to VU mem (indirect, no-op stub)
            break
        // RINIT / RGET / RNEXT / RXOR / WAITP (opcode 0x40–0x44)
        case 0x40: // RINIT
            r = getVF(fs).x.bitPattern
        case 0x41: // RGET
            setVF(ft, applyDest(dest, old: getVF(ft), new: SIMD4<Float>(Float(bitPattern: r), Float(bitPattern: r), Float(bitPattern: r), Float(bitPattern: r))))
        case 0x42: // RNEXT — advance PRNG, then read
            r = ((r >> 4) ^ (r >> 22) ^ r) & 0x007F_FFFF | 0x3F80_0000
            setVF(ft, applyDest(dest, old: getVF(ft), new: SIMD4<Float>(Float(bitPattern: r), Float(bitPattern: r), Float(bitPattern: r), Float(bitPattern: r))))
        case 0x43: // RXOR
            r ^= getVF(fs).x.bitPattern & 0x007F_FFFF
        case 0x44: // WAITP — stall until EFU ready (no-op)
            break
        // EFU operations (opcode 0x60–0x7F)
        case 0x60: // ESADD
            let s60 = getVF(fs); p = s60.x * s60.x + s60.y * s60.y + s60.z * s60.z
        case 0x61: // ERSADD
            let s61 = getVF(fs); let sum61 = s61.x * s61.x + s61.y * s61.y + s61.z * s61.z
            p = sum61 > 0 ? 1.0 / sum61 : Float.infinity
        case 0x62: // ESQRT
            let fsf62 = (raw >> 21) & 0x3
            p = sqrtf(max(0, componentOf(getVF(fs), idx: Int(fsf62))))
        case 0x63: // ERSQRT
            let fsf63 = (raw >> 21) & 0x3
            let val63 = max(0.0, componentOf(getVF(fs), idx: Int(fsf63)))
            p = val63 > 0 ? 1.0 / sqrtf(val63) : Float.infinity
        case 0x64: // ERCPR
            let fsf64 = (raw >> 21) & 0x3
            let val64 = componentOf(getVF(fs), idx: Int(fsf64))
            p = val64 != 0 ? 1.0 / val64 : Float.infinity
        case 0x65: // ELENG — p = |FS.xyz|
            let s65 = getVF(fs); p = sqrtf(s65.x * s65.x + s65.y * s65.y + s65.z * s65.z)
        case 0x66: // ESUM — p = FS.x + FS.y + FS.z + FS.w
            let s66 = getVF(fs); p = s66.x + s66.y + s66.z + s66.w
        case 0x67: // EATAN — p = atan(FS.x)
            let fsf67 = (raw >> 21) & 0x3
            p = atanf(componentOf(getVF(fs), idx: Int(fsf67)))
        case 0x68: // ESIN — p = sin(FS.x)
            let fsf68 = (raw >> 21) & 0x3
            p = sinf(componentOf(getVF(fs), idx: Int(fsf68)))
        case 0x6B: // EEXP — p = e^(-FS.x)
            let fsf6B = (raw >> 21) & 0x3
            p = expf(-componentOf(getVF(fs), idx: Int(fsf6B)))
        case 0x6C: // ERCOR / EATAN2 (alt)
            p = atan2f(getVF(fs).y, getVF(fs).x)
        case 0x7C: // MFP — VF[FT] = P
            let old7C = getVF(ft)
            setVF(ft, applyDest(dest, old: old7C, new: SIMD4<Float>(p, p, p, p)))
        case 0x7B: // XTOP (VU1): VI[IT] = TOPS
            setVI(it, vi[15])
        case 0x7E: // XITOP (VU1): VI[IT] = ITOPS
            setVI(it, vi[14])
        case 0x7F: // XGKICK (VU1): send VU1 mem to GS via GIF
            if index == 1 {
                let startAddr = Int(getVI(is_)) * 16
                let len = dataSize - startAddr
                if len > 0 {
                    let bytes = Array(dataMem[startAddr..<dataMem.count])
                    onXGKICK?(bytes, len)
                }
            }
        default:
            break
        }
        _ = (it, is_, id, ft, fs, dest, imm11, imm15)
    }

    private func componentOf(_ v: SIMD4<Float>, idx: Int) -> Float {
        switch idx & 3 {
        case 0: return v.x
        case 1: return v.y
        case 2: return v.z
        default: return v.w
        }
    }

    // MARK: - Macro-mode (COP2) interface
    //
    // The EE accesses VU0 in macro mode via COP2 instructions.
    // These map to single VU micro-instructions executed immediately.

    func executeMacro(instruction: UInt32) {
        // In macro mode, the EE issues a VU0 instruction directly
        // The upper 26 bits are the VU upper instruction, lower 6 are subtype
        executeUpper(instruction)
    }

    // Read/write VF as float4 from EE (CTC2/CFC2/QMTC2/QMFC2)
    func readVFasGPR(_ idx: Int) -> (hi: UInt64, lo: UInt64) {
        let v = getVF(idx)
        let lo = UInt64(v.x.bitPattern) | (UInt64(v.y.bitPattern) << 32)
        let hi = UInt64(v.z.bitPattern) | (UInt64(v.w.bitPattern) << 32)
        return (hi: hi, lo: lo)
    }
    func writeVFfromGPR(_ idx: Int, hi: UInt64, lo: UInt64) {
        let x = Float(bitPattern: UInt32(lo & 0xFFFF_FFFF))
        let y = Float(bitPattern: UInt32(lo >> 32))
        let z = Float(bitPattern: UInt32(hi & 0xFFFF_FFFF))
        let w = Float(bitPattern: UInt32(hi >> 32))
        setVF(idx, SIMD4<Float>(x, y, z, w))
    }
    func readVIasGPR(_ idx: Int) -> UInt32 { UInt32(getVI(idx)) }
    func writeVIfromGPR(_ idx: Int, value: UInt32) { setVI(idx, UInt16(value & 0xFFFF)) }
}
