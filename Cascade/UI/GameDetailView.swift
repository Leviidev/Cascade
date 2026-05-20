import SwiftUI

struct GameDetailView: View {
    let game: GameEntry
    @EnvironmentObject var emulatorState: EmulatorState
    @EnvironmentObject var library: GameLibraryManager
    @EnvironmentObject var cheatManager: CheatManager
    @Environment(\.dismiss) private var dismiss

    @State private var showAddCheat     = false
    @State private var newCheatName     = ""
    @State private var newCheatCode     = ""
    @State private var showCheatHelp    = false

    var body: some View {
        NavigationStack {
            ZStack {
                coverColor.opacity(0.18).ignoresSafeArea()
                LinearGradient(
                    colors: [coverColor.opacity(0.3), Color(.systemBackground).opacity(0.95)],
                    startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.45)
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {
                        headerSection
                        playSection
                        infoGrid
                        executionBadge
                        collectionsSection
                        cheatsSection
                        fileInfoSection
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 16)
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle(game.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: { library.toggleFavorite(game) }) {
                        Image(systemName: game.isFavorite ? "heart.fill" : "heart")
                            .foregroundStyle(game.isFavorite ? .red : .secondary)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showAddCheat) { addCheatSheet }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 22)
                    .fill(LinearGradient(
                        colors: [coverColor.opacity(0.85), coverColor.opacity(0.5)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .frame(width: 170, height: 226)
                    .shadow(color: coverColor.opacity(0.55), radius: 24, y: 12)

                VStack(spacing: 14) {
                    Image(systemName: "opticaldisc.fill")
                        .font(.system(size: 52))
                        .foregroundColor(.white.opacity(0.92))
                    if !game.discID.isEmpty {
                        Text(game.discID)
                            .font(.caption.monospaced().bold())
                            .foregroundColor(.white.opacity(0.75))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.25), in: Capsule())
                    }
                }
            }

            VStack(spacing: 6) {
                Text(game.title)
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)

                HStack(spacing: 10) {
                    Label(game.region, systemImage: "globe")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if game.isFavorite {
                        Image(systemName: "heart.fill")
                            .font(.subheadline)
                            .foregroundColor(.red)
                    }
                }
            }
        }
    }

    // MARK: - Play

    private var playSection: some View {
        VStack(spacing: 10) {
            Button(action: {
                dismiss()
                emulatorState.launch(game: game)
                library.updateLastPlayed(game)
            }) {
                HStack(spacing: 10) {
                    if emulatorState.status == .loading {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "play.fill")
                    }
                    Text(emulatorState.status == .loading ? "Loading…" : "Play")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    LinearGradient(
                        colors: [Color.cascadeBlue, Color.cascadeBlue.opacity(0.75)],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(color: Color.cascadeBlue.opacity(0.45), radius: 12, y: 6)
            }
            .disabled(emulatorState.status == .loading || !emulatorState.biosLoaded)

            if !emulatorState.biosLoaded {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("BIOS required — import it in Settings")
                }
                .font(.caption)
                .foregroundColor(.orange)
                .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: - Info Grid

    private var infoGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            infoCard(icon: "calendar",   iconColor: .cascadeBlue, title: "Added",
                     value: game.addedDate.formatted(.dateTime.month().day().year()))
            infoCard(icon: "clock.fill", iconColor: .purple, title: "Last Played",
                     value: game.lastPlayed.map { $0.formatted(.relative(presentation: .named)) } ?? "Never")
            infoCard(icon: "timer",      iconColor: .green,  title: "Play Time",
                     value: formatDuration(game.totalPlayTime))
            infoCard(icon: "barcode",    iconColor: .orange, title: "Disc ID",
                     value: game.discID.isEmpty ? "Unknown" : game.discID)
        }
    }

    private func infoCard(icon: String, iconColor: Color, title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.caption.bold()).foregroundStyle(iconColor)
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Text(value).font(.subheadline.bold()).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.1)))
    }

    // MARK: - Execution Badge

    private var executionBadge: some View {
        let mode = emulatorState.executionMode
        return HStack(spacing: 10) {
            Image(systemName: mode.systemImage).font(.subheadline.bold()).foregroundStyle(Color.cascadeBlue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Running in \(mode.displayName)").font(.subheadline.bold())
                Text(mode == .jit ? "Block recompiler enabled" : "Pure interpreter mode")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(Color.cascadeBlue.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.cascadeBlue.opacity(0.2), lineWidth: 1))
    }

    // MARK: - Collections Section

    private var collectionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Collections", systemImage: "folder.fill")
                    .font(.subheadline.bold())
                Spacer()
            }

            if library.collections.isEmpty {
                Text("No collections yet — create one in the Library.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            } else {
                VStack(spacing: 6) {
                    ForEach(library.collections) { col in
                        let inCollection = library.isGame(game, in: col)
                        Button(action: {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            library.toggleGame(game, in: col)
                        }) {
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(col.color)
                                    .frame(width: 10, height: 10)
                                Text(col.name)
                                    .font(.subheadline)
                                Spacer()
                                Image(systemName: inCollection ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(inCollection ? col.color : Color.secondary)
                            }
                            .padding(12)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(inCollection ? col.color.opacity(0.3) : Color.clear, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Cheats Section

    private var cheatsSection: some View {
        let discID = game.discID.uppercased()
        let cheats = cheatManager.cheats(for: discID)

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Cheats", systemImage: "wand.and.stars")
                    .font(.subheadline.bold())
                Spacer()
                Button(action: { showAddCheat = true }) {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(Color.cascadeBlue)
                }
                Button(action: { showCheatHelp = true }) {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(.secondary)
                }
            }

            if cheats.isEmpty {
                Text("No cheats added. Tap + to add a GameShark-style code.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            } else {
                VStack(spacing: 6) {
                    ForEach(cheats) { cheat in
                        HStack(spacing: 12) {
                            Toggle("", isOn: Binding(
                                get: { cheat.enabled },
                                set: { _ in cheatManager.toggle(cheat, for: discID) }
                            ))
                            .labelsHidden()
                            .tint(Color.cascadeBlue)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(cheat.name).font(.subheadline.bold())
                                Text(cheat.code).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                cheatManager.remove(cheat, for: discID)
                            } label: {
                                Image(systemName: "trash").font(.caption)
                            }
                            .foregroundStyle(.red)
                        }
                        .padding(12)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(cheat.enabled ? Color.cascadeBlue.opacity(0.25) : Color.clear, lineWidth: 1)
                        )
                    }
                }
            }

            if !cheats.isEmpty {
                Text("Cheats apply to RAM when the game starts. Re-launch to activate changes.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .alert("Cheat Format", isPresented: $showCheatHelp) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Use GameShark format:\nXXXXXXXX YYYYYYYY\n\nTop nibble of address sets write size:\n0 = 8-bit, 1 = 16-bit, 2+ = 32-bit\n\nExample: 20482000 0000270F")
        }
    }

    // MARK: - Add Cheat Sheet

    private var addCheatSheet: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. Infinite Health", text: $newCheatName)
                }
                Section("Code") {
                    TextField("XXXXXXXX YYYYYYYY", text: $newCheatCode)
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                }
                Section {
                    Text("GameShark format: 8-digit address, space, 8-digit value (all hex). The top nibble of the address controls write size: 0=byte, 1=word, 2+=dword.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add Cheat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        newCheatName = ""; newCheatCode = ""
                        showAddCheat = false
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add") {
                        let cheat = CheatCode(name: newCheatName.isEmpty ? "Cheat" : newCheatName,
                                             code: newCheatCode.uppercased())
                        cheatManager.add(cheat, for: game.discID)
                        newCheatName = ""; newCheatCode = ""
                        showAddCheat = false
                    }
                    .disabled(newCheatCode.isEmpty)
                }
            }
        }
    }

    // MARK: - File Info

    private var fileInfoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("File")
                .font(.caption).foregroundStyle(.secondary).textCase(.uppercase).tracking(1)

            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(Color(.tertiarySystemFill)).frame(width: 40, height: 40)
                    Image(systemName: "doc.fill").foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(game.url.lastPathComponent).font(.subheadline.bold()).lineLimit(1)
                    Text(fileSizeString(game.url)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.1)))
        }
    }

    // MARK: - Helpers

    private var coverColor: Color {
        let seed = abs(game.id.hashValue)
        let hue  = Double(seed % 360) / 360.0
        return Color(hue: hue, saturation: 0.5, brightness: 0.6)
    }

    private func formatDuration(_ t: TimeInterval) -> String {
        let h = Int(t) / 3600; let m = (Int(t) % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    private func fileSizeString(_ url: URL) -> String {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let gb    = Double(bytes) / 1_000_000_000
        return gb > 1 ? String(format: "%.1f GB", gb) : String(format: "%.0f MB", Double(bytes) / 1_000_000)
    }
}
