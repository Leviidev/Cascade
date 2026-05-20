import Foundation

// MARK: - Cheat Code (GameShark / CodeBreaker style)
// Code format: "XXXXXXXX YYYYYYYY"
//   Bits 31-28 of address = type  (0 = 8-bit, 1 = 16-bit, 2+ = 32-bit)
//   Bits 24-0  of address = RAM offset

public struct CheatCode: Identifiable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var code: String
    public var enabled: Bool

    public init(id: UUID = UUID(), name: String, code: String, enabled: Bool = false) {
        self.id = id; self.name = name; self.code = code; self.enabled = enabled
    }
}

// MARK: - Cheat Manager

@MainActor
public final class CheatManager: ObservableObject {

    @Published public var cheatsByDiscID: [String: [CheatCode]] = [:]

    private static var savePath: URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent("cheats.json")
    }

    public init() { load() }

    // MARK: - Accessors

    public func cheats(for discID: String) -> [CheatCode] {
        cheatsByDiscID[discID.uppercased()] ?? []
    }

    // MARK: - CRUD

    public func add(_ cheat: CheatCode, for discID: String) {
        cheatsByDiscID[discID.uppercased(), default: []].append(cheat)
        save()
    }

    public func update(_ cheat: CheatCode, for discID: String) {
        let key = discID.uppercased()
        guard let idx = cheatsByDiscID[key]?.firstIndex(where: { $0.id == cheat.id }) else { return }
        cheatsByDiscID[key]![idx] = cheat
        save()
    }

    public func remove(_ cheat: CheatCode, for discID: String) {
        cheatsByDiscID[discID.uppercased()]?.removeAll { $0.id == cheat.id }
        save()
    }

    public func toggle(_ cheat: CheatCode, for discID: String) {
        var c = cheat; c.enabled.toggle(); update(c, for: discID)
    }

    // MARK: - Apply to RAM

    public func applyEnabled(discID: String, ram: inout [UInt8]) {
        for cheat in cheats(for: discID) where cheat.enabled {
            applyCode(cheat.code, to: &ram)
        }
    }

    private func applyCode(_ code: String, to ram: inout [UInt8]) {
        let parts = code.trimmingCharacters(in: .whitespaces).split(separator: " ")
        guard parts.count == 2,
              let rawAddr = UInt32(parts[0], radix: 16),
              let value   = UInt32(parts[1], radix: 16) else { return }
        let addr = Int(rawAddr & 0x01FF_FFFF)
        let type = (rawAddr >> 28) & 0xF
        switch type {
        case 0:
            guard addr < ram.count else { return }
            ram[addr] = UInt8(value & 0xFF)
        case 1:
            guard addr + 1 < ram.count else { return }
            ram[addr]     = UInt8(value & 0xFF)
            ram[addr + 1] = UInt8((value >> 8) & 0xFF)
        default:
            guard addr + 3 < ram.count else { return }
            ram[addr]     = UInt8(value & 0xFF)
            ram[addr + 1] = UInt8((value >> 8) & 0xFF)
            ram[addr + 2] = UInt8((value >> 16) & 0xFF)
            ram[addr + 3] = UInt8((value >> 24) & 0xFF)
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data    = try? Data(contentsOf: Self.savePath),
              let decoded = try? JSONDecoder().decode([String: [CheatCode]].self, from: data)
        else { return }
        cheatsByDiscID = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(cheatsByDiscID) else { return }
        let dir = Self.savePath.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: Self.savePath)
    }
}
