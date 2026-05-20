import Foundation

// MARK: - Execution Mode

public enum ExecutionMode: String, CaseIterable {
    case jit        = "JIT"
    case jitless    = "JitLess"

    var displayName: String {
        switch self {
        case .jit:     return "JIT (Faster)"
        case .jitless: return "JitLess (Compatible)"
        }
    }

    var description: String {
        switch self {
        case .jit:
            return "Block-recompiler caches decoded instruction sequences for higher performance. Requires JIT entitlement (AltStore, SideStore)."
        case .jitless:
            return "Pure interpreter. Works without any special entitlements. More compatible, slightly slower."
        }
    }

    var systemImage: String {
        switch self {
        case .jit:     return "bolt.fill"
        case .jitless: return "shield.fill"
        }
    }
}

// MARK: - Decoded Instruction

/// A single pre-decoded EE instruction ready for fast dispatch.
struct DecodedInstruction {
    let op:    UInt32
    let rs:    Int
    let rt:    Int
    let rd:    Int
    let shamt: UInt32
    let funct: UInt32
    let imm16: Int32
    let imm26: UInt32
    let raw:   UInt32

    init(_ instruction: UInt32) {
        raw   = instruction
        op    = (instruction >> 26) & 0x3F
        rs    = Int((instruction >> 21) & 0x1F)
        rt    = Int((instruction >> 16) & 0x1F)
        rd    = Int((instruction >> 11) & 0x1F)
        shamt = (instruction >> 6) & 0x1F
        funct = instruction & 0x3F
        imm16 = Int32(Int16(bitPattern: UInt16(instruction & 0xFFFF)))
        imm26 = instruction & 0x03FF_FFFF
    }
}

// MARK: - Compiled Block

/// A cached block of pre-decoded instructions starting at a given PC.
/// In JIT mode the EE fetches these instead of re-decoding each cycle.
final class CompiledBlock {
    let startPC:      UInt32
    let instructions: [DecodedInstruction]
    var hitCount:     Int = 0

    init(startPC: UInt32, instructions: [DecodedInstruction]) {
        self.startPC      = startPC
        self.instructions = instructions
    }
}

// MARK: - JIT Block Cache

/// Caches compiled blocks keyed by their starting PC.
/// Thread-safe for read-heavy workloads (single writer, concurrent readers).
public final class JITBlockCache: @unchecked Sendable {

    // Maximum number of cached blocks before eviction
    private static let maxBlocks = 4096

    private var cache: [UInt32: CompiledBlock] = [:]
    private var insertionOrder: [UInt32] = []
    private let lock = NSLock()

    // MARK: - Stats (for Settings display)
    private(set) var totalCompilations: Int = 0
    private(set) var cacheHits: Int = 0
    private(set) var cacheMisses: Int = 0

    var blockCount: Int {
        lock.lock(); defer { lock.unlock() }
        return cache.count
    }

    var hitRate: Double {
        let total = cacheHits + cacheMisses
        return total > 0 ? Double(cacheHits) / Double(total) : 0
    }

    // MARK: - Lookup / Insert

    func block(for pc: UInt32) -> CompiledBlock? {
        lock.lock(); defer { lock.unlock() }
        if let b = cache[pc] {
            b.hitCount += 1
            cacheHits += 1
            return b
        }
        cacheMisses += 1
        return nil
    }

    func insert(_ block: CompiledBlock) {
        lock.lock(); defer { lock.unlock() }
        if cache[block.startPC] != nil { return }
        if cache.count >= Self.maxBlocks { evictOldest() }
        cache[block.startPC] = block
        insertionOrder.append(block.startPC)
        totalCompilations += 1
    }

    /// Invalidate a specific address range (e.g. after a DMA write to RAM).
    func invalidate(from start: UInt32, size: UInt32) {
        lock.lock(); defer { lock.unlock() }
        let end = start &+ size
        insertionOrder.removeAll { pc in
            if pc >= start && pc < end {
                cache.removeValue(forKey: pc)
                return true
            }
            return false
        }
    }

    func flush() {
        lock.lock(); defer { lock.unlock() }
        cache.removeAll()
        insertionOrder.removeAll()
    }

    // MARK: - Eviction (FIFO)

    private func evictOldest() {
        guard let oldest = insertionOrder.first else { return }
        insertionOrder.removeFirst()
        cache.removeValue(forKey: oldest)
    }
}

// MARK: - Block Compiler

/// Walks memory from `startPC` and decodes instructions into a CompiledBlock.
/// Stops at any branch/jump or after `maxInstructions`.
enum BlockCompiler {
    static let maxInstructions = 64

    /// Branch/jump opcodes that terminate a block
    private static let branchOps: Set<UInt32> = [0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x14, 0x15]
    private static let branchFuncts: Set<UInt32> = [0x08, 0x09] // JR, JALR

    static func compile(at pc: UInt32, bus: MemoryBus) -> CompiledBlock {
        var instructions: [DecodedInstruction] = []
        var currentPC = pc
        var inDelaySlot = false

        for _ in 0..<maxInstructions {
            let raw = bus.read32(address: currentPC)
            let decoded = DecodedInstruction(raw)
            instructions.append(decoded)
            currentPC &+= 4

            if inDelaySlot { break }

            let isBranch = branchOps.contains(decoded.op) ||
                           (decoded.op == 0x01) ||  // REGIMM
                           (decoded.op == 0x00 && branchFuncts.contains(decoded.funct))
            if isBranch { inDelaySlot = true }
        }

        return CompiledBlock(startPC: pc, instructions: instructions)
    }
}
