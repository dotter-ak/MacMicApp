import SwiftUI

struct DeviceSettingsView: View {
    let capture: CaptureController
    let cameras: CameraStore
    @ViewState private var deviceExpanded = true
    @ViewState private var customFPSOpen = false
    @ViewState private var customFPS = "30"
    @FocusState private var customFPSFocused: Bool

    var body: some View {
        SettingsSection("Device", isExpanded: $deviceExpanded) {
            deviceSelectors
            if customFPSOpen {
                customFPSControls
                    .disabled(capture.state != .live || capture.adjustments.isResettingAdjustments)
            }
            if let message = cameras.selectionMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            if let message = capture.modeWarning {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var deviceSelectors: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 12) {
            GridRow {
                Text("Device")
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    Picker("Device", selection: Binding(
                        get: { cameras.selection.deviceID },
                        set: { cameras.selectDevice($0) }
                    )) {
                        Text("Choose a camera").tag(String?.none)
                        ForEach(cameras.devices) { device in
                            Text(cameras.deviceLabel(device)).tag(Optional(device.id))
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("Device")
                    .accessibilityIdentifier("devicePicker")
                    .disabled(cameras.authorization != .authorized || cameras.isRefreshing)
                    .buttonSizing(.flexible)
                    .frame(maxWidth: .infinity)

                    Button("Refresh Cameras", systemImage: "arrow.clockwise") {
                        Task { await cameras.refresh() }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Refresh camera access and devices (⌘R)")
                    .accessibilityIdentifier("refreshCamerasButton")
                    .disabled(cameras.isRefreshing || cameras.isRequestingAccess)
                }
                .frame(maxWidth: .infinity)
            }
            if let snapshot = capture.snapshot, let format = snapshot.activeFormat {
                let activeFPS = snapshot.catalog.canonicalRate(formatIndex: format.index, measuredFPS: snapshot.active.fps)
                let rates = Array(Set(snapshot.catalog.rates(for: format.resolution, formatIndex: format.index) + [activeFPS])).sorted(by: >)
                Group {
                    GridRow {
                        Text("Resolution")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Picker("Resolution", selection: Binding(
                            get: { format.resolution },
                            set: { customFPSOpen = false; capture.selectResolution($0) }
                        )) {
                            ForEach(snapshot.catalog.resolutions, id: \.self) { resolution in
                                Text(resolution.label).tag(resolution)
                            }
                        }
                        .labelsHidden()
                        .accessibilityLabel("Resolution")
                        .accessibilityIdentifier("resolutionPicker")
                        .buttonSizing(.flexible)
                        .frame(maxWidth: .infinity)
                    }
                    GridRow {
                        Text("Pixel Format")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Picker("Pixel Format", selection: Binding(
                            get: { format.index },
                            set: { customFPSOpen = false; capture.selectFormat($0) }
                        )) {
                            ForEach(snapshot.catalog.selectableFormats.filter { $0.resolution == format.resolution }) { option in
                                Text(snapshot.catalog.pixelFormatLabel(for: option)).tag(option.index)
                            }
                        }
                        .labelsHidden()
                        .accessibilityLabel("Pixel Format")
                        .accessibilityIdentifier("pixelFormatPicker")
                        .buttonSizing(.flexible)
                        .frame(maxWidth: .infinity)
                    }
                    GridRow {
                        Text("Frame Rate")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Picker("Frame Rate", selection: Binding(
                            get: { customFPSOpen ? FrameRateSelection.custom : .rate(activeFPS) },
                            set: { selection in
                                switch selection {
                                case .rate(let fps):
                                    customFPSOpen = false
                                    capture.selectFPS(fps)
                                case .custom:
                                    customFPS = String(snapshot.active.fps)
                                    customFPSOpen = true
                                    customFPSFocused = true
                                }
                            }
                        )) {
                            ForEach(rates, id: \.self) { fps in
                                Text("\(VideoMode.fpsLabel(fps)) FPS").tag(FrameRateSelection.rate(fps))
                            }
                            Divider()
                            Text("Custom…").tag(FrameRateSelection.custom)
                        }
                        .labelsHidden()
                        .accessibilityLabel("Frame rate")
                        .accessibilityIdentifier("fpsPicker")
                        .buttonSizing(.flexible)
                        .frame(maxWidth: .infinity)
                    }
                }
                .disabled(capture.state != .live || capture.adjustments.isResettingAdjustments)
            }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: .infinity)
    }

    private var customFPSControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Custom FPS", text: $customFPS)
                .textFieldStyle(.roundedBorder)
                .focused($customFPSFocused)
                .accessibilityLabel("Custom frames per second")
                .onSubmit { applyCustomFPS() }
            if let snapshot = capture.snapshot, let format = snapshot.activeFormat {
                Text("Supported: " + format.rates.map {
                    "\(VideoMode.fpsLabel($0.min))–\(VideoMode.fpsLabel($0.max))"
                }.joined(separator: ", ") + " FPS")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Cancel") { customFPSOpen = false }
                Button("Apply") { applyCustomFPS() }
                    .disabled(!customFPSIsValid || capture.state != .live)
            }
        }
    }

    private func applyCustomFPS() {
        guard customFPSIsValid, capture.state == .live, let fps = Double(customFPS) else { return }
        capture.selectFPS(fps)
        customFPSOpen = false
    }

    private var customFPSIsValid: Bool {
        guard let fps = Double(customFPS), let snapshot = capture.snapshot,
              let resolution = snapshot.resolution else { return false }
        return snapshot.catalog.resolve(resolution: resolution, fps: fps, formatIndex: snapshot.active.formatIndex) != nil
    }

}

private enum FrameRateSelection: Hashable {
    case rate(Double)
    case custom
}
