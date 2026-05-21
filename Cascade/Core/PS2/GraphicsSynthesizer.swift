import Foundation
import Metal
import simd

// MARK: - PS2 Graphics Synthesizer
// The GS renders to a 4MB local VRAM (PSMCT32, PSMCT16, PSMT8, PSMT4)
// It supports alpha blending, fog, depth testing, and texture mapping.

public final class GraphicsSynthesizer {

    // MARK: - VRAM

    let vramSize = 4 * 1024 * 1024
    var vram: [UInt8]

    // MARK: - GS Registers

    struct GSRegisters {
        var prim:    UInt64 = 0
        var rgbaq:   UInt64 = 0
        var uv:      UInt64 = 0
        var xyzf:    UInt64 = 0
        var xyz:     UInt64 = 0
        var tex0:    [UInt64] = [0, 0]
        var tex1:    [UInt64] = [0, 0]
        var clamp:   [UInt64] = [0, 0]
        var fog:     UInt64 = 0
        var xyzf2:   UInt64 = 0
        var xyz2:    UInt64 = 0
        var texA:    UInt64 = 0
        var fogCol:  UInt64 = 0
        var texFlush: UInt64 = 0
        var scissor: [UInt64] = [0, 0]
        var alpha:   [UInt64] = [0, 0]
        var dimx:    UInt64 = 0
        var dthe:    UInt64 = 0
        var colClamp: UInt64 = 0
        var test:    [UInt64] = [0, 0]
        var pabe:    UInt64 = 0
        var fba:     [UInt64] = [0, 0]
        var frame:   [UInt64] = [0, 0]
        var zbuf:    [UInt64] = [0, 0]
        var bitbltbuf: UInt64 = 0
        var trxPos:  UInt64 = 0
        var trxReg:  UInt64 = 0
        var trxDir:  UInt64 = 0
        var hwreg:   UInt64 = 0
        var signal:  UInt64 = 0
        var finish:  UInt64 = 0
        var label:   UInt64 = 0
    }

    var regs = GSRegisters()

    // Privileged registers (accessed via EE bus)
    var pmode:   UInt64 = 0
    var smode1:  UInt64 = 0
    var smode2:  UInt64 = 0
    var srfsh:   UInt64 = 0
    var synch1:  UInt64 = 0
    var synch2:  UInt64 = 0
    var syncv:   UInt64 = 0
    var dispfb:  [UInt64] = [0, 0]
    var display: [UInt64] = [0, 0]
    var extbuf:  UInt64 = 0
    var extdata: UInt64 = 0
    var extwrite: UInt64 = 0
    var bgcolor: UInt64 = 0
    var csr:     UInt64 = 0x1BA
    var imr:     UInt64 = 0xFF00

    // MARK: - Primitive State
    struct Vertex {
        var x, y, z: Float
        var r, g, b, a: Float
        var u, v: Float
        var q: Float
        var fog: Float
    }

    var vertexQueue: [Vertex] = []
    var currentVertex = Vertex(x: 0, y: 0, z: 0, r: 1, g: 1, b: 1, a: 1, u: 0, v: 0, q: 1, fog: 0)

    // Transfer state
    var trxBuffer: [UInt8] = []
    var trxWordsLeft: Int = 0
    var trxDestX: Int = 0
    var trxDestY: Int = 0

    // MARK: - Metal rendering output
    var metalTexture: MTLTexture?
    var outputWidth: Int = 640
    var outputHeight: Int = 448

    // MARK: - Init

    init() {
        vram = [UInt8](repeating: 0, count: vramSize)
    }

    // MARK: - Privileged Register Access (from EE bus)

    func readPriv(offset: UInt32) -> UInt32 {
        switch offset {
        case 0x00: return UInt32(csr & 0xFFFF_FFFF)
        case 0x04: return UInt32(csr >> 32)
        case 0x10: return UInt32(imr & 0xFFFF_FFFF)
        default:   return 0
        }
    }

    func writePriv(offset: UInt32, value: UInt32) {
        switch offset >> 4 {
        case 0x0: pmode   = (pmode   & ~(UInt64(0xFFFF_FFFF) << ((offset & 4) == 0 ? 0 : 32))) | (UInt64(value) << ((offset & 4) == 0 ? 0 : 32))
        case 0xA: csr     = UInt64(value)
        case 0xB: imr     = UInt64(value)
        default:  break
        }
    }

    // MARK: - GIF Packet Processing

    func processGIFPacket(data: [UInt64], qwordCount: Int, flag: Int) {
        // flag: 0 = PACKED, 1 = REGLIST, 2 = IMAGE, 3 = DISABLE
        var offset = 0
        while offset < qwordCount {
            let tag = data[offset]; offset += 1
            let nloop   = Int(tag & 0x7FFF)
            let eop     = (tag >> 15) & 1
            let pre     = (tag >> 46) & 1
            let prim    = (tag >> 47) & 0x7FF
            let flg     = Int((tag >> 58) & 3)
            let nreg    = Int((tag >> 60) & 0xF)
            let regsField = data[offset]; offset += 1

            if pre != 0 { regs.prim = prim }

            var registers: [Int] = []
            for i in 0..<(nreg == 0 ? 16 : nreg) {
                registers.append(Int((regsField >> (i * 4)) & 0xF))
            }

            for _ in 0..<nloop {
                switch flg {
                case 0: // PACKED
                    for reg in registers {
                        guard offset < data.count else { break }
                        let lo = data[offset]; offset += 1
                        let hi = offset < data.count ? data[offset] : 0; offset += 1
                        writeGSRegPacked(reg: reg, lo: lo, hi: hi)
                    }
                case 1: // REGLIST
                    for reg in registers {
                        guard offset < data.count else { break }
                        writeGSReg(reg: reg, value: data[offset]); offset += 1
                    }
                case 2: // IMAGE
                    let words = min((qwordCount - offset) * 2, trxWordsLeft)
                    // feed image transfer
                    offset += words / 2
                default: break
                }
            }
            if eop != 0 { break }
        }
    }

    private func writeGSRegPacked(reg: Int, lo: UInt64, hi: UInt64) {
        switch reg {
        case 0x00: // PRIM
            regs.prim = lo & 0x7FF
        case 0x01: // RGBAQ
            let r = Float(lo & 0xFF) / 255
            let g = Float((lo >> 8) & 0xFF) / 255
            let b = Float((lo >> 16) & 0xFF) / 255
            let a = Float((lo >> 24) & 0xFF) / 255
            let q = Float(bitPattern: UInt32(hi & 0xFFFF_FFFF))
            currentVertex.r = r; currentVertex.g = g; currentVertex.b = b; currentVertex.a = a; currentVertex.q = q
        case 0x02: // ST
            currentVertex.u = Float(bitPattern: UInt32(lo & 0xFFFF_FFFF))
            currentVertex.v = Float(bitPattern: UInt32((lo >> 32) & 0xFFFF_FFFF))
        case 0x03: // UV
            currentVertex.u = Float((lo & 0x3FFF) >> 4)
            currentVertex.v = Float(((lo >> 16) & 0x3FFF) >> 4)
        case 0x04, 0x0C: // XYZF2 / XYZF3
            currentVertex.x = Float(lo & 0xFFFF) / 16.0
            currentVertex.y = Float((lo >> 16) & 0xFFFF) / 16.0
            currentVertex.z = Float((lo >> 32) & 0x00FF_FFFF)
            currentVertex.fog = Float((hi >> 36) & 0xFF)
            submitVertex(kick: reg == 0x04)
        case 0x05, 0x0D: // XYZ2 / XYZ3
            currentVertex.x = Float(lo & 0xFFFF) / 16.0
            currentVertex.y = Float((lo >> 16) & 0xFFFF) / 16.0
            currentVertex.z = Float((lo >> 32) & 0xFFFF_FFFF)
            submitVertex(kick: reg == 0x05)
        case 0x06: regs.tex0[0] = lo
        case 0x07: regs.tex0[1] = lo
        case 0x08: regs.clamp[0] = lo
        case 0x09: regs.clamp[1] = lo
        case 0x0A: currentVertex.fog = Float(lo & 0xFF)
        case 0x0E: writeGSReg(reg: Int(lo & 0xFF), value: hi)
        default: break
        }
    }

    func writeGSReg(reg: Int, value: UInt64) {
        switch reg {
        case 0x00: regs.prim = value
        case 0x01: regs.rgbaq = value
        case 0x02, 0x03: regs.tex0[reg - 0x02] = value
        case 0x06: regs.tex0[0] = value
        case 0x07: regs.tex0[1] = value
        case 0x18: regs.alpha[0] = value
        case 0x19: regs.alpha[1] = value
        case 0x40: regs.scissor[0] = value
        case 0x41: regs.scissor[1] = value
        case 0x4C: regs.frame[0] = value
        case 0x4D: regs.frame[1] = value
        case 0x4E: regs.zbuf[0] = value
        case 0x4F: regs.zbuf[1] = value
        case 0x50: regs.bitbltbuf = value; startTransfer(value)
        case 0x51: regs.trxPos = value
        case 0x52: regs.trxReg = value
        case 0x53: regs.trxDir = value
        case 0x54: feedImageData(value)
        default: break
        }
    }

    // MARK: - Primitive Submission

    private func submitVertex(kick: Bool) {
        vertexQueue.append(currentVertex)
        if kick { rasterize() }
    }

    private func rasterize() {
        let primType = Int(regs.prim & 0x7)
        switch primType {
        case 0: drawPoint()
        case 1: drawLine()
        case 2: drawLineStrip()
        case 3: drawTriangle()
        case 4: drawTriangleStrip()
        case 5: drawTriangleFan()
        case 6: drawSprite()
        default: break
        }
    }

    private func drawPoint() {
        guard !vertexQueue.isEmpty else { return }
        let v = vertexQueue.removeLast()
        let x = Int(v.x); let y = Int(v.y)
        plotPixel(x: x, y: y, r: v.r, g: v.g, b: v.b, a: v.a)
    }

    private func drawLine() {
        guard vertexQueue.count >= 2 else { return }
        let v1 = vertexQueue[vertexQueue.count - 2]
        let v2 = vertexQueue[vertexQueue.count - 1]
        vertexQueue.removeLast(2)
        bresenhamLine(x0: Int(v1.x), y0: Int(v1.y), x1: Int(v2.x), y1: Int(v2.y),
                      r: v1.r, g: v1.g, b: v1.b, a: v1.a)
    }

    private func drawLineStrip() {
        guard vertexQueue.count >= 2 else { return }
        let v1 = vertexQueue[vertexQueue.count - 2]
        let v2 = vertexQueue[vertexQueue.count - 1]
        bresenhamLine(x0: Int(v1.x), y0: Int(v1.y), x1: Int(v2.x), y1: Int(v2.y),
                      r: v2.r, g: v2.g, b: v2.b, a: v2.a)
        vertexQueue.removeFirst()
    }

    private func drawTriangle() {
        guard vertexQueue.count >= 3 else { return }
        let v0 = vertexQueue[0]; let v1 = vertexQueue[1]; let v2 = vertexQueue[2]
        vertexQueue.removeAll()
        fillTriangle(v0: v0, v1: v1, v2: v2)
    }

    private func drawTriangleStrip() {
        guard vertexQueue.count >= 3 else { return }
        let i = vertexQueue.count - 3
        fillTriangle(v0: vertexQueue[i], v1: vertexQueue[i+1], v2: vertexQueue[i+2])
        if vertexQueue.count > 3 { vertexQueue.removeFirst() }
    }

    private func drawTriangleFan() {
        guard vertexQueue.count >= 3 else { return }
        let v0 = vertexQueue[0]
        let v1 = vertexQueue[vertexQueue.count - 2]
        let v2 = vertexQueue[vertexQueue.count - 1]
        fillTriangle(v0: v0, v1: v1, v2: v2)
        if vertexQueue.count > 2 { vertexQueue.removeLast() }
    }

    private func drawSprite() {
        guard vertexQueue.count >= 2 else { return }
        let v0 = vertexQueue[0]; let v1 = vertexQueue[1]
        vertexQueue.removeAll()
        let x0 = Int(min(v0.x, v1.x)); let y0 = Int(min(v0.y, v1.y))
        let x1 = Int(max(v0.x, v1.x)); let y1 = Int(max(v0.y, v1.y))
        for y in y0..<y1 {
            for x in x0..<x1 {
                plotPixel(x: x, y: y, r: v0.r, g: v0.g, b: v0.b, a: v0.a)
            }
        }
    }

    // MARK: - Rasterisation helpers

    private func fillTriangle(v0: Vertex, v1: Vertex, v2: Vertex) {
        var a = v0; var b = v1; var c = v2
        if a.y > b.y { swap(&a, &b) }
        if a.y > c.y { swap(&a, &c) }
        if b.y > c.y { swap(&b, &c) }

        let totalH = c.y - a.y; if totalH == 0 { return }

        for y in Int(a.y)..<Int(c.y) {
            let second = Float(y) >= b.y
            let segH = second ? c.y - b.y : b.y - a.y
            guard segH > 0 else { continue }
            let alpha = (Float(y) - a.y) / totalH
            let beta  = second ? (Float(y) - b.y) / segH : (Float(y) - a.y) / segH
            let pA    = second ? b : a
            var xL = a.x + (c.x - a.x) * alpha
            var xR = pA.x + ((second ? c : b).x - pA.x) * beta
            if xL > xR { swap(&xL, &xR) }
            let r = a.r + (c.r - a.r) * alpha
            let g = a.g + (c.g - a.g) * alpha
            let ba = a.b + (c.b - a.b) * alpha
            let al = a.a + (c.a - a.a) * alpha
            for x in Int(xL)..<Int(xR) { plotPixel(x: x, y: y, r: r, g: g, b: ba, a: al) }
        }
    }

    private func bresenhamLine(x0: Int, y0: Int, x1: Int, y1: Int, r: Float, g: Float, b: Float, a: Float) {
        var cx = x0; var cy = y0
        let dx = abs(x1 - cx); let dy = abs(y1 - cy)
        let sx = cx < x1 ? 1 : -1; let sy = cy < y1 ? 1 : -1
        var err = dx - dy
        while true {
            plotPixel(x: cx, y: cy, r: r, g: g, b: b, a: a)
            if cx == x1 && cy == y1 { break }
            let e2 = 2 * err
            if e2 > -dy { err -= dy; cx += sx }
            if e2 < dx  { err += dx; cy += sy }
        }
    }

    private func plotPixel(x: Int, y: Int, r: Float, g: Float, b: Float, a: Float) {
        guard x >= 0, y >= 0, x < outputWidth, y < outputHeight else { return }
        let fbBase = Int((regs.frame[0] & 0x1FF) << 11)
        let offset = fbBase + (y * outputWidth + x) * 4
        guard offset + 3 < vramSize else { return }
        vram[offset + 0] = UInt8(clamp01(r) * 255)
        vram[offset + 1] = UInt8(clamp01(g) * 255)
        vram[offset + 2] = UInt8(clamp01(b) * 255)
        vram[offset + 3] = UInt8(clamp01(a) * 128)   // PS2 alpha is 0-128
    }

    private func clamp01(_ v: Float) -> Float { min(1, max(0, v)) }

    // MARK: - Image Transfer

    private func startTransfer(_ regVal: UInt64) {
        let dw = Int((regs.trxReg >> 0)  & 0xFFF) + 1
        let dh = Int((regs.trxReg >> 32) & 0xFFF) + 1
        trxDestX = Int(regs.trxPos & 0x7FF)
        trxDestY = Int((regs.trxPos >> 16) & 0x7FF)
        trxWordsLeft = dw * dh
        trxBuffer.removeAll()
    }

    private func feedImageData(_ value: UInt64) {
        guard trxWordsLeft > 0 else { return }
        trxBuffer.append(contentsOf: withUnsafeBytes(of: value.littleEndian) { Array($0) })
        trxWordsLeft -= 1
        if trxWordsLeft == 0 { flushImageTransfer() }
    }

    private func flushImageTransfer() {
        let dstBase = Int(((regs.bitbltbuf >> 32) & 0x3FFF) << 6)
        let dstW    = Int(((regs.bitbltbuf >> 48) & 0x3F) << 6)
        let dstFmt  = Int((regs.bitbltbuf >> 56) & 0x3F)
        _ = dstFmt
        let x0 = trxDestX; let y0 = trxDestY
        var i = 0
        while i + 3 < trxBuffer.count {
            let pixIdx = i / 4
            let px = x0 + (pixIdx % max(1, dstW))
            let py = y0 + (pixIdx / max(1, dstW))
            let off = dstBase + (py * outputWidth + px) * 4
            if off + 3 < vramSize {
                vram[off]   = trxBuffer[i]
                vram[off+1] = trxBuffer[i+1]
                vram[off+2] = trxBuffer[i+2]
                vram[off+3] = trxBuffer[i+3]
            }
            i += 4
        }
        trxBuffer.removeAll()
    }

    // MARK: - Frame Output

    func getFrameBuffer() -> Data {
        let fbBase = Int((regs.frame[0] & 0x1FF) << 11)
        let size   = outputWidth * outputHeight * 4
        let end    = min(fbBase + size, vramSize)
        return Data(vram[fbBase..<end])
    }
}
