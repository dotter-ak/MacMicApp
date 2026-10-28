import Foundation

// UVC Processing Unit selectors, bitmap bits and wire widths.
// White balance here is the temperature control (Kelvin), not component balance.
enum UVCImageControl: String, CaseIterable {
    case autoWhiteBalance, whiteBalance, contrast, saturation, sharpness, gamma, antiFlicker
    var id: CameraControlID { CameraControlID(rawValue: rawValue)! }
    var selector: UInt8 {
        switch self {
        case .autoWhiteBalance: 0x0b
        case .whiteBalance: 0x0a
        case .contrast: 0x03
        case .saturation: 0x07
        case .sharpness: 0x08
        case .gamma: 0x09
        case .antiFlicker: 0x05
        }
    }
    var bit: Int {
        switch self {
        case .autoWhiteBalance: 12
        case .whiteBalance: 6
        case .contrast: 1
        case .saturation: 3
        case .sharpness: 4
        case .gamma: 5
        case .antiFlicker: 10
        }
    }
    var width: Int { self == .autoWhiteBalance || self == .antiFlicker ? 1 : 2 }
}

protocol ImageControlTransport: AnyObject {
    var imageControlVersion: UInt16 { get }
    var whiteBalanceRequiresTemperatureCommit: Bool { get }
    func supportsImageControl(_ id: UVCImageControl) -> Bool
    func readImageControl(_ id: UVCImageControl, request: UInt8) throws -> [UInt8]
    func writeImageControl(_ id: UVCImageControl, bytes: [UInt8]) throws
}

extension ImageControlTransport {
    var whiteBalanceRequiresTemperatureCommit: Bool { false }
}

final class ImageControlBackend: CameraControlBackend {
    private let transport: any ImageControlTransport
    private var writeReadCache: UVCWriteReadCache<UVCImageControl>?
    private var initial: [CameraControlID: CameraControlValue] = [:]
    init(transport: any ImageControlTransport) {
        self.transport = transport
    }

    private var flickerOptions: [CameraControlOption] {
        (transport.imageControlVersion >= 0x0150 ? AntiFlickerMode.allCases : [.off, .hz50, .hz60]).map(CameraControlOption.antiFlicker)
    }
    private func number(_ wire: UVCImageControl, _ request: UInt8) throws -> UInt32 {
        let load = {
            try UVCUnsignedValue.decode(self.transport.readImageControl(wire, request: request),
                width: request == 0x86 ? 1 : wire.width, allowShort: wire.width == 2 && request != 0x86)
        }
        if let writeReadCache { return try writeReadCache.read(wire, request: request, load: load) }
        return try load()
    }
    func read(_ id: CameraControlID) throws -> CameraControl {
        guard let wire = UVCImageControl(rawValue: id.rawValue) else {
            throw CameraControlError.invalid("Unknown image control.")
        }
        guard transport.supportsImageControl(wire) else {
            return .unavailable(id)
        }
        let info = try number(wire, 0x86)
        guard info & 1 != 0 else { throw CameraControlError.invalid("The camera does not allow reading this control.") }
        let raw = try number(wire, 0x81)
        var access: CameraControlAccess = info & 2 == 0 ? .readOnly(.notWritable) : .writable
        if info & 4 != 0 { access = .readOnly(.managedAutomatically) }
        if info & 0x10 != 0 { access = .readOnly(.asynchronous) }
        let kind: CameraControlKind, value: CameraControlValue
        var dependency: CameraControlDependency?
        switch wire {
        case .autoWhiteBalance:
            guard raw <= 1 else { throw CameraControlError.invalid("The camera returned an invalid Auto White Balance value.") }
            kind = .toggle; value = .toggle(raw == 1)
        case .antiFlicker:
            guard Int(raw) < flickerOptions.count else { throw CameraControlError.invalid("The camera returned an unknown Anti-flicker mode.") }
            kind = .options(flickerOptions); value = .option(flickerOptions[Int(raw)])
        default:
            let lower = try number(wire, 0x82), upper = try number(wire, 0x83), step = try number(wire, 0x84)
            let range = CameraControlRange(minimum: Double(lower), maximum: Double(upper), step: Double(step))
            guard range.isValid, range.contains(Double(raw)) else {
                throw CameraControlError.invalid("The camera returned an invalid range or value.")
            }
            kind = .numeric(range); value = .number(Double(raw))
            if wire == .whiteBalance, transport.supportsImageControl(.autoWhiteBalance) {
                dependency = CameraControlDependency(id: .autoWhiteBalance, requiredValue: .toggle(false))
            }
        }
        if initial[id] == nil { initial[id] = value }
        return CameraControl(id: id, title: id.title, kind: kind, unit: wire == .whiteBalance ? .kelvin : .device,
            access: access, dependency: dependency, value: value, initial: initial[id]!)
    }

    func beginWrite(_ id: CameraControlID, value: CameraControlValue, shouldContinue: @escaping () -> Bool) throws -> CameraControlWrite {
        let cache = UVCWriteReadCache<UVCImageControl>()
        writeReadCache = cache
        defer { writeReadCache = nil }
        let current = try read(id)
        var controls = [id: current]
        if let dependency = current.dependency { controls[dependency.id] = try read(dependency.id) }
        try current.validate(value, controls: controls)
        guard let wire = UVCImageControl(rawValue: id.rawValue) else { throw CameraControlError.invalid("Unknown image control.") }
        let raw: UInt32
        switch value {
        case .number(let number):
            guard let integer = UInt32(exactly: number) else { throw CameraControlError.invalid("A whole number is required.") }
            raw = integer
        case .toggle(let enabled): raw = enabled ? 1 : 0
        case .option(.antiFlicker(let mode)):
            guard wire == .antiFlicker, flickerOptions.contains(.antiFlicker(mode)) else {
                throw CameraControlError.invalid("Unknown Anti-flicker mode.")
            }
            raw = mode.rawValue
        case .option: throw CameraControlError.invalid("Unsupported control option.")
        }
        // Yizhan 0ac8:3420 / 0409 commits Auto-off only after a temperature SET.
        // Windows trace #1684/#1686 and the Mac paired-write trial confirm this.
        // Preserve the freshly read temperature; never substitute a default.
        var temperatureCommit: [UInt8]?
        var preservedTemperature: CameraControlValue?
        if id == .autoWhiteBalance, value == .toggle(false),
           transport.whiteBalanceRequiresTemperatureCommit {
            let temperature = try read(.whiteBalance)
            guard temperature.access == .writable,
                  let number = temperature.value.number,
                  let rawTemperature = UInt32(exactly: number),
                  temperature.kind.accepts(temperature.value) else {
                throw CameraControlError.invalid("Cannot preserve the current white balance temperature.")
            }
            temperatureCommit = try UVCUnsignedValue.encode(rawTemperature, width: UVCImageControl.whiteBalance.width)
            preservedTemperature = temperature.value
        }
        guard shouldContinue() else { throw CameraControlError.invalid("Camera session changed before the write.") }
        try transport.writeImageControl(wire, bytes: UVCUnsignedValue.encode(raw, width: wire.width))
        if let temperatureCommit {
            guard shouldContinue() else { throw CameraControlError.invalid("Camera session changed while switching white balance.") }
            try transport.writeImageControl(.whiteBalance, bytes: temperatureCommit)
        }
        // An Auto transition can change temperature capabilities.
        if id == .autoWhiteBalance { writeReadCache?.clear() }
        var matches = 0
        return .pending(CameraControlConfirmation(failureMessage: "The camera did not confirm the change. Use Retry to read its current state.") { [self] in
            writeReadCache = cache
            defer { writeReadCache = nil }
            guard shouldContinue() else { throw CameraControlError.invalid("Camera session changed while confirming the write.") }
            let result = try read(id)
            if let dependency = current.dependency,
               try read(dependency.id).value != dependency.requiredValue {
                matches = 0
                return nil
            }
            var temperatureMatches = true
            if let preservedTemperature {
                temperatureMatches = try read(.whiteBalance).value == preservedTemperature
            }
            matches = result.value == value && temperatureMatches ? matches + 1 : 0
            return matches == 2 ? result : nil
        })
    }
}
