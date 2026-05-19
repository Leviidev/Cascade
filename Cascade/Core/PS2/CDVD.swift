import Foundation

// MARK: - CDVD Drive Controller
// Handles ISO 9660 disc reading, PS2 executable loading,
// and NTSC/PAL region detection.

public final class CDVD {

    // MARK: - State

    enum DriveState { case idle, seeking, reading, paused }
    var driveState: DriveState = .idle

    var discURL: URL?
    var isoData: Data?

    // ISO 9660 cached fields
    var pvd: PrimaryVolumeDescriptor?
    var discID: String = ""
    var discRegion: DiscRegion = .unknown

    // MARK: - Registers

    var status:  UInt8 = 0x40   // TRAY_CLOSE | DISC_INSIDE
    var error:   UInt8 = 0x00
    var iStat:   UInt8 = 0x00
    var iMask:   UInt8 = 0x00
    var command: UInt8 = 0x00
    var result:  [UInt8] = Array(repeating: 0, count: 16)
    var resultPtr: Int = 0
    var resultLen: Int = 0

    var seekTarget: UInt32 = 0

    // MARK: - Disc Loading

    func loadISO(url: URL) throws {
        isoData = try Data(contentsOf: url, options: .mappedIfSafe)
        discURL = url
        parseISO9660()
        driveState = .idle
    }

    private func parseISO9660() {
        guard let data = isoData, data.count > 0x8800 else { return }
        // Primary Volume Descriptor sits at sector 16 (2048-byte sectors)
        let pvdOffset = 16 * 2048
        guard data.count > pvdOffset + 882 else { return }
        let slice = data[pvdOffset..<pvdOffset + 2048]
        pvd = PrimaryVolumeDescriptor(data: slice)
        discID = readDiscID()
        discRegion = detectRegion()
    }

    private func readDiscID() -> String {
        // SYSTEM.CNF contains BOOT2 = cdrom0:\SLUS_XXX.XX
        guard let data = isoData else { return "" }
        if let cnfData = readFile(path: "SYSTEM.CNF", data: data) {
            let text = String(data: cnfData, encoding: .ascii) ?? ""
            for line in text.components(separatedBy: "\n") {
                if line.hasPrefix("BOOT2") {
                    let parts = line.components(separatedBy: "\\")
                    if let last = parts.last {
                        return last.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            }
        }
        return ""
    }

    private func detectRegion() -> DiscRegion {
        let id = discID.uppercased()
        if id.hasPrefix("SLUS") || id.hasPrefix("SCUS") { return .ntscU }
        if id.hasPrefix("SLES") || id.hasPrefix("SCES") { return .pal }
        if id.hasPrefix("SLPS") || id.hasPrefix("SCPS") || id.hasPrefix("SLPM") { return .ntscJ }
        return .unknown
    }

    // MARK: - ISO 9660 File Reading

    func readFile(path: String, data: Data) -> Data? {
        guard let pvd = pvd else { return nil }
        let components = path.split(separator: "/").map(String.init)
        var dirLBA = pvd.rootDirectoryLBA
        var dirSize = pvd.rootDirectorySize

        for (idx, component) in components.enumerated() {
            let isLast = idx == components.count - 1
            let dirData = readSectors(lba: dirLBA, size: dirSize, from: data)
            var offset = 0
            while offset < dirData.count {
                let recLen = Int(dirData[offset])
                guard recLen > 0 else { break }
                let nameLen = Int(dirData[offset + 32])
                guard offset + 33 + nameLen <= dirData.count else { break }
                var entryName = String(bytes: dirData[(offset + 33)..<(offset + 33 + nameLen)], encoding: .ascii) ?? ""
                // Strip version suffix (;1)
                if let semi = entryName.firstIndex(of: ";") { entryName = String(entryName[..<semi]) }
                if entryName.uppercased() == component.uppercased() {
                    let lba  = dirData.withUnsafeBytes { $0.load(fromByteOffset: offset + 2, as: UInt32.self).littleEndian }
                    let size = dirData.withUnsafeBytes { $0.load(fromByteOffset: offset + 10, as: UInt32.self).littleEndian }
                    if isLast { return readSectors(lba: lba, size: size, from: data) }
                    dirLBA = lba; dirSize = size
                    break
                }
                offset += recLen
            }
        }
        return nil
    }

    private func readSectors(lba: UInt32, size: UInt32, from data: Data) -> Data {
        let offset = Int(lba) * 2048
        let length = Int(size)
        guard offset + length <= data.count else { return Data() }
        return data[offset..<offset + length]
    }

    // MARK: - IOP I/O

    func readIO(offset: UInt32) -> UInt32 {
        switch offset {
        case 0: return UInt32(status)
        case 1: return UInt32(error)
        case 2: return resultLen > 0 ? UInt32(result[resultPtr]) : 0
        case 3: return UInt32(iStat)
        case 4: return UInt32(iMask)
        default: return 0
        }
    }

    func writeIO(offset: UInt32, value: UInt32) {
        switch offset {
        case 0: command = UInt8(value & 0xFF); processCommand()
        case 3: iStat &= ~UInt8(value & 0xFF)
        case 4: iMask = UInt8(value & 0xFF)
        default: break
        }
    }

    private func processCommand() {
        switch command {
        case 0x15: // S_READRTC
            let now = Date()
            let cal = Calendar.current
            result[0] = 0
            result[1] = toBCD(cal.component(.second, from: now))
            result[2] = toBCD(cal.component(.minute, from: now))
            result[3] = toBCD(cal.component(.hour,   from: now))
            result[4] = toBCD(cal.component(.day,    from: now))
            result[5] = toBCD(cal.component(.month,  from: now))
            result[6] = toBCD(cal.component(.year,   from: now) % 100)
            resultLen = 8; resultPtr = 0
        case 0x40: // S_GETTYPE — return DVD single-layer
            result[0] = 0; result[1] = 0x14
            resultLen = 2; resultPtr = 0
        default:
            result[0] = 0; resultLen = 1; resultPtr = 0
        }
        iStat |= 0x01   // command complete interrupt
    }

    private func toBCD(_ value: Int) -> UInt8 { UInt8(((value / 10) << 4) | (value % 10)) }
}

// MARK: - ISO 9660 PVD

struct PrimaryVolumeDescriptor {
    var rootDirectoryLBA: UInt32
    var rootDirectorySize: UInt32
    var volumeSpaceSize: UInt32
    var logicalBlockSize: UInt16

    init(data: Data.SubSequence) {
        rootDirectoryLBA  = data.withUnsafeBytes { $0.load(fromByteOffset: 158, as: UInt32.self).littleEndian }
        rootDirectorySize = data.withUnsafeBytes { $0.load(fromByteOffset: 166, as: UInt32.self).littleEndian }
        volumeSpaceSize   = data.withUnsafeBytes { $0.load(fromByteOffset: 80, as: UInt32.self).littleEndian }
        logicalBlockSize  = data.withUnsafeBytes { $0.load(fromByteOffset: 128, as: UInt16.self).littleEndian }
    }
}

// MARK: - Region

enum DiscRegion: String { case ntscU = "NTSC-U", ntscJ = "NTSC-J", pal = "PAL", unknown = "Unknown" }
