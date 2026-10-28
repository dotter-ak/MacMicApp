import SwiftUI

struct CameraStatusView: View {
    let capture: CaptureController
    let cameras: CameraStore
    @Binding var settingsOpenFailed: Bool

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: statusIcon)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.primary)
                .frame(width: 88, height: 88)
                .glassEffect(.regular, in: .circle)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text(statusTitle)
                    .font(.title2.weight(.semibold))

                Text(statusMessage)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            if cameras.isRequestingAccess || cameras.authorization == .checking || (capture.state == .starting || capture.state == .changing || capture.state == .recovering) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(capture.state == .starting ? "Starting camera" : "Checking camera access")
            } else if case .failed = capture.state, cameras.authorization == .authorized {
                Button("Retry") { capture.retry() }
                    .buttonStyle(.glassProminent)
            } else if cameras.authorization == .notDetermined {
                Button("Allow Camera Access") {
                    Task { await cameras.requestAccess() }
                }
                .buttonStyle(.glassProminent)
            } else if cameras.authorization == .denied {
                Button("Open System Settings") { openCameraSettings() }
                    .buttonStyle(.glass)
                if settingsOpenFailed {
                    Text("Open System Settings → Privacy & Security → Camera.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            Color(nsColor: .windowBackgroundColor)
                .overlay {
                    RadialGradient(
                        colors: [.accentColor.opacity(0.08), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 360
                    )
                }
                .ignoresSafeArea()
        }
    }

    private var statusIcon: String {
        switch cameras.authorization {
        case .denied, .restricted, .unavailable: "camera.badge.ellipsis"
        default: "camera.macro"
        }
    }

    private var statusTitle: String {
        switch cameras.authorization {
        case .checking: "Checking camera access"
        case .notDetermined: "Allow camera access"
        case .denied: "Camera access is off"
        case .restricted: "Camera access is restricted"
        case .unavailable: "Camera access is unavailable"
        case .authorized:
            if case .failed = capture.state {
                "Camera unavailable"
            } else if capture.state == .suspended {
                "Camera paused"
            } else if capture.state == .recovering {
                "Restoring camera"
            } else if (capture.state == .starting || capture.state == .changing) {
                capture.state == .changing ? "Changing video mode" : "Starting camera"
            } else if cameras.isRefreshing && cameras.devices.isEmpty {
                "Looking for cameras"
            } else if let device = cameras.selectedDevice {
                cameras.deviceLabel(device)
            } else {
                cameras.devices.isEmpty ? "No cameras found" : "Choose a camera"
            }
        }
    }

    private var statusMessage: String {
        switch cameras.authorization {
        case .checking: "Checking permission to use your microscope."
        case .notDetermined: "MacMicApp needs camera access to find and use your microscope."
        case .denied: "Enable MacMicApp in System Settings → Privacy & Security → Camera, then return here or reopen the app."
        case .restricted: "Camera access is restricted by your Mac’s settings or administrator."
        case .unavailable: "Camera access could not be determined. Try refreshing."
        case .authorized:
            if case .failed(let message) = capture.state {
                message
            } else if capture.state == .suspended {
                "Video will resume after your Mac wakes."
            } else if capture.state == .recovering {
                "Checking camera access and restoring the saved video mode."
            } else if (capture.state == .starting || capture.state == .changing) {
                capture.state == .changing ? "Applying resolution and frame rate." : "Connecting to your microscope."
            } else if cameras.isRefreshing && cameras.devices.isEmpty {
                "Finding available camera devices."
            } else if cameras.selectedDevice != nil {
                "Camera selected"
            } else {
                cameras.devices.isEmpty
                    ? "Connect your USB microscope. The device list updates automatically."
                    : "Select your microscope from the Device menu."
            }
        }
    }

    private func openCameraSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") else {
            settingsOpenFailed = true
            return
        }
        settingsOpenFailed = !NSWorkspace.shared.open(url)
    }
}
