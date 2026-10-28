import Foundation

struct AutomaticExposureReading: Equatable, Sendable {
    let value: Double
    let unit: CameraControlUnit
}

enum CameraControlID: String, Hashable, Sendable, CaseIterable {
    case brightness, autoExposure, exposure, gain
    case autoWhiteBalance, whiteBalance, contrast, saturation, sharpness, gamma, antiFlicker

    var title: String {
        switch self {
        case .brightness: "Brightness"
        case .autoExposure: "Exposure Mode"
        case .exposure: "Exposure"
        case .gain: "Gain"
        case .autoWhiteBalance: "Auto White Balance"
        case .whiteBalance: "White Balance"
        case .contrast: "Contrast"
        case .saturation: "Saturation"
        case .sharpness: "Sharpness"
        case .gamma: "Gamma"
        case .antiFlicker: "Anti-flicker"
        }
    }
}

enum ExposureMode: UInt32, CaseIterable, Sendable {
    case manual = 1, auto = 2, shutterPriority = 4, aperturePriority = 8

    var isAutomatic: Bool { self == .auto || self == .aperturePriority }
    var title: String {
        switch self {
        case .manual: "Manual"
        case .auto: "Auto"
        case .shutterPriority: "Shutter Priority"
        case .aperturePriority: "Aperture Priority"
        }
    }
}

enum AntiFlickerMode: UInt32, CaseIterable, Sendable {
    case off = 0, hz50 = 1, hz60 = 2, auto = 3

    var title: String {
        switch self {
        case .off: "Off"
        case .hz50: "50 Hz"
        case .hz60: "60 Hz"
        case .auto: "Auto"
        }
    }
}

enum CameraControlOption: Hashable, Sendable {
    case exposure(ExposureMode), antiFlicker(AntiFlickerMode), unavailable

    var title: String {
        switch self {
        case .exposure(let mode): mode.title
        case .antiFlicker(let mode): mode.title
        case .unavailable: "Unavailable"
        }
    }
}

enum CameraControlValue: Equatable, Sendable {
    case number(Double)
    case toggle(Bool)
    case option(CameraControlOption)

    var number: Double? { if case .number(let value) = self { value } else { nil } }
}

struct CameraControlRange: Equatable, Sendable {
    let minimum: Double
    let maximum: Double
    let step: Double

    var isValid: Bool {
        minimum.isFinite && maximum.isFinite && step.isFinite && minimum < maximum && step > 0
            && ((maximum - minimum) / step).isFinite
    }
    var lastValue: Double { minimum + floor((maximum - minimum) / step) * step }
    func contains(_ value: Double) -> Bool {
        guard isValid, value.isFinite, value >= minimum, value <= maximum else { return false }
        let steps = (value - minimum) / step
        return abs(steps - steps.rounded()) <= 1e-7
    }
}

enum CameraControlKind: Equatable, Sendable {
    case numeric(CameraControlRange)
    case toggle
    case options([CameraControlOption])

    func accepts(_ value: CameraControlValue) -> Bool {
        switch (self, value) {
        case (.numeric(let range), .number(let number)): range.contains(number)
        case (.toggle, .toggle): true
        case (.options(let choices), .option(let choice)): choices.contains(choice)
        default: false
        }
    }
}

enum CameraControlUnit: String, Sendable { case device, seconds, kelvin, hertz, none }
enum CameraControlAccessReason: Equatable, Sendable {
    case notSupported, notWritable, managedAutomatically, asynchronous, invalidExposureModes
    case other(String)

    var message: String {
        switch self {
        case .notSupported: "Not supported by this camera."
        case .notWritable: "The camera does not allow changes."
        case .managedAutomatically: "This value is managed automatically by the camera."
        case .asynchronous: "Asynchronous camera controls are not supported yet."
        case .invalidExposureModes: "Manual exposure is not available for this camera in MacMicApp yet."
        case .other(let message): message
        }
    }
}

enum CameraControlAccess: Equatable, Sendable {
    case writable
    case readOnly(CameraControlAccessReason)
    case unavailable(CameraControlAccessReason)
}
struct CameraControlDependency: Equatable, Sendable {
    let id: CameraControlID
    let requiredValue: CameraControlValue
}

enum CameraControlError: LocalizedError, Sendable {
    case invalid(String)
    var errorDescription: String? { switch self { case .invalid(let message): message } }
}

struct CameraControl: Equatable, Sendable {
    let id: CameraControlID
    let title: String
    let kind: CameraControlKind
    let unit: CameraControlUnit
    let access: CameraControlAccess
    let dependency: CameraControlDependency?
    let value: CameraControlValue
    let initial: CameraControlValue
    var confirmed = true
    // Some devices quantize numeric settings outside their advertised input grid.
    // Keep the raw readback separate from the bounded slider/input value.
    var reportedValue: CameraControlValue?
    var initialReportedValue: CameraControlValue?
    static func unavailable(_ id: CameraControlID) -> Self {
        Self(id: id, title: id.title, kind: .options([]), unit: .none,
             access: .unavailable(.notSupported), dependency: nil,
             value: .option(.unavailable), initial: .option(.unavailable))
    }
    var isAtInitialValue: Bool {
        value == initial && (initialReportedValue == nil || reportedValue == initialReportedValue)
    }

    func automaticState(for displayedValue: CameraControlValue? = nil) -> Bool? {
        switch (id, displayedValue ?? value) {
        case (.autoWhiteBalance, .toggle(let enabled)), (.autoExposure, .toggle(let enabled)): enabled
        case (.autoExposure, .option(.exposure(let mode))): mode.isAutomatic
        default: nil
        }
    }

    func automaticTarget(enabled: Bool) -> CameraControlValue? {
        guard id == .autoExposure || id == .autoWhiteBalance else { return nil }
        if case .toggle = kind { return .toggle(enabled) }
        guard id == .autoExposure, case .options(let choices) = kind else { return nil }
        // Priority modes differ in who controls exposure time. Only offer
        // transitions actually advertised by this device.
        let preferred: [CameraControlOption] = (enabled
            ? [ExposureMode.auto, .aperturePriority] : [.manual, .shutterPriority]).map(CameraControlOption.exposure)
        return preferred.first(where: choices.contains).map(CameraControlValue.option)
    }

    func validate(_ value: CameraControlValue, controls: [CameraControlID: CameraControl]) throws {
        guard confirmed else { throw CameraControlError.invalid("Read the current value before making another change.") }
        switch access {
        case .writable: break
        case .readOnly(let reason), .unavailable(let reason): throw CameraControlError.invalid(reason.message)
        }
        guard kind.accepts(value) else { throw CameraControlError.invalid("The value does not match the supported range, step or type.") }
        if let dependency {
            guard let other = controls[dependency.id], other.confirmed,
                  other.value == dependency.requiredValue else {
                throw CameraControlError.invalid("This control is unavailable in the current automatic mode.")
            }
        }
    }
}

// CaptureEngine routes controls to their backend and confines all calls
// to its existing serial queue; the UI only receives transport-independent data.
protocol CameraControlBackend: AnyObject {
    func read(_ id: CameraControlID) throws -> CameraControl
    func beginWrite(_ id: CameraControlID, value: CameraControlValue, shouldContinue: @escaping () -> Bool) throws -> CameraControlWrite
}

// All stages stay on the capture queue. A pending write releases that queue
// between reads, while CameraControlQueue keeps other control commands ordered.
enum CameraControlWrite {
    case complete(CameraControl)
    case pending(CameraControlConfirmation)
}

final class CameraControlConfirmation {
    static let interval: TimeInterval = 0.1
    private var remaining = 8
    private let failureMessage: String
    private let read: () throws -> CameraControl?

    init(failureMessage: String, read: @escaping () throws -> CameraControl?) {
        self.failureMessage = failureMessage
        self.read = read
    }

    func poll() throws -> CameraControl? {
        guard remaining > 0 else { throw CameraControlError.invalid(failureMessage) }
        remaining -= 1
        if let result = try read() { return result }
        guard remaining > 0 else { throw CameraControlError.invalid(failureMessage) }
        return nil
    }
}
