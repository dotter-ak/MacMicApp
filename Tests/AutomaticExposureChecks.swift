import AVFoundation

private final class ExposureDriver: CaptureDriving, @unchecked Sendable {
    @MainActor let previewLayer = AVCaptureVideoPreviewLayer()
    private let lock = NSLock()
    private var callbacks: [@Sendable (AutomaticExposureReading?) -> Void] = []
    private var mode: CameraControlValue = .option(.exposure(.auto))
    private var failWrite = false
    @MainActor init() {}
    func start(deviceID: String, report: @escaping @Sendable (CaptureEvent) -> Void) {}
    func changeMode(_ mode: VideoMode, report: @escaping @Sendable (CaptureEvent) -> Void) {}
    func stop(completion: @escaping @Sendable () -> Void) { completion() }
    func control(_ id: CameraControlID, value: CameraControlValue?, report: @escaping @Sendable (Result<CameraControl, CameraControlError>) -> Void) {
        guard id == .autoExposure || id == .exposure else {
            report(.failure(.invalid("Unsupported in test"))); return
        }
        let (current, failed): (CameraControlValue, Bool) = lock.withLock {
            if id == .autoExposure, let value { mode = value }
            let failed = value != nil && failWrite
            if failed { failWrite = false }
            return (id == .autoExposure ? mode : .number(10000), failed)
        }
        if failed { report(.failure(.invalid("Injected USB write failure"))); return }
        report(.success(CameraControl(id: id, title: id.title,
            kind: id == .autoExposure ? .options([.exposure(.auto), .exposure(.shutterPriority)]) : .numeric(CameraControlRange(minimum: 156, maximum: 40000, step: 1)),
            unit: id == .autoExposure ? .none : .device, access: .writable, dependency: nil,
            value: current, initial: current)))
    }
    func readAutomaticExposure(report: @escaping @Sendable (AutomaticExposureReading?) -> Void) {
        lock.withLock { callbacks.append(report) }
    }
    var reads: Int { lock.withLock { callbacks.count } }
    func failNextWrite() { lock.withLock { failWrite = true } }
    func reply(_ index: Int, _ value: Double?) {
        lock.withLock { callbacks[index] }(value.map { AutomaticExposureReading(value: $0, unit: .device) })
    }
}

@main private struct AutomaticExposureChecks {
    @MainActor static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        preconditionFailure("Timed out")
    }

    @MainActor static func main() async throws {
        let driver = ExposureDriver()
        let adjustments = CameraAdjustments(engine: driver)
        adjustments.activate()
        try await wait { adjustments.canObserveAutomaticExposure && adjustments.busyControls.isEmpty }
        let errors = adjustments.controlErrors
        let task = Task { await adjustments.observeAutomaticExposure(interval: .milliseconds(20)) }
        try await wait { driver.reads == 1 }
        try await Task.sleep(for: .milliseconds(75))
        precondition(driver.reads == 1, "Slow USB must not accumulate requests")
        precondition(adjustments.busyControls.isEmpty && adjustments.controlErrors == errors,
                     "Telemetry must not show the settings spinner or control errors")
        driver.reply(0, 16666)
        try await wait { adjustments.automaticExposureReading?.value == 16666 }
        precondition(adjustments.controls[.exposure]?.initial == .number(10000), "Telemetry must not replace reset baseline")
        try await wait { driver.reads == 2 }
        driver.reply(1, nil)
        try await wait { adjustments.automaticExposureReading == nil }
        try await wait { driver.reads == 3 }
        driver.reply(2, 999999)
        try await Task.sleep(for: .milliseconds(5))
        precondition(adjustments.automaticExposureReading == nil, "Invalid reading must not be displayed")
        try await wait { driver.reads == 4 }
        adjustments.setControl(.autoExposure, value: .option(.exposure(.shutterPriority)))
        await task.value
        driver.reply(3, 24992)
        try await Task.sleep(for: .milliseconds(40))
        precondition(adjustments.automaticExposureReading == nil && driver.reads == 4,
                     "Manual mode must stop telemetry and discard a late Auto value")

        adjustments.setControl(.autoExposure, value: .option(.exposure(.auto)))
        try await wait { adjustments.canObserveAutomaticExposure && adjustments.busyControls.isEmpty }
        let hiddenTask = Task { await adjustments.observeAutomaticExposure(interval: .milliseconds(20)) }
        try await wait { driver.reads == 5 }
        hiddenTask.cancel()
        await hiddenTask.value
        driver.reply(4, 8326)
        try await Task.sleep(for: .milliseconds(40))
        precondition(driver.reads == 5 && adjustments.automaticExposureReading == nil,
                     "Hidden/background view must cancel polling and ignore its last reply")

        driver.failNextWrite()
        adjustments.setControl(.autoExposure, value: .option(.exposure(.shutterPriority)))
        try await wait { adjustments.controlErrors[.autoExposure] != nil }
        precondition(adjustments.controls[.exposure]?.confirmed == false)
        adjustments.loadControl(.autoExposure)
        try await wait { adjustments.controls[.exposure]?.confirmed == true && adjustments.busyControls.isEmpty }
        precondition(adjustments.controls[.autoExposure]?.value == .option(.exposure(.shutterPriority)),
                     "Retry must reread actual mode and unlock the freshly read manual exposure")
        adjustments.setControl(.autoExposure, value: .option(.exposure(.auto)))
        try await wait { adjustments.canObserveAutomaticExposure && adjustments.busyControls.isEmpty }

        let sessionTask = Task { await adjustments.observeAutomaticExposure(interval: .milliseconds(20)) }
        try await wait { driver.reads == 6 }
        adjustments.invalidate()
        driver.reply(5, 6045)
        await sessionTask.value
        precondition(adjustments.automaticExposureReading == nil && adjustments.controls.isEmpty)
        print("PASS: single outstanding read, isolated telemetry, errors/invalid values, unchanged baseline, Manual/collapse/session cancellation, stale replies and Retry after a failed write")
    }
}
