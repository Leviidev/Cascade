import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject var library: GameLibraryManager
    @EnvironmentObject var emulatorState: EmulatorState

    @State private var showImporter = false
    @State private var showBIOSImporter = false
    @State private var selectedGame: GameEntry?
    @State private var showGameDetail = false

    private let columns = [
        GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 16)
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                backgroundGradient

                if library.filteredGames.isEmpty {
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
                    if !emulatorState.biosLoaded {
                        biosWarningButton
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    sortMenu
                    addButton
                }
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.iso8211, UTType(filenameExtension: "bin") ?? .data, .data],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    library.importGame(from: url)
                }
            }
            .fileImporter(
                isPresented: $showBIOSImporter,
                allowedContentTypes: [.data],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    emulatorState.importBIOS(from: url)
                }
            }
            .sheet(item: $selectedGame) { game in
                GameDetailView(game: game)
            }
        }
    }

    // MARK: - Subviews

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [Color(.systemBackground), Color.cascadeBlue.opacity(0.04)],
            startPoint: .top, endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    private var gameGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(library.filteredGames) { game in
                    GameCardView(game: game)
                        .onTapGesture { selectedGame = game }
                        .contextMenu { gameContextMenu(game: game) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "opticaldisc")
                .font(.system(size: 64))
                .foregroundStyle(Color.cascadeBlue.gradient)
                .symbolEffect(.pulse)

            VStack(spacing: 8) {
                Text("No Games Yet")
                    .font(.title2.bold())

                Text("Tap + to import PS2 game images\n(ISO or BIN format)")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button(action: { showImporter = true }) {
                Label("Import Game", systemImage: "plus.circle.fill")
                    .font(.headline)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.cascadeBlue.gradient)
                    .foregroundColor(.white)
                    .clipShape(Capsule())
            }
        }
        .padding(40)
    }

    private var biosWarningButton: some View {
        Button(action: { showBIOSImporter = true }) {
            Label("Import BIOS", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.bold())
                .foregroundColor(.orange)
        }
    }

    private var addButton: some View {
        Button(action: { showImporter = true }) {
            Image(systemName: "plus")
                .font(.body.bold())
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

    @ViewBuilder
    private func gameContextMenu(game: GameEntry) -> some View {
        Button(action: { library.toggleFavorite(game) }) {
            Label(game.isFavorite ? "Remove Favorite" : "Add to Favorites",
                  systemImage: game.isFavorite ? "heart.slash" : "heart")
        }
        Divider()
        Button(role: .destructive, action: { library.removeGame(game) }) {
            Label("Remove from Library", systemImage: "trash")
        }
    }
}

// MARK: - Game Card

struct GameCardView: View {
    let game: GameEntry
    @EnvironmentObject var emulatorState: EmulatorState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Cover art placeholder
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(coverGradient)
                    .aspectRatio(3/4, contentMode: .fit)

                VStack(spacing: 8) {
                    Image(systemName: "opticaldisc.fill")
                        .font(.system(size: 32))
                        .foregroundColor(.white.opacity(0.8))
                    Text(game.discID.isEmpty ? "" : game.discID)
                        .font(.caption2.monospaced())
                        .foregroundColor(.white.opacity(0.6))
                }

                if game.isFavorite {
                    VStack {
                        HStack {
                            Spacer()
                            Image(systemName: "heart.fill")
                                .font(.caption)
                                .foregroundColor(.red)
                                .padding(6)
                                .background(.ultraThinMaterial, in: Circle())
                                .padding(8)
                        }
                        Spacer()
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 2) {
                Text(game.title)
                    .font(.subheadline.bold())
                    .lineLimit(2)
                    .padding(.top, 8)

                HStack {
                    Text(game.region)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let lp = game.lastPlayed {
                        Text(lp, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 8)
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }

    private var coverGradient: AnyShapeStyle {
        let seed = abs(game.id.hashValue)
        let hue = Double(seed % 360) / 360.0
        return AnyShapeStyle(
            LinearGradient(
                colors: [
                    Color(hue: hue, saturation: 0.5, brightness: 0.5),
                    Color(hue: (hue + 0.2).truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 0.35)
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        )
    }
}

// MARK: - Color Extension

extension Color {
    static let cascadeBlue = Color(red: 0.2, green: 0.55, blue: 1.0)
}
