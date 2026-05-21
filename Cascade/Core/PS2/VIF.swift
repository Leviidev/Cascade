import Foundation

// MARK: - Vector Interface (VIF0 / VIF1)
//
// VIF sits between the DMAC and the Vector Units.
// It decodes a stream of 32-bit VIF codes and unpacks vertex data into VU memory.
// VIF1 also supports DIRECT/DIRECTHL to send data straight to the GS.
//
// VIF code word: [31:24] CMD  [23:16] NUM  [15:0] IMMEDIATE

public final class VectorInterface {

    let index: Int      // 0 = VIF0, 1 = VIF1

    // MARK: - Registers

    var stat: UInt32 = 0        // VIF_STAT
    var fbrst: UInt32 = 0       // VIF_FBRST
    var err: UInt32 = 0         // VIF_ERR
    var mark: UInt16 = 0        // VIF_MARK
    var cycle: UInt32 = 0       // VIF_CYCLE (CL[7:0], WL[15:8])
    var mode: UInt32 = 0        // VIF_MODE (0=normal, 1=offset, 2=difference)
    var num: UInt8 = 0          // VIF_NUM
    var mask: UInt32 = 0        // VIF_MASK
    var code: UInt32 = 0        // VIF_CODE (last command written)
    var itops: UInt16 = 0       // VIF_ITOPS
    var tops: UInt16 = 0        // VIF_TOPS (VIF1 only)
    var itop: UInt16 = 0        // VIF_ITOP
    var top: UInt16 = 0         // VIF_TOP (VIF1 only)
    var base: UInt16 = 0        // VIF_BASE (VIF1 only)
    var ofst: UInt16 = 0        // VIF_OFST (VIF1 only)

    // VIF ROW/COL registers for UNPACK offset/difference modes
    var row: [UInt32] = [0, 0, 0, 0]
    var col: [UInt32] = [0, 0, 0, 0]

    // MARK: - References

    weak var vu: VectorUnit?
    weak var gs: GraphicsSynthesizer?       // VIF1 DIRECT path

    // MARK: - FIFO / processing state

    private var fifo: [UInt32] = []

    // Active unpack state
    private var unpacking: Bool = false
    private var unpackFmt: Int = 0          // VIF unpack format code (0..F)
    private var unpackAddr: Int = 0         // current VU data address (in 128-bit units)
    private var unpackNum: Int = 0          // qwords remaining
    private var unpackUsn: Bool = false     // unsigned
    private var unpackFlg: Bool = false     // flag bit
    private var unpackMask: Bool = false    // use mask register
    private var unpackWordsPerChunk: Int = 1

    // MPG state
    private var mpgPending: Bool = false
    private var mpgAddr: Int = 0
    private var mpgWords: Int = 0
    private var mpgBuffer: [UInt64] = []

    // DIRECT state (VIF1)
    private var directPending: Bool = false
    private var directQwords: Int = 0
    private var directBuffer: [UInt64] = []

    // MARK: - Init

    init(index: Int) {
        self.index = index
        fifo.reserveCapacity(256)
    }

    // MARK: - Feed data words into the VIF

    func feed(words: [UInt32]) {
        fifo.append(contentsOf: words)
        process()
    }

    func feed(from memory: inout [UInt8], address: UInt32, qwordCount: Int) {
        var addr = Int(address)
        for _ in 0..<(qwordCount * 4) {
            guard addr + 4 <= memory.count else { break }
            let w = memory.withUnsafeBytes { $0.load(fromByteOffset: addr, as: UInt32.self).littleEndian }
            fifo.append(w)
            addr += 4
        }
        process()
    }

    // MARK: - Main Processing Loop

    private func process() {
        while !fifo.isEmpty {
            if mpgPending {
                processMPG()
            } else if directPending {
                processDIRECT()
            } else if unpacking {
                processUNPACK()
            } else {
                // Parse next VIF code
                guard !fifo.isEmpty else { return }
                let word = fifo.removeFirst()
                parseCode(word)
            }
        }
    }

    private func parseCode(_ word: UInt32) {
        code = word
        let cmd  = (word >> 24) & 0x7F   // bits [30:24]
        let num  = UInt8((word >> 16) & 0xFF)
        let imm  = UInt16(word & 0xFFFF)

        switch cmd {
        case 0x00: // NOP
            break
        case 0x01: // STCYCL — set CL and WL
            cycle = UInt32(imm)
        case 0x02: // OFFSET (VIF1)
            if index == 1 { ofst = UInt16(imm & 0x3FF) }
        case 0x03: // BASE (VIF1)
            if index == 1 { base = UInt16(imm & 0x3FF) }
        case 0x04: // ITOP / ITOPS
            if index == 1 { itops = UInt16(imm & 0x3FF) }
            else           { itops = UInt16(imm & 0x3FF) }
        case 0x05: // STMOD
            mode = UInt32(imm & 0x3)
        case 0x06: // MSKPATH3 (VIF1)
            break
        case 0x07: // MARK
            mark = imm
            stat |= (1 << 6)        // MRK bit
        case 0x10: // FLUSHE
            break
        case 0x11: // FLUSH (VIF1)
            break
        case 0x12: // FLUSHA (VIF1)
            break
        case 0x13: // MSCAL — start VU micro at address
            guard let vu = vu else { break }
            vu.pc = UInt32(imm)
            vu.run()
            updateTOPS()
        case 0x14: // MSCNT — continue VU micro (restart from current pc)
            vu?.run()
            updateTOPS()
        case 0x15: // MSCALF (VIF1)
            guard let vu = vu else { break }
            vu.pc = UInt32(imm)
            vu.run()
            updateTOPS()
        case 0x20: // STMASK
            // Next word is the mask value
            if !fifo.isEmpty { mask = fifo.removeFirst() }
        case 0x30: // STROW — next 4 words are ROW[0..3]
            var loaded = 0
            while loaded < 4, !fifo.isEmpty {
                row[loaded] = fifo.removeFirst()
                loaded += 1
            }
        case 0x31: // STCOL — next 4 words are COL[0..3]
            var loaded = 0
            while loaded < 4, !fifo.isEmpty {
                col[loaded] = fifo.removeFirst()
                loaded += 1
            }
        case 0x4A: // MPG — upload microprogram
            mpgAddr   = Int(imm) * 2    // address in 64-bit units
            mpgWords  = Int(num) == 0 ? 256 : Int(num) * 2  // each NUM entry = 2 × 32-bit words (1 × 64-bit)
            mpgBuffer = []
            mpgPending = true
            processMPG()
        case 0x50: // DIRECT (VIF1) — pass data directly to GIF
            if index == 1 {
                directQwords  = Int(imm) == 0 ? 65536 : Int(imm)
                directBuffer  = []
                directPending = true
                processDIRECT()
            }
        case 0x51: // DIRECTHL (VIF1)
            if index == 1 {
                directQwords  = Int(imm) == 0 ? 65536 : Int(imm)
                directBuffer  = []
                directPending = true
                processDIRECT()
            }
        default:
            if (cmd & 0x60) == 0x60 {
                // UNPACK: cmd = 0110_xxxx where xxxx = format
                startUnpack(cmd: cmd, num: num, imm: imm)
            }
        }
    }

    // MARK: - MPG Upload

    private func processMPG() {
        // Consume 32-bit words in pairs (= 64-bit micro-instructions)
        while mpgWords > 0 && fifo.count >= 2 {
            let lo = UInt64(fifo.removeFirst())
            let hi = UInt64(fifo.removeFirst())
            let instr = lo | (hi << 32)
            mpgBuffer.append(instr)
            mpgWords -= 2
        }
        if mpgWords == 0 {
            mpgPending = false
            vu?.writeMicro(at: mpgAddr * 8, words: mpgBuffer)
            mpgBuffer = []
        }
    }

    // MARK: - DIRECT to GS

    private func processDIRECT() {
        while directQwords > 0 && fifo.count >= 4 {
            let w0 = UInt64(fifo.removeFirst()); let w1 = UInt64(fifo.removeFirst())
            let w2 = UInt64(fifo.removeFirst()); let w3 = UInt64(fifo.removeFirst())
            directBuffer.append(w0 | (w1 << 32))
            directBuffer.append(w2 | (w3 << 32))
            directQwords -= 1
        }
        if directQwords == 0 {
            directPending = false
            gs?.processGIFPacket(data: directBuffer, qwordCount: directBuffer.count / 2, flag: 0)
            directBuffer = []
        }
    }

    // MARK: - UNPACK

    // Format table: bits[3:2] = type (S=0,V2=1,V3=2,V4=3), bits[1:0] = width (32=0,16=1,8=2,5=3)
    private static let componentsForFormat: [Int] = [1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4]
    private static let bitsForFormat:      [Int] = [32, 16, 8, 5, 32, 16, 8, 5, 32, 16, 8, 5, 32, 16, 8, 5]

    private func startUnpack(cmd: UInt32, num: UInt8, imm: UInt16) {
        unpackFmt  = Int(cmd & 0xF)
        unpackNum  = Int(num) == 0 ? 256 : Int(num)
        unpackAddr = Int(imm & 0x3FF)
        unpackUsn  = (imm & (1 << 14)) != 0
        unpackFlg  = (imm & (1 << 15)) != 0   // top bit (VIF1 double-buffer)
        unpackMask = (cmd & (1 << 4)) != 0

        let numComp = VectorInterface.componentsForFormat[unpackFmt & 0xF]
        let bits    = VectorInterface.bitsForFormat[unpackFmt & 0xF]
        let wordsNeeded = numComp * bits
        unpackWordsPerChunk = (wordsNeeded + 31) / 32   // 32-bit words per qword entry

        if unpackFlg && index == 1 {
            // Double-buffer mode: write to TOPS+addr
            unpackAddr = Int(tops) + Int(imm & 0x3FF)
        }

        unpacking = true
        processUNPACK()
    }

    private func processUNPACK() {
        guard let vu = vu else { unpacking = false; return }

        let numComp = VectorInterface.componentsForFormat[unpackFmt & 0xF]
        let bits    = VectorInterface.bitsForFormat[unpackFmt & 0xF]
        let wpc     = unpackWordsPerChunk

        while unpackNum > 0 && fifo.count >= wpc {
            // Read source words
            var srcWords: [UInt32] = []
            for _ in 0..<wpc { srcWords.append(fifo.removeFirst()) }

            // Decode source into up to 4 float components
            var components: [Float] = [0, 0, 0, 0]
            decodeComponents(srcWords: srcWords, numComp: numComp, bits: bits, usn: unpackUsn, out: &components)

            // Apply mode (normal / offset / difference)
            for i in 0..<4 {
                switch mode & 3 {
                case 1: components[i] += Float(bitPattern: row[i])          // offset
                case 2:                                                       // difference
                    let prev = vu.readData32((unpackAddr) * 16 + i * 4)
                    components[i] = Float(bitPattern: prev) + components[i]
                    row[i] = components[i].bitPattern
                default: break
                }
            }

            // Apply mask register if needed
            var writeVec: [Float] = [0, 0, 0, 0]
            for i in 0..<4 {
                let maskBits = unpackMask ? (mask >> (i * 2)) & 0x3 : 0
                switch maskBits {
                case 0: writeVec[i] = components[i]
                case 1: writeVec[i] = Float(bitPattern: row[i])
                case 2: writeVec[i] = Float(bitPattern: col[i % 4])
                case 3: writeVec[i] = 0   // write-protect: keep existing
                default: writeVec[i] = components[i]
                }
            }

            // Write 128-bit qword into VU data memory
            let byteAddr = unpackAddr * 16
            var bytes = [UInt8](repeating: 0, count: 16)
            for i in 0..<4 {
                let bits32 = (maskBit(i) == 3) ? vu.readData32(byteAddr + i * 4) : writeVec[i].bitPattern
                bytes[i*4 + 0] = UInt8((bits32 >>  0) & 0xFF)
                bytes[i*4 + 1] = UInt8((bits32 >>  8) & 0xFF)
                bytes[i*4 + 2] = UInt8((bits32 >> 16) & 0xFF)
                bytes[i*4 + 3] = UInt8((bits32 >> 24) & 0xFF)
            }
            vu.writeData128Bytes(byteAddr, bytes: bytes)

            unpackAddr += 1
            unpackNum  -= 1
        }

        if unpackNum == 0 {
            unpacking = false
            itop = itops
            if index == 1 { top = tops }
            vu.vi[14] = itop   // ITOPS -> VI[14]
            vu.vi[15] = top    // TOPS  -> VI[15]
        }
    }

    private func maskBit(_ component: Int) -> UInt32 {
        guard unpackMask else { return 0 }
        return (mask >> (UInt32(component) * 2)) & 0x3
    }

    private func decodeComponents(srcWords: [UInt32], numComp: Int, bits: Int, usn: Bool, out: inout [Float]) {
        switch bits {
        case 32:
            for i in 0..<min(numComp, 4) {
                let raw: UInt32 = i < srcWords.count ? srcWords[i] : 0
                // V4-32 and S-32: float passthrough for V4-32, integer for S-32/V2-32/V3-32
                if unpackFmt == 0x0C {  // V4-32: raw floats
                    out[i] = Float(bitPattern: raw)
                } else {
                    out[i] = usn ? Float(raw) : Float(Int32(bitPattern: raw))
                }
            }
            // Replicate S-32 to all components
            if numComp == 1 { out[1] = out[0]; out[2] = out[0]; out[3] = out[0] }
            if numComp == 2 { out[2] = 0; out[3] = 0 }
            if numComp == 3 { out[3] = 0 }
        case 16:
            let packed: UInt32 = srcWords.isEmpty ? 0 : srcWords[0]
            let packed2: UInt32 = srcWords.count > 1 ? srcWords[1] : 0
            if numComp == 1 {
                let v = usn ? Float(packed & 0xFFFF) : Float(Int16(bitPattern: UInt16(packed & 0xFFFF)))
                out[0] = v; out[1] = v; out[2] = v; out[3] = v
            } else {
                let vals: [UInt16] = [
                    UInt16(packed & 0xFFFF), UInt16(packed >> 16),
                    UInt16(packed2 & 0xFFFF), UInt16(packed2 >> 16)
                ]
                for i in 0..<min(numComp, 4) {
                    out[i] = usn ? Float(vals[i]) : Float(Int16(bitPattern: vals[i]))
                }
            }
        case 8:
            let packed: UInt32 = srcWords.isEmpty ? 0 : srcWords[0]
            for i in 0..<min(numComp, 4) {
                let byte = UInt8((packed >> (i * 8)) & 0xFF)
                out[i] = usn ? Float(byte) : Float(Int8(bitPattern: byte))
            }
            if numComp == 1 { out[1] = out[0]; out[2] = out[0]; out[3] = out[0] }
        case 5: // V2-5-6-5 / V3-5-5-5-1 / V4-4-4-4-4
            let packed = srcWords.isEmpty ? UInt32(0) : srcWords[0]
            if unpackFmt == 0x07 {  // S-5-6-5 (unused but handled)
                out[0] = Float((packed >> 11) & 0x1F) / 31.0
                out[1] = Float((packed >>  5) & 0x3F) / 63.0
                out[2] = Float((packed >>  0) & 0x1F) / 31.0
                out[3] = 1.0
            } else if unpackFmt == 0x0B { // V3-5-5-5-1
                out[0] = Float((packed >> 10) & 0x1F) / 31.0
                out[1] = Float((packed >>  5) & 0x1F) / 31.0
                out[2] = Float((packed >>  0) & 0x1F) / 31.0
                out[3] = Float((packed >> 15) & 0x01)
            } else { // V4-4-4-4-4
                out[0] = Float((packed >> 12) & 0xF) / 15.0
                out[1] = Float((packed >>  8) & 0xF) / 15.0
                out[2] = Float((packed >>  4) & 0xF) / 15.0
                out[3] = Float((packed >>  0) & 0xF) / 15.0
            }
        default:
            break
        }
    }

    // MARK: - TOPS double-buffer management (VIF1)

    private func updateTOPS() {
        if index == 1 {
            tops = base + ofst
            vu?.vi[14] = itop
            vu?.vi[15] = tops
        }
    }

    // MARK: - I/O registers (accessed via EE bus / DMAC)

    func readReg(_ offset: UInt32) -> UInt32 {
        switch offset {
        case 0x000: return stat
        case 0x010: return UInt32(fbrst)
        case 0x020: return err
        case 0x030: return UInt32(mark)
        case 0x040: return cycle
        case 0x050: return mode
        case 0x060: return UInt32(num)
        case 0x070: return mask
        case 0x080: return code
        case 0x090: return UInt32(itops)
        case 0x0A0: return UInt32(base)    // VIF1 only
        case 0x0B0: return UInt32(ofst)    // VIF1 only
        case 0x0C0: return UInt32(tops)    // VIF1 only
        case 0x0D0: return UInt32(itop)
        case 0x0E0: return UInt32(top)     // VIF1 only
        case 0x100: return row[0]
        case 0x110: return row[1]
        case 0x120: return row[2]
        case 0x130: return row[3]
        case 0x140: return col[0]
        case 0x150: return col[1]
        case 0x160: return col[2]
        case 0x170: return col[3]
        default: return 0
        }
    }

    func writeReg(_ offset: UInt32, value: UInt32) {
        switch offset {
        case 0x000:
            // Writing to STAT: only FBF/DBF/INT bits writable
            break
        case 0x010: // FBRST
            fbrst = value
            if value & 0x01 != 0 { resetVIF() }
        case 0x020: err  = value & 0x7
        case 0x030: mark = UInt16(value & 0xFFFF)
        case 0x040: cycle = value
        case 0x050: mode  = value & 0x3
        case 0x070: mask  = value
        case 0x100: row[0] = value
        case 0x110: row[1] = value
        case 0x120: row[2] = value
        case 0x130: row[3] = value
        case 0x140: col[0] = value
        case 0x150: col[1] = value
        case 0x160: col[2] = value
        case 0x170: col[3] = value
        default: break
        }
    }

    private func resetVIF() {
        fifo.removeAll()
        unpacking   = false
        mpgPending  = false
        directPending = false
        stat &= ~(0x1F << 24)   // clear command field
        stat &= ~(1 << 26)      // clear VPS
    }
}
