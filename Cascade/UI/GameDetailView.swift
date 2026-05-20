import SwiftUI

struct GameDetailView: View {
    let game: GameEntry
    @EnvironmentObject var emulatorState: EmulatorState
    @EnvironmentObject var library: GameLibraryManager
    @Environment(\.dismiss) private var dismiss

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
            infoCard(
                icon: "calendar",
                iconColor: .cascadeBlue,
                title: "Added",
                value: game.addedDate.formatted(.dateTime.month().day().year())
            )
            infoCard(
                icon: "clock.fill",
                iconColor: .purple,
                title: "Last Played",
                value: game.lastPlayed.map { $0.formatted(.relative(presentation: .named)) } ?? "Never"
            )
            infoCard(
                icon: "timer",
                iconColor: .green,
                title: "Play Time",
                value: formatDuration(game.totalPlayTime)
            )
            infoCard(
                icon: "barcode",
                iconColor: .orange,
                title: "Disc ID",
                value: game.discID.isEmpty ? "Unknown" : game.discID
            )
        }
    }

    private func infoCard(icon: String, iconColor: Color, title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption.bold())
                    .foregroundStyle(iconColor)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.subheadline.bold())
                .lineLimit(2)
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
            Image(systemName: mode.systemImage)
                .font(.subheadline.bold())
                .foregroundStyle(Color.cascadeBlue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Running in \(mode.displayName)")
                    .font(.subheadline.bold())
                Text(mode == .jit ? "Block recompiler enabled" : "Pure interpreter mode")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(Color.cascadeBlue.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.cascadeBlue.opacity(0.2), lineWidth: 1))
    }

    // MARK: - File Info

    private var fileInfoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("File")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(1)

            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(.tertiarySystemFill))
                        .frame(width: 40, height: 40)
                    Image(systemName: "doc.fill")
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(game.url.lastPathComponent)
                        .font(.subheadline.bold())
                        .lineLimit(1)
                    Text(fileSizeString(game.url))
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
        let hue = Double(seed % 360) / 360.0
        return Color(hue: hue, saturation: 0.5, brightness: 0.6)
    }

    private func formatDuration(_ t: TimeInterval) -> String {
        let h = Int(t) / 3600
        let m = (Int(t) % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    private func fileSizeString(_ url: URL) -> String {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let gb = Double(bytes) / 1_000_000_000
        return gb > 1 ? String(format: "%.1f GB", gb) : String(format: "%.0f MB", Double(bytes) / 1_000_000)
    }
}
