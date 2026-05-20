import SwiftUI
import UniformTypeIdentifiers

// MARK: - Game Entry

public struct GameEntry: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    var title: String
    var url: URL
    var region: String
    var discID: String
    var addedDate: Date
    var lastPlayed: Date?
    var totalPlayTime: TimeInterval
    var coverArtURL: String?
    var isFavorite: Bool

    init(url: URL, cdvd: CDVD? = nil) {
        self.url = url
        self.id = url.deletingPathExtension().lastPathComponent
        self.title = url.deletingPathExtension().lastPathComponent
        self.region = cdvd?.discRegion.rawValue ?? "Unknown"
        self.discID = cdvd?.discID ?? ""
        self.addedDate = Date()
        self.totalPlayTime = 0
        self.isFavorite = false
    }
}

// MARK: - Game Library Manager

@MainActor
public final class GameLibraryManager: ObservableObject {

    @Published var games: [GameEntry] = []
    @Published var sortOrder: SortOrder = .title
    @Published var searchText: String = ""
    @Published var isImporting: Bool = false
    @Published var importError: String?

    enum SortOrder: String, CaseIterable {
        case title = "Title"
        case lastPlayed = "Last Played"
        case addedDate = "Recently Added"
        case favorite = "Favorites"
    }

    var filteredGames: [GameEntry] {
        let base = searchText.isEmpty ? games : games.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.discID.localizedCaseInsensitiveContains(searchText)
        }
        switch sortOrder {
        case .title:      return base.sorted { $0.title < $1.title }
        case .lastPlayed: return base.sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
        case .addedDate:  return base.sorted { $0.addedDate > $1.addedDate }
        case .favorite:   return base.sorted { $0.isFavorite && !$1.isFavorite }
        }
    }

    // MARK: - Persistence

    private var saveURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent("library.json")
    }

    init() { load() }

    func load() {
        guard let data = try? Data(contentsOf: saveURL),
              let decoded = try? JSONDecoder().decode([GameEntry].self, from: data)
        else { return }
        // Filter out entries whose files no longer exist
        games = decoded.filter { FileManager.default.fileExists(atPath: $0.url.path) }
    }

    func save() {
        let data = try? JSONEncoder().encode(games)
        try? data?.write(to: saveURL)
    }

    // MARK: - Import

    func importGame(from url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        defer { url.stopAccessingSecurityScopedResource() }

        let gamesDir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("games")
        try? FileManager.default.createDirectory(at: gamesDir, withIntermediateDirectories: true)

        let dest = gamesDir.appendingPathComponent(url.lastPathComponent)

        // Don't duplicate
        if games.contains(where: { $0.url == dest }) { return }

        do {
            if !FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.copyItem(at: url, to: dest)
            }
            let cdvd = CDVD()
            try? cdvd.loadISO(url: dest)
            var entry = GameEntry(url: dest, cdvd: cdvd)

            // Try to improve the title from CDVD metadata
            if !cdvd.discID.isEmpty {
                entry.id = cdvd.discID
                entry.title = titleFromID(cdvd.discID) ?? entry.title
            }
            games.append(entry)
            save()
        } catch {
            importError = error.localizedDescription
        }
    }

    func removeGame(_ game: GameEntry) {
        games.removeAll { $0.id == game.id }
        save()
    }

    func toggleFavorite(_ game: GameEntry) {
        if let idx = games.firstIndex(where: { $0.id == game.id }) {
            games[idx].isFavorite.toggle()
            save()
        }
    }

    func updateLastPlayed(_ game: GameEntry) {
        if let idx = games.firstIndex(where: { $0.id == game.id }) {
            games[idx].lastPlayed = Date()
            save()
        }
    }

    // MARK: - Title lookup (offline, basic)

    private func titleFromID(_ id: String) -> String? {
        // Simple built-in lookup for popular titles — expand as needed
        let lookup: [String: String] = [
            "SLUS-20062": "Grand Theft Auto III",
            "SLUS-20415": "Grand Theft Auto: San Andreas",
            "SLUS-20184": "Grand Theft Auto: Vice City",
            "SLUS-20136": "God of War",
            "SLUS-21236": "God of War II",
            "SLUS-20762": "Shadow of the Colossus",
            "SCES-50360": "Ico",
            "SLUS-20552": "Kingdom Hearts",
            "SLUS-21005": "Kingdom Hearts II",
            "SLPS-25088": "Final Fantasy X",
            "SLUS-20302": "Final Fantasy X",
            "SLUS-21275": "Final Fantasy XII",
            "SLUS-20946": "Resident Evil 4",
            "SLUS-21315": "Metal Gear Solid 3: Snake Eater",
            "SLUS-20488": "Metal Gear Solid 2: Sons of Liberty",
            "SLUS-20063": "Devil May Cry",
        ]
        return lookup[id.uppercased()]
    }
}
