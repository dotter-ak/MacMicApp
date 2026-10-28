import AVFoundation

enum CaptureEvent: Sendable {
    case running(CaptureSnapshot, warning: String? = nil)
    case fps(Double)
    case frameAvailable(Bool)
    case failed(String)
}

protocol CaptureDriving: Sendable {
    @MainActor var previewLayer: AVCaptureVideoPreviewLayer { get }
    func start(deviceID: String, report: @escaping @Sendable (CaptureEvent) -> Void)
    func start(deviceID: String, preferredMode: SavedVideoMode?, report: @escaping @Sendable (CaptureEvent) -> Void)
    func changeMode(_ mode: VideoMode, report: @escaping @Sendable (CaptureEvent) -> Void)
    func control(_ id: CameraControlID, value: CameraControlValue?, report: @escaping @Sendable (Result<CameraControl, CameraControlError>) -> Void)
    func readAutomaticExposure(report: @escaping @Sendable (AutomaticExposureReading?) -> Void)
    func snapshotFrame() throws -> FrameSnapshot
    func stop(completion: @escaping @Sendable () -> Void)
}

// Test drivers and cameras without frame delivery can explicitly report no frame.
extension CaptureDriving {
    func readAutomaticExposure(report: @escaping @Sendable (AutomaticExposureReading?) -> Void) { report(nil) }
    func start(deviceID: String, preferredMode: SavedVideoMode?, report: @escaping @Sendable (CaptureEvent) -> Void) {
        start(deviceID: deviceID, report: report)
    }
    func snapshotFrame() throws -> FrameSnapshot { throw FrameSaveError.noFrame }
}

// Session configuration, observers and start/stop belong exclusively to queue.
// The preview layer is bound once, before any work, and only laid out on main.
// The lock protects only the desired request revision across callers/queue.
final class CaptureEngine: CaptureDriving, @unchecked Sendable {
    private let session: AVCaptureSession
    @MainActor let previewLayer: AVCaptureVideoPreviewLayer
    private let queue = DispatchQueue(label: "local.MacMicApp.capture", qos: .userInitiated)
    private lazy var controlCommands = CameraControlQueue(queue: queue)
    private let frameMonitor = FrameRateMonitor()
    private let requestLock = NSLock()
    private var revision = 0
    private var brightnessBackend: BrightnessControlBackend?
    private var imageBackend: ImageControlBackend?
    private var exposureBackend: ExposureControlBackend?
    private var controlConnection: UVCControlConnection?
    private var observers: [NSObjectProtocol] = []
    #if DEBUG
    private var probe: HardwareProbe?
    private var brightnessProbe: BrightnessProbe?
    private var brightnessTrialScheduled = false
    #endif

    @MainActor
    init() {
        let session = AVCaptureSession()
        self.session = session
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspect
    }

    func start(deviceID: String, report: @escaping @Sendable (CaptureEvent) -> Void) {
        start(deviceID: deviceID, preferredMode: nil, report: report)
    }

    func start(deviceID: String, preferredMode: SavedVideoMode?, report: @escaping @Sendable (CaptureEvent) -> Void) {
        let request = nextRevision()
        #if DEBUG
        let requestedAt = ProcessInfo.processInfo.systemUptime
        #endif
        queue.async { [self] in
            guard isCurrent(request) else { return }
            tearDown()
            guard isCurrent(request) else { return }
            guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
                report(.failed("Camera access is unavailable. Check System Settings → Privacy & Security → Camera."))
                return
            }
            guard let device = AVCaptureDevice(uniqueID: deviceID), device.isConnected else {
                report(.failed("The selected camera is no longer connected. Reconnect it and try again."))
                return
            }

            do {
                let input = try AVCaptureDeviceInput(device: device)
                session.beginConfiguration()
                guard session.canAddInput(input) else {
                    session.commitConfiguration()
                    report(.failed("This camera could not be added to the video session."))
                    return
                }
                session.addInput(input)
                // Preview may still work for devices that reject a data output.
                if session.canAddOutput(frameMonitor.output) { session.addOutput(frameMonitor.output) }
                session.commitConfiguration()
                #if DEBUG
                if HardwareProbe.isEnabled {
                    guard session.outputs.contains(frameMonitor.output) else {
                        throw ModeError.invalid("Cannot add the frame measurement output.")
                    }
                    let probe = HardwareProbe(requestedAt: requestedAt, sampleQueue: frameMonitor.sampleQueue)
                    self.probe = probe
                    frameMonitor.setProbe(probe)
                    try probe.configure(session: session, device: device)
                }
                #endif
                // The diagnostic probe owns explicit test modes. Normal starts
                // use the same checked configuration path as UI changes.
                var useDefault = true
                #if DEBUG
                useDefault = !HardwareProbe.isEnabled || HardwareProbe.measuresUIModes
                #endif
                var startupWarning: String?
                if useDefault {
                    let catalog = Self.snapshot(device).catalog
                    guard let fallback = catalog.preferred() else {
                        throw ModeError.invalid("This camera has no supported video modes.")
                    }
                    let restored = preferredMode?.resolve(in: catalog)
                    if preferredMode != nil && restored == nil {
                        startupWarning = "The saved video mode is unavailable or ambiguous. Using an available mode; see Resolution and FPS."
                    }
                    do { try apply(restored ?? fallback, device: device) }
                    catch {
                        guard restored != nil, restored != fallback else { throw error }
                        try apply(fallback, device: device)
                        startupWarning = "The saved video mode could not start. Using an available mode; see Resolution and FPS."
                    }
                }
                guard isCurrent(request) else { tearDown(); return }
                observeSession(request: request, report: report)
                if !session.isRunning { session.startRunning() }
                guard isCurrent(request) else { tearDown(); return }
                if session.isRunning {
                    let snapshot = Self.snapshot(device)
                    report(.running(snapshot, warning: startupWarning))
                    #if DEBUG
                    probe?.started(device: device, session: session)
                    scheduleProbe(request: request)
                    #endif
                    startFrameMonitor(generation: request, expectedFPS: snapshot.active.fps, report: report)
                } else {
                    tearDown()
                    report(.failed("The camera could not start. Check its connection and try again."))
                }
            } catch {
                tearDown()
                if isCurrent(request) {
                    report(.failed("Could not open the camera. \(error.localizedDescription)"))
                }
            }
        }
    }

    func changeMode(_ mode: VideoMode, report: @escaping @Sendable (CaptureEvent) -> Void) {
        let request = nextRevision()
        queue.async { [self] in
            guard isCurrent(request) else { return }
            controlCommands.cancelAll()
            guard let device = (session.inputs.first as? AVCaptureDeviceInput)?.device, device.isConnected else {
                tearDown()
                report(.failed("The selected camera is no longer connected."))
                return
            }
            #if DEBUG
            brightnessProbe?.restore(reason: "mode-change")
            brightnessProbe = nil
            probe?.prepareForModeChange()
            #endif
            frameMonitor.stop()
            let previous = Self.snapshot(device).active
            removeObservers()
            if session.isRunning { session.stopRunning() }
            #if DEBUG
            if probe != nil && !HardwareProbe.measuresUIModes {
                session.beginConfiguration()
                probe?.restore(session: session)
                probe = nil
                frameMonitor.setProbe(nil)
                session.commitConfiguration()
            }
            #endif
            var warning: String?
            do {
                guard Self.snapshot(device).catalog.supports(mode) else {
                    throw ModeError.invalid("This resolution and frame rate are not supported.")
                }
                try apply(mode, device: device)
            } catch {
                let failure = error.localizedDescription
                guard isCurrent(request) else { return }
                do {
                    try apply(previous, device: device)
                    warning = "Could not change video mode. The previous mode was restored. \(failure)"
                } catch {
                    tearDown()
                    if isCurrent(request) {
                        report(.failed("Could not change or restore the video mode. \(error.localizedDescription)"))
                    }
                    return
                }
            }
            guard isCurrent(request) else { return }
            // A successfully changed mode starts a new adjustments baseline.
            // A failed change that restores the same mode retains the old baseline.
            if Self.snapshot(device).active != previous {
                brightnessBackend = nil
                exposureBackend = nil
                imageBackend = nil
            }
            observeSession(request: request, report: report)
            let snapshot = Self.snapshot(device)
            report(.running(snapshot, warning: warning))
            #if DEBUG
            if HardwareProbe.measuresUIModes {
                probe?.started(device: device, session: session)
                scheduleProbe(request: request)
            }
            #endif
            startFrameMonitor(generation: request, expectedFPS: snapshot.active.fps, report: report)
        }
    }

    private func startFrameMonitor(generation: Int, expectedFPS: Double, report: @escaping @Sendable (CaptureEvent) -> Void) {
        guard isCurrent(generation), session.outputs.contains(frameMonitor.output) else { return }
        frameMonitor.start(generation: generation, expectedFPS: expectedFPS, reportAvailability: { report(.frameAvailable($0)) }) {
            report(.fps($0))
        }
    }

    func snapshotFrame() throws -> FrameSnapshot {
        let request = requestLock.withLock { revision }
        let frame = try frameMonitor.snapshot(generation: request)
        guard isCurrent(request) else { throw FrameSaveError.noFrame }
        return frame
    }

    // Called only on queue, with the stream stopped. The device lock spans
    // commit/start because macOS otherwise renegotiates the requested rate.
    private func apply(_ mode: VideoMode, device: AVCaptureDevice) throws {
        guard device.formats.indices.contains(mode.formatIndex),
              let range = device.formats[mode.formatIndex].videoSupportedFrameRateRanges.first(where: {
                  mode.fps.isFinite && mode.fps > 0 && mode.fps >= $0.minFrameRate && mode.fps <= $0.maxFrameRate
              }) else { throw ModeError.invalid("Unsupported video mode.") }
        let duration = mode.fps == range.maxFrameRate ? range.minFrameDuration
            : mode.fps == range.minFrameRate ? range.maxFrameDuration
            : CMTime(seconds: 1 / mode.fps, preferredTimescale: 1_000_000_000)
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        session.beginConfiguration()
        device.activeFormat = device.formats[mode.formatIndex]
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
        session.commitConfiguration()
        session.startRunning()
        guard session.isRunning, device.activeFormat == device.formats[mode.formatIndex],
              abs(device.activeVideoMinFrameDuration.seconds - duration.seconds) < 0.000001,
              abs(device.activeVideoMaxFrameDuration.seconds - duration.seconds) < 0.000001 else {
            if session.isRunning { session.stopRunning() }
            throw ModeError.invalid("The camera did not accept the requested video mode.")
        }
    }

    private static func snapshot(_ device: AVCaptureDevice) -> CaptureSnapshot {
        let formats = device.formats.enumerated().map { index, format in
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return VideoFormat(index: index, resolution: VideoResolution(width: size.width, height: size.height),
                subtype: CMFormatDescriptionGetMediaSubType(format.formatDescription),
                rates: format.videoSupportedFrameRateRanges.map { VideoRateRange(min: $0.minFrameRate, max: $0.maxFrameRate) })
        }
        let index = device.formats.firstIndex(of: device.activeFormat) ?? -1
        let fps = VideoModeCatalog(formats: formats).canonicalRate(formatIndex: index,
            measuredFPS: 1 / device.activeVideoMinFrameDuration.seconds)
        return CaptureSnapshot(formats: formats, active: VideoMode(formatIndex: index, fps: fps))
    }

    func control(_ id: CameraControlID, value: CameraControlValue?, report: @escaping @Sendable (Result<CameraControl, CameraControlError>) -> Void) {
        let request = requestLock.withLock { revision }
        queue.async { [self] in
            guard isCurrent(request), session.isRunning,
                  let device = (session.inputs.first as? AVCaptureDeviceInput)?.device else { return }
            controlCommands.enqueue(isCurrent: { [self] in isCurrent(request) && session.isRunning }, begin: { [self] in
                if controlConnection == nil { controlConnection = try UVCControlConnection(device: device) }
                guard let connection = controlConnection else {
                    throw CameraControlError.invalid("The camera connection is unavailable.")
                }
                guard isCurrent(request) else {
                    throw CameraControlError.invalid("The camera session changed before the command was sent.")
                }
                let backend: any CameraControlBackend
                if id == .brightness {
                    if brightnessBackend == nil { brightnessBackend = BrightnessControlBackend(transport: connection) }
                    backend = brightnessBackend!
                } else if UVCImageControl(rawValue: id.rawValue) != nil {
                    if imageBackend == nil { imageBackend = ImageControlBackend(transport: connection) }
                    backend = imageBackend!
                } else {
                    if exposureBackend == nil { exposureBackend = ExposureControlBackend(transport: connection) }
                    backend = exposureBackend!
                }
                if let value {
                    return try backend.beginWrite(id, value: value, shouldContinue: { self.isCurrent(request) })
                }
                return .complete(try backend.read(id))
            }, report: report)
        }
    }

    func readAutomaticExposure(report: @escaping @Sendable (AutomaticExposureReading?) -> Void) {
        let request = requestLock.withLock { revision }
        queue.async { [self] in
            // Telemetry never interleaves with a write/confirmation or opens a
            // connection of its own. A busy session simply skips this sample.
            guard isCurrent(request), session.isRunning, controlCommands.isIdle,
                  let exposureBackend else { report(nil); return }
            let reading = try? exposureBackend.readAutomaticExposure()
            report(isCurrent(request) ? reading : nil)
        }
    }

    func stop(completion: @escaping @Sendable () -> Void) {
        _ = nextRevision()
        queue.async { [self] in
            tearDown()
            completion()
        }
    }

    private func observeSession(request: Int, report: @escaping @Sendable (CaptureEvent) -> Void) {
        for name in [AVCaptureSession.runtimeErrorNotification,
                     AVCaptureSession.wasInterruptedNotification,
                     AVCaptureSession.didStopRunningNotification] {
            let token = NotificationCenter.default.addObserver(forName: name, object: session, queue: nil) { [weak self] note in
                let detail = (note.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription
                let message = detail.map { "The camera stopped. \($0)" }
                    ?? "The camera stream was interrupted. Check the connection and try again."
                self?.handleFailure(message, request: request, report: report)
            }
            observers.append(token)
        }
    }

    private func handleFailure(_ message: String, request: Int, report: @escaping @Sendable (CaptureEvent) -> Void) {
        queue.async { [self] in
            guard isCurrent(request), !observers.isEmpty else { return }
            tearDown()
            report(.failed(message))
        }
    }

    #if DEBUG
    private func scheduleProbe(request: Int) {
        guard probe != nil else { return }
        let brightnessEnabled = CommandLine.arguments.contains("--probe-brightness")
        if brightnessEnabled && !brightnessTrialScheduled {
            brightnessTrialScheduled = true
            queue.asyncAfter(deadline: .now() + 5) { [self] in
                guard isCurrent(request), session.isRunning,
                      let device = (session.inputs.first as? AVCaptureDeviceInput)?.device else { return }
                let trial = BrightnessProbe()
                brightnessProbe = trial
                trial.begin(device: device, shouldContinue: { self.isCurrent(request) })
            }
            queue.asyncAfter(deadline: .now() + 65) { [self] in
                guard isCurrent(request) else { return }
                brightnessProbe?.restore(reason: "scheduled")
            }
        }
        queue.asyncAfter(deadline: .now() + (brightnessEnabled ? 75 : 22)) { [self] in
            guard isCurrent(request), session.isRunning,
                  let device = (session.inputs.first as? AVCaptureDeviceInput)?.device else { return }
            probe?.finish(device: device, session: session)
        }
    }
    #endif

    private func removeObservers() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    private func tearDown() {
        controlCommands.cancelAll()
        brightnessBackend = nil
        exposureBackend = nil
        imageBackend = nil
        controlConnection = nil
        #if DEBUG
        brightnessProbe?.restore(reason: "session-stop")
        brightnessProbe = nil
        #endif
        frameMonitor.stop()
        removeObservers()
        if session.isRunning { session.stopRunning() }
        session.beginConfiguration()
        #if DEBUG
        probe?.restore(session: session)
        probe = nil
        frameMonitor.setProbe(nil)
        #endif
        if session.outputs.contains(frameMonitor.output) { session.removeOutput(frameMonitor.output) }
        for input in session.inputs { session.removeInput(input) }
        session.commitConfiguration()
    }

    private func nextRevision() -> Int {
        requestLock.withLock {
            revision += 1
            return revision
        }
    }

    private func isCurrent(_ value: Int) -> Bool {
        requestLock.withLock { revision == value }
    }
}

private enum ModeError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { message } else { nil } }
}
