import SwiftUI

// Select the native property wrapper: the macOS 27 SDK also exports a State
// macro whose compiler plugin is not bundled with Command Line Tools.
typealias ViewState<Value> = SwiftUI.State<Value>

struct ContentView: View {
    let capture: CaptureController
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var cameras: CameraStore
    @ViewState private var settingsOpenFailed = false
    @ViewState private var sidebarVisibility: NavigationSplitViewVisibility = .all

    init(capture: CaptureController, preferences: CapturePreferences) {
        self.capture = capture
        _cameras = ViewState(initialValue: CameraStore(preferences: preferences))
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            VStack(spacing: 0) {
                ZStack {
                    Text("MacMicApp")
                        .font(.headline)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 80)
                        .gesture(WindowDragGesture())
                    HStack {
                        Spacer()
                        sidebarButton
                    }
                    .padding(.trailing, 12)
                }
                .frame(height: 52)
                SettingsSidebar(capture: capture, cameras: cameras)
            }
                // Use the system sidebar surface, without a second glass panel.
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 420)
                .toolbar(removing: .sidebarToggle)
                .ignoresSafeArea(.container, edges: .top)
        } detail: {
            ZStack {
                CameraPreview(capture: capture, onClose: closeWindowSession)
                    .opacity(capture.state == .live ? 1 : 0)
                if capture.state != .live {
                    CameraStatusView(capture: capture, cameras: cameras, settingsOpenFailed: $settingsOpenFailed)
                }
            }
            .frame(minWidth: 360, minHeight: 360)
            .background(.black)
            // Keep live video in its preview layer; extending it behind the
            // sidebar adds mirrored, blurred video surfaces on every frame.
            .overlay(alignment: .topTrailing) {
                ActualFPSBadge(capture: capture)
                    .padding(16)
            }
            .overlay(alignment: .bottomLeading) {
                ZoomBadge(capture: capture)
                    .padding(20)
            }
            .overlay(alignment: .bottomTrailing) {
                Button(action: capture.saveFrame) {
                    Image(systemName: "camera")
                        .font(.system(size: 22, weight: .medium))
                        .frame(width: 56, height: 56)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .disabled(!capture.canSaveFrame)
                .help("Capture Frame (Space)")
                .accessibilityLabel("Capture frame")
                .accessibilityIdentifier("captureFrameButton")
                .padding(20)
            }
            .overlay(alignment: .topLeading) {
                if sidebarVisibility == .detailOnly {
                    sidebarButton
                        .padding(.leading, 16)
                        .padding(.top, 44)
                }
            }
            .ignoresSafeArea(.container, edges: .top)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .title)
        .toolbar(removing: .sidebarToggle)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .ignoresSafeArea(.container, edges: .top)
        .focusedSceneValue(\.cameraRefresh, CameraRefreshAction(
            isEnabled: !cameras.isRefreshing && !cameras.isRequestingAccess,
            perform: { Task { await cameras.refresh() } }
        ))
        .transaction { if reduceMotion { $0.animation = nil } }
        .alert("Could Not Save Frame", isPresented: Binding(
            get: { capture.saveFrameError != nil },
            set: { if !$0 { capture.dismissSaveError() } }
        )) {
            Button("OK") { capture.dismissSaveError() }
        } message: { Text(capture.saveFrameError ?? "") }
        .alert("Capture Folder Error", isPresented: Binding(
            get: { capture.captureFolderError != nil },
            set: { if !$0 { capture.dismissFolderError() } }
        )) {
            Button("OK") { capture.dismissFolderError() }
        } message: { Text(capture.captureFolderError ?? "") }
        .frame(minWidth: 680, minHeight: 480)
        .onAppear {
            #if DEBUG
            if HardwareProbe.measuresUIModes {
                sidebarVisibility = CommandLine.arguments.contains("--probe-inspector") ? .all : .detailOnly
            }
            #endif
            capture.configureRecovery(
                validate: { id in await cameras.validateRecovery(deviceID: id) },
                afterWake: { await cameras.refreshAfterWake() }
            )
            capture.open(deviceID: authorizedDeviceID)
            cameras.startMonitoring { id in capture.selectDevice(id) }
        }
        .onDisappear(perform: closeWindowSession)
        .task { await cameras.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await cameras.refresh() }
            }
        }
    }

    private var authorizedDeviceID: String? {
        cameras.authorization == .authorized ? cameras.selection.deviceID : nil
    }

    private func closeWindowSession() {
        cameras.stopMonitoring()
        capture.close()
    }

    private var sidebarButton: some View {
        Button {
            withAnimation {
                sidebarVisibility = sidebarVisibility == .detailOnly ? .all : .detailOnly
            }
        } label: {
            Image(systemName: "sidebar.left")
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .help(sidebarVisibility == .detailOnly ? "Show Sidebar" : "Hide Sidebar")
        .accessibilityLabel(sidebarVisibility == .detailOnly ? "Show sidebar" : "Hide sidebar")
        .accessibilityIdentifier("sidebarToggleButton")
    }

}

struct CameraRefreshAction {
    let isEnabled: Bool
    let perform: @MainActor () -> Void
}

private struct CameraRefreshKey: FocusedValueKey {
    typealias Value = CameraRefreshAction
}

extension FocusedValues {
    var cameraRefresh: CameraRefreshAction? {
        get { self[CameraRefreshKey.self] }
        set { self[CameraRefreshKey.self] = newValue }
    }
}
