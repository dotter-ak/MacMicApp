import AVFoundation

enum CameraAuthorization: Equatable, Sendable {
    case checking, notDetermined, authorized, denied, restricted, unavailable
}

protocol CameraProviding: Sendable {
    func authorizationStatus() async -> CameraAuthorization
    func requestAccess() async
    func devices() async -> [CameraDevice]
}

enum CameraConnectionEvent: Sendable {
    case connected(String)
    case disconnected(String)
}

@MainActor
protocol CameraConnectionWatching: AnyObject {
    func start(_ receive: @escaping @MainActor (CameraConnectionEvent) -> Void)
    func stop()
}

@MainActor
final class SystemCameraConnectionWatcher: CameraConnectionWatching {
    private var observers: [NSObjectProtocol] = []

    func start(_ receive: @escaping @MainActor (CameraConnectionEvent) -> Void) {
        stop()
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                guard let device = note.object as? AVCaptureDevice, device.hasMediaType(.video) else { return }
                let event: CameraConnectionEvent = note.name == AVCaptureDevice.wasDisconnectedNotification
                    ? .disconnected(device.uniqueID) : .connected(device.uniqueID)
                // NotificationCenter guarantees delivery on the main queue.
                MainActor.assumeIsolated { receive(event) }
            }
            observers.append(token)
        }
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    isolated deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}

actor SystemCameraProvider: CameraProviding {
    func authorizationStatus() -> CameraAuthorization {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined: .notDetermined
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .unavailable
        }
    }

    func requestAccess() async {
        guard authorizationStatus() == .notDetermined else { return }
        _ = await AVCaptureDevice.requestAccess(for: .video)
    }

    func devices() -> [CameraDevice] {
        guard authorizationStatus() == .authorized else { return [] }
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external, .builtInWideAngleCamera, .continuityCamera, .deskViewCamera],
            mediaType: .video,
            position: .unspecified
        )

        return discovery.devices.filter(\.isConnected).map { device in
            let kind: CameraDevice.Kind
            switch device.deviceType {
            case .external: kind = .external
            case .continuityCamera: kind = .continuity
            case .deskViewCamera: kind = .deskView
            default: kind = .builtIn
            }
            return CameraDevice(id: device.uniqueID, name: device.localizedName, kind: kind)
        }.sorted { lhs, rhs in
            if (lhs.kind == .external) != (rhs.kind == .external) {
                return lhs.kind == .external
            }
            if lhs.name == rhs.name { return lhs.id < rhs.id }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}
