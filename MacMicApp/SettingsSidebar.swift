import SwiftUI

struct SettingsSidebar: View {
    let capture: CaptureController
    let cameras: CameraStore
    @ViewState private var imageExpanded = true
    @ViewState private var otherExpanded = true

    private static let versionLabel: String = {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String else {
            return "Version unavailable"
        }
        return "v\(version) (\(build))"
    }()

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                DeviceSettingsView(capture: capture, cameras: cameras)
                SettingsSection("Image", isExpanded: $imageExpanded,
                                   isBusy: !capture.adjustments.busyControls.isEmpty || capture.adjustments.isResettingAdjustments) {
                    ImageSettingsView(capture: capture)
                }
                SettingsSection("Other", isExpanded: $otherExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Capture Folder")
                            Spacer()
                            if !capture.captureFolder.isDefault {
                                Button("Restore Default Folder", systemImage: "arrow.clockwise") {
                                    capture.captureFolder.restoreDefault()
                                }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .help("Restore Downloads/MacMicApp Captures")
                            }
                            Button("Choose…", action: capture.chooseCaptureFolder)
                                .accessibilityIdentifier("chooseCaptureFolderButton")
                            Button("Open", action: capture.openCaptureFolder)
                                .help("Open the capture folder in Finder")
                                .accessibilityIdentifier("openCaptureFolderButton")
                        }
                        Text(capture.captureFolder.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .help(capture.captureFolder.path)
                            .accessibilityIdentifier("captureFolderPath")
                    }
                    .disabled(capture.isSavingFrame || capture.isChoosingCaptureFolder || capture.isOpeningCaptureFolder)
                    ResetAdjustmentsView(capture: capture)
                }
                Text(Self.versionLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("App version")
                    .accessibilityValue(Self.versionLabel)
                    .accessibilityIdentifier("appVersion")
                    .help("Installed version and build number")
            }
            .padding(12)
        }
        .font(.body)
        .accessibilityIdentifier("settingsSidebar")
    }

}

struct SettingsSection<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    let isBusy: Bool
    let content: Content

    init(_ title: String, isExpanded: Binding<Bool>, isBusy: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title
        _isExpanded = isExpanded
        self.isBusy = isBusy
        self.content = content()
    }

    var body: some View {
        GroupBox {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
            } label: {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    if isBusy {
                        ProgressView()
                            .controlSize(.mini)
                            .accessibilityLabel("Updating \(title) settings")
                    }
                }
            }
            .disclosureGroupStyle(SectionDisclosureStyle(title: title))
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // GroupBox draws native grouping without another glass effect.
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SectionDisclosureStyle: DisclosureGroupStyle {
    let title: String

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                configuration.isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                    configuration.label
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Expand or collapse this section")
            .accessibilityIdentifier(title.lowercased() + "SectionHeader")

            if configuration.isExpanded {
                configuration.content
            }
        }
    }
}
