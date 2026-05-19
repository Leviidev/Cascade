import SwiftUI

struct GameDetailView: View {
    let game: GameEntry
    @EnvironmentObject var emulatorState: EmulatorState
    @EnvironmentObject var library: GameLibraryManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                // Blurred background art
                LinearGradient(
                    colors: [coverColor.opacity(0.35), Color(.systemBackground)],
                    startPoint: .top, endPoint: .center
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 28) {
                        // Cover + metadata
                        headerSection

                        // Play button
                        playSection

                        // Info grid
                        infoGrid

                        // File info
                        fileInfoSection
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle(game.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        VStack(spacing: 16) {
            // Cover art
            ZStack {
                RoundedRectangle(cornerRadius: 20)
                    .fill(LinearGradient(
                        colors: [coverColor.opacity(0.8), coverColor.opacity(0.5)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .frame(width: 180, height: 240)
                    .shadow(color: coverColor.opacity(0.5), radius: 20, y: 10)

                VStack(spacing: 12) {
                    Image(systemName: "opticaldisc.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.white.opacity(0.9))
                    Text(game.discID.isEmpty ? "PS2" : game.discID)
                        .font(.caption.monospaced())
                        .foregroundColor(.white.opacity(0.7))
                }
            }

            VStack(spacing: 4) {
                Text(game.title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)

                HStack(spacing: 12) {
                    Label(game.region, systemImage: "globe")
                    if game.isFavorite {
                        Image(systemName: "heart.fill").foregroundColor(.red)
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var playSection: some View {
        VStack(spacing: 12) {
            Button(action: {
                dismiss()
                emulatorState.launch(game: game)
                library.updateLastPlayed(game)
            }) {
                HStack(spacing: 10) {
                    if emulatorState.status == .loading {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "play.fill")
                    }
                    Text(emulatorState.status == .loading ? "Loading…" : "Play")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    LinearGradient(colors: [Color.cascadeBlue, Color.cascadeBlue.opacity(0.8)],
                                   startPoint: .leading, endPoint: .trailing)
                )
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(color: Color.cascadeBlue.opacity(0.4), radius: 10, y: 5)
            }
            .disabled(emulatorState.status == .loading)

            if !emulatorState.biosLoaded {
                Label("BIOS required — go to Settings to import", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var infoGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            infoCard(title: "Added", value: game.addedDate.formatted(.dateTime.month().day().year()))
            infoCard(title: "Last Played", value: game.lastPlayed.map { $0.formatted(.relative(presentation: .named)) } ?? "Never")
            infoCard(title: "Play Time", value: formatDuration(game.totalPlayTime))
            infoCard(title: "Disc ID", value: game.discID.isEmpty ? "Unknown" : game.discID)
        }
    }

    private func infoCard(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.bold())
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.1)))
    }

    private var fileInfoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("File")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(1)

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(game.url.lastPathComponent)
                        .font(.subheadline.bold())
                        .lineLimit(1)
                    Text(fileSizeString(game.url))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "doc.fill")
                    .foregroundStyle(.secondary)
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
