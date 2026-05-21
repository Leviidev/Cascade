import Foundation
import Metal

// MARK: - PS2 Emulator — Main Orchestrator

public final class PS2Emulator: @unchecked Sendable {

    // MARK: - Components

    let bus:   MemoryBus
    let ee:    EmotionEngine
    let iop:   IOProcessor
    let gs:    GraphicsSynthesizer
    let dmac:  DMAC
    let intc:  INTC
    let timer: EETimer
    let spu2:  SPU2
    let cdvd:  CDVD
    let pad:   PadManager

    // MARK: - JIT

    let jitCache = JITBlockCache()
    var executionMode: ExecutionMode = .jit {
        didSet { if executionMode == .jitless { jitCache.flush() } }
    }

    // MARK: - State

    enum State { case off, paused, running }
    private(set) var state: State = .off
    private var runThread: Thread?
    private var running = false

    // MARK: - Timing
    // EE runs at ~294.9 MHz; GS at ~147.5 MHz; IOP at ~36.8 MHz
    // We execute in bursts per emulated VSync (50 or 60 Hz)

    var framesPerSecond: Double = 60
    var eePerFrame: Int { Int(294_912_000 / framesPerSecond) }
    var iopPerFrame: Int { Int(36_864_000 / framesPerSecond) }

    // MARK: - BIOS

    private(set) var biosLoaded = false

    // MARK: - Callbacks

    var onFrameReady: ((Data, Int, Int) -> Void)?
    var onError: ((Error) -> Void)?

    // MARK: - Active Cheats
    // Written from the main thread; read every frame on the emulator thread.
    // @unchecked Sendable on PS2Emulator covers this access pattern.
    nonisolated(unsafe) var activeCheats: [CheatCode] = []

    // MARK: - Init

    init() {
        bus   = MemoryBus()
        gs    = GraphicsSynthesizer()
        intc  = INTC()
        timer = EETimer()
        dmac  = DMAC()
        spu2  = SPU2()
        cdvd  = CDVD()
        pad   = PadManager()
        ee    = EmotionEngine(bus: bus)
        iop   = IOProcessor()

        bus.gs    = gs
        bus.dmac  = dmac
        bus.intc  = intc
        bus.timer = timer
        bus.iop   = iop
        dmac.bus  = bus
        dmac.intc = intc
        dmac.gs   = gs
        timer.intc = intc
        iop.spu2   = spu2
        iop.cdvd   = cdvd
        iop.pad    = pad
    }

    // MARK: - BIOS Loading

    func loadBIOS(data: Data) throws {
        guard bus.loadBIOS(data: data) else {
            throw EmulatorError.biosInvalid("BIOS file is too small or corrupted")
        }
        biosLoaded = true
        let iopBiosSize = min(data.count, iop.ram.count)
        data.copyBytes(to: &iop.ram, count: iopBiosSize)
    }

    // MARK: - Disc Loading

    func loadDisc(url: URL) throws {
        guard biosLoaded else { throw EmulatorError.biosNotLoaded }
        switch url.pathExtension.lowercased() {
        case "cue": try cdvd.loadCUE(url: url)
        case "bin": try cdvd.loadBIN(url: url)
        case "chd": try cdvd.loadCHD(url: url)
        default:    try cdvd.loadISO(url: url)
        }
        framesPerSecond = cdvd.discRegion == .pal ? 50 : 60
    }

    // MARK: - Run / Pause / Stop

    func start() {
        guard state == .paused || state == .off else { return }
        state = .running
        running = true
        runThread = Thread { [weak self] in self?.runLoop() }
        runThread?.name = "com.cascade.emulator"
        runThread?.qualityOfService = .userInteractive
        runThread?.start()
    }

    func pause() {
        state = .paused
        running = false
    }

    func stop() {
        running = false
        state = .off
        ee.reset()
        iop.reset()
        jitCache.flush()
    }

    // MARK: - Run Loop

    private func runLoop() {
        let nsPerFrame = 1_000_000_000.0 / framesPerSecond
        var lastTime = DispatchTime.now().uptimeNanoseconds

        while running {
            let now = DispatchTime.now().uptimeNanoseconds
            let elapsed = Double(now - lastTime)

            if elapsed >= nsPerFrame {
                lastTime = now
                executeFrame()
            } else {
                let sleepNs = UInt32((nsPerFrame - elapsed) / 2)
                usleep(sleepNs / 1000)
            }
        }
    }

    private func executeFrame() {
        switch executionMode {
        case .jit:     executeFrameJIT()
        case .jitless: executeFrameInterpreter()
        }

        iop.step(count: iopPerFrame)
        dmac.step()
        for _ in 0..<(eePerFrame / 256) { timer.tick() }
        applyActiveCheatsToRAM()
        signalVBlank()

        let frame = gs.getFrameBuffer()
        onFrameReady?(frame, gs.outputWidth, gs.outputHeight)
    }

    private func applyActiveCheatsToRAM() {
        for cheat in activeCheats where cheat.enabled {
            let parts = cheat.code.split(separator: " ")
            guard parts.count == 2,
                  let rawAddr = UInt32(parts[0], radix: 16),
                  let value   = UInt32(parts[1], radix: 16) else { continue }
            let addr = Int(rawAddr & 0x01FF_FFFF)
            let type = (rawAddr >> 28) & 0xF
            switch type {
            case 0:
                guard addr < bus.ram.count else { continue }
                bus.ram[addr] = UInt8(value & 0xFF)
            case 1:
                guard addr + 1 < bus.ram.count else { continue }
                bus.ram[addr]     = UInt8(value & 0xFF)
                bus.ram[addr + 1] = UInt8((value >> 8) & 0xFF)
            default:
                guard addr + 3 < bus.ram.count else { continue }
                bus.ram[addr]     = UInt8(value & 0xFF)
                bus.ram[addr + 1] = UInt8((value >> 8) & 0xFF)
                bus.ram[addr + 2] = UInt8((value >> 16) & 0xFF)
                bus.ram[addr + 3] = UInt8((value >> 24) & 0xFF)
            }
        }
    }

    // MARK: - JIT Execution (block recompiler)

    private func executeFrameJIT() {
        var remaining = eePerFrame

        while remaining > 0 {
            let pc = ee.pc

            // Look up a compiled block from the cache
            if let block = jitCache.block(for: pc) {
                ee.executeBlock(block)
                remaining -= block.instructions.count
            } else {
                // Compile a new block and cache it
                let block = BlockCompiler.compile(at: pc, bus: bus)
                jitCache.insert(block)
                ee.executeBlock(block)
                remaining -= block.instructions.count
            }
        }
    }

    // MARK: - Interpreter Execution (JitLess)

    private func executeFrameInterpreter() {
        ee.step(count: eePerFrame)
    }

    // MARK: - VBlank

    private func signalVBlank() {
        intc.assertIRQ(bit: 2)
        gs.csr |= (1 << 3)
    }

    // MARK: - Save States

    func saveState(to url: URL) throws {
        let state = SaveState(
            eePc: ee.pc,
            eeGpr: ee.gpr.map { [$0.hi, $0.lo] },
            iopPc: iop.pc,
            iopGpr: iop.gpr,
            ram: Data(bus.ram),
            iopRam: Data(iop.ram)
        )
        let data = try JSONEncoder().encode(state)
        try data.write(to: url)
    }

    func loadState(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let s = try JSONDecoder().decode(SaveState.self, from: data)
        ee.pc = s.eePc
        ee.gpr = s.eeGpr.map { UInt128(hi: $0[0], lo: $0[1]) }
        iop.pc = s.iopPc
        iop.gpr = s.iopGpr
        s.ram.copyBytes(to: &bus.ram, count: min(s.ram.count, bus.ram.count))
        s.iopRam.copyBytes(to: &iop.ram, count: min(s.iopRam.count, iop.ram.count))
        // Flush JIT cache after state load — code may have changed
        jitCache.flush()
    }
}

// MARK: - Save State Codable

struct SaveState: Codable {
    var eePc:   UInt32
    var eeGpr:  [[UInt64]]
    var iopPc:  UInt32
    var iopGpr: [UInt32]
    var ram:    Data
    var iopRam: Data
}

// MARK: - Errors

enum EmulatorError: LocalizedError {
    case biosNotLoaded
    case biosInvalid(String)
    case discLoadFailed(String)

    var errorDescription: String? {
        switch self {
        case .biosNotLoaded:         return "No PS2 BIOS is loaded. Please import a BIOS file first."
        case .biosInvalid(let m):    return "Invalid BIOS: \(m)"
        case .discLoadFailed(let m): return "Failed to load disc: \(m)"
        }
    }
}
