import SwiftUI

struct ImageSettingsView: View {
    let capture: CaptureController
    private var adjustments: CameraAdjustments { capture.adjustments }
    private let controlIDs: [CameraControlID] = [
        .autoExposure, .exposure, .autoWhiteBalance, .whiteBalance, .gain,
        .brightness, .contrast, .saturation, .sharpness, .gamma, .antiFlicker
    ]

    var body: some View {
        if capture.state != .live {
            Text("Image settings become available when the camera is live.")
                .font(.callout).foregroundStyle(.secondary)
                .lineLimit(nil)
        } else {
            ForEach(controlIDs, id: \.self) { id in
                if showsControl(id) {
                    VStack(alignment: .leading, spacing: 6) {
                        if let control = adjustments.controls[id] {
                            controlView(control)
                        } else {
                            Text(id == .autoExposure ? "Auto Exposure" : id.title)
                                .font(.body)
                        }
                        if let error = adjustments.controlErrors[id] {
                            Text(error).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Retry") { adjustments.loadControl(id) }
                                .accessibilityLabel("Retry \(id.title)")
                                .disabled(adjustments.busyControls.contains(id) || adjustments.isResettingAdjustments)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .disabled(adjustments.isResettingAdjustments)
            flipRow("Horizontal Flip", identifier: "horizontalFlipToggle", isOn: Binding(
                get: { capture.imageOrientation.horizontalFlip },
                set: { capture.setImageOrientation(horizontal: $0) }
            ))
            flipRow("Vertical Flip", identifier: "verticalFlipToggle", isOn: Binding(
                get: { capture.imageOrientation.verticalFlip },
                set: { capture.setImageOrientation(vertical: $0) }
            ))
        }
    }

    private func flipRow(_ title: String, identifier: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title).font(.body)
            Spacer()
            Toggle(title, isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel(title)
                .accessibilityIdentifier(identifier)
        }
        .padding(.vertical, 4)
    }

    private func showsControl(_ id: CameraControlID) -> Bool {
        // Auto Off first preserves the fresh device value, then reads it back.
        // Do not flash the old manual value while that transition is in flight.
        // Slider writes keep their optimistic value visible until confirmation.
        if id == .exposure,
           adjustments.busyControls.contains(.autoExposure)
            || (adjustments.busyControls.contains(.exposure) && adjustments.requestedValues[.exposure] == nil) {
            return false
        }
        let autoID: CameraControlID
        switch id {
        case .exposure: autoID = .autoExposure
        case .whiteBalance: autoID = .autoWhiteBalance
        default: return true
        }
        guard let auto = adjustments.controls[autoID] else { return false }
        if case .unavailable = auto.access {
            // A manual-only camera need not implement an automatic control.
            return adjustments.controls[id]?.dependency == nil && adjustments.controls[id] != nil
        }
        guard auto.confirmed else { return false }
        return auto.automaticState(for: adjustments.requestedValues[autoID]) == false
    }

    @ViewBuilder private func controlView(_ control: CameraControl) -> some View {
        let displayed = adjustments.requestedValues[control.id] ?? control.value
        let writable = canWrite(control)
        let isAutomatic = control.id == .autoExposure || control.id == .autoWhiteBalance
        let title = control.id == .autoExposure ? "Auto Exposure" : control.title
        if case .unavailable(let reason) = control.access {
            HStack {
                Text(title).font(.body)
                Spacer()
                Text(reason.message).font(.caption).foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(title).font(.body)
                    if control.id == .autoExposure, control.automaticState(for: displayed) == true {
                        AutomaticExposureValueView(adjustments: adjustments)
                    }
                    Spacer()
                    if isAutomatic {
                        Toggle(title, isOn: Binding(
                            get: { control.automaticState(for: displayed) ?? false },
                            set: { enabled in
                                if let target = control.automaticTarget(enabled: enabled) {
                                    adjustments.setControl(control.id, value: target)
                                }
                            }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .accessibilityLabel(title)
                        .accessibilityIdentifier(control.id.rawValue + "Toggle")
                        .disabled(!writable || control.automaticState(for: displayed) == nil
                                  || control.automaticTarget(enabled: true) == nil
                                  || control.automaticTarget(enabled: false) == nil)
                        .help(reason(control) ?? title)
                    } else if case .options(let options) = control.kind, control.access == .writable {
                        Picker(control.title, selection: Binding<CameraControlOption?>(
                            get: { if case .option(let option) = displayed { option } else { nil } },
                            set: { if let option = $0 { adjustments.setControl(control.id, value: .option(option)) } }
                        )) { ForEach(options, id: \.self) { Text($0.title).tag(Optional($0)) } }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .accessibilityLabel(control.title)
                        .accessibilityIdentifier(control.id.rawValue + "Picker")
                        .disabled(!writable)
                    } else {
                        Text(control.confirmed ? formatted(displayed, unit: control.unit) : "—")
                            .monospacedDigit()
                            .help(control.title)
                    }
                    if !isAutomatic && control.access == .writable && (displayed != control.initial || !control.isAtInitialValue) {
                        Button("Restore Initial", systemImage: "arrow.clockwise") {
                            adjustments.setControl(control.id, value: control.initial)
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .help("Restore Initial \(control.title)")
                        .accessibilityLabel("Restore Initial \(control.title)")
                        .accessibilityIdentifier(control.id.rawValue + "RestoreButton")
                        .disabled(!writable || !control.kind.accepts(control.initial))
                    }
                }
                switch control.kind {
                case .numeric(let range):
                    if range.isValid {
                        let binding = Binding<Double>(
                            get: { displayed.number ?? range.minimum },
                            set: { value in
                                let snapped = range.minimum + ((value - range.minimum) / range.step).rounded() * range.step
                                adjustments.setControl(control.id, value: .number(min(range.lastValue, max(range.minimum, snapped))))
                            }
                        )
                        // Keep the native track free of ticks while sending valid camera steps.
                        Slider(value: binding, in: range.minimum...range.lastValue)
                        .accessibilityAdjustableAction { direction in
                            switch direction {
                            case .increment: binding.wrappedValue += range.step
                            case .decrement: binding.wrappedValue -= range.step
                            @unknown default: break
                            }
                        }
                        .accessibilityLabel(control.title)
                        .accessibilityValue(control.confirmed ? formatted(displayed, unit: control.unit) : "Unavailable")
                        .accessibilityIdentifier(control.id.rawValue + "Slider")
                        .disabled(!writable)
                    }
                case .options:
                    EmptyView() // The selector replaces the value in the heading row.
                case .toggle:
                    EmptyView() // Automatic switches live in the heading row.
                }

            }
        }
    }
    private func canWrite(_ control: CameraControl) -> Bool {
        guard control.confirmed, control.access == .writable else { return false }
        if control.id == .exposure && adjustments.busyControls.contains(.autoExposure) { return false }
        if let dep = control.dependency {
            guard !adjustments.busyControls.contains(dep.id) else { return false }
            return adjustments.controls[dep.id]?.confirmed == true && adjustments.controls[dep.id]?.value == dep.requiredValue
        }
        return true
    }
    private func reason(_ control: CameraControl) -> String? {
        switch control.access {
        case .readOnly(let reason), .unavailable(let reason):
            return reason.message
        case .writable:
            if control.dependency != nil && !canWrite(control) {
                return control.id == .whiteBalance ? "Turn off Auto White Balance to adjust this value." : "Select a manual exposure mode to adjust this value."
            }
            return nil
        }
    }
    private func formatted(_ value: CameraControlValue, unit: CameraControlUnit) -> String {
        switch value {
        case .number(let number):
            let scaled = unit == .seconds ? number * 1000 : number
            return scaled.formatted(.number.precision(.fractionLength(0...2)).locale(Locale(identifier: "en_US"))) + (unit == .seconds ? " ms" : unit == .kelvin ? " K" : "")
        case .option(let option): return option.title
        case .toggle(let value): return value ? "On" : "Off"
        }
    }
}

// Frequent readbacks only invalidate this small label, not the settings list.
private struct AutomaticExposureValueView: View {
    let adjustments: CameraAdjustments
    @Environment(\.scenePhase) private var scenePhase

    private var shouldObserve: Bool {
        scenePhase == .active && adjustments.canObserveAutomaticExposure
    }

    var body: some View {
        Text("(\(label))")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .accessibilityLabel("Current automatic exposure")
            .accessibilityValue(label)
            .accessibilityIdentifier("automaticExposureValue")
            .help("Current camera-reported exposure. Yizhan values are in device units, not milliseconds.")
            .task(id: shouldObserve) {
                if shouldObserve { await adjustments.observeAutomaticExposure() }
            }
    }

    private var label: String {
        guard let reading = adjustments.automaticExposureReading else { return "—" }
        let value = reading.unit == .seconds ? reading.value * 1000 : reading.value
        return value.formatted(.number.grouping(.never).precision(.fractionLength(0...2)).locale(Locale(identifier: "en_US")))
            + (reading.unit == .seconds ? " ms" : "")
    }
}

struct ResetAdjustmentsView: View {
    let capture: CaptureController
    private var adjustments: CameraAdjustments { capture.adjustments }

    var body: some View {
        if capture.state == .live {
            Button("Reset Adjustments") { adjustments.resetAdjustments() }
                .disabled(!adjustments.canResetAdjustments)
            if adjustments.isResettingAdjustments { ProgressView().controlSize(.small) }
            Text("Restores the values from when this camera or video mode was opened.")
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
            if let message = adjustments.resetMessage {
                Text(message).font(.caption).textSelection(.enabled)
            }
        }
    }
}
