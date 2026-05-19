import Foundation

// MARK: - PS2 Memory Map
//
//  0x0000_0000 – 0x01FF_FFFF   Main RAM (32 MB)
//  0x1000_0000 – 0x1000_FFFF   Hardware I/O registers
//  0x1FC0_0000 – 0x1FC7_FFFF   BIOS ROM (4 MB)
//  0x1C00_0000 – 0x1C1F_FFFF   IOP RAM (2 MB, mirrored from EE bus)
//  Mirrors: KSEG0 (0x8000_0000), KSEG1 (0xA000_0000) → physical

public final class MemoryBus {

    // MARK: - Memory Regions

    let ramSize  = 32 * 1024 * 1024   // 32 MB EE RAM
    let biosSize =  4 * 1024 * 1024   // 4 MB BIOS
    let iopSize  =  2 * 1024 * 1024   // 2 MB IOP RAM
    let scratchSize = 16 * 1024       // 16 KB scratchpad

    var ram:      [UInt8]
    var bios:     [UInt8]
    var iopRam:   [UInt8]
    var scratch:  [UInt8]

    // MARK: - Hardware components (weak to avoid retain cycles)
    weak var gs: GraphicsSynthesizer?
    weak var dmac: DMAC?
    weak var intc: INTC?
    weak var timer: EETimer?
    weak var iop: IOProcessor?

    // MARK: - Init

    init() {
        ram     = [UInt8](repeating: 0, count: ramSize)
        bios    = [UInt8](repeating: 0, count: biosSize)
        iopRam  = [UInt8](repeating: 0, count: iopSize)
        scratch = [UInt8](repeating: 0, count: scratchSize)
    }

    // MARK: - BIOS Loading

    func loadBIOS(data: Data) -> Bool {
        guard data.count <= biosSize else { return false }
        data.copyBytes(to: &bios, count: min(data.count, biosSize))
        return true
    }

    // MARK: - Address Translation

    func physicalAddress(_ virtual: UInt32) -> UInt32 {
        // Strip KSEG0 / KSEG1 / KSEG2 prefixes
        switch virtual >> 29 {
        case 0x4: return virtual & 0x1FFF_FFFF  // KSEG0
        case 0x5: return virtual & 0x1FFF_FFFF  // KSEG1
        default:  return virtual & 0x1FFF_FFFF
        }
    }

    // MARK: - Read

    func read8(address: UInt32) -> UInt8 {
        let phys = physicalAddress(address)
        switch phys {
        case 0x0000_0000..<0x0200_0000: return ram[Int(phys)]
        case 0x1FC0_0000..<0x2000_0000: return bios[Int(phys - 0x1FC0_0000)]
        case 0x1C00_0000..<0x1C20_0000: return iopRam[Int(phys - 0x1C00_0000)]
        case 0x7000_0000..<0x7000_4000: return scratch[Int(phys - 0x7000_0000)]
        case 0x1000_0000..<0x1001_0000: return readIO8(offset: phys - 0x1000_0000)
        default: return 0xFF
        }
    }

    func read16(address: UInt32) -> UInt16 {
        let p = physicalAddress(address)
        return UInt16(read8(address: address)) | (UInt16(read8(address: address + 1)) << 8)
    }

    func read32(address: UInt32) -> UInt32 {
        let phys = physicalAddress(address)
        switch phys {
        case 0x0000_0000..<0x0200_0000:
            return ram.withUnsafeBytes { ptr in
                ptr.load(fromByteOffset: Int(phys), as: UInt32.self).littleEndian
            }
        case 0x1FC0_0000..<0x2000_0000:
            let off = Int(phys - 0x1FC0_0000)
            return bios.withUnsafeBytes { ptr in
                ptr.load(fromByteOffset: off, as: UInt32.self).littleEndian
            }
        case 0x1000_0000..<0x1001_0000:
            return readIO32(offset: phys - 0x1000_0000)
        case 0x7000_0000..<0x7000_4000:
            let off = Int(phys - 0x7000_0000)
            return scratch.withUnsafeBytes { ptr in
                ptr.load(fromByteOffset: off, as: UInt32.self).littleEndian
            }
        default:
            return 0xFFFF_FFFF
        }
    }

    func read64(address: UInt32) -> UInt64 {
        let lo = UInt64(read32(address: address))
        let hi = UInt64(read32(address: address &+ 4))
        return lo | (hi << 32)
    }

    func read128(address: UInt32) -> UInt128 {
        UInt128(hi: read64(address: address &+ 8), lo: read64(address: address))
    }

    // MARK: - Write

    func write8(address: UInt32, value: UInt8) {
        let phys = physicalAddress(address)
        switch phys {
        case 0x0000_0000..<0x0200_0000: ram[Int(phys)] = value
        case 0x1C00_0000..<0x1C20_0000: iopRam[Int(phys - 0x1C00_0000)] = value
        case 0x7000_0000..<0x7000_4000: scratch[Int(phys - 0x7000_0000)] = value
        case 0x1000_0000..<0x1001_0000: writeIO8(offset: phys - 0x1000_0000, value: value)
        default: break
        }
    }

    func write16(address: UInt32, value: UInt16) {
        write8(address: address, value: UInt8(value & 0xFF))
        write8(address: address + 1, value: UInt8(value >> 8))
    }

    func write32(address: UInt32, value: UInt32) {
        let phys = physicalAddress(address)
        switch phys {
        case 0x0000_0000..<0x0200_0000:
            ram.withUnsafeMutableBytes { ptr in
                ptr.storeBytes(of: value.littleEndian, toByteOffset: Int(phys), as: UInt32.self)
            }
        case 0x1C00_0000..<0x1C20_0000:
            let off = Int(phys - 0x1C00_0000)
            iopRam.withUnsafeMutableBytes { ptr in
                ptr.storeBytes(of: value.littleEndian, toByteOffset: off, as: UInt32.self)
            }
        case 0x7000_0000..<0x7000_4000:
            let off = Int(phys - 0x7000_0000)
            scratch.withUnsafeMutableBytes { ptr in
                ptr.storeBytes(of: value.littleEndian, toByteOffset: off, as: UInt32.self)
            }
        case 0x1000_0000..<0x1001_0000:
            writeIO32(offset: phys - 0x1000_0000, value: value)
        default:
            break
        }
    }

    func write64(address: UInt32, value: UInt64) {
        write32(address: address, value: UInt32(value & 0xFFFF_FFFF))
        write32(address: address &+ 4, value: UInt32(value >> 32))
    }

    func write128(address: UInt32, value: UInt128) {
        write64(address: address, value: value.lo)
        write64(address: address &+ 8, value: value.hi)
    }

    // MARK: - Hardware I/O

    private func readIO8(offset: UInt32) -> UInt8 {
        return UInt8(readIO32(offset: offset & ~3) >> ((offset & 3) * 8))
    }

    private func writeIO8(offset: UInt32, value: UInt8) {
        var word = readIO32(offset: offset & ~3)
        let shift = (offset & 3) * 8
        word = (word & ~(0xFF << shift)) | (UInt32(value) << shift)
        writeIO32(offset: offset & ~3, value: word)
    }

    func readIO32(offset: UInt32) -> UInt32 {
        switch offset {
        case 0x0000..<0x1000:   // GS privileged registers
            return gs?.readPriv(offset: offset) ?? 0
        case 0x2000..<0x3000:   // INTC
            return intc?.read(offset: offset - 0x2000) ?? 0
        case 0x3000..<0x4000:   // Timer
            return timer?.read(offset: offset - 0x3000) ?? 0
        case 0x8000..<0x9000:   // DMAC
            return dmac?.read(offset: offset - 0x8000) ?? 0
        default:
            return 0
        }
    }

    func writeIO32(offset: UInt32, value: UInt32) {
        switch offset {
        case 0x0000..<0x1000:
            gs?.writePriv(offset: offset, value: value)
        case 0x2000..<0x3000:
            intc?.write(offset: offset - 0x2000, value: value)
        case 0x3000..<0x4000:
            timer?.write(offset: offset - 0x3000, value: value)
        case 0x8000..<0x9000:
            dmac?.write(offset: offset - 0x8000, value: value)
        default:
            break
        }
    }
}
