import AppKit
import SwiftUI

/// Restores after SwiftUI has placed the window, then owns persistence explicitly.
@MainActor
final class WindowState {
    static let frameKey = "mainWindow.frame"
    private let defaults: UserDefaults
    private weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var restored = false
    private var changingFullScreen = false

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func attach(to window: NSWindow) {
        guard self.window !== window else { return }
        detach()
        self.window = window
        observe(NSWindow.didBecomeKeyNotification) { $0.restore() }
        observe(NSWindow.didMoveNotification) { $0.save() }
        observe(NSWindow.didResizeNotification) { $0.save() }
        observe(NSWindow.willCloseNotification) { state in
            state.save()
            // SwiftUI can reuse this same NSWindow when it is reopened.
            state.restored = false
        }
        observe(NSWindow.willEnterFullScreenNotification) { state in
            state.save()
            state.changingFullScreen = true
        }
        observe(NSWindow.willExitFullScreenNotification) { $0.changingFullScreen = true }
        observe(NSWindow.didEnterFullScreenNotification) { $0.changingFullScreen = false }
        observe(NSWindow.didExitFullScreenNotification) { state in
            state.changingFullScreen = false
            state.save()
        }
        if window.isKeyWindow { restore() }
    }

    private func restore() {
        guard !restored, let window else { return }
        // No autosave name: SwiftUI manages its own name and initial placement.
        // Our separate descriptor cannot be overwritten by those startup events.
        if !window.styleMask.contains(.fullScreen),
           let descriptor = defaults.string(forKey: Self.frameKey)
                ?? defaults.string(forKey: "NSWindow Frame MacMicApp.MainWindow"),
           var frame = Self.frame(from: descriptor) {
            // Restore coordinates directly, then fit to a connected display.
            let screen = NSScreen.screens.max { lhs, rhs in
                Self.overlap(frame, lhs.visibleFrame) < Self.overlap(frame, rhs.visibleFrame)
            }
            let visible = screen.flatMap { Self.overlap(frame, $0.visibleFrame) > 0 ? $0.visibleFrame : nil }
                ?? NSScreen.main?.visibleFrame
            if let visible {
                frame.size.width = min(frame.width, visible.width)
                frame.size.height = min(frame.height, visible.height)
                frame.origin.x = max(visible.minX, min(frame.minX, visible.maxX - frame.width))
                frame.origin.y = max(visible.minY, min(frame.minY, visible.maxY - frame.height))
            }
            window.setFrame(frame, display: true)
        }
        restored = true
    }

    func save() {
        guard restored, !changingFullScreen, let window,
              !window.styleMask.contains(.fullScreen), !window.isMiniaturized else { return }
        defaults.set(window.frameDescriptor, forKey: Self.frameKey)
    }

    func detach() {
        save()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        window = nil
        restored = false
        changingFullScreen = false
    }

    isolated deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    private func observe(_ name: Notification.Name, action: @escaping @MainActor (WindowState) -> Void) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        })
    }

    private static func frame(from descriptor: String) -> NSRect? {
        let tokens = descriptor.split(whereSeparator: \.isWhitespace)
        let values = tokens.compactMap { Double($0) }
        guard tokens.count == 8, values.count == 8, values.allSatisfy(\.isFinite),
              values[2] > 0, values[3] > 0 else { return nil }
        return NSRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }

    private static func overlap(_ lhs: NSRect, _ rhs: NSRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }
}

struct WindowStateReader: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowStateView { WindowStateView() }
    func updateNSView(_ nsView: WindowStateView, context: Context) {}
    static func dismantleNSView(_ nsView: WindowStateView, coordinator: ()) { nsView.state.detach() }
}

final class WindowStateView: NSView {
    let state = WindowState()

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { state.attach(to: window) } else { state.detach() }
    }
}
