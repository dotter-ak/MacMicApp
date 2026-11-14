import AppKit

@MainActor
private final class FakeSleepAssertion: SleepAssertionProviding {
    var starts = 0
    var active = false
    var succeeds = true
    func start() -> Bool { starts += 1; active = succeeds; return succeeds }
    func refreshUserActivity() -> Bool { succeeds }
    func stop() { active = false }
}

@main
struct WindowAndSleepChecks {
    @MainActor
    static func main() {
        _ = NSApplication.shared
        precondition(!NSScreen.screens.isEmpty, "Run this check with access to the macOS display")
        let suite = "MacMicApp.WindowAndSleepChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        checkWindows(defaults, suite: suite)
        checkSleep(defaults)
        let systemAssertion = SystemSleepAssertion()
        precondition(systemAssertion.start(), "macOS must accept the sleep-prevention assertions")
        precondition(systemAssertion.refreshUserActivity())
        systemAssertion.stop()
        systemAssertion.stop()
        print("PASS: window restore, startup ordering, move/resize, reopen, full-screen preservation, corrupt frame; sleep preference, lifecycle, suspension, errors, cleanup")
    }

    @MainActor
    private static func checkWindows(_ defaults: UserDefaults, suite: String) {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 500),
                              styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let expected = window.frame
        defaults.set(window.frameDescriptor, forKey: WindowState.frameKey)
        let saved = defaults.string(forKey: WindowState.frameKey)
        window.setFrame(NSRect(x: 200, y: 200, width: 960, height: 640), display: false)
        let state = WindowState(defaults: defaults)
        state.attach(to: window)
        // SwiftUI's startup placement must not replace the saved geometry.
        post(NSWindow.didResizeNotification, window)
        precondition(defaults.string(forKey: WindowState.frameKey) == saved)
        post(NSWindow.didBecomeKeyNotification, window)
        precondition(window.frame == expected, "Must restore both origin and size: saved=\(saved ?? "nil"), expected=\(expected), actual=\(window.frame), screens=\(NSScreen.screens.map(\.visibleFrame))")
        window.setFrame(NSRect(x: 120, y: 130, width: 850, height: 550), display: false)
        post(NSWindow.didMoveNotification, window)
        post(NSWindow.didResizeNotification, window)
        let moved = window.frame
        let movedSaved = defaults.string(forKey: WindowState.frameKey)

        post(NSWindow.willEnterFullScreenNotification, window)
        window.setFrame(NSRect(x: 0, y: 0, width: 1600, height: 1000), display: false)
        post(NSWindow.didResizeNotification, window)
        precondition(defaults.string(forKey: WindowState.frameKey) == movedSaved)
        window.setFrame(moved, display: false)
        post(NSWindow.didExitFullScreenNotification, window)
        post(NSWindow.willCloseNotification, window)
        window.setFrame(expected, display: false)
        post(NSWindow.didBecomeKeyNotification, window)
        precondition(window.frame == moved, "Reopening the same window must restore its frame")
        state.detach()

        let relaunched = WindowState(defaults: UserDefaults(suiteName: suite)!)
        window.setFrame(expected, display: false)
        relaunched.attach(to: window)
        post(NSWindow.didBecomeKeyNotification, window)
        precondition(window.frame == moved, "A new controller must load saved geometry")
        relaunched.detach()

        defaults.set("invalid frame", forKey: WindowState.frameKey)
        let corrupt = WindowState(defaults: defaults)
        corrupt.attach(to: window)
        post(NSWindow.didBecomeKeyNotification, window)
        precondition(window.frame == moved)
        corrupt.detach()
        window.close()
    }

    @MainActor
    private static func post(_ name: Notification.Name, _ window: NSWindow) {
        NotificationCenter.default.post(name: name, object: window)
    }

    @MainActor
    private static func checkSleep(_ defaults: UserDefaults) {
        let backend = FakeSleepAssertion()
        var sleep: SleepPrevention? = SleepPrevention(defaults: defaults, assertion: backend)
        precondition(sleep?.isEnabled == false)
        sleep?.setEnabled(true)
        precondition(!backend.active, "A saved preference must not hold assertions without a window")
        sleep?.setWindowOpen(true)
        sleep?.setWindowOpen(true)
        precondition(backend.active && backend.starts == 1)
        let center = NSWorkspace.shared.notificationCenter
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        precondition(!backend.active)
        center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        precondition(!backend.active, "Do not wake the sleeping display")
        center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        precondition(backend.active)
        center.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        precondition(!backend.active)
        center.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        precondition(backend.active)
        sleep?.setWindowOpen(false)
        precondition(!backend.active && sleep?.isEnabled == true)
        sleep?.setWindowOpen(true)
        precondition(backend.active)
        sleep = nil
        precondition(!backend.active, "Deinitialization must release assertions and timers")
        let reloaded = SleepPrevention(defaults: defaults, assertion: backend)
        precondition(reloaded.isEnabled && !backend.active)
        backend.succeeds = false
        reloaded.setWindowOpen(true)
        precondition(reloaded.errorMessage != nil && !backend.active)
        reloaded.setEnabled(false)
        precondition(reloaded.errorMessage == nil)
        backend.succeeds = true
        reloaded.setEnabled(true)
        precondition(reloaded.errorMessage == nil && backend.active)
        reloaded.setEnabled(false)
        precondition(!backend.active && !defaults.bool(forKey: "preventScreenSaverAndSleep"))
    }
}
