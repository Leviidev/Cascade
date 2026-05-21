import Foundation

// MARK: - Crash Reporter
// Records emulator errors/crashes to timestamped log files in Application Support.
// Logs can be viewed and shared from the Settings screen.

@MainActor
public final class CrashReporter: ObservableObject {

    public static let shared = CrashReporter()

    @Published public private(set) var logFiles: [URL] = []
    @Published public private(set) var lastCrash: CrashLog?

    // MARK: - CrashLog

    public struct CrashLog: Identifiable {
        public let id       = UUID()
        public let timestamp: Date
        public let game:     String
        public let error:    String
        public let context:  [(key: String, value: String)]
        public let fileURL:  URL

        public var formattedText: String {
            let df = ISO8601DateFormatter()
            var lines: [String] = [
                "Cascade Crash Report",
                "====================",
                "Date  : \(df.string(from: timestamp))",
                "Game  : \(game)",
                "Error : \(error)",
            ]
            if !context.isEmpty {
                lines.append("Context:")
                for pair in context { lines.append("  \(pair.key): \(pair.value)") }
            }
            lines.append("")
            lines.append("Please report this at https://github.com/leviidev/cascade")
            return lines.joined(separator: "\n")
        }
    }

    // MARK: - Private State

    private let logsDir: URL
    private static let maxLogs = 20

    private init() {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        logsDir = support.appendingPathComponent("crash_logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        refreshLogFiles()
    }

    // MARK: - Public API

    /// Record an error that occurred during emulation.
    public func record(
        error: Error,
        game: String?,
        context: [(key: String, value: String)] = []
    ) {
        let log = CrashLog(
            timestamp: Date(),
            game:      game ?? "Unknown",
            error:     error.localizedDescription,
            context:   context,
            fileURL:   logsDir.appendingPathComponent(
                           "crash_\(Int(Date().timeIntervalSince1970)).txt"
                       )
        )
        try? log.formattedText.write(to: log.fileURL, atomically: true, encoding: .utf8)
        lastCrash = log
        pruneOldLogs()
        refreshLogFiles()
    }

    /// Delete all stored crash logs.
    public func clearAll() {
        logFiles.forEach { try? FileManager.default.removeItem(at: $0) }
        logFiles = []
        lastCrash = nil
    }

    /// Re-scan the logs directory.
    public func refreshLogFiles() {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: logsDir,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        )) ?? []
        logFiles = items
            .filter { $0.pathExtension == "txt" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    // MARK: - Private Helpers

    private func pruneOldLogs() {
        let sorted = logFiles.sorted { $0.lastPathComponent > $1.lastPathComponent }
        if sorted.count >= Self.maxLogs {
            sorted.dropFirst(Self.maxLogs - 1).forEach {
                try? FileManager.default.removeItem(at: $0)
            }
        }
    }
}
