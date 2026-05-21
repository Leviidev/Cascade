import Foundation
import Compression

// MARK: - CHD v5 Disc Image Reader
// Implements the CHD (Compressed Hunks of Data) v5 format used by chdman.
// Supports NONE (uncompressed) and ZLIB/LZMA compressed hunks.
// Reference: libchdr (MAME project).

public final class CHDReader {

    // MARK: - Codec identifiers (big-endian 4-byte tags)
    private static let CODEC_NONE: UInt32 = 0x00000000
    private static let CODEC_ZLIB: UInt32 = 0x7a6c6962  // "zlib"
    private static let CODEC_LZMA: UInt32 = 0x6c7a6d61  // "lzma"

    // MARK: - Map entry types
    private static let MAP_COMPTYPE0:    UInt8 = 0
    private static let MAP_COMPTYPE1:    UInt8 = 1
    private static let MAP_COMPTYPE2:    UInt8 = 2
    private static let MAP_COMPTYPE3:    UInt8 = 3
    private static let MAP_NONE:         UInt8 = 4  // uncompressed full hunk
    private static let MAP_SELF:         UInt8 = 5  // copy of another hunk
    private static let MAP_PARENT:       UInt8 = 6  // from parent CHD
    private static let MAP_RLE_SMALL:    UInt8 = 7  // repeat 2-9 entries
    private static let MAP_RLE_LARGE:    UInt8 = 8  // repeat 10-73 entries

    // MARK: - Types

    public enum CHDError: Error, LocalizedError {
        case badSignature
        case unsupportedVersion(Int)
        case mapDecodeFailed(String)
        case unsupportedCodec(UInt32)
        case decompressionFailed
        case outOfBounds

        public var errorDescription: String? {
            switch self {
            case .badSignature:             return "Not a valid CHD file."
            case .unsupportedVersion(let v): return "CHD v\(v) is not supported (only v5)."
            case .mapDecodeFailed(let r):   return "CHD map decode failed: \(r)."
            case .unsupportedCodec(let c):  return "CHD codec 0x\(String(c, radix: 16)) is not supported."
            case .decompressionFailed:      return "CHD hunk decompression failed."
            case .outOfBounds:              return "CHD read out of bounds."
            }
        }
    }

    private struct MapEntry {
        var fileOffset: UInt64
        var compLength: UInt32
        var type:       UInt8
    }

    // MARK: - State

    private let raw:   Data
    public private(set) var hunkBytes:    UInt32 = 0
    public private(set) var hunkCount:   UInt32 = 0
    public private(set) var logicalBytes: UInt64 = 0
    private var codecs: [UInt32] = [0, 0, 0, 0]
    private var map:    [MapEntry] = []

    private var cache:  [(hunk: UInt32, data: Data)] = []
    private let cacheMax = 32

    // MARK: - Init

    public init(data: Data) throws {
        raw = data
        try parseHeader()
        try decodeMap()
    }

    // MARK: - Public Read API

    /// Read `length` bytes starting at logical byte offset `offset`.
    public func readBytes(at offset: UInt64, length: Int) throws -> Data {
        var out = Data(capacity: length)
        var rem = length
        var pos = offset
        while rem > 0 {
            let hunkIdx = UInt32(pos / UInt64(hunkBytes))
            let hunkOff = Int(pos % UInt64(hunkBytes))
            let hunkDat = try hunkData(hunkIdx)
            let take    = min(rem, hunkDat.count - hunkOff)
            guard take > 0 else { throw CHDError.outOfBounds }
            out.append(hunkDat[hunkOff ..< hunkOff + take])
            pos += UInt64(take)
            rem -= take
        }
        return out
    }

    // MARK: - Header Parsing

    private func parseHeader() throws {
        guard raw.count >= 124 else { throw CHDError.badSignature }
        let sig = String(bytes: raw[0..<8], encoding: .ascii)
        guard sig == "MComprHD" else { throw CHDError.badSignature }

        let ver = rbe32(at: 12)
        guard ver == 5 else { throw CHDError.unsupportedVersion(Int(ver)) }

        codecs[0]    = rbe32(at: 16)
        codecs[1]    = rbe32(at: 20)
        codecs[2]    = rbe32(at: 24)
        codecs[3]    = rbe32(at: 28)
        logicalBytes = rbe64(at: 32)
        mapOff       = Int(rbe64(at: 40))
        hunkBytes    = rbe32(at: 56)
        guard hunkBytes > 0 else { throw CHDError.mapDecodeFailed("hunkBytes is 0") }
        hunkCount    = UInt32((logicalBytes + UInt64(hunkBytes) - 1) / UInt64(hunkBytes))
    }

    private var mapOff: Int = 0

    // MARK: - Map Decoding
    // Implements libchdr's decompress_v5_map.

    private func decodeMap() throws {
        guard mapOff + 16 <= raw.count else {
            throw CHDError.mapDecodeFailed("map header out of bounds")
        }

        let compBytes  = Int(rbe32(at: mapOff))
        let firstOff   = rbe48(at: mapOff + 4)
        let lenBits    = Int(raw[mapOff + 12])
        let selfBits   = Int(raw[mapOff + 13])
        let parentBits = Int(raw[mapOff + 14])

        guard compBytes >= 0, mapOff + 16 + compBytes <= raw.count else {
            throw CHDError.mapDecodeFailed("compressed map out of bounds")
        }

        var bs = BitStream(raw, start: mapOff + 16, byteCount: compBytes)

        // Build the 16-symbol Huffman tree that encodes entry types.
        // libchdr: huffman_init(&decoder, 16, 8) then huffman_import_tree_huffman(&decoder, &bitbuf)
        let tree = try buildHuffTree(numSymbols: 16, from: &bs)

        map.reserveCapacity(Int(hunkCount))

        var curOffset: UInt64 = firstOff
        var repCount  = 0
        var repEntry  = MapEntry(fileOffset: 0, compLength: 0, type: 0)

        for _ in 0 ..< Int(hunkCount) {
            if repCount > 0 {
                map.append(repEntry)
                repCount -= 1
                continue
            }

            let t = try tree.decode(&bs)

            switch t {
            case Self.MAP_COMPTYPE0, Self.MAP_COMPTYPE1, Self.MAP_COMPTYPE2, Self.MAP_COMPTYPE3:
                let len = UInt32(try bs.read(lenBits))
                let e   = MapEntry(fileOffset: curOffset, compLength: len, type: t)
                map.append(e)
                curOffset += UInt64(len)

            case Self.MAP_NONE:
                let e = MapEntry(fileOffset: curOffset, compLength: 0, type: t)
                map.append(e)
                curOffset += UInt64(hunkBytes)

            case Self.MAP_SELF:
                let idx = UInt64(try bs.read(selfBits))
                map.append(MapEntry(fileOffset: idx, compLength: 0, type: t))

            case Self.MAP_PARENT:
                let idx = UInt64(try bs.read(parentBits))
                map.append(MapEntry(fileOffset: idx, compLength: 0, type: t))

            case Self.MAP_RLE_SMALL:
                let count = Int(try bs.read(3)) + 2       // 2-9
                repEntry  = map.last ?? MapEntry(fileOffset: 0, compLength: 0, type: 0)
                map.append(repEntry)
                repCount  = count - 2

            case Self.MAP_RLE_LARGE:
                let count = Int(try bs.read(6)) + 10      // 10-73
                repEntry  = map.last ?? MapEntry(fileOffset: 0, compLength: 0, type: 0)
                map.append(repEntry)
                repCount  = count - 2

            default:
                break   // symbols 9-15 are unused padding in libchdr's 16-slot table
            }
        }
    }

    // MARK: - Hunk Decompression

    private func hunkData(_ index: UInt32) throws -> Data {
        if let hit = cache.first(where: { $0.hunk == index }) { return hit.data }
        guard Int(index) < map.count else { throw CHDError.outOfBounds }

        let entry  = map[Int(index)]
        let result: Data

        switch entry.type {

        case Self.MAP_NONE:
            let start = Int(entry.fileOffset)
            let len   = Int(hunkBytes)
            guard start + len <= raw.count else { throw CHDError.outOfBounds }
            result = Data(raw[start ..< start + len])

        case Self.MAP_COMPTYPE0, Self.MAP_COMPTYPE1, Self.MAP_COMPTYPE2, Self.MAP_COMPTYPE3:
            let codec  = codecs[Int(entry.type)]
            let start  = Int(entry.fileOffset)
            let cLen   = Int(entry.compLength)
            guard start + cLen <= raw.count else { throw CHDError.outOfBounds }
            let src    = Data(raw[start ..< start + cLen])

            switch codec {
            case Self.CODEC_NONE:
                result = src
            case Self.CODEC_ZLIB:
                result = try inflateZlib(src, outputSize: Int(hunkBytes))
            case Self.CODEC_LZMA:
                result = try inflateLZMA(src, outputSize: Int(hunkBytes))
            default:
                throw CHDError.unsupportedCodec(codec)
            }

        case Self.MAP_SELF:
            result = try hunkData(UInt32(entry.fileOffset))

        default:
            throw CHDError.unsupportedCodec(UInt32(entry.type))
        }

        if cache.count >= cacheMax { cache.removeFirst() }
        cache.append((hunk: index, data: result))
        return result
    }

    // MARK: - Decompression Helpers

    private func inflateZlib(_ data: Data, outputSize: Int) throws -> Data {
        var out = Data(count: outputSize)
        let written: Int = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!,
                    outputSize,
                    src.bindMemory(to: UInt8.self).baseAddress!,
                    data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        if written > 0 { return Data(out.prefix(written)) }

        // Fallback: CHD zlib stores data with zlib wrapper (2-byte header).
        // If Apple's COMPRESSION_ZLIB expects raw deflate, strip the wrapper.
        guard data.count > 6 else { throw CHDError.decompressionFailed }
        let raw = data.dropFirst(2).dropLast(4)
        var out2 = Data(count: outputSize)
        let w2: Int = out2.withUnsafeMutableBytes { dst in
            raw.withUnsafeBytes { src in
                compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!,
                    outputSize,
                    src.bindMemory(to: UInt8.self).baseAddress!,
                    raw.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard w2 > 0 else { throw CHDError.decompressionFailed }
        return Data(out2.prefix(w2))
    }

    private func inflateLZMA(_ data: Data, outputSize: Int) throws -> Data {
        var out = Data(count: outputSize)
        let written: Int = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!,
                    outputSize,
                    src.bindMemory(to: UInt8.self).baseAddress!,
                    data.count,
                    nil,
                    COMPRESSION_LZMA
                )
            }
        }
        guard written > 0 else { throw CHDError.decompressionFailed }
        return Data(out.prefix(written))
    }

    // MARK: - Big-Endian Helpers

    private func rbe32(at i: Int) -> UInt32 {
        UInt32(raw[i]) << 24 | UInt32(raw[i+1]) << 16 | UInt32(raw[i+2]) << 8 | UInt32(raw[i+3])
    }
    private func rbe64(at i: Int) -> UInt64 {
        UInt64(rbe32(at: i)) << 32 | UInt64(rbe32(at: i+4))
    }
    private func rbe48(at i: Int) -> UInt64 {
        UInt64(raw[i]) << 40 | UInt64(raw[i+1]) << 32 | UInt64(raw[i+2]) << 24 |
        UInt64(raw[i+3]) << 16 | UInt64(raw[i+4]) << 8 | UInt64(raw[i+5])
    }
}

// MARK: - BitStream (MSB-first)

private struct BitStream {
    private let bytes: [UInt8]
    private var bytePos: Int = 0
    private var bitPos:  Int = 0   // 0 = MSB of current byte

    init(_ data: Data, start: Int, byteCount: Int) {
        let s = data.startIndex + start
        let e = min(s + byteCount, data.endIndex)
        bytes = Array(data[s..<e])
    }

    /// Read and consume `n` bits, MSB first.
    mutating func read(_ n: Int) throws -> UInt64 {
        var result: UInt64 = 0
        for _ in 0..<n {
            guard bytePos < bytes.count else { throw CHDReader.CHDError.mapDecodeFailed("bitstream underflow") }
            result = (result << 1) | UInt64((bytes[bytePos] >> (7 - bitPos)) & 1)
            bitPos += 1
            if bitPos == 8 { bitPos = 0; bytePos += 1 }
        }
        return result
    }

    /// Peek `n` bits without consuming.
    func peek(_ n: Int) throws -> UInt64 {
        var copy = self
        return try copy.read(n)
    }

    /// Consume `n` bits without returning them.
    mutating func skip(_ n: Int) {
        for _ in 0..<n {
            guard bytePos < bytes.count else { return }
            bitPos += 1
            if bitPos == 8 { bitPos = 0; bytePos += 1 }
        }
    }
}

// MARK: - Canonical Huffman Decoder

/// Decodes symbols using a canonical Huffman code built from per-symbol bit lengths.
private struct HuffDecoder {
    private struct Entry { let symbol: UInt8; let codeBits: Int }
    private let table:   [Entry?]   // indexed by maxBits-aligned bit pattern
    private let maxBits: Int

    init(lengths: [Int]) throws {
        let mb = lengths.max() ?? 0
        maxBits = mb
        guard mb <= 16 else { throw CHDReader.CHDError.mapDecodeFailed("code length > 16") }
        guard mb > 0 else { table = []; return }

        // Count how many symbols have each code length
        var counts = [Int](repeating: 0, count: mb + 1)
        for l in lengths where l > 0 { counts[l] += 1 }

        // Assign canonical starting codes for each length
        var nextCode = [UInt32](repeating: 0, count: mb + 2)
        var code: UInt32 = 0
        for bits in 1...mb {
            code = (code + UInt32(counts[bits - 1])) << 1
            nextCode[bits] = code
        }

        // Populate lookup table: fill all maxBits entries that start with each code
        var t = [Entry?](repeating: nil, count: 1 << mb)
        for (sym, len) in lengths.enumerated() {
            guard len > 0 else { continue }
            let c     = Int(nextCode[len])
            nextCode[len] += 1
            let shift = mb - len
            let base  = c << shift
            let span  = 1 << shift
            for j in base ..< min(base + span, t.count) {
                t[j] = Entry(symbol: UInt8(sym), codeBits: len)
            }
        }
        table = t
    }

    /// Decode one symbol from `bs`, consuming exactly as many bits as the symbol's code.
    func decode(_ bs: inout BitStream) throws -> UInt8 {
        guard maxBits > 0 else { throw CHDReader.CHDError.mapDecodeFailed("empty huffman tree") }
        let bits = Int(try bs.peek(maxBits))
        guard bits < table.count, let entry = table[bits] else {
            throw CHDReader.CHDError.mapDecodeFailed("bad huffman code 0x\(String(bits, radix: 16))")
        }
        bs.skip(entry.codeBits)
        return entry.symbol
    }
}

// MARK: - Huffman Tree Builder
// Implements libchdr's huffman_import_tree_huffman:
//   1. Read 3 bits → bits_per_length (0 = all zeros)
//   2. For each of numSymbols codes, read bits_per_length bits.
//      If value == (1 << bits_per_length) - 1 (sentinel):
//        read 3 bits → run_count + 2, read bits_per_length bits → actual value.
//   3. Build canonical Huffman from the lengths.

private func buildHuffTree(numSymbols: Int, from bs: inout BitStream) throws -> HuffDecoder {
    let bitsPerLen = Int(try bs.read(3))
    var lengths    = [Int](repeating: 0, count: numSymbols)

    if bitsPerLen > 0 {
        let sentinel = (1 << bitsPerLen) - 1
        var idx = 0
        while idx < numSymbols {
            let val = Int(try bs.read(bitsPerLen))
            var count    = 1
            var actual   = val
            if val == sentinel {
                count  = Int(try bs.read(3)) + 2
                actual = Int(try bs.read(bitsPerLen))
            }
            while count > 0, idx < numSymbols {
                lengths[idx] = actual
                idx += 1; count -= 1
            }
        }
    }

    return try HuffDecoder(lengths: lengths)
}
