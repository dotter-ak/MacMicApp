struct CameraDevice: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case external = "External camera"
        case builtIn = "Built-in camera"
        case continuity = "Continuity Camera"
        case deskView = "Desk View"
    }

    let id: String
    let name: String
    let kind: Kind
}

struct CameraSelection {
    private(set) var deviceID: String?
    private var hasMadeInitialChoice = false

    mutating func update(devices: [CameraDevice]) {
        if let deviceID, !devices.contains(where: { $0.id == deviceID }) {
            self.deviceID = nil
        }

        guard !hasMadeInitialChoice, !devices.isEmpty else { return }
        hasMadeInitialChoice = true
        let external = devices.filter { $0.kind == .external }
        if external.count == 1 {
            deviceID = external[0].id
        }
    }

    mutating func select(_ id: String?, devices: [CameraDevice]) {
        hasMadeInitialChoice = true
        deviceID = devices.first(where: { $0.id == id })?.id
    }
}
