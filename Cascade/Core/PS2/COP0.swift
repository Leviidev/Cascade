import Foundation

// MARK: - COP0 System Control Coprocessor

public final class COP0Registers {

    // Core COP0 registers
    var index: UInt32 = 0
    var random: UInt32 = 47
    var entryLo0: UInt32 = 0
    var entryLo1: UInt32 = 0
    var context: UInt32 = 0
    var pageMask: UInt32 = 0
    var wired: UInt32 = 0
    var badVAddr: UInt32 = 0
    var count: UInt32 = 0
    var entryHi: UInt32 = 0
    var compare: UInt32 = 0
    var status: UInt32 = 0x0040_0004
    var cause: UInt32 = 0
    var epc: UInt32 = 0
    var prid: UInt32 = 0x0000_2E20   // EE revision
    var config: UInt32 = 0
    var badPAddr: UInt32 = 0
    var debug: UInt32 = 0
    var perf: UInt32 = 0
    var tagLo: UInt32 = 0
    var tagHi: UInt32 = 0
    var errorEPC: UInt32 = 0

    // FPU condition flag (FCR31 bit 23)
    var fcr31_cond: Bool = false

    // 48-entry TLB
    var tlb: [TLBEntry] = Array(repeating: TLBEntry(), count: 48)

    func reset() {
        status = 0x0040_0004
        cause = 0
        epc = 0
        count = 0
        compare = 0
        index = 0
        random = 47
    }

    func read(register: Int) -> UInt32 {
        switch register {
        case 0:  return index
        case 1:  return random
        case 2:  return entryLo0
        case 3:  return entryLo1
        case 4:  return context
        case 5:  return pageMask
        case 6:  return wired
        case 8:  return badVAddr
        case 9:  return count
        case 10: return entryHi
        case 11: return compare
        case 12: return status
        case 13: return cause
        case 14: return epc
        case 15: return prid
        case 16: return config
        case 23: return badPAddr
        case 24: return debug
        case 25: return perf
        case 28: return tagLo
        case 29: return tagHi
        case 30: return errorEPC
        default: return 0
        }
    }

    func write(register: Int, value: UInt32) {
        switch register {
        case 0:  index = value & 0x3F
        case 2:  entryLo0 = value
        case 3:  entryLo1 = value
        case 4:  context = value
        case 5:  pageMask = value
        case 6:  wired = value & 0x3F
        case 9:  count = value
        case 10: entryHi = value
        case 11: compare = value; cause &= ~(1 << 15)  // clear timer interrupt
        case 12: status = value
        case 13: cause = (cause & ~0x300) | (value & 0x300)
        case 14: epc = value
        case 16: config = value
        case 28: tagLo = value
        case 29: tagHi = value
        case 30: errorEPC = value
        default: break
        }
    }

    func tlbWriteIndexed() {
        let i = Int(index & 0x3F)
        tlb[i] = TLBEntry(entryHi: entryHi, entryLo0: entryLo0, entryLo1: entryLo1, pageMask: pageMask)
    }

    func tlbWriteRandom() {
        let i = Int(random & 0x3F)
        tlb[i] = TLBEntry(entryHi: entryHi, entryLo0: entryLo0, entryLo1: entryLo1, pageMask: pageMask)
        if random == wired { random = 47 } else { random -= 1 }
    }

    func tlbProbe() {
        for (i, entry) in tlb.enumerated() {
            if entry.vpn2 == (entryHi >> 13) & 0x7_FFFF {
                index = UInt32(i)
                return
            }
        }
        index = 0x8000_0000
    }

    @discardableResult
    func triggerException(type: ExceptionType) -> UInt32 {
        let vector: UInt32 = (status & (1 << 22)) != 0 ? 0xBFC0_0200 : 0x8000_0180
        cause = (cause & ~(0x1F << 2)) | (type.code << 2)
        status |= (1 << 1)
        return vector
    }
}

// MARK: - TLB Entry

struct TLBEntry {
    var vpn2: UInt32 = 0
    var asid: UInt8 = 0
    var global: Bool = false
    var pfn0: UInt32 = 0
    var pfn1: UInt32 = 0
    var c0: UInt8 = 0
    var c1: UInt8 = 0
    var d0: Bool = false
    var d1: Bool = false
    var v0: Bool = false
    var v1: Bool = false
    var mask: UInt32 = 0

    init() {}

    init(entryHi: UInt32, entryLo0: UInt32, entryLo1: UInt32, pageMask: UInt32) {
        vpn2 = (entryHi >> 13) & 0x7_FFFF
        asid = UInt8(entryHi & 0xFF)
        global = (entryLo0 & 1) != 0 && (entryLo1 & 1) != 0
        pfn0 = (entryLo0 >> 6) & 0xF_FFFF
        pfn1 = (entryLo1 >> 6) & 0xF_FFFF
        c0 = UInt8((entryLo0 >> 3) & 0x7)
        c1 = UInt8((entryLo1 >> 3) & 0x7)
        d0 = (entryLo0 & (1 << 2)) != 0
        d1 = (entryLo1 & (1 << 2)) != 0
        v0 = (entryLo0 & (1 << 1)) != 0
        v1 = (entryLo1 & (1 << 1)) != 0
        mask = pageMask
    }
}

// MARK: - Exception Types

enum ExceptionType {
    case interrupt, tlbModification, tlbLoadMiss, tlbStoreMiss
    case addressLoadError, addressStoreError, busError
    case syscall, breakpoint, reservedInstruction, coprocessorUnusable
    case overflow, trap, virtualCoherency

    var code: UInt32 {
        switch self {
        case .interrupt:             return 0
        case .tlbModification:       return 1
        case .tlbLoadMiss:           return 2
        case .tlbStoreMiss:          return 3
        case .addressLoadError:      return 4
        case .addressStoreError:     return 5
        case .busError:              return 7
        case .syscall:               return 8
        case .breakpoint:            return 9
        case .reservedInstruction:   return 10
        case .coprocessorUnusable:   return 11
        case .overflow:              return 12
        case .trap:                  return 13
        case .virtualCoherency:      return 14
        }
    }
}
