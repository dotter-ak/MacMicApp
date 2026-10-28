import AppKit

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    var capture: CaptureController?
    private var powerObservers: [NSObjectProtocol] = []
    private var terminationPending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = NSWorkspace.shared.notificationCenter
        powerObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.capture?.suspendForSleep() }
        })
        powerObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let capture = self?.capture else { return }
                Task { await capture.resumeAfterSleep() }
            }
        })
    }

    isolated deinit {
        powerObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let capture else { return .terminateNow }
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        Task { @MainActor in
            await capture.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
