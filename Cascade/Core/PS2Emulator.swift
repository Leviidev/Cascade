import Foundation
import Metal

// MARK: - PS2 Emulator — Main Orchestrator

public final class PS2Emulator {

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

        // Wire up cross-references
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
        // Also load BIOS into IOP RAM mirror
        let iopBiosSize = min(data.count, iop.ram.count)
        data.copyBytes(to: &iop.ram, count: iopBiosSize)
    }

    // MARK: - Disc Loading

    func loadDisc(url: URL) throws {
        guard biosLoaded else { throw EmulatorError.biosNotLoaded }
        try cdvd.loadISO(url: url)
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
                // Sleep for ~half a frame to reduce spin-wait overhead
                let sleepNs = UInt32((nsPerFrame - elapsed) / 2)
                usleep(sleepNs / 1000)
            }
        }
    }

    private func executeFrame() {
        // Step EE CPU
        ee.step(count: eePerFrame)

        // Step IOP CPU (and SPU2, via IOP.step)
        iop.step(count: iopPerFrame)

        // Step DMAC
        dmac.step()

        // Step EE timers
        for _ in 0..<(eePerFrame / 256) { timer.tick() }

        // Signal VBlank to GS
        signalVBlank()

        // Deliver frame
        let frame = gs.getFrameBuffer()
        onFrameReady?(frame, gs.outputWidth, gs.outputHeight)
    }

    private func signalVBlank() {
        intc.assertIRQ(bit: 2)   // VBLANK-IN
        gs.csr |= (1 << 3)       // VBlank flag in GS CSR
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
        case .biosNotLoaded:      return "No PS2 BIOS is loaded. Please import a BIOS file first."
        case .biosInvalid(let m): return "Invalid BIOS: \(m)"
        case .discLoadFailed(let m): return "Failed to load disc: \(m)"
        }
    }
}
