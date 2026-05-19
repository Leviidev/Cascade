import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var emulatorState: EmulatorState
    @AppStorage("resolutionScale")   var resolutionScale: Double = 1.0
    @AppStorage("frameLimiter")      var frameLimiter: String = "60"
    @AppStorage("widescreenHack")    var widescreenHack: Bool = false
    @AppStorage("hapticFeedback")    var hapticFeedback: Bool = true
    @AppStorage("audioEnabled")      var audioEnabled: Bool = true
    @AppStorage("controllerOpacity") var controllerOpacity: Double = 0.8
    @AppStorage("eeClockMultiplier") var eeClockMultiplier: Double = 1.0

    @State private var showBIOSImporter = false
    @State private var showAbout = false

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [Color(.systemBackground), Color.cascadeBlue.opacity(0.04)],
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea()

                List {
                    biosSection
                    renderingSection
                    gameplaySection
                    audioSection
                    controllerSection
                    aboutSection
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .fileImporter(
                isPresented: $showBIOSImporter,
                allowedContentTypes: [.data],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    emulatorState.importBIOS(from: url)
                }
            }
            .sheet(isPresented: $showAbout) { AboutView() }
        }
    }

    // MARK: - Sections

    private var biosSection: some View {
        Section {
            HStack {
                Image(systemName: emulatorState.biosLoaded ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(emulatorState.biosLoaded ? Color.green : Color.orange)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    Text("PS2 BIOS")
                        .font(.headline)
                    Text(emulatorState.biosLoaded ? "Loaded and ready" : "Not imported — required to play")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Import") { showBIOSImporter = true }
                    .buttonStyle(.bordered)
                    .tint(emulatorState.biosLoaded ? .secondary : .cascadeBlue)
                    .controlSize(.small)
            }
            .padding(.vertical, 4)
        } header: {
            Label("BIOS", systemImage: "cpu")
        }
    }

    private var renderingSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Resolution Scale")
                    Spacer()
                    Text("\(Int(resolutionScale))×")
                        .foregroundStyle(Color.cascadeBlue)
                        .font(.subheadline.bold())
                }
                Slider(value: $resolutionScale, in: 1...4, step: 1)
                    .tint(Color.cascadeBlue)
                Text("Higher scales look sharper but use more GPU power")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Picker("Frame Limiter", selection: $frameLimiter) {
                Text("30 FPS").tag("30")
                Text("50 FPS").tag("50")
                Text("60 FPS").tag("60")
                Text("Uncapped").tag("0")
            }

            Toggle("Widescreen Hack (16:9)", isOn: $widescreenHack)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("EE Clock Speed")
                    Spacer()
                    Text(String(format: "%.0f%%", eeClockMultiplier * 100))
                        .foregroundStyle(Color.cascadeBlue)
                        .font(.subheadline.bold())
                }
                Slider(value: $eeClockMultiplier, in: 0.5...2.0, step: 0.1)
                    .tint(Color.cascadeBlue)
                Text("Increase for speed, decrease for compatibility")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        } header: {
            Label("Rendering", systemImage: "display")
        }
    }

    private var gameplaySection: some View {
        Section {
            Toggle("Haptic Feedback", isOn: $hapticFeedback)
        } header: {
            Label("Gameplay", systemImage: "gamecontroller")
        }
    }

    private var audioSection: some View {
        Section {
            Toggle("Enable Audio", isOn: $audioEnabled)
        } header: {
            Label("Audio", systemImage: "speaker.wave.2")
        }
    }

    private var controllerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Controller Opacity")
                    Spacer()
                    Text(String(format: "%.0f%%", controllerOpacity * 100))
                        .foregroundStyle(Color.cascadeBlue)
                        .font(.subheadline.bold())
                }
                Slider(value: $controllerOpacity, in: 0.2...1.0, step: 0.05)
                    .tint(Color.cascadeBlue)
            }
        } header: {
            Label("Controller", systemImage: "hand.tap")
        }
    }

    private var aboutSection: some View {
        Section {
            Button(action: { showAbout = true }) {
                HStack {
                    Label("About Cascade", systemImage: "info.circle")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(.primary)

            Link(destination: URL(string: "https://github.com/your-org/cascade")!) {
                HStack {
                    Label("Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(.primary)
        } header: {
            Label("About", systemImage: "info")
        }
    }
}

// MARK: - About

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                VStack(spacing: 16) {
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 72))
                        .foregroundStyle(Color.cascadeBlue.gradient)
                        .symbolEffect(.pulse)

                    VStack(spacing: 6) {
                        Text("Cascade")
                            .font(.largeTitle.bold())
                        Text("PS2 Emulator for iOS")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("Version 1.0")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.top, 40)

                VStack(alignment: .leading, spacing: 16) {
                    infoRow(icon: "shield.fill", title: "Legal",
                            body: "Cascade does not include any PS2 software or BIOS. You must own a physical PS2 to legally dump your own BIOS and games.")
                    infoRow(icon: "heart.fill", title: "Open Source",
                            body: "Cascade is GPL-2.0. Pull requests and contributions are very welcome.")
                    infoRow(icon: "envelope.fill", title: "Feedback",
                            body: "Open an issue or PR on GitHub to report bugs, request features, or contribute.")
                }
                .padding(.horizontal, 24)

                Spacer()
            }
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func infoRow(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color.cascadeBlue)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(body).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}
