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
        self.id  = url.deletingPathExtension().lastPathComponent
        self.title = url.deletingPathExtension().lastPathComponent
        self.region = cdvd?.discRegion.rawValue ?? "Unknown"
        self.discID = cdvd?.discID ?? ""
        self.addedDate = Date()
        self.totalPlayTime = 0
        self.isFavorite = false
    }
}

// MARK: - Game Collection

public struct GameCollection: Identifiable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var gameIDs: [String]
    public var colorIndex: Int

    public init(id: UUID = UUID(), name: String, gameIDs: [String] = [], colorIndex: Int = 0) {
        self.id = id; self.name = name; self.gameIDs = gameIDs; self.colorIndex = colorIndex
    }

    static let palette: [Color] = [
        .cascadeBlue, .purple, .pink, .orange, .green, .red, .teal, .yellow
    ]

    var color: Color { Self.palette[colorIndex % Self.palette.count] }
}

// MARK: - Game Library Manager

@MainActor
public final class GameLibraryManager: ObservableObject {

    @Published var games: [GameEntry] = []
    @Published var collections: [GameCollection] = []
    @Published var selectedCollectionID: UUID? = nil
    @Published var sortOrder: SortOrder = .title
    @Published var searchText: String = ""
    @Published var formatFilter: String? = nil
    @Published var regionFilter: String? = nil
    @Published var isImporting: Bool = false
    @Published var importError: String?

    enum SortOrder: String, CaseIterable {
        case title      = "Title"
        case lastPlayed = "Last Played"
        case addedDate  = "Recently Added"
        case favorite   = "Favorites"
    }

    var activeFilterCount: Int {
        (formatFilter != nil ? 1 : 0) + (regionFilter != nil ? 1 : 0)
    }

    func clearFilters() {
        formatFilter = nil
        regionFilter = nil
    }

    var filteredGames: [GameEntry] {
        var base = games

        if let id = selectedCollectionID,
           let col = collections.first(where: { $0.id == id }) {
            let idSet = Set(col.gameIDs)
            base = base.filter { idSet.contains($0.id) }
        }

        if !searchText.isEmpty {
            base = base.filter {
                $0.title.localizedCaseInsensitiveContains(searchText) ||
                $0.discID.localizedCaseInsensitiveContains(searchText)
            }
        }

        if let fmt = formatFilter {
            base = base.filter { $0.url.pathExtension.lowercased() == fmt }
        }

        if let region = regionFilter {
            base = base.filter { $0.region == region }
        }

        switch sortOrder {
        case .title:      return base.sorted { $0.title < $1.title }
        case .lastPlayed: return base.sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
        case .addedDate:  return base.sorted { $0.addedDate > $1.addedDate }
        case .favorite:   return base.sorted { $0.isFavorite && !$1.isFavorite }
        }
    }

    var availableRegions: [String] {
        Array(Set(games.map { $0.region })).filter { !$0.isEmpty && $0 != "Unknown" }.sorted()
    }

    var availableFormats: [String] {
        Array(Set(games.map { $0.url.pathExtension.lowercased() })).filter { !$0.isEmpty }.sorted()
    }

    // MARK: - Persistence URLs

    private var gamesURL: URL { supportDir.appendingPathComponent("library.json") }
    private var collectionsURL: URL { supportDir.appendingPathComponent("collections.json") }
    private var gamesDir: URL { supportDir.appendingPathComponent("games") }

    private var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    }

    init() { load() }

    func load() {
        if let data = try? Data(contentsOf: gamesURL),
           let decoded = try? JSONDecoder().decode([GameEntry].self, from: data) {
            games = decoded.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        }
        if let data = try? Data(contentsOf: collectionsURL),
           let decoded = try? JSONDecoder().decode([GameCollection].self, from: data) {
            collections = decoded
        }
    }

    func save() {
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try? JSONEncoder().encode(games).write(to: gamesURL)
    }

    private func saveCollections() {
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try? JSONEncoder().encode(collections).write(to: collectionsURL)
    }

    // MARK: - Import Games (async — file copy runs on a background thread)

    func importGame(from url: URL) {
        guard !isImporting else { return }
        _ = url.startAccessingSecurityScopedResource()
        isImporting = true
        importError = nil

        let destDir  = gamesDir
        let ext      = url.pathExtension.lowercased()

        Task.detached(priority: .userInitiated) { [weak self] in
            defer { url.stopAccessingSecurityScopedResource() }
            do {
                try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
                let entry: GameEntry
                if ext == "cue" {
                    entry = try GameLibraryManager.copyCUE(from: url, to: destDir)
                } else {
                    entry = try GameLibraryManager.copyISO(from: url, to: destDir)
                }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if !self.games.contains(where: { $0.id == entry.id }) {
                        self.games.append(entry)
                        self.save()
                    }
                    self.isImporting = false
                }
            } catch {
                let msg = error.localizedDescription
                await MainActor.run { [weak self] in
                    self?.importError = msg
                    self?.isImporting = false
                }
            }
        }
    }

    // MARK: - Static Copy Helpers (run off main actor)

    private static func copyISO(from url: URL, to gamesDir: URL) throws -> GameEntry {
        let dest = gamesDir.appendingPathComponent(url.lastPathComponent)
        if !FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.copyItem(at: url, to: dest)
        }
        let cdvd = CDVD()
        try? cdvd.loadISO(url: dest)
        var entry = GameEntry(url: dest, cdvd: cdvd)
        if !cdvd.discID.isEmpty {
            entry.id    = cdvd.discID
            entry.title = titleLookup[cdvd.discID.uppercased()] ?? entry.title
        }
        return entry
    }

    private static func copyCUE(from cueURL: URL, to gamesDir: URL) throws -> GameEntry {
        let cueText = (try? String(contentsOf: cueURL, encoding: .utf8)) ?? ""
        var binName: String?
        for line in cueText.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.uppercased().hasPrefix("FILE") {
                let parts = t.components(separatedBy: "\"")
                if parts.count >= 2 { binName = parts[1]; break }
            }
        }

        let cueDest = gamesDir.appendingPathComponent(cueURL.lastPathComponent)
        if !FileManager.default.fileExists(atPath: cueDest.path) {
            try FileManager.default.copyItem(at: cueURL, to: cueDest)
        }

        if let binName {
            let binSrc  = cueURL.deletingLastPathComponent().appendingPathComponent(binName)
            let binDest = gamesDir.appendingPathComponent(binName)
            if FileManager.default.fileExists(atPath: binSrc.path),
               !FileManager.default.fileExists(atPath: binDest.path) {
                try FileManager.default.copyItem(at: binSrc, to: binDest)
            }
        }

        let cdvd = CDVD()
        try? cdvd.loadCUE(url: cueDest)
        var entry = GameEntry(url: cueDest, cdvd: cdvd)
        if !cdvd.discID.isEmpty {
            entry.id    = cdvd.discID
            entry.title = titleLookup[cdvd.discID.uppercased()] ?? entry.title
        }
        return entry
    }

    // MARK: - Game Mutations

    func removeGame(_ game: GameEntry) {
        games.removeAll { $0.id == game.id }
        for i in collections.indices {
            collections[i].gameIDs.removeAll { $0 == game.id }
        }
        save(); saveCollections()
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

    // MARK: - Collections CRUD

    func addCollection(name: String, colorIndex: Int = 0) {
        collections.append(GameCollection(name: name, colorIndex: colorIndex))
        saveCollections()
    }

    func renameCollection(_ collection: GameCollection, to name: String) {
        if let idx = collections.firstIndex(where: { $0.id == collection.id }) {
            collections[idx].name = name
            saveCollections()
        }
    }

    func deleteCollection(_ collection: GameCollection) {
        collections.removeAll { $0.id == collection.id }
        if selectedCollectionID == collection.id { selectedCollectionID = nil }
        saveCollections()
    }

    func toggleGame(_ game: GameEntry, in collection: GameCollection) {
        guard let idx = collections.firstIndex(where: { $0.id == collection.id }) else { return }
        if collections[idx].gameIDs.contains(game.id) {
            collections[idx].gameIDs.removeAll { $0 == game.id }
        } else {
            collections[idx].gameIDs.append(game.id)
        }
        saveCollections()
    }

    func isGame(_ game: GameEntry, in collection: GameCollection) -> Bool {
        collection.gameIDs.contains(game.id)
    }

    // MARK: - Title Lookup

    private static let titleLookup: [String: String] = [
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
}
