import AVFoundation

private func brightness(_ value: Double = 60) -> CameraControl {
    CameraControl(id: .brightness, title: "Brightness", kind: .numeric(CameraControlRange(minimum: 0, maximum: 100, step: 2)), unit: .device, access: .writable, dependency: nil, value: .number(value), initial: .number(60))
}
private final class Transport: BrightnessTransport {
    var supportsBrightness = true
    var current = 60
    var maximum = 100
    var requests: [UInt8] = []
    var writes: [Int] = []
    var ignoreWrite = false
    var readOnly = false
    func get(_ request: UInt8) throws -> [UInt8] {
        requests.append(request)
        if request == 0x86 { return [readOnly ? 1 : 3] }
        return try BrightnessCodec.encode([0x81: current, 0x82: 0, 0x83: maximum, 0x84: 2][request]!)
    }
    func set(_ bytes: [UInt8]) throws {
        let value = try BrightnessCodec.decode(bytes)
        writes.append(value)
        if !ignoreWrite { current = value }
    }
}
private final class Driver: CaptureDriving, @unchecked Sendable {
    @MainActor let previewLayer = AVCaptureVideoPreviewLayer()
    private let lock = NSLock()
    private var sessionReports: [@Sendable (CaptureEvent) -> Void] = []
    private var replies: [@Sendable (Result<CameraControl, CameraControlError>) -> Void] = []
    private var values: [CameraControlValue?] = []
    @MainActor init() {}
    func start(deviceID: String, report: @escaping @Sendable (CaptureEvent) -> Void) { lock.withLock { sessionReports.append(report) } }
    func changeMode(_ mode: VideoMode, report: @escaping @Sendable (CaptureEvent) -> Void) { lock.withLock { sessionReports.append(report) } }
    func stop(completion: @escaping @Sendable () -> Void) { completion() }
    func control(_ id: CameraControlID, value: CameraControlValue?, report: @escaping @Sendable (Result<CameraControl, CameraControlError>) -> Void) {
        guard id == .brightness else { report(.failure(.invalid("Not available in this test camera"))); return }
        lock.withLock { values.append(value); replies.append(report) }
    }
    var requests: [CameraControlValue?] { lock.withLock { values } }
    func finish(_ index: Int, _ result: Result<CameraControl, CameraControlError>) { lock.withLock { replies[index] }(result) }
    func live(_ index: Int) {
        let format = VideoFormat(index: 0, resolution: VideoResolution(width: 1920, height: 1080), subtype: 0x34323076, rates: [VideoRateRange(min: 10, max: 30)])
        lock.withLock { sessionReports[index] }(.running(CaptureSnapshot(formats: [format], active: VideoMode(formatIndex: 0, fps: 30))))
    }
}
@main
private struct CameraControlChecks {
    static func rejects(_ body: () throws -> Void) {
        do { try body(); preconditionFailure("Expected rejection") } catch {}
    }
    @MainActor static func settle() async { for _ in 0..<12 { await Task.yield() }; try? await Task.sleep(for: .milliseconds(10)) }
    @MainActor static func main() async throws {
        let unsupported = Transport()
        unsupported.supportsBrightness = false
        let unsupportedBackend = BrightnessControlBackend(transport: unsupported)
        let absent = try unsupportedBackend.read(.brightness)
        precondition(absent == .unavailable(.brightness))
        rejects { _ = try unsupportedBackend.write(.brightness, value: .number(60)) }
        precondition(unsupported.requests.isEmpty && unsupported.writes.isEmpty)
        let measured = Transport()
        let measuredBackend = BrightnessControlBackend(transport: measured)
        _ = try measuredBackend.write(.brightness, value: .number(62))
        precondition(measured.requests.count == 7 && measured.writes.count == 1,
                     "Brightness: 7 GET + 1 SET instead of 10 GET + 1 SET")
        precondition(measured.requests.filter { $0 == 0x81 }.count == 2)
        precondition(measured.requests.filter { $0 == 0x86 }.count == 2)
        measured.maximum = 64
        rejects { _ = try measuredBackend.write(.brightness, value: .number(66)) }
        precondition(measured.writes.count == 1, "Next command must read fresh brightness limits")
        print("PASS: brightness 11 → 8 USB requests with fresh value, access and next-command limits")
        let control = brightness()
        for value in [Double.nan, .infinity, -2, 101, 61] {
            rejects { try control.validate(.number(value), controls: [:]) }
        }
        try control.validate(.number(0), controls: [:]); try control.validate(.number(100), controls: [:])
        rejects { try control.validate(.toggle(true), controls: [:]) }
        precondition(CameraControlRange(minimum: -1, maximum: 1, step: 0.1).contains(0.3))
        precondition(!CameraControlRange(minimum: 0, maximum: 10, step: 0).contains(1))
        precondition(CameraControlRange(minimum: 1, maximum: 10, step: 2).lastValue == 9)
        precondition(CameraControlKind.options([.antiFlicker(.hz50), .antiFlicker(.hz60)]).accepts(.option(.antiFlicker(.hz50))))
        precondition(!CameraControlKind.options([.antiFlicker(.hz50)]).accepts(.option(.antiFlicker(.hz60))))
        let auto = CameraControl(id: .autoExposure, title: "Auto", kind: .toggle, unit: .none, access: .writable, dependency: nil, value: .toggle(false), initial: .toggle(false))
        precondition(auto.automaticState() == false && auto.automaticTarget(enabled: true) == .toggle(true))
        precondition(auto.automaticState(for: .toggle(true)) == true)
        let transitions: [([ExposureMode], ExposureMode, ExposureMode)] = [
            ([.auto, .manual], .auto, .manual),
            ([.aperturePriority, .shutterPriority], .aperturePriority, .shutterPriority)
        ]
        for (modes, automatic, manual) in transitions {
            let choices = modes.map(CameraControlOption.exposure)
            let on = CameraControlOption.exposure(automatic), off = CameraControlOption.exposure(manual)
            let mode = CameraControl(id: .autoExposure, title: "Mode", kind: .options(choices), unit: .none,
                access: .writable, dependency: nil, value: .option(on), initial: .option(on))
            precondition(mode.automaticState() == true && mode.automaticState(for: .option(off)) == false)
            precondition(mode.automaticTarget(enabled: true) == .option(on))
            precondition(mode.automaticTarget(enabled: false) == .option(off))
        }
        let invalidMode = CameraControl(id: .autoExposure, title: "Mode", kind: .options([]), unit: .none,
            access: .readOnly(.other("Invalid capabilities")), dependency: nil, value: .option(.exposure(.auto)), initial: .option(.exposure(.auto)))
        precondition(invalidMode.automaticState() == true)
        precondition(invalidMode.automaticTarget(enabled: false) == nil && invalidMode.automaticTarget(enabled: true) == nil)
        precondition(invalidMode.automaticState(for: .option(.unavailable)) == nil)
        precondition(control.automaticTarget(enabled: true) == nil && control.automaticState() == nil)
        let whiteBalanceAuto = CameraControl(id: .autoWhiteBalance, title: "Auto White Balance", kind: .toggle,
            unit: .none, access: .writable, dependency: nil, value: .toggle(true), initial: .toggle(true))
        precondition(whiteBalanceAuto.automaticState() == true && whiteBalanceAuto.automaticTarget(enabled: false) == .toggle(false))
        print("PASS: Auto UI maps only supported exposure modes and WB toggles; invalid capabilities cannot fabricate a target")
        let manual = CameraControl(id: .exposure, title: "Exposure", kind: .numeric(CameraControlRange(minimum: 0.001, maximum: 1, step: 0.001)), unit: .seconds, access: .writable, dependency: CameraControlDependency(id: .autoExposure, requiredValue: .toggle(false)), value: .number(0.1), initial: .number(0.1))
        try manual.validate(.number(0.2), controls: [.autoExposure: auto])
        rejects { try manual.validate(.number(0.2), controls: [:]) }
        let autoOn = CameraControl(id: .autoExposure, title: "Auto", kind: .toggle, unit: .none, access: .writable, dependency: nil, value: .toggle(true), initial: .toggle(false))
        rejects { try manual.validate(.number(0.2), controls: [.autoExposure: autoOn]) }
        var unknownAuto = auto; unknownAuto.confirmed = false
        rejects { try manual.validate(.number(0.2), controls: [.autoExposure: unknownAuto]) }
        let readonly = CameraControl(id: .brightness, title: "Brightness", kind: control.kind, unit: .device, access: .readOnly(.other("Read only")), dependency: nil, value: .number(60), initial: .number(60))
        rejects { try readonly.validate(.number(70), controls: [:]) }
        let transport = Transport(), backend = BrightnessControlBackend(transport: Transport())
        rejects { _ = try backend.read(.gain) }
        let realBackend = BrightnessControlBackend(transport: transport)
        let read = try realBackend.read(.brightness); precondition(read == control && transport.writes.isEmpty)
        rejects { _ = try realBackend.write(.brightness, value: .number(61)) }
        rejects { _ = try realBackend.write(.brightness, value: .number(70), shouldContinue: { false }) }
        precondition(transport.writes.isEmpty)
        let changed = try realBackend.write(.brightness, value: .number(70))
        precondition(changed.value == .number(70) && changed.initial == .number(60))
        transport.ignoreWrite = true
        rejects { _ = try realBackend.write(.brightness, value: .number(80)) }
        transport.readOnly = true
        rejects { _ = try realBackend.write(.brightness, value: .number(80)) }
        precondition(transport.writes == [70, 80])

        let driver = Driver()
        let store = CaptureController(engine: driver)
        store.open(deviceID: "a"); driver.live(0); await settle()
        precondition(driver.requests.count == 1)
        driver.finish(0, .success(control)); await settle()
        store.adjustments.setControl(.brightness, value: .number(60))
        precondition(driver.requests.count == 1) // Already confirmed; no redundant SET.
        store.adjustments.setControl(.brightness, value: .number(62))
        for value in stride(from: 64, through: 100, by: 2) { store.adjustments.setControl(.brightness, value: .number(Double(value))) }
        precondition(driver.requests.count == 2 && store.adjustments.requestedValues[.brightness] == .number(100))
        driver.finish(1, .success(brightness(62))); await settle()
        precondition(driver.requests.count == 3 && driver.requests[2] == .number(100))
        precondition(store.adjustments.requestedValues[.brightness] == .number(100))
        driver.finish(2, .success(brightness(100))); await settle()
        precondition(store.adjustments.requestedValues.isEmpty && store.adjustments.busyControls.isEmpty)
        store.adjustments.setControl(.brightness, value: .number(80))
        store.adjustments.setControl(.brightness, value: .number(70))
        driver.finish(3, .failure(.invalid("Readback failed"))); await settle()
        precondition(store.state == .live && store.adjustments.controls[.brightness]?.confirmed == false && driver.requests.count == 4)
        store.adjustments.setControl(.brightness, value: .number(60)); precondition(driver.requests.count == 4)
        store.adjustments.loadControl(.brightness); driver.finish(4, .success(brightness(80))); await settle()
        precondition(store.adjustments.controls[.brightness]?.confirmed == true)
        store.adjustments.setControl(.brightness, value: .number(60))
        store.selectDevice("b"); driver.live(1); await settle()
        driver.finish(5, .success(brightness(60))); await settle()
        precondition(store.adjustments.controls.isEmpty && store.adjustments.busyControls == [.brightness])
        driver.finish(6, .success(brightness(30))); await settle()
        precondition(store.adjustments.controls[.brightness]?.value == .number(30))
        store.adjustments.setControl(.brightness, value: .number(40)); store.close()
        driver.finish(7, .success(brightness(40))); await settle()
        precondition(store.state == .stopped && store.adjustments.controls.isEmpty && store.adjustments.requestedValues.isEmpty)
        print("PASS: ranges, steps, types, Auto dependencies, access, cancellation before SET, readback, last-value coalescing, error recovery and stale camera/closed-session responses")
    }
}
