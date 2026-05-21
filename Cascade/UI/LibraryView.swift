import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject var library: GameLibraryManager
    @EnvironmentObject var emulatorState: EmulatorState

    @State private var showGameImporter  = false
    @State private var showBIOSImporter  = false
    @State private var showNoBIOSAlert   = false
    @State private var showNewCollection = false
    @State private var newCollectionName = ""
    @State private var selectedGame: GameEntry?

    private let columns = [
        GridItem(.adaptive(minimum: 155, maximum: 195), spacing: 14)
    ]

    private var lastPlayedGame: GameEntry? {
        if let g = emulatorState.lastPlayedGame { return g }
        let id = UserDefaults.standard.string(forKey: "lastPlayedGameID") ?? ""
        return library.games.first { $0.id == id }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                backgroundGradient

                if library.games.isEmpty {
                    emptyState
                } else {
                    gameGrid
                }
            }
            .navigationTitle("Cascade")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $library.searchText, prompt: "Search games…")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !emulatorState.biosLoaded { biosWarningButton }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    filterButton
                    sortMenu
                    addButton
                }
            }
            // Game file importer — separate from BIOS importer for reliability
            .fileImporter(
                isPresented: $showGameImporter,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result {
                    for url in urls { library.importGame(from: url) }
                }
            }
            .overlay(alignment: .bottom) {
                if library.isImporting {
                    importingBanner
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.35), value: library.isImporting)
            .alert("Import Failed", isPresented: Binding(
                get: { library.importError != nil },
                set: { if !$0 { library.importError = nil } }
            )) {
                Button("OK") { library.importError = nil }
            } message: {
                Text(library.importError ?? "")
            }
            // BIOS file importer
            .fileImporter(
                isPresented: $showBIOSImporter,
                allowedContentTypes: [.item],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    emulatorState.importBIOS(from: url)
                }
            }
            // No BIOS alert — shown when tapping Add Game without a BIOS loaded
            .alert("No BIOS Detected", isPresented: $showNoBIOSAlert) {
                Button("Import BIOS") {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    showBIOSImporter = true
                }
                Button("Add Game Anyway", role: .none) {
                    showGameImporter = true
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("A PS2 BIOS file is required to play games. You can still add games to your library now, but you won't be able to launch them until a BIOS is imported.\n\nRecommended: SCPH-70012.bin")
            }
            .sheet(item: $selectedGame) { game in
                GameDetailView(game: game)
            }
            .alert("New Collection", isPresented: $showNewCollection) {
                TextField("Collection name", text: $newCollectionName)
                Button("Create") {
                    if !newCollectionName.isEmpty {
                        library.addCollection(name: newCollectionName)
                        newCollectionName = ""
                    }
                }
                Button("Cancel", role: .cancel) { newCollectionName = "" }
            }
        }
    }

    // MARK: - Add Game Action (BIOS-gated)

    private func requestGameImport() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if emulatorState.biosLoaded {
            showGameImporter = true
        } else {
            showNoBIOSAlert = true
        }
    }

    // MARK: - Background

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [Color(.systemBackground), Color.cascadeBlue.opacity(0.05)],
            startPoint: .top, endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    // MARK: - Game Grid

    private var gameGrid: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Resume last game banner
                if let last = lastPlayedGame, emulatorState.status == .idle {
                    resumeBanner(game: last)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                }

                // JIT status badge
                statusBadge
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                // Active filter summary (shows when filters are on)
                if library.activeFilterCount > 0 {
                    activeFilterBanner
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                }

                // Collections filter chips
                if !library.collections.isEmpty {
                    collectionsBar.padding(.top, 10)
                }

                if library.filteredGames.isEmpty {
                    noResultsState
                        .padding(.top, 60)
                } else {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(library.filteredGames) { game in
                            GameCardView(game: game)
                                .onTapGesture {
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    selectedGame = game
                                }
                                .contextMenu { gameContextMenu(game: game) }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
        }
    }

    // MARK: - Resume Banner

    private func resumeBanner(game: GameEntry) -> some View {
        Button(action: {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            emulatorState.launch(game: game)
            library.updateLastPlayed(game)
        }) {
            HStack(spacing: 12) {
                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.cascadeBlue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Continue Playing")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Text(game.title)
                        .font(.subheadline.bold())
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.cascadeBlue.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Status Badge

    private var statusBadge: some View {
        HStack(spacing: 8) {
            Image(systemName: emulatorState.executionMode == .jit ? "bolt.fill" : "cpu")
                .font(.caption2.bold())
                .foregroundStyle(emulatorState.executionMode == .jit ? Color.cascadeBlue : Color.orange)
            Text(emulatorState.executionMode == .jit ? "JIT Active" : "JitLess Mode")
                .font(.caption.bold())
                .foregroundStyle(emulatorState.executionMode == .jit ? Color.cascadeBlue : Color.orange)
            Spacer()
            if emulatorState.executionMode == .jit {
                Text("\(emulatorState.jitBlockCount) blocks cached")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            (emulatorState.executionMode == .jit ? Color.cascadeBlue : Color.orange).opacity(0.08),
            in: Capsule()
        )
        .overlay(
            Capsule().stroke(
                (emulatorState.executionMode == .jit ? Color.cascadeBlue : Color.orange).opacity(0.2),
                lineWidth: 1
            )
        )
    }

    // MARK: - Active Filter Banner

    private var activeFilterBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                .foregroundStyle(Color.cascadeBlue)
                .font(.caption.bold())

            if let fmt = library.formatFilter {
                filterTag(fmt.uppercased(), color: .cascadeBlue)
            }
            if let region = library.regionFilter {
                filterTag(region, color: .purple)
            }

            Text("· \(library.filteredGames.count) game\(library.filteredGames.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button(action: {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                library.clearFilters()
            }) {
                Text("Clear")
                    .font(.caption.bold())
                    .foregroundStyle(Color.cascadeBlue)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.cascadeBlue.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.cascadeBlue.opacity(0.15), lineWidth: 1))
    }

    private func filterTag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.bold())
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
    }

    // MARK: - Collections Bar

    private var collectionsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                collectionChip(label: "All", id: nil, color: .cascadeBlue)
                ForEach(library.collections) { col in
                    collectionChip(label: col.name, id: col.id, color: col.color)
                        .contextMenu {
                            Button(role: .destructive) {
                                library.deleteCollection(col)
                            } label: {
                                Label("Delete Collection", systemImage: "trash")
                            }
                        }
                }
                Button(action: { showNewCollection = true }) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus").font(.caption2.bold())
                        Text("New").font(.caption.bold())
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color(.tertiarySystemFill), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
        }
    }

    private func collectionChip(label: String, id: UUID?, color: Color) -> some View {
        let isSelected = library.selectedCollectionID == id
        return Button(action: {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            library.selectedCollectionID = isSelected ? nil : id
        }) {
            Text(label)
                .font(.caption.bold())
                .foregroundStyle(isSelected ? .white : color)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? color : color.opacity(0.1), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(Color.cascadeBlue.opacity(0.1))
                    .frame(width: 120, height: 120)
                Image(systemName: "opticaldisc")
                    .font(.system(size: 56))
                    .foregroundStyle(Color.cascadeBlue.gradient)
                    .modifier(PulseIfAvailable())
            }
            VStack(spacing: 8) {
                Text("No Games Yet")
                    .font(.title2.bold())
                Text("Import PS2 game images in ISO, BIN/CUE, or CHD format.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
            VStack(spacing: 12) {
                Button(action: requestGameImport) {
                    Label("Import Game", systemImage: "plus.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: 220)
                        .padding(.vertical, 14)
                        .background(Color.cascadeBlue.gradient)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .shadow(color: Color.cascadeBlue.opacity(0.35), radius: 8, y: 4)
                }
                if !emulatorState.biosLoaded {
                    Button(action: { showBIOSImporter = true }) {
                        Label("Import BIOS", systemImage: "cpu")
                            .font(.subheadline)
                            .frame(maxWidth: 220)
                            .padding(.vertical, 12)
                            .background(Color.orange.opacity(0.15))
                            .foregroundColor(.orange)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.orange.opacity(0.3), lineWidth: 1))
                    }
                }
            }
        }
        .padding(40)
    }

    // MARK: - Importing Banner

    private var importingBanner: some View {
        HStack(spacing: 12) {
            ProgressView()
                .tint(Color.cascadeBlue)
            Text("Importing game…")
                .font(.subheadline.bold())
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.cascadeBlue.opacity(0.3), lineWidth: 1))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
        .padding(.horizontal, 24)
    }

    // MARK: - No Results State

    private var noResultsState: some View {
        VStack(spacing: 14) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("No games match your filters")
                .font(.headline)
                .foregroundStyle(.secondary)
            if library.activeFilterCount > 0 {
                Button(action: {
                    library.clearFilters()
                    library.searchText = ""
                }) {
                    Text("Clear Filters")
                        .font(.subheadline)
                        .foregroundStyle(Color.cascadeBlue)
                }
            }
        }
    }

    // MARK: - Toolbar Items

    private var biosWarningButton: some View {
        Button(action: { showBIOSImporter = true }) {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("BIOS")
            }
            .font(.caption.bold())
            .foregroundColor(.orange)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.orange.opacity(0.12), in: Capsule())
        }
    }

    private var addButton: some View {
        Button(action: requestGameImport) {
            Image(systemName: "plus").font(.body.bold())
        }
    }

    private var filterButton: some View {
        Menu {
            // Format section
            Section("Format") {
                Button(action: { library.formatFilter = nil }) {
                    HStack {
                        Text("All Formats")
                        if library.formatFilter == nil { Image(systemName: "checkmark") }
                    }
                }
                ForEach(["iso", "bin", "chd"], id: \.self) { fmt in
                    let available = library.availableFormats.contains(fmt)
                    Button(action: {
                        library.formatFilter = library.formatFilter == fmt ? nil : fmt
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }) {
                        HStack {
                            Text(fmt.uppercased())
                            if !available { Text("(none)").foregroundStyle(.secondary) }
                            if library.formatFilter == fmt { Image(systemName: "checkmark") }
                        }
                    }
                }
            }

            // Region section
            Section("Region") {
                Button(action: { library.regionFilter = nil }) {
                    HStack {
                        Text("All Regions")
                        if library.regionFilter == nil { Image(systemName: "checkmark") }
                    }
                }
                ForEach(["NTSC-U", "PAL", "NTSC-J"], id: \.self) { region in
                    let available = library.availableRegions.contains(region)
                    Button(action: {
                        library.regionFilter = library.regionFilter == region ? nil : region
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }) {
                        HStack {
                            Text(region)
                            if !available { Text("(none)").foregroundStyle(.secondary) }
                            if library.regionFilter == region { Image(systemName: "checkmark") }
                        }
                    }
                }
            }

            if library.activeFilterCount > 0 {
                Divider()
                Button(role: .destructive, action: {
                    library.clearFilters()
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }) {
                    Label("Clear All Filters", systemImage: "xmark.circle")
                }
            }
        } label: {
            Image(systemName: library.activeFilterCount > 0
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
                .foregroundStyle(library.activeFilterCount > 0 ? Color.cascadeBlue : Color.primary)
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: $library.sortOrder) {
                ForEach(GameLibraryManager.SortOrder.allCases, id: \.self) { order in
                    Text(order.rawValue).tag(order)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func gameContextMenu(game: GameEntry) -> some View {
        Button { selectedGame = game } label: {
            Label("Game Details", systemImage: "info.circle")
        }
        Button { library.toggleFavorite(game) } label: {
            Label(game.isFavorite ? "Remove Favorite" : "Add to Favorites",
                  systemImage: game.isFavorite ? "heart.slash" : "heart")
        }
        Divider()
        Button(role: .destructive) { library.removeGame(game) } label: {
            Label("Remove from Library", systemImage: "trash")
        }
    }
}

// MARK: - Game Card

struct GameCardView: View {
    let game: GameEntry
    @EnvironmentObject var emulatorState: EmulatorState
    @State private var pressed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            coverArt
            gameInfo
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 5)
        .scaleEffect(pressed ? 0.96 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: pressed)
        .onLongPressGesture(minimumDuration: 0.01, maximumDistance: .infinity,
                            pressing: { p in pressed = p }, perform: {})
    }

    private var coverArt: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(coverGradient)
                .aspectRatio(3/4, contentMode: .fit)
            VStack(spacing: 10) {
                Image(systemName: "opticaldisc.fill")
                    .font(.system(size: 34))
                    .foregroundColor(.white.opacity(0.85))
                if !game.discID.isEmpty {
                    Text(game.discID)
                        .font(.caption2.monospaced())
                        .foregroundColor(.white.opacity(0.6))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.25), in: Capsule())
                }
            }
            VStack {
                HStack {
                    // Format badge (top-left)
                    Text(game.url.pathExtension.uppercased())
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.85))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.3), in: Capsule())
                        .padding(8)
                    Spacer()
                    if game.isFavorite {
                        Image(systemName: "heart.fill")
                            .font(.caption)
                            .foregroundColor(.red)
                            .padding(6)
                            .background(.ultraThinMaterial, in: Circle())
                            .padding(8)
                    }
                }
                Spacer()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var gameInfo: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(game.title)
                .font(.subheadline.bold())
                .lineLimit(2)
                .padding(.top, 8)
            HStack {
                Text(game.region)
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(.tertiarySystemFill), in: Capsule())
                Spacer()
                if let lp = game.lastPlayed {
                    Text(lp, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 10)
    }

    private var coverGradient: AnyShapeStyle {
        let seed = abs(game.id.hashValue)
        let hue  = Double(seed % 360) / 360.0
        return AnyShapeStyle(LinearGradient(
            colors: [
                Color(hue: hue, saturation: 0.5, brightness: 0.5),
                Color(hue: (hue + 0.2).truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 0.32)
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing
        ))
    }
}

// MARK: - Color Extension

extension Color {
    static let cascadeBlue = Color(red: 0.2, green: 0.55, blue: 1.0)
}
