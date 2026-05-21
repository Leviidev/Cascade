import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var emulatorState: EmulatorState
    @EnvironmentObject var keepAlive: BackgroundKeepAlive
    @AppStorage("resolutionScale")   var resolutionScale: Double = 1.0
    @AppStorage("frameLimiter")      var frameLimiter: String = "60"
    @AppStorage("widescreenHack")    var widescreenHack: Bool = false
    @AppStorage("hapticFeedback")    var hapticFeedback: Bool = true
    @AppStorage("audioEnabled")      var audioEnabled: Bool = true
    @AppStorage("controllerOpacity") var controllerOpacity: Double = 0.8
    @AppStorage("eeClockMultiplier") var eeClockMultiplier: Double = 1.0
    @AppStorage("executionMode")     var executionModeRaw: String = ExecutionMode.jit.rawValue

    @ObservedObject private var crashReporter = CrashReporter.shared
    @State private var showBIOSImporter = false
    @State private var showAbout = false
    @State private var showJITInfo = false
    @State private var showCrashLog = false
    @State private var crashLogToShare: IdentifiableURL?

    private var executionMode: ExecutionMode {
        ExecutionMode(rawValue: executionModeRaw) ?? .jit
    }

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
                    executionSection
                    renderingSection
                    gameplaySection
                    audioSection
                    backgroundSection
                    controllerSection
                    diagnosticsSection
                    aboutSection
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .fileImporter(
                isPresented: $showBIOSImporter,
                allowedContentTypes: [.item],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    emulatorState.importBIOS(from: url)
                }
            }
            .sheet(isPresented: $showAbout) { AboutView() }
            .sheet(isPresented: $showJITInfo) { JITInfoSheet() }
        }
    }

    // MARK: - BIOS Section

    private var biosSection: some View {
        Section {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(emulatorState.biosLoaded ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
                        .frame(width: 40, height: 40)
                    Image(systemName: emulatorState.biosLoaded ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(emulatorState.biosLoaded ? Color.green : Color.orange)
                        .font(.system(size: 18, weight: .semibold))
                }

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
            .padding(.vertical, 2)
        } header: {
            Label("BIOS", systemImage: "cpu")
        }
    }

    // MARK: - Execution Mode Section

    private var executionSection: some View {
        Section {
            VStack(spacing: 10) {
                ForEach(ExecutionMode.allCases, id: \.self) { mode in
                    executionModeRow(mode)
                }
            }
            .padding(.vertical, 4)

            if executionMode == .jit {
                jitStatsRow
            }

            Button(action: { showJITInfo = true }) {
                HStack {
                    Label("What's the difference?", systemImage: "questionmark.circle")
                        .font(.subheadline)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(Color.cascadeBlue)
        } header: {
            Label("CPU Execution Mode", systemImage: "bolt.fill")
        } footer: {
            Text(executionMode == .jit
                 ? "JIT requires the dynamic-codesigning entitlement (AltStore / SideStore JIT)."
                 : "JitLess works without any special entitlements on all devices.")
        }
    }

    private func executionModeRow(_ mode: ExecutionMode) -> some View {
        let selected = executionMode == mode
        return Button(action: {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                executionModeRaw = mode.rawValue
                emulatorState.executionMode = mode
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(selected ? Color.cascadeBlue : Color(.tertiarySystemFill))
                        .frame(width: 38, height: 38)
                    Image(systemName: mode.systemImage)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(selected ? .white : .secondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.displayName)
                        .font(.subheadline.bold())
                        .foregroundStyle(selected ? Color.cascadeBlue : .primary)
                    Text(mode == .jit ? "Block recompiler" : "Pure interpreter")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.cascadeBlue)
                        .font(.system(size: 18))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(selected ? Color.cascadeBlue.opacity(0.08) : Color(.secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(selected ? Color.cascadeBlue.opacity(0.3) : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    private var jitStatsRow: some View {
        HStack(spacing: 0) {
            statCell(
                value: "\(emulatorState.jitBlockCount)",
                label: "Cached Blocks",
                icon: "square.stack.3d.up.fill",
                color: .cascadeBlue
            )
            Divider().frame(height: 36)
            statCell(
                value: String(format: "%.0f%%", emulatorState.jitHitRate * 100),
                label: "Cache Hit Rate",
                icon: "checkmark.circle.fill",
                color: .green
            )
        }
        .padding(.vertical, 6)
    }

    private func statCell(value: String, label: String, icon: String, color: Color) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.caption2).foregroundStyle(color)
                Text(value).font(.subheadline.bold()).foregroundStyle(color)
            }
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Rendering Section

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

    // MARK: - Gameplay Section

    private var gameplaySection: some View {
        Section {
            Toggle("Haptic Feedback", isOn: $hapticFeedback)
        } header: {
            Label("Gameplay", systemImage: "gamecontroller")
        }
    }

    // MARK: - Audio Section

    private var audioSection: some View {
        Section {
            Toggle("Enable Audio", isOn: $audioEnabled)
        } header: {
            Label("Audio", systemImage: "speaker.wave.2")
        }
    }

    // MARK: - Controller Section

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

    // MARK: - Background Keep-Alive Section

    private var backgroundSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $keepAlive.isEnabled) {
                    Label("Keep App Alive in Background", systemImage: "location.fill")
                }
                Text("Uses a silent, minimal location update to prevent iOS from suspending the emulator when you switch apps — identical to the technique used by MeloNX.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if keepAlive.authStatus == .denied || keepAlive.authStatus == .restricted {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Location permission denied. Enable it in iOS Settings → Cascade.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Background")
        }
    }

    // MARK: - Diagnostics Section

    private var diagnosticsSection: some View {
        Section {
            HStack {
                Label("Crash Logs", systemImage: "exclamationmark.triangle")
                Spacer()
                Text("\(crashReporter.logFiles.count)")
                    .foregroundStyle(.secondary)
            }

            if let latest = crashReporter.logFiles.first {
                Button(action: { crashLogToShare = latest.identifiable }) {
                    Label("Share Latest Log", systemImage: "square.and.arrow.up")
                }
                .sheet(item: $crashLogToShare) { iurl in
                    ShareSheet(items: [iurl.url])
                }
            }

            if !crashReporter.logFiles.isEmpty {
                Button(role: .destructive, action: { crashReporter.clearAll() }) {
                    Label("Clear All Logs", systemImage: "trash")
                }
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("Crash logs are saved locally when an emulation error occurs. Share them to help improve Cascade.")
        }
    }

    // MARK: - About Section

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

// MARK: - JIT Info Sheet

struct JITInfoSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    ForEach(ExecutionMode.allCases, id: \.self) { mode in
                        modeCard(mode: mode)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Label("Which should I use?", systemImage: "lightbulb.fill")
                            .font(.headline)
                            .foregroundStyle(Color.cascadeBlue)

                        Text("Use **JIT** for best performance — most games run faster with the block recompiler. If a game crashes or behaves unexpectedly, switch to **JitLess** for maximum compatibility.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.1)))
                }
                .padding(20)
            }
            .navigationTitle("Execution Modes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func modeCard(mode: ExecutionMode) -> some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.cascadeBlue.opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: mode.systemImage)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.cascadeBlue)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(mode.displayName)
                    .font(.headline)
                Text(mode.description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.1)))
    }
}

// MARK: - About View

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 32) {
                    VStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .fill(Color.cascadeBlue.opacity(0.15))
                                .frame(width: 100, height: 100)
                            Image(systemName: "gamecontroller.fill")
                                .font(.system(size: 48))
                                .foregroundStyle(Color.cascadeBlue.gradient)
                                .modifier(PulseIfAvailable())
                        }

                        VStack(spacing: 6) {
                            Text("Cascade")
                                .font(.largeTitle.bold())
                            Text("PS2 Emulator for iOS")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text("Version 1.0.1")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 4)
                                .background(Color(.secondarySystemFill), in: Capsule())
                        }
                    }
                    .padding(.top, 20)

                    VStack(spacing: 12) {
                        infoRow(icon: "shield.fill", color: .orange, title: "Legal",
                                body: "Cascade does not include any PS2 software or BIOS. You must own a physical PS2 to legally dump your own BIOS and games.")
                        infoRow(icon: "heart.fill", color: .red, title: "Open Source",
                                body: "Cascade is GPL-2.0. Pull requests and contributions are very welcome.")
                        infoRow(icon: "envelope.fill", color: .cascadeBlue, title: "Feedback",
                                body: "Open an issue or PR on GitHub to report bugs, request features, or contribute.")
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 40)
                }
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

    private func infoRow(icon: String, color: Color, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(body).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.1)))
    }
}
