import AVFoundation
import AppKit

private final class FakeCaptureEngine: CaptureDriving, @unchecked Sendable {
    @MainActor let previewLayer = AVCaptureVideoPreviewLayer()
    private let lock = NSLock()
    private var reports: [@Sendable (CaptureEvent) -> Void] = []
    private var requestedIDs: [String] = []
    private var restoredModes: [SavedVideoMode?] = []
    private var stopCount = 0
    private var modeRequests: [VideoMode] = []
    private var heldStops: [@Sendable () -> Void] = []
    private var holdStops = false

    @MainActor init() {}

    func start(deviceID: String, report: @escaping @Sendable (CaptureEvent) -> Void) {
        lock.withLock {
            requestedIDs.append(deviceID)
            reports.append(report)
        }
    }

    func start(deviceID: String, preferredMode: SavedVideoMode?, report: @escaping @Sendable (CaptureEvent) -> Void) {
        lock.withLock { restoredModes.append(preferredMode) }
        start(deviceID: deviceID, report: report)
    }

    func changeMode(_ mode: VideoMode, report: @escaping @Sendable (CaptureEvent) -> Void) {
        lock.withLock { modeRequests.append(mode); reports.append(report) }
    }

    func control(_ id: CameraControlID, value: CameraControlValue?, report: @escaping @Sendable (Result<CameraControl, CameraControlError>) -> Void) {
        report(.success(CameraControl(id: id, title: "Brightness", kind: .numeric(CameraControlRange(minimum: 0, maximum: 100, step: 2)), unit: .device, access: .writable, dependency: nil, value: value ?? .number(60), initial: .number(60))))
    }

    func stop(completion: @escaping @Sendable () -> Void) {
        let hold = lock.withLock {
            stopCount += 1
            if holdStops { heldStops.append(completion) }
            return holdStops
        }
        if !hold { completion() }
    }

    func emit(_ event: CaptureEvent, request: Int) {
        let report = lock.withLock { reports[request] }
        report(event)
    }

    var requestedModes: [VideoMode] { lock.withLock { modeRequests } }
    var preferredModes: [SavedVideoMode?] { lock.withLock { restoredModes } }
    var starts: [String] { lock.withLock { requestedIDs } }
    var stops: Int { lock.withLock { stopCount } }
    var pendingStopCount: Int { lock.withLock { heldStops.count } }
    func holdShutdown() { lock.withLock { holdStops = true } }
    func finishShutdown() {
        let completions = lock.withLock {
            let result = heldStops
            heldStops.removeAll()
            holdStops = false
            return result
        }
        completions.forEach { $0() }
    }
}

@main
private struct CaptureControllerChecks {
    static let sample = CaptureSnapshot(formats: [
        VideoFormat(index: 0, resolution: VideoResolution(width: 1920, height: 1080), subtype: 0x34323076,
                    rates: [VideoRateRange(min: 10, max: 30)])
    ], active: VideoMode(formatIndex: 0, fps: 30))

    @MainActor
    static func main() async {
        checkPreviewGeometry()
        await checkIdempotentClosing()
        let engine = FakeCaptureEngine()
        let capture = CaptureController(engine: engine)
        capture.selectDevice("a")
        expect(engine.starts.isEmpty, "A closed window must not start capture")
        capture.open(deviceID: nil)
        expect(capture.state == .stopped && engine.starts.isEmpty, "No camera means stopped")

        capture.selectDevice("a")
        expect(capture.state == .starting && engine.starts == ["a"], "Selection must start once")
        capture.selectDevice("a")
        capture.open(deviceID: "a")
        expect(engine.starts == ["a"], "Repeated activation must not restart the same device")
        engine.emit(.running(sample), request: 0)
        await waitUntil { capture.state == .live }

        capture.scrollPreviewZoom(delta: 3, precise: false)
        expect(capture.previewZoom == 1.1, "Wheel up must add exactly 0.1x")
        capture.scrollPreviewZoom(delta: -3, precise: false)
        expect(abs(capture.previewZoom - 1) < 0.000001, "Opposite wheel deltas undo zoom")
        capture.scrollPreviewZoom(delta: 5, precise: true)
        expect(capture.previewZoom == 1, "Tiny trackpad events accumulate without a jump")
        capture.scrollPreviewZoom(delta: 15, precise: true)
        expect(capture.previewZoom == 1.1, "Accumulated trackpad motion takes a 0.1x step")
        capture.scrollPreviewZoom(delta: 1e6, precise: false)
        expect(capture.previewZoom == 1.2, "Accelerated wheel input still takes only one step")
        capture.setPreviewZoom(4)
        capture.scrollPreviewZoom(delta: 1, precise: false)
        expect(capture.previewZoom == 4.1, "Zoom step remains 0.1x at high magnification")
        for _ in 0..<100 { capture.scrollPreviewZoom(delta: 1, precise: false) }
        expect(capture.previewZoom == 8, "Zoom is bounded at 8x")
        capture.scrollPreviewZoom(delta: .nan, precise: true)
        expect(capture.previewZoom == 8, "Invalid scroll data must not corrupt zoom")
        expect(engine.starts == ["a"] && engine.stops == 0 && engine.requestedModes.isEmpty,
               "Preview zoom must not reconfigure capture")
        capture.resetPreviewZoom()
        expect(capture.previewZoom == 1, "Click reset returns to 1x")
        capture.scrollPreviewZoom(delta: -100, precise: false)
        expect(capture.previewZoom == 1, "Cannot zoom out below fit-to-view")
        capture.scrollPreviewZoom(delta: 3, precise: false)

        capture.selectDevice("b")
        expect(capture.previewZoom == 1, "A new camera session resets zoom")
        expect(capture.state == .starting, "Switching must hide the old live state immediately")
        engine.emit(.failed("old failure"), request: 0)
        engine.emit(.running(sample), request: 1)
        await waitUntil { capture.state == .live }
        engine.emit(.failed("disconnected"), request: 1)
        await waitUntil { capture.state == .failed("disconnected") }
        engine.emit(.running(sample), request: 1)
        await settle()
        expect(capture.state == .failed("disconnected"), "A late start must not erase a failure")
        capture.selectDevice("b")
        expect(engine.starts.count == 2, "Refresh must not silently retry failures")
        capture.retry()
        expect(engine.starts == ["a", "b", "b"] && capture.state == .starting, "Retry must create a new request")

        capture.close()
        expect(capture.state == .stopped && engine.stops == 1, "Closing must stop capture")
        capture.scrollPreviewZoom(delta: 100, precise: false)
        expect(capture.previewZoom == 1, "Scrolling without live video must not change zoom")
        engine.emit(.running(sample), request: 2)
        capture.selectDevice("a")
        capture.retry()
        await settle()
        expect(capture.state == .stopped && engine.starts.count == 3,
               "Close during startup must ignore completion and later refreshes")

        capture.open(deviceID: "a")
        expect(engine.starts.count == 4, "Reopening must start a new session")
        capture.selectDevice(nil)
        expect(capture.state == .stopped && engine.stops == 2, "Deselecting must release the camera")
        engine.emit(.running(sample), request: 3)
        await settle()
        expect(capture.state == .stopped, "A deselected camera must not return to Live")

        capture.selectDevice("a")
        engine.emit(.running(sample), request: 4)
        await waitUntil { capture.state == .live }
        engine.holdShutdown()
        var shutdownFinished = false
        let shutdown = Task {
            await capture.shutdown()
            shutdownFinished = true
        }
        await waitUntil { engine.pendingStopCount == 1 }
        expect(!shutdownFinished && capture.state == .stopped,
               "App termination must wait until the backend releases the camera")
        engine.emit(.failed("late shutdown error"), request: 4)
        engine.finishShutdown()
        await shutdown.value
        await settle()
        expect(shutdownFinished && capture.state == .stopped, "Shutdown must finish without stale updates")
        let modeEngine = FakeCaptureEngine()
        let modes = CaptureController(engine: modeEngine)
        modes.open(deviceID: "a")
        modeEngine.emit(.running(sample), request: 0)
        await waitUntil { modes.state == .live }
        modeEngine.emit(.fps(29.8), request: 0)
        await waitUntil { modes.actualFPS == 29.8 }
        modes.selectFPS(500)
        expect(modes.state == .live, "Unsupported combinations must not start a change")
        modes.selectFPS(15)
        expect(modes.state == .changing && modes.snapshot == sample, "Only confirmed modes may be displayed")
        expect(modes.actualFPS == nil, "Changing mode must clear FPS")
        modeEngine.emit(.fps(30), request: 0)
        modes.selectFPS(10)
        let slower = CaptureSnapshot(formats: sample.formats, active: VideoMode(formatIndex: 0, fps: 10))
        modeEngine.emit(.running(sample, warning: "stale"), request: 1)
        await settle()
        expect(modes.state == .changing && modes.modeWarning == nil, "Stale mode completion must be ignored")
        modeEngine.emit(.running(slower), request: 2)
        await waitUntil { modes.state == .live }
        expect(modes.actualFPS == nil, "Old FPS must not appear in the new mode")
        modeEngine.emit(.fps(9.9), request: 2)
        await waitUntil { modes.actualFPS == 9.9 }
        modeEngine.emit(.fps(.nan), request: 2)
        await settle()
        expect(modes.actualFPS == 9.9, "Invalid telemetry must be ignored")
        expect(modes.snapshot == slower, "Confirmed mode must replace the old snapshot")
        modes.selectFPS(30)
        modeEngine.emit(.running(slower, warning: "restored"), request: 3)
        await waitUntil { modes.state == .live }
        expect(modes.snapshot == slower && modes.modeWarning == "restored", "Rollback must display the actual restored mode")
        modes.selectFPS(15)
        modes.close()
        modeEngine.emit(.running(sample), request: 4)
        modeEngine.emit(.fps(15), request: 4)
        await settle()
        expect(modes.state == .stopped && modes.snapshot == nil && modes.actualFPS == nil, "Close must invalidate pending mode changes")
        let formatEngine = FakeCaptureEngine()
        let formatCapture = CaptureController(engine: formatEngine)
        let alternative = VideoFormat(index: 1, resolution: sample.formats[0].resolution,
            subtype: 0x32767579, rates: [VideoRateRange(min: 10, max: 30)])
        let pair = sample.formats + [alternative]
        formatCapture.open(deviceID: "a")
        formatEngine.emit(.running(CaptureSnapshot(formats: pair, active: sample.active)), request: 0)
        await waitUntil { formatCapture.state == .live }
        formatCapture.selectFormat(1)
        expect(formatEngine.requestedModes.last == VideoMode(formatIndex: 1, fps: 30), "Format selection must not prefer 420v over an explicit choice")
        formatEngine.emit(.running(CaptureSnapshot(formats: pair, active: VideoMode(formatIndex: 1, fps: 30))), request: 1)
        await waitUntil { formatCapture.state == .live }
        formatCapture.selectFPS(15)
        expect(formatEngine.requestedModes.last == VideoMode(formatIndex: 1, fps: 15), "FPS selection must retain the chosen pixel format")
        formatCapture.close()
        await checkReconnect()
        await checkRecovery()
        print("PASS: controller selects 2vuy and retains it when FPS changes")
        print("PASS: mode validation, rapid changes, stale completion, rollback and close during change")
        print("PASS: start/live/error/retry, duplicate requests, device switch, close during start, reopen, deselect and awaited shutdown")
    }

    @MainActor
    private static func checkPreviewGeometry() {
        _ = NSApplication.shared
        var resets = 0
        var closeNotifications = 0
        let video = AVCaptureVideoPreviewLayer()
        let view = PreviewView(previewLayer: video, onClose: { closeNotifications += 1 }, onCapture: {}, onResetZoom: { resets += 1 }, onZoomInterrupted: { _ in }, onScroll: { _, _ in })
        view.frame = CGRect(x: 0, y: 0, width: 500, height: 300)
        view.layout()
        view.setPresentation(orientation: .init(horizontalFlip: true, verticalFlip: true), zoom: 4)
        expect(view.layer?.masksToBounds == true, "Zoom must be clipped to the preview")
        expect(video.affineTransform().a == -4 && video.affineTransform().d == -4,
               "Zoom composes with both flips")
        view.frame = CGRect(x: 0, y: 0, width: 700, height: 400)
        view.layout()
        expect(video.bounds.size == CGSize(width: 700, height: 400) && video.position == CGPoint(x: 350, y: 200),
               "Resizing a zoomed/flipped preview preserves centered geometry")
        view.setPresentation(orientation: .init(horizontalFlip: true), zoom: 1)
        expect(video.affineTransform().a == -1 && video.affineTransform().d == 1,
               "Reset zoom preserves the selected flip")
        let cursor = CGPoint(x: 140, y: 130)
        func imagePoint() -> CGPoint {
            let offset = CGPoint(x: cursor.x - video.position.x, y: cursor.y - video.position.y)
                .applying(video.affineTransform().inverted())
            return CGPoint(x: offset.x + video.bounds.midX, y: offset.y + video.bounds.midY)
        }
        for horizontal in [false, true] { for vertical in [false, true] {
            let flip = ImageOrientation(horizontalFlip: horizontal, verticalFlip: vertical)
            view.setPresentation(orientation: flip, zoom: 1, animated: false)
            let original = imagePoint()
            for zoom in [2.0, 3.0, 1.5] {
                view.setPresentation(orientation: flip, zoom: zoom, anchor: cursor, animated: false)
                let actual = imagePoint()
                expect(abs(actual.x - original.x) < 0.00001 && abs(actual.y - original.y) < 0.00001,
                       "The same image point stays under the cursor for zoom in/out with any flip")
            }
            view.setPresentation(orientation: flip, zoom: 1, animated: false)
            expect(video.position == CGPoint(x: 350, y: 200), "Reset must recenter as well as rescale")
        } }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 700, height: 400),
                              styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false // The test retains and inspects the window after close.
        window.contentView = view
        view.layout()
        view.setPresentation(orientation: .init(), zoom: 1, animated: false)
        view.setPresentation(orientation: .init(), zoom: 2, anchor: cursor)
        expect(video.animation(forKey: "previewZoom") is CAAnimationGroup,
               "Visible zoom uses a native animation")
        video.removeAllAnimations()
        let click = NSEvent.mouseEvent(with: .leftMouseDown, location: cursor, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 2, pressure: 1)!
        view.mouseDown(with: click)
        expect(resets == 1, "Double click on the image invokes zoom reset")
        view.setPresentation(orientation: .init(), zoom: 1, animated: false)
        expect(video.animation(forKey: "previewZoom") == nil, "Reduced-motion update has no animation")
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                              windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                              clickCount: 1, pressure: 1)!
        }
        for horizontal in [false, true] { for vertical in [false, true] {
            let flip = ImageOrientation(horizontalFlip: horizontal, verticalFlip: vertical)
            view.setPresentation(orientation: flip, zoom: 1, animated: false)
            view.setPresentation(orientation: flip, zoom: 2, animated: false)
            view.mouseDown(with: mouse(.leftMouseDown, cursor))
            view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: cursor.x + 50, y: cursor.y + 30)))
            expect(video.position == CGPoint(x: 400, y: 230), "Dragging follows the mouse in screen space regardless of flips")
            let farPoint = CGPoint(x: cursor.x + 10000, y: cursor.y + 10000)
            view.mouseDragged(with: mouse(.leftMouseDragged, farPoint))
            expect(video.position == CGPoint(x: 700, y: 400), "Dragging cannot expose space outside the image")
            let reverse = CGPoint(x: farPoint.x - 10, y: farPoint.y - 10)
            view.mouseDragged(with: mouse(.leftMouseDragged, reverse))
            expect(video.position == CGPoint(x: 690, y: 390), "Reversing at an edge responds immediately")
            view.mouseUp(with: mouse(.leftMouseUp, reverse))
            view.mouseDragged(with: mouse(.leftMouseDragged, cursor))
            expect(video.position == CGPoint(x: 690, y: 390), "Mouse up ends panning")
        } }
        view.setPresentation(orientation: .init(), zoom: 1, animated: false)
        view.mouseDown(with: mouse(.leftMouseDown, cursor))
        view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: cursor.x + 50, y: cursor.y + 30)))
        expect(video.position == CGPoint(x: 350, y: 200), "Fit-to-view does not pan")
        window.close()
        expect(closeNotifications == 1, "Native window closure signals its owner")
        view.detach()
        view.detach()
        expect(closeNotifications == 1 && video.superlayer == nil,
               "Dismantling only cleans preview resources; it does not close the session again")
        window.contentView = nil
        print("PASS: cursor anchoring, resize, animation, double-click reset and bounded mouse panning with all flips")
    }

    @MainActor
    private static func checkIdempotentClosing() async {
        let engine = FakeCaptureEngine()
        let capture = CaptureController(engine: engine)
        capture.close()
        expect(engine.stops == 0, "Closing a never-opened window does nothing")
        capture.open(deviceID: "a")
        engine.emit(.running(sample), request: 0)
        await waitUntil { capture.state == .live }
        engine.holdShutdown()
        capture.close()
        capture.close()
        capture.close()
        expect(engine.stops == 1 && engine.pendingStopCount == 1,
               "Window notification and disappearance must share one stop")
        var finished = 0
        let first = Task { await capture.shutdown(); finished += 1 }
        let second = Task { await capture.shutdown(); finished += 1 }
        await settle()
        expect(finished == 0 && engine.stops == 1,
               "Concurrent termination waits for the already pending stop")
        capture.open(deviceID: "a")
        expect(engine.starts.count == 1, "Termination must prevent reopening")
        engine.emit(.running(sample), request: 0)
        engine.finishShutdown()
        await first.value
        await second.value
        expect(finished == 2 && capture.state == .stopped && engine.stops == 1,
               "Both termination callers complete after the same teardown")
        await capture.shutdown()
        expect(engine.stops == 1, "Completed shutdown must not stop again")

        let reopenedEngine = FakeCaptureEngine()
        let reopened = CaptureController(engine: reopenedEngine)
        reopened.open(deviceID: "a")
        reopenedEngine.holdShutdown()
        reopened.close()
        expect(reopenedEngine.stops == 1, "Stop must be enqueued synchronously")
        reopened.open(deviceID: "a")
        expect(reopenedEngine.starts.count == 2, "A normal window close permits reopening")
        reopenedEngine.emit(.running(sample), request: 1)
        await waitUntil { reopened.state == .live }
        reopenedEngine.finishShutdown()
        await settle()
        expect(reopened.state == .live && reopenedEngine.stops == 1,
               "Completion of the old stop must not invalidate the new session")
        reopened.close()
        reopened.close()
        expect(reopenedEngine.stops == 2, "The new window lifetime gets exactly one close")
        await reopened.shutdown()
        expect(reopenedEngine.stops == 2, "Shutdown reuses the most recent close")
        print("PASS: duplicate close, shared pending/completed shutdown, stale replies and immediate reopen")
    }

    @MainActor
    private static func checkRecovery() async {
        let engine = FakeCaptureEngine()
        let capture = CaptureController(engine: engine, recoveryDelay: .zero)
        var validations = 0
        var wakeRefreshes = 0
        capture.configureRecovery(validate: { id in validations += 1; return id == "a" },
                                  afterWake: { wakeRefreshes += 1 })
        capture.open(deviceID: "a")
        engine.emit(.running(sample), request: 0)
        await waitUntil { capture.state == .live }
        for cycle in 1...3 {
            capture.suspendForSleep()
            expect(capture.state == .suspended && capture.snapshot == nil && capture.adjustments.controls.isEmpty,
                   "Sleep must clear preview and controls")
            capture.selectDevice("b")
            capture.selectDevice("a")
            expect(engine.starts.count == cycle, "Discovery changes during sleep must not start capture")
            engine.emit(.running(sample), request: cycle - 1)
            await capture.resumeAfterSleep()
            await waitUntil { engine.starts.count == cycle + 1 }
            engine.emit(.running(sample), request: cycle)
            await waitUntil { capture.state == .live }
        }
        expect(validations == 3 && wakeRefreshes == 3, "Every wake must revalidate access and discovery")
        capture.suspendForSleep()
        capture.close()
        await capture.resumeAfterSleep()
        expect(engine.starts.count == 4, "Wake after closing must not start capture")

        let failingEngine = FakeCaptureEngine()
        let failing = CaptureController(engine: failingEngine, recoveryDelay: .zero, frameTimeout: .milliseconds(20))
        failing.configureRecovery(validate: { _ in true }, afterWake: {})
        failing.open(deviceID: "a")
        failingEngine.emit(.failed("interrupted"), request: 0)
        await waitUntil { failingEngine.starts.count == 2 }
        failingEngine.emit(.failed("still unavailable"), request: 1)
        await waitUntil { failing.state == .failed("still unavailable") }
        await settle()
        expect(failingEngine.starts.count == 2, "A failed recovery must not create a retry loop")
        failing.retry()
        await waitUntil { failingEngine.starts.count == 3 }
        failingEngine.emit(.running(sample), request: 2)
        await waitUntil { failing.state == .live }
        failingEngine.emit(.frameAvailable(false), request: 2)
        await waitUntil { if case .failed = failing.state { return true }; return false }
        expect(failingEngine.starts.count == 3, "No-frame timeout must retain the recovery budget")
        failing.close()

        let blockedEngine = FakeCaptureEngine()
        let blocked = CaptureController(engine: blockedEngine, recoveryDelay: .zero)
        blocked.configureRecovery(validate: { _ in false }, afterWake: {})
        blocked.open(deviceID: "a")
        blockedEngine.emit(.failed("lost"), request: 0)
        await waitUntil { if case .failed = blocked.state { return true }; return false }
        expect(blockedEngine.starts.count == 1, "Failed identity/access validation cannot open a camera")
        blocked.close()

        let closingEngine = FakeCaptureEngine()
        let closing = CaptureController(engine: closingEngine, recoveryDelay: .zero)
        var enteredValidation = false
        closing.configureRecovery(validate: { _ in
            enteredValidation = true
            try? await Task.sleep(for: .milliseconds(50))
            return true
        }, afterWake: {})
        closing.open(deviceID: "a")
        closingEngine.emit(.failed("lost"), request: 0)
        await waitUntil { enteredValidation }
        closing.close()
        await settle()
        expect(closing.state == .stopped && closingEngine.starts.count == 1, "Closing cancels pending recovery validation")

        let sleepingEngine = FakeCaptureEngine()
        let sleeping = CaptureController(engine: sleepingEngine, recoveryDelay: .zero)
        sleeping.configureRecovery(validate: { _ in true }, afterWake: { sleeping.suspendForSleep() })
        sleeping.open(deviceID: "a")
        sleeping.suspendForSleep()
        await sleeping.resumeAfterSleep()
        expect(sleeping.state == .suspended && sleepingEngine.starts.count == 1,
               "A newer sleep must invalidate an in-flight wake")
        sleeping.close()
        let timeoutEngine = FakeCaptureEngine()
        let timeout = CaptureController(engine: timeoutEngine, recoveryDelay: .zero, startupTimeout: .milliseconds(20))
        timeout.configureRecovery(validate: { _ in true }, afterWake: {})
        timeout.open(deviceID: "a")
        await waitUntil { if case .failed = timeout.state { return true }; return false }
        expect(timeoutEngine.starts.count == 2, "A silent startup must time out after one recovery attempt")
        timeoutEngine.emit(.running(sample), request: 1)
        await settle()
        expect(timeout.snapshot == nil, "A timed-out startup cannot restore a stale live session")
        timeout.close()
        print("PASS: three sleep cycles, fresh validation, bounded recovery, frame timeout, denied recovery and close/wake races")
    }

    @MainActor
    private static func checkReconnect() async {
        let suite = "MacMicApp.ReconnectChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = CapturePreferences(defaults: defaults)
        let engine = FakeCaptureEngine()
        let capture = CaptureController(engine: engine, preferences: preferences)
        capture.open(deviceID: "a")
        engine.emit(.running(sample), request: 0)
        await waitUntil { capture.state == .live }
        expect(capture.imageOrientation == .init(), "Flips default to off")
        capture.setImageOrientation(horizontal: true)
        capture.setImageOrientation(vertical: true)
        capture.setImageOrientation(horizontal: false)
        expect(capture.imageOrientation == ImageOrientation(horizontalFlip: false, verticalFlip: true),
               "Each flip is independent")
        expect(engine.starts == ["a"] && engine.stops == 0 && engine.requestedModes.isEmpty,
               "Changing orientation must not restart the camera or change its mode")
        let restored = CaptureController(engine: FakeCaptureEngine(), preferences: CapturePreferences(defaults: defaults))
        expect(restored.imageOrientation == capture.imageOrientation, "Orientation survives controller recreation")
        capture.scrollPreviewZoom(delta: 5, precise: false)
        let newSession = CaptureController(engine: FakeCaptureEngine(), preferences: CapturePreferences(defaults: defaults))
        expect(capture.previewZoom > 1 && newSession.previewZoom == 1, "Zoom must not persist in preferences")
        capture.selectFPS(15)
        let selected = CaptureSnapshot(formats: sample.formats, active: VideoMode(formatIndex: 0, fps: 15))
        engine.emit(.running(selected), request: 1)
        await waitUntil { capture.state == .live }
        engine.emit(.frameAvailable(true), request: 1)
        await waitUntil { capture.frameAvailable }
        capture.selectFPS(10)
        capture.selectDevice(nil)
        expect(capture.state == .stopped && capture.snapshot == nil && !capture.frameAvailable
               && capture.adjustments.controls.isEmpty && capture.adjustments.busyControls.isEmpty,
               "Disconnect during a mode change clears live state, frames and adjustments")
        capture.selectDevice("a")
        capture.selectDevice("a")
        expect(engine.starts == ["a", "a"] && engine.stops == 1, "Fast same-ID reconnect must stop once and start once")
        expect(engine.preferredModes.last!?.fps == 15, "Reconnect restores the last confirmed mode, not the in-flight request")
        engine.emit(.running(sample), request: 2)
        engine.emit(.frameAvailable(true), request: 1)
        engine.emit(.fps(30), request: 1)
        await settle()
        expect(capture.state == .starting && !capture.frameAvailable && capture.actualFPS == nil,
               "Old session events cannot revive live state or frames")
        engine.emit(.running(selected), request: 3)
        await waitUntil { capture.state == .live && !capture.adjustments.controls.isEmpty }
        expect(capture.snapshot == selected, "Reconnect rereads the format and adjustments")
        capture.close()
        capture.selectDevice("a")
        expect(engine.starts.count == 2, "Reconnection cannot restart a closed window")
        print("PASS: disconnect during mode change, restored confirmed FPS, fresh adjustments and stale session rejection")
    }

    @MainActor
    private static func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        fatalError("Timed out waiting for state transition")
    }

    private static func settle() async {
        try? await Task.sleep(for: .milliseconds(20))
    }

    private static func expect(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
    }
}
