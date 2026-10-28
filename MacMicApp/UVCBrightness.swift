import Foundation

// Signed UVC brightness values and the production brightness backend.
protocol BrightnessTransport: AnyObject {
    var supportsBrightness: Bool { get }
    func get(_ request: UInt8) throws -> [UInt8]
    func set(_ bytes: [UInt8]) throws
}

extension BrightnessTransport {
    var supportsBrightness: Bool { true }
}

enum BrightnessError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { message } else { nil } }
}

struct BrightnessCodec {
    static func decode(_ bytes: [UInt8]) throws -> Int {
        guard bytes.count == 2 else { throw BrightnessError.invalid("Brightness response must contain exactly 2 bytes.") }
        return Int(Int16(bitPattern: UInt16(bytes[0]) | UInt16(bytes[1]) << 8))
    }
    static func encode(_ value: Int) throws -> [UInt8] {
        guard let signed = Int16(exactly: value) else { throw BrightnessError.invalid("Brightness exceeds signed 16-bit range.") }
        let bits = UInt16(bitPattern: signed)
        return [UInt8(bits & 255), UInt8(bits >> 8)]
    }
}

struct BrightnessSetting: Equatable, Sendable {
    let minimum: Int
    let maximum: Int
    let step: Int
    let value: Int
    let initial: Int

    func accepts(_ value: Int) -> Bool {
        value >= minimum && value <= maximum && (value - minimum) % step == 0
    }

    static func read(from transport: any BrightnessTransport, initial: Int? = nil,
                     capabilities: BrightnessSetting? = nil) throws -> Self {
        let info = try transport.get(0x86)
        guard info.count == 1, info[0] & 0x03 == 0x03, info[0] & 0x1c == 0 else {
            throw BrightnessError.invalid("Brightness control is unavailable on this camera.")
        }
        let minimum = try capabilities?.minimum ?? BrightnessCodec.decode(transport.get(0x82))
        let maximum = try capabilities?.maximum ?? BrightnessCodec.decode(transport.get(0x83))
        let step = try capabilities?.step ?? BrightnessCodec.decode(transport.get(0x84))
        let value = try BrightnessCodec.decode(transport.get(0x81))
        guard minimum < maximum, step > 0, value >= minimum, value <= maximum,
              (value - minimum) % step == 0 else {
            throw BrightnessError.invalid("The camera returned invalid brightness values.")
        }
        return Self(minimum: minimum, maximum: maximum, step: step, value: value, initial: initial ?? value)
    }

    func applying(_ value: Int, to transport: any BrightnessTransport) throws -> Self {
        guard accepts(value) else { throw BrightnessError.invalid("Brightness is outside the supported range or step.") }
        try transport.set(BrightnessCodec.encode(value))
        // The backend read these capabilities immediately before this write.
        // Access flags and the actual value still come from the camera.
        let confirmed = try Self.read(from: transport, initial: initial, capabilities: self)
        guard confirmed.value == value else { throw BrightnessError.invalid("The camera did not confirm the requested brightness.") }
        return confirmed
    }
}


final class BrightnessControlBackend: CameraControlBackend {
    private let transport: any BrightnessTransport
    private var initial: Int?
    init(transport: any BrightnessTransport) { self.transport = transport }

    func read(_ id: CameraControlID) throws -> CameraControl {
        guard id == .brightness else { throw CameraControlError.invalid("This control has no verified backend yet.") }
        guard transport.supportsBrightness else { return .unavailable(id) }
        let setting = try BrightnessSetting.read(from: transport, initial: initial)
        if initial == nil { initial = setting.value }
        return model(setting)
    }

    func beginWrite(_ id: CameraControlID, value: CameraControlValue, shouldContinue: @escaping () -> Bool) throws -> CameraControlWrite {
        guard id == .brightness else { throw CameraControlError.invalid("This control has no verified backend yet.") }
        guard transport.supportsBrightness else { throw CameraControlError.invalid("Not supported by this camera.") }
        let setting = try BrightnessSetting.read(from: transport, initial: initial)
        if initial == nil { initial = setting.value }
        let current = model(setting)
        try current.validate(value, controls: [id: current])
        guard let number = value.number, let integer = Int(exactly: number) else {
            throw CameraControlError.invalid("Brightness requires a whole number.")
        }
        guard shouldContinue() else { throw CameraControlError.invalid("The camera session changed before the command was sent.") }
        return .complete(model(try setting.applying(integer, to: transport)))
    }

    private func model(_ setting: BrightnessSetting) -> CameraControl {
        CameraControl(id: .brightness, title: "Brightness",
            kind: .numeric(CameraControlRange(minimum: Double(setting.minimum), maximum: Double(setting.maximum), step: Double(setting.step))),
            unit: .device, access: .writable, dependency: nil,
            value: .number(Double(setting.value)), initial: .number(Double(setting.initial)))
    }
}
