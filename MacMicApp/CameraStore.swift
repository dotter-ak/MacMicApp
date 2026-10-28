import Observation

@MainActor
@Observable
final class CameraStore {
    private(set) var selectionMessage: String?
    private(set) var authorization: CameraAuthorization = .checking
    private(set) var devices: [CameraDevice] = []
    private(set) var selection = CameraSelection()
    private(set) var isRefreshing = false
    private(set) var isRequestingAccess = false

    @ObservationIgnored private let provider: any CameraProviding
    @ObservationIgnored private let preferences: CapturePreferences?
    @ObservationIgnored private let connectionWatcher: any CameraConnectionWatching
    @ObservationIgnored private var selectionChanged: (@MainActor (String?) -> Void)?
    @ObservationIgnored private var connectionRefresh: Task<Void, Never>?
    @ObservationIgnored private var disconnectedIDs: Set<String> = []
    @ObservationIgnored private var reconnectCamera: SavedCamera?
    @ObservationIgnored private var monitoringRevision = 0
    @ObservationIgnored private var resolvedSavedSelection = false
    @ObservationIgnored private var refreshRevision = 0

    init(provider: any CameraProviding = SystemCameraProvider(), preferences: CapturePreferences? = nil,
         connectionWatcher: any CameraConnectionWatching = SystemCameraConnectionWatcher()) {
        self.provider = provider
        self.preferences = preferences
        self.connectionWatcher = connectionWatcher
    }

    func startMonitoring(selectionChanged: @escaping @MainActor (String?) -> Void) {
        stopMonitoring()
        self.selectionChanged = selectionChanged
        disconnectedIDs.removeAll()
        let revision = monitoringRevision
        connectionWatcher.start { [weak self] event in
            guard let self, self.monitoringRevision == revision else { return }
            self.connectionChanged(event)
        }
    }

    func stopMonitoring() {
        monitoringRevision += 1
        selectionChanged = nil
        connectionWatcher.stop()
        connectionRefresh?.cancel()
        connectionRefresh = nil
        refreshRevision += 1
        isRefreshing = false
    }

    private func publishSelection() {
        selectionChanged?(authorization == .authorized ? selection.deviceID : nil)
    }

    private func connectionChanged(_ event: CameraConnectionEvent) {
        guard selectionChanged != nil else { return }
        // Invalidate discovery before removing the device. An older response
        // must never bring it back while the connect notification is pending.
        refreshRevision += 1
        connectionRefresh?.cancel()
        switch event {
        case .disconnected(let id):
            disconnectedIDs.insert(id)
            if let selectedDevice, selectedDevice.id == id {
                reconnectCamera = SavedCamera(selectedDevice)
                selection.select(nil, devices: [])
                selectionMessage = "Camera disconnected. Waiting for it to reconnect."
                // Deliver directly: SwiftUI may coalesce a fast nil → same-ID change.
                publishSelection()
            }
            devices.removeAll { $0.id == id }
        case .connected(let id):
            disconnectedIDs.remove(id)
        }
        connectionRefresh = Task { [weak self] in
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    var selectedDevice: CameraDevice? {
        devices.first { $0.id == selection.deviceID }
    }

    func selectDevice(_ id: String?) {
        guard id == nil || devices.filter({ $0.id == id }).count == 1 else { return }
        selection.select(id, devices: devices)
        reconnectCamera = nil
        resolvedSavedSelection = true
        selectionMessage = nil
        preferences?.rememberCamera(selectedDevice)
        publishSelection()
    }

    func deviceLabel(_ device: CameraDevice) -> String {
        let sameName = devices.filter { $0.name == device.name }
        guard sameName.count > 1,
              let index = sameName.firstIndex(where: { $0.id == device.id }) else {
            return device.name
        }
        return "\(device.name) (\(index + 1))"
    }

    @discardableResult
    func refresh() async -> Bool {
        refreshRevision += 1
        let revision = refreshRevision
        isRefreshing = true

        let status = await provider.authorizationStatus()
        guard revision == refreshRevision else { return false }
        authorization = status
        if status != .authorized {
            if let selectedDevice { reconnectCamera = SavedCamera(selectedDevice) }
            devices = []
            selection.update(devices: [])
            isRefreshing = false
            publishSelection()
            return true
        }

        let discovered = await provider.devices()
        guard revision == refreshRevision else { return false }
        let found = discovered.filter { !disconnectedIDs.contains($0.id) }
        if let selectedDevice, !found.contains(selectedDevice) {
            reconnectCamera = SavedCamera(selectedDevice)
            selection.select(nil, devices: [])
            publishSelection()
        }
        devices = found
        restoreSelection(devices: found)
        isRefreshing = false
        publishSelection()
        return true
    }

    private func restoreSelection(devices found: [CameraDevice]) {
        if let saved = reconnectCamera {
            let matches = found.filter { saved.matches($0) }
            let sameName = found.filter { $0.name == saved.name && $0.kind.rawValue == saved.kind }
            guard matches.count == 1, sameName.count == 1 else {
                selectionMessage = matches.isEmpty
                    ? "Camera disconnected or its identity changed. Reconnect it or choose a camera."
                    : "Several matching cameras are connected. Choose the camera to use."
                return
            }
            selection.select(matches[0].id, devices: found)
            reconnectCamera = nil
            selectionMessage = nil
            return
        }
        if !resolvedSavedSelection, let preferences, preferences.hasSelection {
            selection.select(nil, devices: found)
            guard let saved = preferences.camera else {
                selectionMessage = preferences.loadWarning
                resolvedSavedSelection = true
                return
            }
            let matches = found.filter { saved.matches($0) }
            let sameName = found.filter { $0.name == saved.name && $0.kind.rawValue == saved.kind }
            guard matches.count == 1, sameName.count == 1 else {
                selectionMessage = matches.isEmpty
                    ? "The saved camera is unavailable or its identity changed. Connect it or choose a camera."
                    : "Several matching cameras are connected. Choose the camera to use."
                return
            }
            selection.select(matches[0].id, devices: found)
            selectionMessage = nil
            resolvedSavedSelection = true
            return
        }
        selection.update(devices: found)
        if let selectedDevice {
            resolvedSavedSelection = true
            selectionMessage = nil
            preferences?.rememberCamera(selectedDevice)
        } else if preferences?.camera != nil {
            selectionMessage = "The selected camera is unavailable. Connect it and choose it again."
        }
    }

    func requestAccess() async {
        guard !isRequestingAccess else { return }
        isRequestingAccess = true
        await provider.requestAccess()
        await refresh()
        isRequestingAccess = false
    }

    func refreshAfterWake() async {
        // Notifications may have been missed while asleep. Discovery still
        // filters isConnected and checks the complete saved identity.
        disconnectedIDs.removeAll()
        await refresh()
    }

    func validateRecovery(deviceID: String) async -> Bool {
        guard await refresh() else { return false }
        guard authorization == .authorized, let device = selectedDevice, device.id == deviceID else { return false }
        return devices.filter { $0.name == device.name && $0.kind == device.kind }.count == 1
    }
}
