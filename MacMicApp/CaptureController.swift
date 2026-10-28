import AVFoundation
import Observation
import AppKit

enum CaptureState: Equatable {
    case stopped
    case starting
    case changing
    case suspended
    case recovering
    case live
    case failed(String)
}

@MainActor
@Observable
final class CaptureController {
    private(set) var frameAvailable = false
    private(set) var imageOrientation: ImageOrientation
    private(set) var previewZoom = 1.0
    @ObservationIgnored private var zoomScrollRemainder = 0.0
    private(set) var isSavingFrame = false
    private(set) var saveFrameError: String?
    private(set) var captureFolderError: String?
    let captureFolder = CaptureFolderPreferences()
    private(set) var isChoosingCaptureFolder = false
    private(set) var isOpeningCaptureFolder = false
    @ObservationIgnored private var folderPanel: NSOpenPanel?
    @ObservationIgnored private var folderTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var closeTask: Task<Void, Never>?
    @ObservationIgnored private var isShuttingDown = false
    private(set) var state: CaptureState = .stopped
    private(set) var snapshot: CaptureSnapshot?
    let adjustments: CameraAdjustments
    private(set) var actualFPS: Double?
    private(set) var modeWarning: String?
    @ObservationIgnored private let preferences: CapturePreferences?
    @ObservationIgnored private let engine: any CaptureDriving
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var deviceID: String?
    @ObservationIgnored private var windowIsOpen = false
    @ObservationIgnored private var isSleeping = false
    @ObservationIgnored private var powerRevision = 0
    @ObservationIgnored private var automaticRecoveryUsed = false
    @ObservationIgnored private var recoveryTask: Task<Void, Never>?
    @ObservationIgnored private var validateRecovery: (@MainActor (String) async -> Bool)?
    @ObservationIgnored private var refreshAfterWake: (@MainActor () async -> Void)?
    @ObservationIgnored private let recoveryDelay: Duration
    @ObservationIgnored private var frameTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private let frameTimeout: Duration
    @ObservationIgnored private var startupTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private let startupTimeout: Duration

    init(engine: any CaptureDriving = CaptureEngine(), preferences: CapturePreferences? = nil,
         recoveryDelay: Duration = .seconds(1), frameTimeout: Duration = .seconds(5),
         startupTimeout: Duration = .seconds(15)) {
        self.engine = engine
        adjustments = CameraAdjustments(engine: engine)
        self.preferences = preferences
        imageOrientation = ImageOrientation(horizontalFlip: preferences?.horizontalFlip ?? false,
                                            verticalFlip: preferences?.verticalFlip ?? false)
        self.recoveryDelay = recoveryDelay
        self.frameTimeout = frameTimeout
        self.startupTimeout = startupTimeout
    }

    func configureRecovery(validate: @escaping @MainActor (String) async -> Bool,
                           afterWake: @escaping @MainActor () async -> Void) {
        validateRecovery = validate
        refreshAfterWake = afterWake
    }

    func suspendForSleep() {
        guard windowIsOpen else { return }
        powerRevision += 1
        guard !isSleeping else { return }
        isSleeping = true
        invalidate()
        state = .suspended
        engine.stop(completion: {})
    }

    func resumeAfterSleep() async {
        guard windowIsOpen, isSleeping else { return }
        powerRevision += 1
        let wake = powerRevision
        await refreshAfterWake?()
        guard windowIsOpen, isSleeping, powerRevision == wake else { return }
        isSleeping = false
        automaticRecoveryUsed = false
        if deviceID != nil { beginRecovery(message: "The camera could not resume after sleep.") }
        else { invalidate() }
    }

    private func beginRecovery(message: String, delay: Bool = true) {
        guard windowIsOpen, !isSleeping, let id = deviceID else { return }
        invalidate()
        engine.stop(completion: {})
        guard let validateRecovery else { state = .failed(message); return }
        automaticRecoveryUsed = true
        state = .recovering
        let request = revision
        recoveryTask = Task { [weak self, recoveryDelay] in
            if delay {
                do { try await Task.sleep(for: recoveryDelay) } catch { return }
            }
            guard !Task.isCancelled, let self, self.windowIsOpen, !self.isSleeping,
                  self.revision == request else { return }
            let valid = await validateRecovery(id)
            guard !Task.isCancelled, self.windowIsOpen, !self.isSleeping,
                  self.revision == request, self.deviceID == id else { return }
            self.recoveryTask = nil
            if valid { self.start(id) }
            else {
                self.invalidate()
                self.state = .failed("Camera access or identity could not be confirmed. Choose a camera or try Retry.")
            }
        }
        watchStartup()
    }

    var previewLayer: AVCaptureVideoPreviewLayer { engine.previewLayer }

    func scrollPreviewZoom(delta: Double, precise: Bool) {
        guard state == .live, delta.isFinite, delta != 0 else { return }
        let steps: Int
        if precise {
            // Accumulate trackpad motion instead of taking a step for every tiny event.
            if zoomScrollRemainder.sign != delta.sign { zoomScrollRemainder = 0 }
            zoomScrollRemainder += min(1400, max(-1400, delta))
            steps = Int(zoomScrollRemainder / 20)
            zoomScrollRemainder -= Double(steps) * 20
        } else {
            zoomScrollRemainder = 0
            // Mouse acceleration must not turn a wheel event into a larger step.
            steps = delta > 0 ? 1 : -1
        }
        guard steps != 0 else { return }
        let tenths = Int((previewZoom * 10).rounded()) + steps
        previewZoom = Double(min(80, max(10, tenths))) / 10
        if previewZoom == 1 || previewZoom == 8 { zoomScrollRemainder = 0 }
    }

    func setPreviewZoom(_ value: Double) {
        guard state == .live, value.isFinite else { return }
        zoomScrollRemainder = 0
        previewZoom = min(8, max(1, value))
    }

    func resetPreviewZoom() {
        zoomScrollRemainder = 0
        previewZoom = 1
    }

    func setImageOrientation(horizontal: Bool? = nil, vertical: Bool? = nil) {
        if let horizontal { imageOrientation.horizontalFlip = horizontal }
        if let vertical { imageOrientation.verticalFlip = vertical }
        preferences?.rememberOrientation(horizontal: imageOrientation.horizontalFlip,
                                         vertical: imageOrientation.verticalFlip)
    }

    func open(deviceID: String?) {
        guard !isShuttingDown else { return }
        windowIsOpen = true
        selectDevice(deviceID)
    }

    func selectDevice(_ id: String?) {
        guard windowIsOpen else { return }
        guard deviceID != id else { return }
        resetPreviewZoom()
        recoveryTask?.cancel()
        recoveryTask = nil
        automaticRecoveryUsed = false
        deviceID = id
        snapshot = nil
        modeWarning = nil
        actualFPS = nil
        resetSessionState()
        if isSleeping {
            invalidate()
            state = .suspended
            return
        }
        if let id {
            start(id)
        } else {
            invalidate()
            engine.stop(completion: {})
        }
    }

    func retry() {
        guard windowIsOpen, !isSleeping, let deviceID else { return }
        if validateRecovery != nil { beginRecovery(message: "The camera could not restart.", delay: false) }
        else { start(deviceID) }
    }

    func close() {
        guard windowIsOpen else { return }
        windowIsOpen = false
        resetPreviewZoom()
        folderPanel?.cancel(nil)
        folderTask?.cancel()
        endRecoveryLifecycle()
        deviceID = nil
        invalidate()
        // Enqueue stop synchronously, before a possible immediate reopen.
        // A single task lets shutdown await this same stop without repeating it.
        let (completion, continuation) = AsyncStream<Void>.makeStream()
        engine.stop { continuation.finish() }
        closeTask = Task { for await _ in completion {} }
    }

    func shutdown() async {
        isShuttingDown = true
        close()
        // A save owns its completed pixel buffer and can finish after capture stops.
        await saveTask?.value
        await closeTask?.value
    }

    private func start(_ id: String) {
        resetPreviewZoom()
        revision += 1
        let request = revision
        state = .starting
        snapshot = nil
        modeWarning = nil
        actualFPS = nil
        resetSessionState()
        engine.start(deviceID: id, preferredMode: preferences?.mode(for: id), report: handler(request: request))
        watchStartup()
    }

    func selectResolution(_ resolution: VideoResolution) {
        guard let snapshot,
              let mode = snapshot.catalog.preferred(resolution: resolution, preserving: snapshot.active) else { return }
        changeMode(mode)
    }

    func selectFormat(_ index: Int) {
        guard let snapshot, let mode = snapshot.catalog.preferred(formatIndex: index, near: snapshot.active.fps) else { return }
        changeMode(mode)
    }

    func selectFPS(_ fps: Double) {
        guard let snapshot, let resolution = snapshot.resolution,
              let mode = snapshot.catalog.resolve(resolution: resolution, fps: fps, formatIndex: snapshot.active.formatIndex) else { return }
        changeMode(mode)
    }

    func changeMode(_ mode: VideoMode) {
        guard !adjustments.isResettingAdjustments, windowIsOpen, state == .live || state == .changing,
              let snapshot, snapshot.catalog.supports(mode) else { return }
        // During an in-flight change even the old applied mode is a new intent.
        guard state == .changing || mode != snapshot.active else { return }
        revision += 1
        state = .changing
        modeWarning = nil
        actualFPS = nil
        resetSessionState()
        engine.changeMode(mode, report: handler(request: revision))
        watchStartup()
    }

    var canSaveFrame: Bool { state == .live && frameAvailable && !isSavingFrame && !isChoosingCaptureFolder && !isOpeningCaptureFolder }

    func dismissSaveError() { saveFrameError = nil }
    func dismissFolderError() { captureFolderError = nil }

    func openCaptureFolder() {
        guard windowIsOpen, !isOpeningCaptureFolder, !isChoosingCaptureFolder, !isSavingFrame else { return }
        isOpeningCaptureFolder = true
        captureFolderError = nil
        folderTask = Task { [self] in
            defer { isOpeningCaptureFolder = false; folderTask = nil }
            do {
                let directory = try await captureFolder.resolve()
                try Task.checkCancellation()
                try await CaptureFolderIO.shared.prepareDirectory(directory)
                try Task.checkCancellation()
                let scoped = directory.startAccessingSecurityScopedResource()
                defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
                if !NSWorkspace.shared.open(directory) {
                    captureFolderError = "Finder could not open the capture folder."
                }
            } catch is CancellationError {
                // Closing the window cancels pending folder UI actions.
            } catch {
                if !Task.isCancelled {
                    captureFolderError = "Choose the capture folder again in Other settings. " + error.localizedDescription
                }
            }
        }
    }

    func chooseCaptureFolder() {
        guard windowIsOpen, !isChoosingCaptureFolder, !isOpeningCaptureFolder, !isSavingFrame,
              let window = NSApp.keyWindow ?? NSApp.mainWindow, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "Capture Folder"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: captureFolder.path, isDirectory: true)
        folderPanel = panel
        isChoosingCaptureFolder = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.folderPanel = nil
            guard response == .OK, self.windowIsOpen, let url = panel.url else {
                self.isChoosingCaptureFolder = false
                return
            }
            self.captureFolderError = nil
            self.folderTask = Task { [self] in
                defer { isChoosingCaptureFolder = false; folderTask = nil }
                do { try await captureFolder.select(url) }
                catch is CancellationError {}
                catch {
                    if !Task.isCancelled {
                        captureFolderError = "Could not remember the capture folder. " + error.localizedDescription
                    }
                }
            }
        }
    }

    func saveFrame() {
        guard windowIsOpen, canSaveFrame,
              (NSApp.keyWindow ?? NSApp.mainWindow)?.attachedSheet == nil else { return }
        let frame: FrameSnapshot
        do {
            frame = try engine.snapshotFrame()
        }
        catch { saveFrameError = error.localizedDescription; return }
        // Freeze the frame and orientation before asynchronous I/O. Folder
        // controls stay disabled until the selected destination has been used.
        let orientation = imageOrientation
        isSavingFrame = true
        saveFrameError = nil
        saveTask = Task { [self] in
            defer { isSavingFrame = false; saveTask = nil }
            do {
                let directory = try await captureFolder.resolve()
                _ = try await FramePNGEncoder.shared.save(frame, in: directory, orientation: orientation)
            } catch {
                saveFrameError = "Could not save the PNG. Check the Capture Folder in Other settings. " + error.localizedDescription
            }
        }
    }

    private func resetSessionState() {
        startupTimeoutTask?.cancel()
        startupTimeoutTask = nil
        frameTimeoutTask?.cancel()
        frameTimeoutTask = nil
        frameAvailable = false
        adjustments.invalidate()
    }

    private func handler(request: Int) -> @Sendable (CaptureEvent) -> Void {
        { [weak self] event in
            Task { @MainActor in
                guard let self, self.windowIsOpen, self.revision == request else { return }
                switch event {
                case .running(let snapshot, let warning):
                    if self.state == .starting || self.state == .changing {
                        self.startupTimeoutTask?.cancel()
                        self.startupTimeoutTask = nil
                        self.snapshot = snapshot
                        self.modeWarning = warning
                        if warning == nil, let id = self.deviceID, let preferences = self.preferences,
                           !preferences.rememberMode(snapshot, cameraID: id) {
                            self.modeWarning = "This video mode cannot be uniquely identified for the next launch. Choose a mode if needed."
                        }
                        self.state = .live
                        if self.frameTimeoutTask != nil { self.watchFrameDelivery(available: self.frameAvailable) }
                        self.adjustments.activate()
                    }
                case .frameAvailable(let available):
                    if self.state == .live || self.state == .starting || self.state == .changing {
                        self.frameAvailable = available
                        self.watchFrameDelivery(available: available)
                    }
                case .fps(let fps):
                    if self.state == .live, fps.isFinite, fps >= 0 { self.actualFPS = fps }
                case .failed(let message):
                    if self.state == .starting || self.state == .changing || self.state == .live {
                        self.streamFailed(message)
                    }
                }
            }
        }
    }

    private func invalidate() {
        recoveryTask?.cancel()
        recoveryTask = nil
        revision += 1
        state = .stopped
        snapshot = nil
        modeWarning = nil
        actualFPS = nil
        resetSessionState()
    }

    private func endRecoveryLifecycle() {
        powerRevision += 1
        isSleeping = false
        validateRecovery = nil
        refreshAfterWake = nil
    }

    private func streamFailed(_ message: String) {
        if !automaticRecoveryUsed, validateRecovery != nil {
            beginRecovery(message: message)
        } else {
            invalidate()
            state = .failed(message)
        }
    }

    private func watchFrameDelivery(available: Bool) {
        frameTimeoutTask?.cancel()
        frameTimeoutTask = nil
        guard !available, validateRecovery != nil else { return }
        let request = revision
        // Allow at least three frame intervals for legitimately slow modes.
        let timeout = max(frameTimeout, .seconds(3 / max(snapshot?.active.fps ?? 30, 0.000001)))
        frameTimeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self, !Task.isCancelled, self.windowIsOpen, !self.isSleeping,
                  self.revision == request, self.state == .live, !self.frameAvailable else { return }
            self.frameTimeoutTask = nil
            self.engine.stop(completion: {})
            self.streamFailed("The camera stopped delivering frames. Check its connection and try Retry.")
        }
    }

    private func watchStartup() {
        guard validateRecovery != nil else { return }
        let request = revision
        startupTimeoutTask = Task { [weak self, startupTimeout] in
            do { try await Task.sleep(for: startupTimeout) } catch { return }
            guard let self, !Task.isCancelled, self.windowIsOpen, !self.isSleeping,
                  self.revision == request,
                  self.state == .starting || self.state == .changing || self.state == .recovering else { return }
            self.startupTimeoutTask = nil
            self.engine.stop(completion: {})
            self.streamFailed("The camera did not finish starting. Check its connection and try Retry.")
        }
    }
}
