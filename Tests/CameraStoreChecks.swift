import Foundation

@MainActor
private final class FakeConnectionWatcher: CameraConnectionWatching {
    var receive: (@MainActor (CameraConnectionEvent) -> Void)?
    func start(_ receive: @escaping @MainActor (CameraConnectionEvent) -> Void) { self.receive = receive }
    func stop() { receive = nil }
    func emit(_ event: CameraConnectionEvent) { receive?(event) }
}

private actor FakeCameraProvider: CameraProviding {
    var status: CameraAuthorization
    var available: [CameraDevice]
    var discoveryCount = 0
    var requestCount = 0

    init(status: CameraAuthorization, devices: [CameraDevice] = []) {
        self.status = status
        self.available = devices
    }

    func authorizationStatus() -> CameraAuthorization { status }
    func requestAccess() {
        guard status == .notDetermined else { return }
        requestCount += 1
        status = .authorized
    }
    func devices() -> [CameraDevice] {
        discoveryCount += 1
        return available
    }
    func change(status: CameraAuthorization, devices: [CameraDevice]) {
        self.status = status
        available = devices
    }
}

private actor DelayedCameraProvider: CameraProviding {
    var pending: CheckedContinuation<[CameraDevice], Never>?
    let latest: CameraDevice

    init(latest: CameraDevice) { self.latest = latest }
    func authorizationStatus() -> CameraAuthorization { .authorized }
    func requestAccess() {}
    func devices() async -> [CameraDevice] {
        if pending != nil { return [latest] }
        return await withCheckedContinuation { pending = $0 }
    }
    func waitForFirstDiscovery() async {
        while pending == nil { await Task.yield() }
    }
    func finishOldDiscovery(with device: CameraDevice) {
        pending?.resume(returning: [device])
        pending = nil
    }
}

@main
private struct CameraStoreChecks {
    @MainActor
    static func main() async {
        let microscope = CameraDevice(id: "usb-a", name: "Webcam gadget", kind: .external)
        let second = CameraDevice(id: "usb-b", name: "Webcam gadget", kind: .external)
        let builtIn = CameraDevice(id: "internal", name: "Built-in", kind: .builtIn)
        let phone = CameraDevice(id: "phone", name: "Phone", kind: .continuity)

        for status: CameraAuthorization in [.notDetermined, .denied, .restricted, .unavailable] {
            let provider = FakeCameraProvider(status: status, devices: [microscope])
            let store = CameraStore(provider: provider)
            await store.refresh()
            expect(store.authorization == status, "Permission state must be preserved")
            expect(store.devices.isEmpty && store.selectedDevice == nil, "No devices without authorization")
            let calls = await provider.discoveryCount
            expect(calls == 0, "Discovery must not run without authorization")
            expect(!store.isRefreshing, "Permission-only refresh must finish")
        }

        let provider = FakeCameraProvider(status: .notDetermined, devices: [microscope, builtIn, phone])
        let store = CameraStore(provider: provider)
        await store.requestAccess()
        expect(store.authorization == .authorized && !store.isRequestingAccess, "Permission request must refresh state")
        expect(store.selectedDevice == microscope, "Only the sole external camera may be auto-selected")
        await store.requestAccess()
        let requests = await provider.requestCount
        expect(requests == 1, "An existing permission must not prompt again")

        await provider.change(status: .authorized, devices: [microscope, second])
        await store.refresh()
        expect(store.selectedDevice == microscope, "Keep selection when another device appears")
        expect(store.deviceLabel(microscope) != store.deviceLabel(second), "Duplicate names need distinct labels")
        store.selectDevice(second.id)
        await store.refresh()
        expect(store.selectedDevice == second, "Refresh must preserve explicit selection")
        await provider.change(status: .authorized, devices: [microscope, builtIn])
        await store.refresh()
        expect(store.selectedDevice == nil, "Never replace a missing selected device automatically")
        store.selectDevice("missing")
        expect(store.selectedDevice == nil, "Reject stale picker values")

        for devices in [[builtIn], [phone], [microscope, second]] {
            let unselected = CameraStore(provider: FakeCameraProvider(status: .authorized, devices: devices))
            await unselected.refresh()
            expect(unselected.selectedDevice == nil, "Built-in, Continuity and ambiguous choices must remain manual")
        }

        let emptyProvider = FakeCameraProvider(status: .authorized)
        let emptyStore = CameraStore(provider: emptyProvider)
        await emptyStore.refresh()
        expect(emptyStore.devices.isEmpty && !emptyStore.isRefreshing, "Empty discovery must finish normally")
        await emptyProvider.change(status: .authorized, devices: [microscope])
        await emptyStore.refresh()
        expect(emptyStore.selectedDevice == microscope, "First available external device may be selected after an empty launch")
        await emptyProvider.change(status: .denied, devices: [microscope])
        await emptyStore.refresh()
        expect(emptyStore.devices.isEmpty && emptyStore.selectedDevice == nil, "Permission revocation must clear device state")

        let delayed = DelayedCameraProvider(latest: second)
        let racingStore = CameraStore(provider: delayed)
        let oldRefresh = Task { await racingStore.refresh() }
        await delayed.waitForFirstDiscovery()
        await racingStore.refresh()
        await delayed.finishOldDiscovery(with: microscope)
        _ = await oldRefresh.value
        expect(racingStore.devices == [second] && racingStore.selectedDevice == second,
               "An old discovery result must not replace a newer refresh")
        expect(!racingStore.isRefreshing, "Overlapping refreshes must finish")

        await checkPreferences(microscope: microscope, second: second, builtIn: builtIn)
        await checkReconnect(microscope: microscope, second: second)
        print("PASS: permissions, safe selection, stale refresh, saved camera identity, mode restoration and invalid preferences")
    }

    @MainActor
    static func checkReconnect(microscope: CameraDevice, second: CameraDevice) async {
        let provider = FakeCameraProvider(status: .authorized, devices: [microscope])
        let watcher = FakeConnectionWatcher()
        let store = CameraStore(provider: provider, connectionWatcher: watcher)
        var selections: [String?] = []
        store.startMonitoring { selections.append($0) }
        await store.refresh()
        for _ in 0..<5 {
            // Discovery intentionally still contains the disconnected device.
            watcher.emit(.disconnected(microscope.id))
            expect(store.selectedDevice == nil && selections.last! == nil, "Disconnect must synchronously stop capture")
            await settle()
            expect(store.selectedDevice == nil, "Stale discovery cannot resurrect a disconnected device")
            watcher.emit(.connected(microscope.id))
            await waitUntil { store.selectedDevice == microscope }
            expect(selections.last! == microscope.id, "Reconnect must publish selection directly")
        }
        // Both events in the same main-actor turn still deliver a nil transition.
        watcher.emit(.disconnected(microscope.id))
        watcher.emit(.connected(microscope.id))
        expect(selections.last! == nil, "Fast reconnect must not coalesce away the stop")
        await waitUntil { store.selectedDevice == microscope }

        watcher.emit(.disconnected(microscope.id))
        await provider.change(status: .authorized, devices: [second])
        watcher.emit(.connected(second.id))
        await settle()
        expect(store.selectedDevice == nil, "A different camera must never replace the desired camera")
        await provider.change(status: .authorized, devices: [microscope, second])
        watcher.emit(.connected(microscope.id))
        await settle()
        expect(store.selectedDevice == nil, "Ambiguous reconnection must require selection")
        store.selectDevice(second.id)
        expect(selections.last! == second.id, "Manual choice must replace the reconnect target")
        watcher.emit(.disconnected(second.id))
        store.selectDevice(nil)
        watcher.emit(.connected(second.id))
        await settle()
        expect(store.selectedDevice == nil, "Explicit no-camera selection cancels automatic recovery")

        let oldReceive = watcher.receive
        store.stopMonitoring()
        let count = selections.count
        oldReceive?(.connected(microscope.id))
        await settle()
        expect(selections.count == count, "Closing monitoring must suppress queued events")
        store.startMonitoring { selections.append($0) }
        oldReceive?(.disconnected(microscope.id))
        await provider.change(status: .authorized, devices: [microscope])
        await store.refresh()
        store.selectDevice(microscope.id)
        expect(store.selectedDevice == microscope, "Old observer cannot affect a reopened window")
        store.stopMonitoring()

        let delayed = DelayedCameraProvider(latest: microscope)
        let delayedWatcher = FakeConnectionWatcher()
        let delayedStore = CameraStore(provider: delayed, connectionWatcher: delayedWatcher)
        delayedStore.startMonitoring { _ in }
        let refresh = Task { await delayedStore.refresh() }
        await delayed.waitForFirstDiscovery()
        delayedWatcher.emit(.disconnected(microscope.id))
        await settle()
        await delayed.finishOldDiscovery(with: microscope)
        _ = await refresh.value
        expect(delayedStore.selectedDevice == nil && delayedStore.devices.isEmpty, "Pre-disconnect discovery must be discarded")
        delayedStore.stopMonitoring()
        print("PASS: five reconnect cycles, fast events, stale discovery, ambiguous identity, manual override and observer lifetime")
    }

    @MainActor
    private static func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        fatalError("Timed out waiting for camera discovery")
    }

    private static func settle() async { try? await Task.sleep(for: .milliseconds(20)) }

    @MainActor
    static func checkPreferences(microscope: CameraDevice, second: CameraDevice, builtIn: CameraDevice) async {
        let suite = "MacMicApp.Checks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = CapturePreferences(defaults: defaults)
        let freshProvider = FakeCameraProvider(status: .authorized, devices: [microscope])
        let freshStore = CameraStore(provider: freshProvider, preferences: preferences)
        await freshStore.refresh()
        await freshProvider.change(status: .authorized, devices: [microscope, second])
        await freshStore.refresh()
        expect(freshStore.selectedDevice == microscope, "A newly saved active choice is not a new restoration on each refresh")
        preferences.rememberCamera(microscope)

        let resolution = VideoResolution(width: 1920, height: 1080)
        let rates = [VideoRateRange(min: 15, max: 30)]
        let a = VideoFormat(index: 0, resolution: resolution, subtype: 0x34323076, rates: rates)
        let b = VideoFormat(index: 1, resolution: resolution, subtype: 0x32767579, rates: rates)
        let snapshot = CaptureSnapshot(formats: [a, b], active: VideoMode(formatIndex: 1, fps: 24))
        expect(preferences.rememberMode(snapshot, cameraID: microscope.id), "Save a unique supported mode")
        let reloaded = CapturePreferences(defaults: defaults)
        let saved = reloaded.mode(for: microscope.id)!
        let moved = VideoFormat(index: 7, resolution: resolution, subtype: b.subtype, rates: rates)
        expect(saved.resolve(in: VideoModeCatalog(formats: [moved, a])) == VideoMode(formatIndex: 7, fps: 24),
               "Restore pixel format and custom FPS after indices change")
        expect(saved.resolve(in: VideoModeCatalog(formats: [a])) == nil, "Never substitute the other pixel format")
        expect(saved.resolve(in: VideoModeCatalog(formats: [b, moved])) == nil, "Duplicate signatures are ambiguous")
        let changed = VideoFormat(index: 1, resolution: resolution, subtype: b.subtype, rates: [VideoRateRange(min: 30, max: 30)])
        expect(saved.resolve(in: VideoModeCatalog(formats: [changed])) == nil, "Changed rates must be re-evaluated")
        expect(reloaded.mode(for: second.id) == nil, "Modes are isolated by camera identity")

        let provider = FakeCameraProvider(status: .authorized, devices: [builtIn, second])
        let store = CameraStore(provider: provider, preferences: reloaded)
        await store.refresh()
        expect(store.selectedDevice == nil && store.selectionMessage != nil, "Do not replace a missing saved camera")
        expect(reloaded.camera?.id == microscope.id, "Missing camera must not erase saved selection")
        await provider.change(status: .authorized, devices: [microscope, second])
        await store.refresh()
        expect(store.selectedDevice == nil, "Identical camera names need an explicit choice")
        await provider.change(status: .authorized, devices: [microscope, builtIn])
        await store.refresh()
        expect(store.selectedDevice == microscope, "Restore the exact unique saved camera")

        let renamed = CameraDevice(id: microscope.id, name: "Different device", kind: .external)
        let changedStore = CameraStore(provider: FakeCameraProvider(status: .authorized, devices: [renamed]), preferences: reloaded)
        await changedStore.refresh()
        expect(changedStore.selectedDevice == nil, "An ID with changed identity must not silently restore")

        store.selectDevice(nil)
        let unselected = CapturePreferences(defaults: defaults)
        let noneStore = CameraStore(provider: FakeCameraProvider(status: .authorized, devices: [microscope]), preferences: unselected)
        await noneStore.refresh()
        await noneStore.refresh()
        expect(unselected.hasSelection && noneStore.selectedDevice == nil, "Explicit no-camera selection survives relaunch and refresh")

        defaults.set(Data("invalid".utf8), forKey: "capturePreferences.v1")
        let corrupt = CapturePreferences(defaults: defaults)
        let corruptStore = CameraStore(provider: FakeCameraProvider(status: .authorized, devices: [microscope]), preferences: corrupt)
        await corruptStore.refresh()
        await corruptStore.refresh()
        expect(corruptStore.selectedDevice == nil && corruptStore.selectionMessage != nil, "Corrupt data must not auto-start a camera")
        corruptStore.selectDevice(microscope.id)
        expect(CapturePreferences(defaults: defaults).camera?.id == microscope.id, "Explicit choice repairs corrupt settings")
    }

    static func expect(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
    }
}
