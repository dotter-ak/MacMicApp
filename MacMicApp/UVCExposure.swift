import Foundation

enum UVCExposureControl: CaseIterable, Sendable {
    case mode, exposure, gain
    var width: Int { switch self { case .mode: 1; case .exposure: 4; case .gain: 2 } }
    var selector: UInt8 { self == .mode ? 2 : 4 }
    var bit: Int { switch self { case .mode: 1; case .exposure: 3; case .gain: 9 } }
    var usesCameraTerminal: Bool { self != .gain }
}

enum UVCUnsignedValue {
    // Same integer compatibility rule as Linux uvcvideo: a successful nonempty
    // short unsigned LE reply omits zero MSBs. Never apply to INFO, masks or SET.
    static func decode(_ bytes: [UInt8], width: Int, allowShort: Bool) throws -> UInt32 {
        guard (1...4).contains(width), !bytes.isEmpty, bytes.count <= width,
              allowShort || bytes.count == width else { throw CameraControlError.invalid("Incomplete camera response.") }
        return bytes.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
    }
    static func encode(_ value: UInt32, width: Int) throws -> [UInt8] {
        guard (1...4).contains(width), width == 4 || value < (UInt32(1) << (width * 8)) else {
            throw CameraControlError.invalid("Value exceeds the camera control size.")
        }
        return (0..<width).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }
}


// Used only within one write and its scheduled confirmations. Current values and access
// flags always reach the device; only MIN/MAX/RES capability reads are reused.
final class UVCWriteReadCache<Control: Hashable> {
    private var values: [Control: [UInt8: UInt32]] = [:]

    func read(_ control: Control, request: UInt8, load: () throws -> UInt32) throws -> UInt32 {
        guard request == 0x82 || request == 0x83 || request == 0x84 else { return try load() }
        if let cached = values[control]?[request] { return cached }
        let value = try load()
        values[control, default: [:]][request] = value
        return value
    }

    func clear() { values.removeAll() }
}



protocol ExposureTransport: AnyObject {
    var usesYizhanExposureProtocol: Bool { get }
    func supportsExposureControl(_ id: UVCExposureControl) -> Bool
    func readExposure(_ id: UVCExposureControl, request: UInt8) throws -> [UInt8]
    func writeExposure(_ id: UVCExposureControl, bytes: [UInt8]) throws
}

extension ExposureTransport {
    var usesYizhanExposureProtocol: Bool { false }
    func supportsExposureControl(_ id: UVCExposureControl) -> Bool { true }
}

final class ExposureControlBackend: CameraControlBackend {
    private let transport: any ExposureTransport
    private var initial: [CameraControlID: CameraControlValue] = [:]
    private var writeReadCache: UVCWriteReadCache<UVCExposureControl>?
    private var initialReportedExposure: CameraControlValue?

    init(transport: any ExposureTransport) {
        self.transport = transport
    }
    private func number(_ id: UVCExposureControl, _ request: UInt8) throws -> UInt32 {
        let load = {
            try UVCUnsignedValue.decode(self.transport.readExposure(id, request: request),
                width: request == 0x86 ? 1 : id.width, allowShort: id != .mode && request != 0x86)
        }
        if let writeReadCache { return try writeReadCache.read(id, request: request, load: load) }
        return try load()
    }
    private func wire(_ id: CameraControlID) throws -> UVCExposureControl {
        switch id {
        case .autoExposure: .mode
        case .exposure: .exposure
        case .gain: .gain
        default: throw CameraControlError.invalid("Not an exposure control.")
        }
    }
    func read(_ id: CameraControlID) throws -> CameraControl {
        try readState(id).control
    }

    // Share a fresh mode only within this read/write stage. Every confirmation
    // reads the mode again, and no current-value cache survives a USB write.
    private func readState(_ id: CameraControlID, mode: CameraControl? = nil) throws -> (control: CameraControl, mode: CameraControl?) {
        let wire = try wire(id)
        guard transport.supportsExposureControl(wire) else { return (.unavailable(id), nil) }
        var exposureMode = mode
        let info = try number(wire, 0x86)
        guard info & 1 != 0 else { throw CameraControlError.invalid("The camera does not allow reading this control.") }
        let raw = try number(wire, 0x81)
        var access: CameraControlAccess = info & 2 == 0 ? .readOnly(.notWritable) : .writable
        if info & 0x10 != 0 { access = .readOnly(.asynchronous) }
        if info & 4 != 0 { access = .readOnly(.managedAutomatically) }
        let kind: CameraControlKind, value: CameraControlValue, unit: CameraControlUnit, title: String
        var dependency: CameraControlDependency?
        var reportedValue: CameraControlValue?
        if wire == .mode {
            let advertisedMask = try number(.mode, 0x84)
            // This exact firmware reports zero but Windows and bounded Mac
            // trials confirm Auto (02) and Shutter Priority (04), not Manual (01).
            let mask: UInt32 = transport.usesYizhanExposureProtocol && advertisedMask == 0 ? 6 : advertisedMask
            guard let current = ExposureMode(rawValue: raw) else { throw CameraControlError.invalid("The camera returned an unknown exposure mode.") }
            let supported = ExposureMode.allCases.filter { mask & $0.rawValue != 0 }.map(CameraControlOption.exposure)
            kind = .options(supported); value = .option(.exposure(current)); unit = .none; title = "Exposure Mode"
            if mask == 0 || mask & ~UInt32(15) != 0 || mask & raw == 0 {
                access = .readOnly(.invalidExposureModes)
            }
        } else {
            let lower = try number(wire, 0x82), upper = try number(wire, 0x83), step = try number(wire, 0x84)
            let reportedExposure = wire == .exposure && transport.usesYizhanExposureProtocol
            guard lower < upper, step > 0, step <= upper-lower,
                  reportedExposure ? (raw > 0 && raw <= upper) : (raw >= lower && raw <= upper && (raw-lower) % step == 0) else {
                throw CameraControlError.invalid("The camera returned an invalid range or value.")
            }
            let scale = wire == .exposure && !reportedExposure ? 0.0001 : 1.0 // Standard UVC: 100 μs. Yizhan physical units unverified.
            kind = .numeric(CameraControlRange(minimum: Double(lower)*scale, maximum: Double(upper)*scale, step: Double(step)*scale))
            if reportedExposure {
                // E.g. input MIN=156, accepted readback=149. Never widen the
                // device's writable range or present the clamped value as raw.
                let bounded = min(upper, max(lower, raw))
                value = .number(Double(lower + ((bounded-lower)/step)*step))
                reportedValue = .number(Double(raw))
                if initialReportedExposure == nil { initialReportedExposure = reportedValue }
            } else {
                value = .number(Double(raw)*scale)
            }
            unit = wire == .exposure && !reportedExposure ? .seconds : .device
            title = wire == .exposure ? "Exposure" : "Gain"
            if wire == .exposure {
                let mode = try exposureMode ?? read(.autoExposure)
                exposureMode = mode
                let required = mode.value == .option(.exposure(.shutterPriority)) || transport.usesYizhanExposureProtocol
                    ? ExposureMode.shutterPriority : .manual
                dependency = CameraControlDependency(id: .autoExposure, requiredValue: .option(.exposure(required)))
                if mode.access != .writable {
                    access = .readOnly(.invalidExposureModes)
                }
            }
        }
        if initial[id] == nil { initial[id] = value }
        let control = CameraControl(id: id, title: title, kind: kind, unit: unit, access: access,
                             dependency: dependency, value: value, initial: initial[id]!, reportedValue: reportedValue,
                             initialReportedValue: id == .exposure ? initialReportedExposure : nil)
        return (control, exposureMode)
    }
    func readAutomaticExposure() throws -> AutomaticExposureReading? {
        guard transport.supportsExposureControl(.mode), transport.supportsExposureControl(.exposure) else { return nil }
        let mode = try number(.mode, 0x81)
        guard ExposureMode(rawValue: mode)?.isAutomatic == true else { return nil }
        let raw = try number(.exposure, 0x81)
        guard raw > 0 else { throw CameraControlError.invalid("The camera returned an invalid exposure value.") }
        return AutomaticExposureReading(value: Double(raw) * (transport.usesYizhanExposureProtocol ? 1 : 0.0001),
                                        unit: transport.usesYizhanExposureProtocol ? .device : .seconds)
    }

    func beginWrite(_ id: CameraControlID, value: CameraControlValue, shouldContinue: @escaping () -> Bool) throws -> CameraControlWrite {
        let cache = UVCWriteReadCache<UVCExposureControl>()
        writeReadCache = cache
        defer { writeReadCache = nil }
        let state = try readState(id), wire = try wire(id)
        let current = state.control
        var controls = [id: current]
        if let mode = state.mode { controls[.autoExposure] = mode }
        try current.validate(value, controls: controls)
        let raw: UInt32
        switch value {
        case .option(.exposure(let mode)):
            raw = mode.rawValue
        case .number(let number):
            let scaled = id == .exposure && !transport.usesYizhanExposureProtocol ? number * 10000 : number
            guard scaled.isFinite, abs(scaled-scaled.rounded()) < 1e-6, let encoded = UInt32(exactly: scaled.rounded()) else {
                throw CameraControlError.invalid("Value cannot be encoded for this camera.")
            }
            raw = encoded
        default: throw CameraControlError.invalid("Unsupported control value.")
        }
        var exposureCommit: [UInt8]?
        if transport.usesYizhanExposureProtocol, id == .autoExposure, raw == 4 {
            let exposure = try readState(.exposure, mode: current).control
            guard exposure.access == .writable, let value = exposure.value.number,
                  let bounded = UInt32(exactly: value), exposure.kind.accepts(exposure.value) else {
                throw CameraControlError.invalid("Cannot preserve the current exposure setting.")
            }
            exposureCommit = try UVCUnsignedValue.encode(bounded, width: 4)
        }
        guard shouldContinue() else { throw CameraControlError.invalid("Camera session changed before the write.") }
        if transport.usesYizhanExposureProtocol, id == .exposure {
            // Repeat Shutter Priority immediately before each exposure SET,
            // matching ImageView. Fresh dependency validation above is mandatory.
            try transport.writeExposure(.mode, bytes: [4])
            guard shouldContinue() else { throw CameraControlError.invalid("Camera session changed while setting exposure.") }
        }
        try transport.writeExposure(wire, bytes: UVCUnsignedValue.encode(raw, width: wire.width))
        if let exposureCommit {
            guard shouldContinue() else { throw CameraControlError.invalid("Camera session changed while switching exposure.") }
            try transport.writeExposure(.exposure, bytes: exposureCommit)
        }
        // Mode changes may change capabilities. Re-read them after all paired
        // writes, even when a Yizhan exposure SET repeats Shutter Priority.
        if id == .autoExposure || (transport.usesYizhanExposureProtocol && id == .exposure) {
            writeReadCache?.clear()
        }
        // Require two consecutive readbacks, allowing a bounded device settling time.
        var matches = 0
        var previousReported: CameraControlValue?
        return .pending(CameraControlConfirmation(failureMessage: "The camera did not confirm the requested value. Use Retry to read its current state.") { [self] in
            writeReadCache = cache
            defer { writeReadCache = nil }
            guard shouldContinue() else { throw CameraControlError.invalid("Camera session changed while confirming the write.") }
            let state = try readState(id)
            let result = state.control
            if transport.usesYizhanExposureProtocol, id == .exposure || exposureCommit != nil {
                let exposure = id == .exposure ? result : try readState(.exposure, mode: result).control
                let mode = id == .autoExposure ? result : state.mode
                guard let reported = exposure.reportedValue else {
                    throw CameraControlError.invalid("The camera did not report its exposure value.")
                }
                // No guessed ±N tolerance: return the stable actual setting,
                // even when the hardware keeps it unchanged after a tiny move.
                let restoresInitial = id == .exposure && value == current.initial
                let restored = !restoresInitial || reported == initialReportedExposure
                if mode?.value == .option(.exposure(.shutterPriority)) && restored {
                    matches = reported == previousReported ? matches + 1 : 1
                } else { matches = 0 }
                previousReported = reported
                if matches == 2 { return result }
                return nil
            }
            let equal: Bool
            if let a = result.value.number, let b = value.number { equal = abs(a-b) < 1e-8 }
            else { equal = result.value == value }
            matches = equal ? matches+1 : 0
            return matches == 2 ? result : nil
        })
    }
}
