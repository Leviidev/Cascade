import Foundation

// MARK: - EE DMA Controller
// 10 DMA channels for bulk transfers between RAM, GIF, VIF0/1, SPR, SIF0/1/2, IPU, etc.

public final class DMAC {

    static let channelCount = 10

    struct Channel {
        var madr: UInt32 = 0    // memory address
        var qwc:  UInt32 = 0    // quadword count
        var tadr: UInt32 = 0    // tag address
        var chcr: UInt32 = 0    // channel control
        var sadr: UInt32 = 0    // scratchpad address

        var active: Bool { chcr & (1 << 8) != 0 }
    }

    var channels: [Channel] = Array(repeating: Channel(), count: DMAC.channelCount)
    var dstat: UInt32 = 0    // interrupt status
    var dmask: UInt32 = 0    // interrupt mask
    var ctrl:  UInt32 = 0    // global control
    var sqwc:  UInt32 = 0    // stall quad-word count
    var rbsr:  UInt32 = 0    // ring buffer size
    var rbor:  UInt32 = 0    // ring buffer offset

    weak var bus: MemoryBus?
    weak var intc: INTC?
    weak var gs: GraphicsSynthesizer?
    weak var vif0: VectorInterface?
    weak var vif1: VectorInterface?

    func step() {
        for i in 0..<DMAC.channelCount {
            guard channels[i].active else { continue }
            performTransfer(channel: i)
        }
    }

    private func performTransfer(channel idx: Int) {
        var ch = channels[idx]
        guard ch.qwc > 0, let bus = bus else {
            channels[idx].chcr &= ~(1 << 8)   // clear STR
            dstat |= (1 << idx)
            checkInterrupt()
            return
        }

        let batchSize = min(ch.qwc, 16)
        switch idx {
        case 0: // VIF0 — feed data into VIF0
            if let vif = vif0 {
                var words: [UInt32] = []
                for _ in 0..<(batchSize * 4) {
                    words.append(bus.read32(address: ch.madr))
                    ch.madr += 4
                }
                ch.qwc -= batchSize
                vif.feed(words: words)
            } else {
                ch.madr += batchSize * 16
                ch.qwc  -= batchSize
            }
        case 1: // VIF1 — feed data into VIF1
            if let vif = vif1 {
                var words: [UInt32] = []
                for _ in 0..<(batchSize * 4) {
                    words.append(bus.read32(address: ch.madr))
                    ch.madr += 4
                }
                ch.qwc -= batchSize
                vif.feed(words: words)
            } else {
                ch.madr += batchSize * 16
                ch.qwc  -= batchSize
            }
        case 2: // GIF — direct path to GS
            var gifData: [UInt64] = []
            for _ in 0..<batchSize {
                let lo = UInt64(bus.read32(address: ch.madr))
                let hi = UInt64(bus.read32(address: ch.madr + 4))
                gifData.append(lo | (hi << 32))
                ch.madr += 16
                ch.qwc  -= 1
            }
            gs?.processGIFPacket(data: gifData, qwordCount: gifData.count, flag: 0)
        default:
            ch.madr += batchSize * 16
            ch.qwc  -= batchSize
        }

        channels[idx] = ch

        if ch.qwc == 0 {
            channels[idx].chcr &= ~(1 << 8)
            dstat |= (1 << idx)
            checkInterrupt()
        }
    }

    private func checkInterrupt() {
        if dstat & dmask != 0 { intc?.assertIRQ(bit: 3) }
    }

    // MARK: - I/O

    func read(offset: UInt32) -> UInt32 {
        let ch = Int((offset >> 8) & 0xF)
        switch offset & 0xFF {
        case 0x00: return ch < channels.count ? channels[ch].chcr : 0
        case 0x10: return ch < channels.count ? channels[ch].madr : 0
        case 0x20: return ch < channels.count ? channels[ch].qwc  : 0
        case 0x30: return ch < channels.count ? channels[ch].tadr : 0
        case 0xE0: return dstat
        case 0xF0: return dmask
        default:   return 0
        }
    }

    func write(offset: UInt32, value: UInt32) {
        let ch = Int((offset >> 8) & 0xF)
        switch offset & 0xFF {
        case 0x00:
            if ch < channels.count {
                channels[ch].chcr = value
                if value & (1 << 8) != 0 { performTransfer(channel: ch) }
            }
        case 0x10: if ch < channels.count { channels[ch].madr = value }
        case 0x20: if ch < channels.count { channels[ch].qwc  = value }
        case 0x30: if ch < channels.count { channels[ch].tadr = value }
        case 0xE0: dstat = value
        case 0xF0: dmask = value
        default:   break
        }
    }
}

// MARK: - INTC

public final class INTC {
    var stat: UInt32 = 0
    var mask: UInt32 = 0

    func assertIRQ(bit: Int) {
        stat |= (1 << bit)
    }

    func read(offset: UInt32) -> UInt32 {
        switch offset {
        case 0: return stat
        case 4: return mask
        default: return 0
        }
    }

    func write(offset: UInt32, value: UInt32) {
        switch offset {
        case 0: stat &= ~value
        case 4: mask = value
        default: break
        }
    }
}

// MARK: - EE Timer

public final class EETimer {
    var count: [UInt32] = [0, 0, 0, 0]
    var mode:  [UInt32] = [0, 0, 0, 0]
    var comp:  [UInt32] = [0, 0, 0, 0]
    weak var intc: INTC?

    func tick() {
        for i in 0..<4 {
            guard mode[i] & 1 != 0 else { continue }
            count[i] &+= 1
            if count[i] >= comp[i] {
                count[i] = 0
                intc?.assertIRQ(bit: 9 + i)
            }
        }
    }

    func read(offset: UInt32) -> UInt32 {
        let t = Int((offset >> 4) & 3)
        switch offset & 0xF {
        case 0: return count[t]
        case 4: return mode[t]
        case 8: return comp[t]
        default: return 0
        }
    }

    func write(offset: UInt32, value: UInt32) {
        let t = Int((offset >> 4) & 3)
        switch offset & 0xF {
        case 0: count[t] = value
        case 4: mode[t]  = value
        case 8: comp[t]  = value
        default: break
        }
    }
}
