import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject var library: GameLibraryManager
    @EnvironmentObject var emulatorState: EmulatorState

    @State private var showImporter = false
    @State private var showBIOSImporter = false
    @State private var selectedGame: GameEntry?

    private let columns = [
        GridItem(.adaptive(minimum: 155, maximum: 195), spacing: 14)
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
                allowedContentTypes: [UTType(filenameExtension: "iso") ?? .data, UTType(filenameExtension: "bin") ?? .data, .data],
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
            colors: [Color(.systemBackground), Color.cascadeBlue.opacity(0.05)],
            startPoint: .top, endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    private var gameGrid: some View {
        ScrollView {
            // Status bar
            if emulatorState.executionMode == .jit {
                jitBadge
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }

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

    private var jitBadge: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.fill")
                .font(.caption2.bold())
                .foregroundStyle(Color.cascadeBlue)
            Text("JIT Active")
                .font(.caption.bold())
                .foregroundStyle(Color.cascadeBlue)
            Spacer()
            Text("\(emulatorState.jitBlockCount) blocks cached")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.cascadeBlue.opacity(0.08), in: Capsule())
        .overlay(Capsule().stroke(Color.cascadeBlue.opacity(0.2), lineWidth: 1))
    }

    private var emptyState: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(Color.cascadeBlue.opacity(0.1))
                    .frame(width: 120, height: 120)
                Image(systemName: "opticaldisc")
                    .font(.system(size: 56))
                    .foregroundStyle(Color.cascadeBlue.gradient)
                    .symbolEffect(.pulse)
            }

            VStack(spacing: 8) {
                Text("No Games Yet")
                    .font(.title2.bold())
                Text("Import PS2 game images in ISO or BIN format to get started.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }

            VStack(spacing: 12) {
                Button(action: { showImporter = true }) {
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
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                            )
                    }
                }
            }
        }
        .padding(40)
    }

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
        Button(action: {
            selectedGame = game
        }) {
            Label("Game Details", systemImage: "info.circle")
        }
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
    @State private var pressed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            coverArt
            gameInfo
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 10, y: 5)
        .scaleEffect(pressed ? 0.96 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: pressed)
        .onLongPressGesture(minimumDuration: 0.01, maximumDistance: .infinity,
                            pressing: { pressing in pressed = pressing },
                            perform: {})
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
                regionBadge
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

    private var regionBadge: some View {
        Text(game.region)
            .font(.caption2.bold())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color(.tertiarySystemFill), in: Capsule())
    }

    private var coverGradient: AnyShapeStyle {
        let seed = abs(game.id.hashValue)
        let hue = Double(seed % 360) / 360.0
        return AnyShapeStyle(
            LinearGradient(
                colors: [
                    Color(hue: hue, saturation: 0.5, brightness: 0.5),
                    Color(hue: (hue + 0.2).truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 0.32)
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
