import AVFoundation

private final class ResetDriver: CaptureDriving, @unchecked Sendable {
    @MainActor let previewLayer = AVCaptureVideoPreviewLayer()
    private let lock = NSLock()
    private var values: [CameraControlID: CameraControlValue] = [.brightness: .number(60), .gain: .number(40), .autoWhiteBalance: .toggle(false), .whiteBalance: .number(4500)]
    private var initial: [CameraControlID: CameraControlValue] = [:]
    private var recorded: [CameraControlID] = []
    private var failures: Set<CameraControlID> = []
    private var holdNext = false
    private var held: (() -> Void)?
    @MainActor init(auto: Bool = false) {
        values[.autoWhiteBalance] = .toggle(auto)
        initial = values
    }
    func start(deviceID: String, report: @escaping @Sendable (CaptureEvent) -> Void) {
        let format = VideoFormat(index: 0, resolution: VideoResolution(width: 1920, height: 1080), subtype: 0x34323076, rates: [VideoRateRange(min: 10, max: 30)])
        report(.running(CaptureSnapshot(formats: [format], active: VideoMode(formatIndex: 0, fps: 30))))
    }
    func changeMode(_ mode: VideoMode, report: @escaping @Sendable (CaptureEvent) -> Void) {}
    func stop(completion: @escaping @Sendable () -> Void) { completion() }
    func change(_ id: CameraControlID, _ value: CameraControlValue) { lock.withLock { values[id] = value } }
    func fail(_ id: CameraControlID) { _ = lock.withLock { failures.insert(id) } }
    func hold() { lock.withLock { holdNext = true } }
    func release() { let callback = lock.withLock { let c = held; held = nil; return c }; callback?() }
    var writes: [CameraControlID] { lock.withLock { recorded } }
    func value(_ id: CameraControlID) -> CameraControlValue? { lock.withLock { values[id] } }
    private func model(_ id: CameraControlID) -> CameraControl {
        guard let value = values[id], let baseline = initial[id] else {
            return CameraControl(id: id, title: id.title, kind: .options([]), unit: .none,
                access: .unavailable(.other("Unsupported")), dependency: nil, value: .option(.unavailable), initial: .option(.unavailable))
        }
        let kind: CameraControlKind = id == .autoWhiteBalance ? .toggle : .numeric(CameraControlRange(minimum: 0, maximum: 10000, step: 1))
        let auto = values[.autoWhiteBalance] == .toggle(true)
        return CameraControl(id: id, title: id.title, kind: kind, unit: .device,
            access: id == .whiteBalance && auto ? .readOnly(.other("Auto")) : .writable,
            dependency: id == .whiteBalance ? CameraControlDependency(id: .autoWhiteBalance, requiredValue: .toggle(false)) : nil,
            value: value, initial: baseline)
    }
    func control(_ id: CameraControlID, value: CameraControlValue?, report: @escaping @Sendable (Result<CameraControl, CameraControlError>) -> Void) {
        let result: Result<CameraControl, CameraControlError> = lock.withLock {
            if let value {
                if failures.contains(id) { return .failure(.invalid("Injected failure")) }
                do { try model(id).validate(value, controls: [.autoWhiteBalance: model(.autoWhiteBalance)]) }
                catch { return .failure(.invalid(error.localizedDescription)) }
                values[id] = value
                recorded.append(id)
            }
            return .success(model(id))
        }
        let deferred = lock.withLock {
            if holdNext { holdNext = false; held = { report(result) }; return true }
            return false
        }
        if !deferred { report(result) }
    }
}

@main struct ResetAdjustmentsChecks {
    @MainActor static func settle() async {
        for _ in 0..<40 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
    }
    @MainActor static func finished(_ controller: CaptureController) async {
        for _ in 0..<100 {
            await settle()
            if !controller.adjustments.isResettingAdjustments && controller.adjustments.busyControls.isEmpty { return }
        }
        preconditionFailure("Reset did not finish")
    }
    @MainActor static func main() async {
        let d = ResetDriver(), c = CaptureController(engine: d)
        c.open(deviceID: "a"); await settle()
        d.change(.brightness, .number(80)); d.change(.gain, .number(55))
        d.change(.whiteBalance, .number(5500)); d.change(.autoWhiteBalance, .toggle(true))
        c.adjustments.resetAdjustments(); await finished(c)
        precondition(d.writes.first == .autoWhiteBalance)
        precondition(d.value(.whiteBalance) == .number(4500) && d.value(.brightness) == .number(60) && d.value(.gain) == .number(40))
        precondition(c.adjustments.resetMessage?.hasPrefix("Initial adjustments restored.") == true)
        let count = d.writes.count
        c.adjustments.resetAdjustments(); await finished(c)
        precondition(d.writes.count == count) // Repeated reset makes no redundant writes.

        let ad = ResetDriver(auto: true), ac = CaptureController(engine: ad)
        ac.open(deviceID: "b"); await settle()
        ad.change(.autoWhiteBalance, .toggle(false)); ad.change(.whiteBalance, .number(6000)); ad.change(.brightness, .number(80))
        ac.adjustments.resetAdjustments(); await finished(ac)
        precondition(ad.writes == [.brightness, .autoWhiteBalance])
        precondition(ad.value(.whiteBalance) == .number(6000)) // Never replay an Auto snapshot as manual WB.

        d.change(.brightness, .number(90)); d.change(.gain, .number(60)); d.fail(.brightness)
        c.adjustments.resetAdjustments(); await finished(c)
        precondition(c.adjustments.resetMessage?.contains("Reset incomplete: Brightness") == true)
        precondition(d.value(.gain) == .number(40)) // Independent controls still restore.

        let sd = ResetDriver(), sc = CaptureController(engine: sd)
        sc.open(deviceID: "c"); await settle()
        sd.change(.brightness, .number(90)); sd.hold()
        sc.adjustments.resetAdjustments(); await settle()
        precondition(sc.adjustments.isResettingAdjustments)
        sc.close(); sd.release(); await settle()
        precondition(sd.writes.isEmpty && sc.adjustments.controls.isEmpty && !sc.adjustments.isResettingAdjustments)
        print("PASS: manual-first restoration, Auto-last restoration without numeric replay, repeated reset, partial failure, cancellation before stale continuation")
    }
}
