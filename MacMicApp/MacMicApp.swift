import SwiftUI

@main
struct MacMicApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var applicationDelegate
    @FocusedValue(\.cameraRefresh) private var refreshAction
    @ViewState private var capture = CaptureController(preferences: .shared)
    @ViewState private var sleepPrevention = SleepPrevention()

    var body: some Scene {
        Window("MacMicApp", id: "main") {
            ContentView(capture: capture, preferences: .shared, sleepPrevention: sleepPrevention)
                .onAppear {
                    applicationDelegate.capture = capture
                    applicationDelegate.sleepPrevention = sleepPrevention
                }
        }
        .commands {
            SidebarCommands()
            CommandMenu("Camera") {
                Button("Refresh Cameras") { refreshAction?.perform() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(refreshAction?.isEnabled != true)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Capture Frame") { capture.saveFrame() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!capture.canSaveFrame)
            }
        }
        .defaultSize(width: 960, height: 640)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
    }
}
