import SwiftUI

// Keep telemetry observation local: FPS updates must not rebuild the settings list.
struct ActualFPSBadge: View {
    let capture: CaptureController

    var body: some View {
        Text(label)
            .font(.callout.monospacedDigit())
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)
            .accessibilityLabel("Actual frames per second")
            .accessibilityValue(label)
            .accessibilityIdentifier("actualFPS")
            .help("Frames received per second. This can differ from the selected FPS.")
            .allowsHitTesting(false)
    }

    private var label: String {
        guard let fps = capture.actualFPS else { return "— FPS" }
        return fps.formatted(.number.precision(.fractionLength(1)).locale(Locale(identifier: "en_US"))) + " FPS"
    }
}

struct ZoomBadge: View {
    let capture: CaptureController

    var body: some View {
        Button(action: capture.resetPreviewZoom) {
            Text(capture.previewZoom.formatted(.number.precision(.fractionLength(1)).locale(Locale(identifier: "en_US"))) + "×")
                .font(.callout.monospacedDigit())
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: .capsule)
        .accessibilityLabel("Preview zoom")
        .accessibilityValue(capture.previewZoom.formatted() + " times")
        .accessibilityHint("Activate to reset to 1 times zoom")
        .accessibilityIdentifier("previewZoomButton")
        .help("Scroll to zoom at the pointer, then drag to pan. Click here or double-click the image to reset to 1×.")
    }
}
