import AppKit
import IOKit.pwr_mgt
import Observation

@MainActor
protocol SleepAssertionProviding {
    func start() -> Bool
    func refreshUserActivity() -> Bool
    func stop()
}

@MainActor
final class SystemSleepAssertion: SleepAssertionProviding {
    private var displayID = IOPMAssertionID(kIOPMNullAssertionID)
    private var activityID = IOPMAssertionID(kIOPMNullAssertionID)
    private let reason = "MacMicApp microscope viewing" as CFString

    func start() -> Bool {
        let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &displayID)
        guard result == kIOReturnSuccess, refreshUserActivity() else {
            stop()
            return false
        }
        return true
    }

    func refreshUserActivity() -> Bool {
        // Display-sleep prevention alone does not reset the screen saver's idle timer.
        IOPMAssertionDeclareUserActivity(reason, kIOPMUserActiveLocal, &activityID) == kIOReturnSuccess
    }

    func stop() {
        if activityID != kIOPMNullAssertionID { IOPMAssertionRelease(activityID) }
        if displayID != kIOPMNullAssertionID { IOPMAssertionRelease(displayID) }
        activityID = IOPMAssertionID(kIOPMNullAssertionID)
        displayID = IOPMAssertionID(kIOPMNullAssertionID)
    }

    isolated deinit { stop() }
}

@Observable @MainActor
final class SleepPrevention {
    private(set) var isEnabled: Bool
    private(set) var errorMessage: String?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let assertion: any SleepAssertionProviding
    @ObservationIgnored private var windowIsOpen = false
    @ObservationIgnored private var systemSleeping = false
    @ObservationIgnored private var displaySleeping = false
    @ObservationIgnored private var sessionInactive = false
    @ObservationIgnored private var running = false
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(defaults: UserDefaults = .standard, assertion: any SleepAssertionProviding = SystemSleepAssertion()) {
        self.defaults = defaults
        self.assertion = assertion
        isEnabled = defaults.bool(forKey: "preventScreenSaverAndSleep")
        observe(NSWorkspace.willSleepNotification) { $0.systemSleeping = true }
        observe(NSWorkspace.didWakeNotification) { $0.systemSleeping = false }
        observe(NSWorkspace.screensDidSleepNotification) { $0.displaySleeping = true }
        observe(NSWorkspace.screensDidWakeNotification) { $0.displaySleeping = false }
        observe(NSWorkspace.sessionDidResignActiveNotification) { $0.sessionInactive = true }
        observe(NSWorkspace.sessionDidBecomeActiveNotification) { $0.sessionInactive = false }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: "preventScreenSaverAndSleep")
        update()
    }

    func setWindowOpen(_ open: Bool) {
        windowIsOpen = open
        update()
    }

    private func update() {
        let shouldRun = isEnabled && windowIsOpen && !systemSleeping && !displaySleeping && !sessionInactive
        guard shouldRun else {
            stop()
            errorMessage = nil
            return
        }
        guard !running else { return }
        guard assertion.start() else { fail(); return }
        running = true
        errorMessage = nil
        let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.running else { return }
                if !self.assertion.refreshUserActivity() { self.fail() }
            }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func fail() {
        stop()
        errorMessage = "Could not prevent screen saver and sleep. Turn this option off and on to retry."
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        assertion.stop()
        running = false
    }

    private func observe(_ name: Notification.Name, change: @escaping @MainActor (SleepPrevention) -> Void) {
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                change(self)
                self.update()
            }
        })
    }

    isolated deinit {
        timer?.invalidate()
        assertion.stop()
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    }
}
