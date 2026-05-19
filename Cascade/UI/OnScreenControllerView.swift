import SwiftUI

// MARK: - On-Screen PS2 DualShock 2 Controller
// iOS 26 "Liquid Glass" glassmorphism style

struct OnScreenControllerView: View {
    @EnvironmentObject var emulatorState: EmulatorState

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let btnSize: CGFloat = 46
            let padSize: CGFloat = 110

            ZStack {
                // ─── Left side ───────────────────────────────
                // D-Pad
                DPadView()
                    .frame(width: padSize, height: padSize)
                    .position(x: w * 0.18, y: h - 160)

                // SELECT / START
                HStack(spacing: 20) {
                    SmallButton(label: "SELECT") {
                        emulatorState.emulator.pad.pressButton(.select)
                    } onRelease: {
                        emulatorState.emulator.pad.releaseButton(.select)
                    }
                    SmallButton(label: "START") {
                        emulatorState.emulator.pad.pressButton(.start)
                    } onRelease: {
                        emulatorState.emulator.pad.releaseButton(.start)
                    }
                }
                .position(x: w * 0.5, y: h - 200)

                // ─── Right side ───────────────────────────────
                // Face buttons (×, ○, △, □)
                FaceButtonsView(size: btnSize)
                    .frame(width: padSize, height: padSize)
                    .position(x: w * 0.82, y: h - 160)

                // ─── Shoulder buttons ─────────────────────────
                ShoulderButton(label: "L1", action: { emulatorState.emulator.pad.pressButton(.l1) },
                               release: { emulatorState.emulator.pad.releaseButton(.l1) })
                    .position(x: w * 0.1, y: h - 310)

                ShoulderButton(label: "L2", action: { emulatorState.emulator.pad.pressButton(.l2) },
                               release: { emulatorState.emulator.pad.releaseButton(.l2) })
                    .position(x: w * 0.1, y: h - 360)

                ShoulderButton(label: "R1", action: { emulatorState.emulator.pad.pressButton(.r1) },
                               release: { emulatorState.emulator.pad.releaseButton(.r1) })
                    .position(x: w * 0.9, y: h - 310)

                ShoulderButton(label: "R2", action: { emulatorState.emulator.pad.pressButton(.r2) },
                               release: { emulatorState.emulator.pad.releaseButton(.r2) })
                    .position(x: w * 0.9, y: h - 360)

                // ─── Analog Sticks ────────────────────────────
                AnalogStickView { x, y in
                    emulatorState.emulator.pad.setLeftStick(x: x, y: y)
                }
                .frame(width: 80, height: 80)
                .position(x: w * 0.3, y: h - 80)

                AnalogStickView { x, y in
                    emulatorState.emulator.pad.setRightStick(x: x, y: y)
                }
                .frame(width: 80, height: 80)
                .position(x: w * 0.7, y: h - 80)
            }
        }
    }
}

// MARK: - D-Pad

struct DPadView: View {
    @EnvironmentObject var emulatorState: EmulatorState
    private let size: CGFloat = 38

    var body: some View {
        ZStack {
            // Horizontal bar
            HStack(spacing: 4) {
                dpadButton(.left,  icon: "chevron.left")
                Spacer()
                dpadButton(.right, icon: "chevron.right")
            }
            .frame(height: size)

            // Vertical bar
            VStack(spacing: 4) {
                dpadButton(.up,   icon: "chevron.up")
                Spacer()
                dpadButton(.down, icon: "chevron.down")
            }
            .frame(width: size)
        }
    }

    private func dpadButton(_ btn: PS2Button, icon: String) -> some View {
        GlassButton(size: size) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))
        } onPress: {
            emulatorState.emulator.pad.pressButton(btn)
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.5)
        } onRelease: {
            emulatorState.emulator.pad.releaseButton(btn)
        }
    }
}

// MARK: - Face Buttons

struct FaceButtonsView: View {
    let size: CGFloat
    @EnvironmentObject var emulatorState: EmulatorState

    var body: some View {
        ZStack {
            faceBtn(.triangle, label: "△", color: Color(red: 0.3, green: 0.8, blue: 0.7), offset: CGPoint(x: 0, y: -size * 0.45))
            faceBtn(.circle,   label: "○", color: Color(red: 1.0, green: 0.3, blue: 0.3), offset: CGPoint(x: size * 0.45, y: 0))
            faceBtn(.cross,    label: "×", color: Color(red: 0.4, green: 0.5, blue: 1.0), offset: CGPoint(x: 0, y: size * 0.45))
            faceBtn(.square,   label: "□", color: Color(red: 1.0, green: 0.5, blue: 0.7), offset: CGPoint(x: -size * 0.45, y: 0))
        }
    }

    private func faceBtn(_ btn: PS2Button, label: String, color: Color, offset: CGPoint) -> some View {
        GlassButton(size: 42, tint: color) {
            Text(label)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(color)
        } onPress: {
            emulatorState.emulator.pad.pressButton(btn)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } onRelease: {
            emulatorState.emulator.pad.releaseButton(btn)
        }
        .offset(x: offset.x, y: offset.y)
    }
}

// MARK: - Analog Stick

struct AnalogStickView: View {
    let onChange: (Float, Float) -> Void

    @State private var thumbOffset: CGSize = .zero
    private let baseSize: CGFloat = 80
    private let thumbSize: CGFloat = 34
    private let maxRadius: CGFloat = 24

    var body: some View {
        ZStack {
            // Base
            Circle()
                .fill(.ultraThinMaterial)
                .overlay(Circle().stroke(Color.white.opacity(0.15), lineWidth: 1))
                .shadow(color: .black.opacity(0.3), radius: 6, y: 3)

            // Thumb
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.white.opacity(0.4), Color.white.opacity(0.1)],
                        center: .topLeading, startRadius: 0, endRadius: thumbSize
                    )
                )
                .frame(width: thumbSize, height: thumbSize)
                .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1))
                .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
                .offset(thumbOffset)
        }
        .frame(width: baseSize, height: baseSize)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    let clamped = clamp(v.translation)
                    thumbOffset = clamped
                    onChange(Float(clamped.width / maxRadius), Float(clamped.height / maxRadius))
                }
                .onEnded { _ in
                    withAnimation(.spring(response: 0.2)) { thumbOffset = .zero }
                    onChange(0, 0)
                }
        )
    }

    private func clamp(_ size: CGSize) -> CGSize {
        let dist = sqrt(size.width * size.width + size.height * size.height)
        if dist <= maxRadius { return size }
        let scale = maxRadius / dist
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}

// MARK: - Shoulder Button

struct ShoulderButton: View {
    let label: String
    let action: () -> Void
    let release: () -> Void

    var body: some View {
        GlassButton(size: 44) {
            Text(label)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white.opacity(0.85))
        } onPress: {
            action()
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.6)
        } onRelease: {
            release()
        }
    }
}

// MARK: - Small Center Button (SELECT / START)

struct SmallButton: View {
    let label: String
    let action: () -> Void
    let onRelease: () -> Void

    var body: some View {
        GlassButton(size: CGSize(width: 60, height: 28)) {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white.opacity(0.75))
        } onPress: {
            action()
        } onRelease: {
            onRelease()
        }
    }
}

// MARK: - Reusable Glass Button

struct GlassButton<Label: View>: View {
    var size: CGSize
    var tint: Color
    let label: () -> Label
    let onPress: () -> Void
    let onRelease: () -> Void

    @State private var pressed = false

    init(size: CGFloat, tint: Color = .white,
         @ViewBuilder label: @escaping () -> Label,
         onPress: @escaping () -> Void,
         onRelease: @escaping () -> Void) {
        self.size = CGSize(width: size, height: size)
        self.tint = tint
        self.label = label
        self.onPress = onPress
        self.onRelease = onRelease
    }

    init(size: CGSize, tint: Color = .white,
         @ViewBuilder label: @escaping () -> Label,
         onPress: @escaping () -> Void,
         onRelease: @escaping () -> Void) {
        self.size = size
        self.tint = tint
        self.label = label
        self.onPress = onPress
        self.onRelease = onRelease
    }

    var body: some View {
        label()
            .frame(width: size.width, height: size.height)
            .background(
                ZStack {
                    // Liquid Glass base
                    RoundedRectangle(cornerRadius: min(size.width, size.height) * 0.35)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: min(size.width, size.height) * 0.35)
                        .fill(
                            LinearGradient(
                                colors: pressed
                                    ? [tint.opacity(0.35), tint.opacity(0.2)]
                                    : [Color.white.opacity(0.15), Color.white.opacity(0.05)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: min(size.width, size.height) * 0.35)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.3), Color.white.opacity(0.05)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ), lineWidth: 0.8
                    )
            )
            .shadow(color: .black.opacity(pressed ? 0.1 : 0.25), radius: pressed ? 2 : 6, y: pressed ? 1 : 3)
            .scaleEffect(pressed ? 0.93 : 1.0)
            .animation(.spring(response: 0.15, dampingFraction: 0.7), value: pressed)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !pressed { pressed = true; onPress() } }
                    .onEnded   { _ in pressed = false; onRelease() }
            )
    }
}
