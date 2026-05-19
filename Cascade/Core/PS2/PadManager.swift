import Foundation
import GameController

// MARK: - PS2 Dual Shock 2 Controller Emulation

public final class PadManager {

    // MARK: - Button Bitmask (PS2 button register, active LOW)
    struct ButtonState {
        var buttons1: UInt8 = 0xFF   // select/L3/R3/start/up/right/down/left
        var buttons2: UInt8 = 0xFF   // L2/R2/L1/R1/triangle/circle/cross/square
        var rightX: UInt8 = 0x80
        var rightY: UInt8 = 0x80
        var leftX:  UInt8 = 0x80
        var leftY:  UInt8 = 0x80
        // Analog pressures (DualShock 2)
        var rightXPressure:  UInt8 = 0
        var rightYPressure:  UInt8 = 0
        var trianglePressure: UInt8 = 0
        var circlePressure:   UInt8 = 0
        var crossPressure:    UInt8 = 0
        var squarePressure:   UInt8 = 0
        var l1Pressure: UInt8 = 0
        var r1Pressure: UInt8 = 0
        var l2Pressure: UInt8 = 0
        var r2Pressure: UInt8 = 0
    }

    var port: [ButtonState] = [ButtonState(), ButtonState()]

    // SIO2 state
    var sioBuffer: [UInt8] = []
    var sioResult: [UInt8] = []
    var sioIndex: Int = 0

    // MARK: - Init

    init() {
        connectControllers()
        NotificationCenter.default.addObserver(
            self, selector: #selector(connectControllers),
            name: .GCControllerDidConnect, object: nil)
    }

    @objc func connectControllers() {
        for (i, controller) in GCController.controllers().prefix(2).enumerated() {
            bindController(controller, port: i)
        }
    }

    private func bindController(_ controller: GCController, port i: Int) {
        guard let gamepad = controller.extendedGamepad else { return }

        gamepad.valueChangedHandler = { [weak self] _, element in
            guard let self = self else { return }
            self.updateState(gamepad: gamepad, port: i)
        }
    }

    private func updateState(gamepad: GCExtendedGamepad, port i: Int) {
        var b1: UInt8 = 0xFF
        var b2: UInt8 = 0xFF

        // buttons1: select=0, L3=1, R3=2, start=3, up=4, right=5, down=6, left=7
        if gamepad.buttonOptions?.isPressed == true { b1 &= ~(1 << 0) }
        if gamepad.leftThumbstickButton?.isPressed == true { b1 &= ~(1 << 1) }
        if gamepad.rightThumbstickButton?.isPressed == true { b1 &= ~(1 << 2) }
        if gamepad.buttonMenu.isPressed { b1 &= ~(1 << 3) }
        if gamepad.dpad.up.isPressed    { b1 &= ~(1 << 4) }
        if gamepad.dpad.right.isPressed { b1 &= ~(1 << 5) }
        if gamepad.dpad.down.isPressed  { b1 &= ~(1 << 6) }
        if gamepad.dpad.left.isPressed  { b1 &= ~(1 << 7) }

        // buttons2: L2=0, R2=1, L1=2, R1=3, tri=4, circle=5, cross=6, square=7
        if gamepad.leftTrigger.isPressed  { b2 &= ~(1 << 0) }
        if gamepad.rightTrigger.isPressed { b2 &= ~(1 << 1) }
        if gamepad.leftShoulder.isPressed  { b2 &= ~(1 << 2) }
        if gamepad.rightShoulder.isPressed { b2 &= ~(1 << 3) }
        if gamepad.buttonY.isPressed  { b2 &= ~(1 << 4) }   // triangle
        if gamepad.buttonB.isPressed  { b2 &= ~(1 << 5) }   // circle
        if gamepad.buttonA.isPressed  { b2 &= ~(1 << 6) }   // cross
        if gamepad.buttonX.isPressed  { b2 &= ~(1 << 7) }   // square

        port[i].buttons1 = b1
        port[i].buttons2 = b2

        // Analog sticks (map -1..1 to 0..255)
        port[i].leftX  = toAnalog(gamepad.leftThumbstick.xAxis.value)
        port[i].leftY  = toAnalog(-gamepad.leftThumbstick.yAxis.value)
        port[i].rightX = toAnalog(gamepad.rightThumbstick.xAxis.value)
        port[i].rightY = toAnalog(-gamepad.rightThumbstick.yAxis.value)

        // Pressure
        port[i].l2Pressure = UInt8(gamepad.leftTrigger.value  * 255)
        port[i].r2Pressure = UInt8(gamepad.rightTrigger.value * 255)
    }

    private func toAnalog(_ v: Float) -> UInt8 { UInt8(max(0, min(255, Int((v + 1) * 127.5))) ) }

    // MARK: - On-Screen Button Press (called from UI)

    func pressButton(_ button: PS2Button, port i: Int = 0) {
        applyButton(button, pressed: true, port: i)
    }

    func releaseButton(_ button: PS2Button, port i: Int = 0) {
        applyButton(button, pressed: false, port: i)
    }

    private func applyButton(_ button: PS2Button, pressed: Bool, port i: Int) {
        switch button {
        case .select:   setB1(i, bit: 0, pressed: pressed)
        case .l3:       setB1(i, bit: 1, pressed: pressed)
        case .r3:       setB1(i, bit: 2, pressed: pressed)
        case .start:    setB1(i, bit: 3, pressed: pressed)
        case .up:       setB1(i, bit: 4, pressed: pressed)
        case .right:    setB1(i, bit: 5, pressed: pressed)
        case .down:     setB1(i, bit: 6, pressed: pressed)
        case .left:     setB1(i, bit: 7, pressed: pressed)
        case .l2:       setB2(i, bit: 0, pressed: pressed); port[i].l2Pressure = pressed ? 255 : 0
        case .r2:       setB2(i, bit: 1, pressed: pressed); port[i].r2Pressure = pressed ? 255 : 0
        case .l1:       setB2(i, bit: 2, pressed: pressed); port[i].l1Pressure = pressed ? 255 : 0
        case .r1:       setB2(i, bit: 3, pressed: pressed); port[i].r1Pressure = pressed ? 255 : 0
        case .triangle: setB2(i, bit: 4, pressed: pressed); port[i].trianglePressure = pressed ? 255 : 0
        case .circle:   setB2(i, bit: 5, pressed: pressed); port[i].circlePressure   = pressed ? 255 : 0
        case .cross:    setB2(i, bit: 6, pressed: pressed); port[i].crossPressure    = pressed ? 255 : 0
        case .square:   setB2(i, bit: 7, pressed: pressed); port[i].squarePressure   = pressed ? 255 : 0
        }
    }

    private func setB1(_ i: Int, bit: Int, pressed: Bool) {
        if pressed { port[i].buttons1 &= ~(1 << bit) } else { port[i].buttons1 |= (1 << bit) }
    }
    private func setB2(_ i: Int, bit: Int, pressed: Bool) {
        if pressed { port[i].buttons2 &= ~(1 << bit) } else { port[i].buttons2 |= (1 << bit) }
    }

    // MARK: - Analog Stick

    func setLeftStick(x: Float, y: Float, port i: Int = 0) {
        port[i].leftX = toAnalog(x)
        port[i].leftY = toAnalog(y)
    }

    func setRightStick(x: Float, y: Float, port i: Int = 0) {
        port[i].rightX = toAnalog(x)
        port[i].rightY = toAnalog(y)
    }

    // MARK: - SIO2 Transfer

    func processSIO2(portIdx: Int, command: [UInt8]) -> [UInt8] {
        guard portIdx < 2 else { return [] }
        var response: [UInt8] = [0xFF, 0x41, 0x5A]   // ID bytes

        let state = port[portIdx]
        response += [state.buttons1, state.buttons2,
                     state.rightX, state.rightY, state.leftX, state.leftY]
        return response
    }
}

enum PS2Button: String, CaseIterable {
    case cross, circle, square, triangle
    case l1, r1, l2, r2, l3, r3
    case up, down, left, right
    case start, select
}
