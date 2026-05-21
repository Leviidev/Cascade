import SwiftUI

// MARK: - Main Emulator View (full-screen game display + on-screen controller)

struct EmulatorView: View {
    @EnvironmentObject var emulatorState: EmulatorState
    @State private var showMenu = false
    @State private var menuOpacity: Double = 0
    @State private var controllerVisible = true
    @State private var lastTap = Date()

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                // Game output
                gameOutput

                // Gradient vignette for controller readability
                if controllerVisible {
                    VStack {
                        Spacer()
                        LinearGradient(
                            colors: [.clear, .black.opacity(0.7)],
                            startPoint: .top, endPoint: .bottom
                        )
                        .frame(height: geo.size.height * 0.45)
                    }
                    .ignoresSafeArea()
                }

                // On-screen controller
                if controllerVisible {
                    OnScreenControllerView()
                        .ignoresSafeArea()
                }

                // Swipe gesture zone (top of screen)
                VStack {
                    swipeTarget
                    Spacer()
                }
                .ignoresSafeArea()

                // In-game menu overlay
                if showMenu {
                    EmulatorMenuView(isPresented: $showMenu)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
            }
        }
        .statusBarHidden(!showMenu)
        .persistentSystemOverlays(.hidden)
    }

    private var gameOutput: some View {
        Group {
            if let frame = emulatorState.frameImage {
                Image(uiImage: frame)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                loadingState
            }
        }
    }

    private var loadingState: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
                .tint(.white)
            Text(emulatorState.currentGame?.title ?? "Starting…")
                .font(.headline)
                .foregroundColor(.white.opacity(0.8))
        }
    }

    private var swipeTarget: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 60)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 20)
                    .onEnded { value in
                        if value.translation.height > 30 {
                            withAnimation(.spring(response: 0.3)) { showMenu = true }
                        }
                    }
            )
    }
}

// MARK: - Emulator Menu (in-game pause menu)

struct EmulatorMenuView: View {
    @Binding var isPresented: Bool
    @EnvironmentObject var emulatorState: EmulatorState
    @State private var showSaveSlots = false
    @State private var showLoadSlots = false

    var body: some View {
        ZStack {
            // Backdrop
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation { isPresented = false }
                }

            // Menu card (iOS 26 Liquid Glass style)
            VStack(spacing: 0) {
                menuHeader
                Divider().background(.white.opacity(0.15))
                menuItems
            }
            .frame(width: 300)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 28))
            .overlay(
                RoundedRectangle(cornerRadius: 28)
                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.4), radius: 30, y: 10)
        }
    }

    private var menuHeader: some View {
        VStack(spacing: 8) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 32))
                .foregroundStyle(Color.cascadeBlue.gradient)
                .modifier(PulseIfAvailable())

            Text(emulatorState.currentGame?.title ?? "Cascade")
                .font(.headline)
                .lineLimit(1)

            if emulatorState.status == .running {
                HStack(spacing: 6) {
                    Circle().fill(.green).frame(width: 6, height: 6)
                    Text("\(Int(emulatorState.fps)) FPS")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 24)
        .padding(.horizontal, 20)
    }

    private var menuItems: some View {
        VStack(spacing: 0) {
            menuButton(icon: "play.fill", label: "Resume", color: .green) {
                withAnimation { isPresented = false }
                emulatorState.resume()
            }

            Divider().background(.white.opacity(0.08)).padding(.horizontal, 16)

            menuButton(icon: "square.and.arrow.down.fill", label: "Save State", color: .cascadeBlue) {
                showSaveSlots = true
            }

            Divider().background(.white.opacity(0.08)).padding(.horizontal, 16)

            menuButton(icon: "square.and.arrow.up.fill", label: "Load State", color: .cascadeBlue) {
                showLoadSlots = true
            }

            Divider().background(.white.opacity(0.08)).padding(.horizontal, 16)

            menuButton(icon: "camera.fill", label: "Screenshot", color: .purple) {
                takeScreenshot()
            }

            Divider().background(.white.opacity(0.08)).padding(.horizontal, 16)

            menuButton(icon: "xmark.circle.fill", label: "Exit to Library", color: .red) {
                withAnimation { isPresented = false }
                emulatorState.stop()
            }
        }
        .sheet(isPresented: $showSaveSlots) { SaveStateSheet(mode: .save, isPresented: $showSaveSlots) }
        .sheet(isPresented: $showLoadSlots) { SaveStateSheet(mode: .load, isPresented: $showLoadSlots) }
    }

    private func menuButton(icon: String, label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 28)
                Text(label)
                    .font(.body.weight(.medium))
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func takeScreenshot() {
        guard let image = emulatorState.frameImage else { return }
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation { isPresented = false }
    }
}

// MARK: - Save/Load State Sheet

struct SaveStateSheet: View {
    enum Mode { case save, load }
    let mode: Mode
    @Binding var isPresented: Bool
    @EnvironmentObject var emulatorState: EmulatorState

    var body: some View {
        NavigationStack {
            List(0..<8) { slot in
                let date = emulatorState.stateDate(slot: slot)
                Button(action: {
                    mode == .save ? emulatorState.saveState(slot: slot) : emulatorState.loadState(slot: slot)
                    isPresented = false
                }) {
                    HStack {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(date != nil ? Color.cascadeBlue.opacity(0.15) : Color(.tertiarySystemFill))
                                .frame(width: 38, height: 38)
                            Image(systemName: date != nil ? "square.fill.on.square.fill" : "square.dashed")
                                .foregroundStyle(date != nil ? Color.cascadeBlue : Color.secondary)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Slot \(slot + 1)")
                                .font(.headline)
                            if let date {
                                Text(date, style: .relative)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Empty")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                        if date != nil {
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .disabled(mode == .load && date == nil)
            }
            .navigationTitle(mode == .save ? "Save State" : "Load State")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { isPresented = false }
                }
            }
        }
    }
}
