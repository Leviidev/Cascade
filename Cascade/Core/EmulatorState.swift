import SwiftUI
import Combine
import Compression
import UniformTypeIdentifiers

// MARK: - Global Emulator State (ObservableObject)

@MainActor
public final class EmulatorState: ObservableObject {

    // MARK: - Published State

    @Published var status: Status = .idle
    @Published var fps: Double = 0
    @Published var currentGame: GameEntry?
    @Published var lastPlayedGame: GameEntry?
    @Published var frameImage: UIImage?
    @Published var biosLoaded: Bool = false
    @Published var errorMessage: String?
    @Published var showError: Bool = false
    @Published var jitBlockCount: Int = 0
    @Published var jitHitRate: Double = 0

    // MARK: - Execution Mode

    var executionMode: ExecutionMode = .jit {
        didSet {
            emulator.executionMode = executionMode
            UserDefaults.standard.set(executionMode.rawValue, forKey: "executionMode")
        }
    }

    // MARK: - Emulator

    let emulator = PS2Emulator()
    private var fpsTimer: Timer?
    private var frameCount: Int = 0

    // MARK: - Status

    enum Status: Equatable {
        case idle, running, paused, loading
    }

    // MARK: - Init

    init() {
        let savedMode = UserDefaults.standard.string(forKey: "executionMode") ?? ExecutionMode.jit.rawValue
        executionMode = ExecutionMode(rawValue: savedMode) ?? .jit
        emulator.executionMode = executionMode
        checkBIOS()
        setupFrameCallback()
    }

    private func setupFrameCallback() {
        emulator.onFrameReady = { [weak self] data, width, height in
            guard let self else { return }
            self.frameCount += 1
            if let image = UIImage.fromRGBA(data: data, width: width, height: height) {
                DispatchQueue.main.async { self.frameImage = image }
            }
        }
        emulator.onError = { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.errorMessage = error.localizedDescription
                self.showError = true
                CrashReporter.shared.record(
                    error: error,
                    game: self.currentGame?.title,
                    context: [
                        ("fps",    String(format: "%.1f", self.fps)),
                        ("status", "\(self.status)"),
                    ]
                )
            }
        }
    }

    // MARK: - BIOS

    func checkBIOS() {
        biosLoaded = biosURL != nil
    }

    var biosURL: URL? {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let url = dir?.appendingPathComponent("bios.bin")
        return (url.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil })
    }

    func importBIOS(from url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            let raw = try Data(contentsOf: url)
            let data: Data
            if url.pathExtension.lowercased() == "zip" || isZipData(raw) {
                guard let extracted = extractBinFromZip(raw) else {
                    throw EmulatorError.biosInvalid("No .bin file found inside the ZIP archive.")
                }
                data = extracted
            } else {
                data = raw
            }
            let dir  = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent("bios.bin")
            try data.write(to: dest)
            try emulator.loadBIOS(data: data)
            biosLoaded = true
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    // MARK: - ZIP Extraction

    private func isZipData(_ data: Data) -> Bool {
        data.count >= 4 &&
        data[0] == 0x50 && data[1] == 0x4B &&
        data[2] == 0x03 && data[3] == 0x04
    }

    private func extractBinFromZip(_ zipData: Data) -> Data? {
        let bytes = [UInt8](zipData)
        var offset = 0
        while offset + 30 <= bytes.count {
            guard bytes[offset]   == 0x50, bytes[offset+1] == 0x4B,
                  bytes[offset+2] == 0x03, bytes[offset+3] == 0x04 else { break }

            let method   = Int(bytes[offset+8])  | (Int(bytes[offset+9])  << 8)
            let cmpSize  = Int(bytes[offset+18]) | (Int(bytes[offset+19]) << 8)
                         | (Int(bytes[offset+20]) << 16) | (Int(bytes[offset+21]) << 24)
            let ucmpSize = Int(bytes[offset+22]) | (Int(bytes[offset+23]) << 8)
                         | (Int(bytes[offset+24]) << 16) | (Int(bytes[offset+25]) << 24)
            let nameLen  = Int(bytes[offset+26]) | (Int(bytes[offset+27]) << 8)
            let extraLen = Int(bytes[offset+28]) | (Int(bytes[offset+29]) << 8)

            let nameStart = offset + 30
            let dataStart = nameStart + nameLen + extraLen
            let dataEnd   = dataStart + cmpSize

            guard dataEnd <= bytes.count else { break }

            let name = String(bytes: bytes[nameStart ..< nameStart + nameLen], encoding: .utf8) ?? ""

            if name.lowercased().hasSuffix(".bin") {
                let compressed = Data(bytes[dataStart ..< dataEnd])
                switch method {
                case 0:
                    return compressed
                case 8:
                    let capacity = max(ucmpSize, 1)
                    var out = Data(count: capacity)
                    let written: Int = out.withUnsafeMutableBytes { dst in
                        compressed.withUnsafeBytes { src in
                            compression_decode_buffer(
                                dst.bindMemory(to: UInt8.self).baseAddress!,
                                capacity,
                                src.bindMemory(to: UInt8.self).baseAddress!,
                                compressed.count,
                                nil,
                                COMPRESSION_ZLIB
                            )
                        }
                    }
                    return written > 0 ? Data(out.prefix(written)) : nil
                default:
                    break
                }
            }
            offset = dataEnd
        }
        return nil
    }

    // MARK: - Game Launch

    func launch(game: GameEntry) {
        status = .loading
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if let burl = biosURL {
                    let bdata = try Data(contentsOf: burl)
                    try emulator.loadBIOS(data: bdata)
                }
                try emulator.loadDisc(url: game.url)
                currentGame = game
                lastPlayedGame = game
                UserDefaults.standard.set(game.id, forKey: "lastPlayedGameID")
                status = .running
                startFPSCounter()
                emulator.start()
            } catch {
                status = .idle
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    func pause() {
        emulator.pause()
        status = .paused
    }

    func resume() {
        emulator.start()
        status = .running
    }

    func stop() {
        emulator.stop()
        status = .idle
        currentGame = nil
        frameImage = nil
        fpsTimer?.invalidate()
        fpsTimer = nil
    }

    // MARK: - Save States

    func saveState(slot: Int) {
        guard let game = currentGame else { return }
        try? emulator.saveState(to: stateURL(game: game, slot: slot))
    }

    func loadState(slot: Int) {
        guard let game = currentGame else { return }
        let url = stateURL(game: game, slot: slot)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? emulator.loadState(from: url)
    }

    func stateExists(slot: Int) -> Bool {
        guard let game = currentGame else { return false }
        return FileManager.default.fileExists(atPath: stateURL(game: game, slot: slot).path)
    }

    func stateDate(slot: Int) -> Date? {
        guard let game = currentGame else { return nil }
        let url = stateURL(game: game, slot: slot)
        return (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    func stateURL(game: GameEntry, slot: Int) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let statesDir = dir.appendingPathComponent("states/\(game.id)")
        try? FileManager.default.createDirectory(at: statesDir, withIntermediateDirectories: true)
        return statesDir.appendingPathComponent("slot\(slot).cstate")
    }

    // MARK: - FPS + JIT Stats Counter

    private func startFPSCounter() {
        fpsTimer?.invalidate()
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.fps = Double(self.frameCount)
                self.frameCount = 0
                self.jitBlockCount = self.emulator.jitCache.blockCount
                self.jitHitRate   = self.emulator.jitCache.hitRate
            }
        }
    }
}

// MARK: - UIImage helper

extension UIImage {
    static func fromRGBA(data: Data, width: Int, height: Int) -> UIImage? {
        guard data.count >= width * height * 4 else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let provider = CGDataProvider(data: data as CFData),
              let cgImage  = CGImage(
                width: width, height: height,
                bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                provider: provider, decode: nil,
                shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
