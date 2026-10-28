import AppKit
import AVFoundation
import SwiftUI

struct CameraPreview: NSViewRepresentable {
    let capture: CaptureController
    let onClose: @MainActor () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> PreviewView {
        PreviewView(previewLayer: capture.previewLayer, onClose: onClose,
                    onCapture: { capture.saveFrame() }, onResetZoom: { capture.resetPreviewZoom() },
                    onZoomInterrupted: { capture.setPreviewZoom($0) },
                    onScroll: { delta, precise in capture.scrollPreviewZoom(delta: delta, precise: precise) })
    }

    func updateNSView(_ nsView: PreviewView, context: Context) {
        nsView.setPresentation(orientation: capture.imageOrientation, zoom: capture.previewZoom, animated: !reduceMotion)
    }

    static func dismantleNSView(_ nsView: PreviewView, coordinator: ()) {
        nsView.detach()
    }
}

@MainActor
final class PreviewView: NSView {
    private let previewLayer: AVCaptureVideoPreviewLayer
    private let onClose: @MainActor () -> Void
    private let onResetZoom: @MainActor () -> Void
    private let onZoomInterrupted: @MainActor (Double) -> Void
    private var lastDragPoint: CGPoint?
    private var scrollAnchor: CGPoint?
    private var orientation = ImageOrientation()
    private var zoom = 1.0
    private let onCapture: @MainActor () -> Void
    private let onScroll: @MainActor (Double, Bool) -> Void
    private var closeObserver: NSObjectProtocol?
    private var keyMonitor: Any?

    init(previewLayer: AVCaptureVideoPreviewLayer, onClose: @escaping @MainActor () -> Void,
         onCapture: @escaping @MainActor () -> Void,
         onResetZoom: @escaping @MainActor () -> Void,
         onZoomInterrupted: @escaping @MainActor (Double) -> Void,
         onScroll: @escaping @MainActor (Double, Bool) -> Void) {
        self.previewLayer = previewLayer
        self.onClose = onClose
        self.onResetZoom = onResetZoom
        self.onZoomInterrupted = onZoomInterrupted
        self.onCapture = onCapture
        self.onScroll = onScroll
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        layer?.addSublayer(previewLayer)
        setAccessibilityElement(true)
        setAccessibilityLabel("Microscope video preview")
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let newBounds = CGRect(origin: .zero, size: bounds.size)
        guard previewLayer.bounds != newBounds else { return }
        let oldBounds = previewLayer.bounds
        let oldPosition = previewLayer.position
        stopZoomAnimation()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.bounds = newBounds
        // Preserve the viewed region on resize; 1x always returns to fit-to-view.
        let x = oldBounds.width > 0 ? (oldPosition.x - oldBounds.midX) * newBounds.width / oldBounds.width : 0
        let y = oldBounds.height > 0 ? (oldPosition.y - oldBounds.midY) * newBounds.height / oldBounds.height : 0
        previewLayer.position = constrainedPosition(CGPoint(x: bounds.midX + x, y: bounds.midY + y), zoom: zoom)
        CATransaction.commit()
        window?.invalidateCursorRects(for: self)
    }

    private var imageRect: CGRect {
        let rect = previewLayer.layerRectConverted(fromMetadataOutputRect: CGRect(x: 0, y: 0, width: 1, height: 1))
        return rect.isEmpty ? previewLayer.bounds : rect
    }

    private func constrainedPosition(_ position: CGPoint, zoom: Double) -> CGPoint {
        let image = imageRect
        func constrained(_ value: CGFloat, min: CGFloat, max: CGFloat, imageLength: CGFloat) -> CGFloat {
            let half = imageLength * zoom / 2
            guard half * 2 > max - min else { return (min + max) / 2 }
            return Swift.min(min + half, Swift.max(max - half, value))
        }
        return CGPoint(x: constrained(position.x, min: bounds.minX, max: bounds.maxX, imageLength: image.width),
                       y: constrained(position.y, min: bounds.minY, max: bounds.maxY, imageLength: image.height))
    }

    func setPresentation(orientation: ImageOrientation, zoom: Double, anchor: CGPoint? = nil, animated: Bool = true) {
        let cursor = anchor ?? scrollAnchor
        scrollAnchor = nil
        guard zoom != self.zoom || orientation != self.orientation else { return }
        let flipsChanged = orientation != self.orientation
        let visible = previewLayer.presentation() ?? previewLayer
        let fromTransform = visible.transform
        let fromPosition = visible.position
        let visibleZoom = hypot(fromTransform.m11, fromTransform.m12)
        var position = previewLayer.position
        if zoom == 1 {
            position = CGPoint(x: bounds.midX, y: bounds.midY)
        } else if !flipsChanged, let cursor, visibleZoom > 0 {
            // Keep the image point currently under the cursor in that same place.
            // Retarget from the presentation layer so rapid wheel events don't jump.
            let ratio = zoom / visibleZoom
            position = CGPoint(x: cursor.x + (fromPosition.x - cursor.x) * ratio,
                               y: cursor.y + (fromPosition.y - cursor.y) * ratio)
        }
        position = constrainedPosition(position, zoom: zoom)
        let transform = orientation.transform().scaledBy(x: zoom, y: zoom)
        self.orientation = orientation
        self.zoom = zoom
        lastDragPoint = nil
        window?.invalidateCursorRects(for: self)
        stopZoomAnimation()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.setAffineTransform(transform)
        previewLayer.position = position
        CATransaction.commit()
        guard animated, !flipsChanged, window != nil else { return }
        // Matching interpolation for position and scale keeps the anchor steady.
        let scaling = CABasicAnimation(keyPath: "transform")
        scaling.duration = 0.16
        scaling.fromValue = NSValue(caTransform3D: fromTransform)
        scaling.toValue = NSValue(caTransform3D: previewLayer.transform)
        let translation = CABasicAnimation(keyPath: "position")
        translation.duration = 0.16
        translation.fromValue = NSValue(point: fromPosition)
        translation.toValue = NSValue(point: position)
        let animation = CAAnimationGroup()
        animation.animations = [scaling, translation]
        animation.duration = 0.16
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        previewLayer.add(animation, forKey: "previewZoom")
    }

    private func stopZoomAnimation() {
        previewLayer.removeAnimation(forKey: "previewZoom")
    }

    private func imagePoint(for event: NSEvent) -> CGPoint? {
        guard let window, window.attachedSheet == nil, NSApp.modalWindow == nil else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return nil }
        let visible = previewLayer.presentation() ?? previewLayer
        let offset = CGPoint(x: point.x - visible.position.x, y: point.y - visible.position.y)
            .applying(visible.affineTransform().inverted())
        let localPoint = CGPoint(x: offset.x + visible.bounds.midX, y: offset.y + visible.bounds.midY)
        return imageRect.contains(localPoint) ? point : nil
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.momentumPhase.isEmpty, let point = imagePoint(for: event) else { return }
        scrollAnchor = point
        // Physical wheel up always zooms in, regardless of Natural Scrolling.
        let delta = event.scrollingDeltaY * (event.isDirectionInvertedFromDevice ? -1 : 1)
        onScroll(Double(delta), event.hasPreciseScrollingDeltas)
    }

    override func mouseDown(with event: NSEvent) {
        lastDragPoint = nil
        guard let point = imagePoint(for: event) else {
            super.mouseDown(with: event)
            return
        }
        scrollAnchor = nil
        if event.clickCount == 2 {
            onResetZoom()
            return
        }
        guard zoom > 1 else { return }
        // Grab the visible frame, even if a zoom animation is still finishing.
        // Keep the controller/badge in sync with the interrupted scale.
        if previewLayer.animation(forKey: "previewZoom") != nil {
            let visible = previewLayer.presentation() ?? previewLayer
            let transform = visible.transform
            let position = visible.position
            zoom = min(8, max(1, hypot(transform.m11, transform.m12)))
            stopZoomAnimation()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewLayer.setAffineTransform(orientation.transform().scaledBy(x: zoom, y: zoom))
            previewLayer.position = constrainedPosition(position, zoom: zoom)
            CATransaction.commit()
            onZoomInterrupted(zoom)
        }
        guard zoom > 1 else { return }
        lastDragPoint = point
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let previous = lastDragPoint, zoom > 1, let window,
              window.attachedSheet == nil, NSApp.modalWindow == nil else {
            endDrag()
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        lastDragPoint = point
        let position = CGPoint(x: previewLayer.position.x + point.x - previous.x,
                               y: previewLayer.position.y + point.y - previous.y)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.position = constrainedPosition(position, zoom: zoom)
        CATransaction.commit()
    }

    override func mouseUp(with event: NSEvent) {
        endDrag()
    }

    private func endDrag() {
        lastDragPoint = nil
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard zoom > 1, let layer else { return }
        let rect = previewLayer.convert(imageRect, to: layer).intersection(bounds)
        if !rect.isEmpty {
            addCursorRect(rect, cursor: lastDragPoint == nil ? .openHand : .closedHand)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        endDrag()
        removeCloseObserver()
        removeKeyMonitor()
        if let window {
            // AppKit persists the normal window frame across moves, resizes,
            // close/reopen and relaunch, including its display coordinates.
            let frameName = "MacMicApp.MainWindow"
            if window.frameAutosaveName != frameName {
                window.setFrameUsingName(frameName)
                window.setFrameAutosaveName(frameName)
            }
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.onClose() }
            }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = MainActor.assumeIsolated {
                    guard let self, let window = self.window,
                          event.window === window, window.isKeyWindow,
                          event.keyCode == 49,
                          event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                          window.attachedSheet == nil, NSApp.modalWindow == nil,
                          !(window.firstResponder is NSTextView) else { return false }
                    // One capture per press; typing in fields and sheets remains native.
                    if !event.isARepeat { self.onCapture() }
                    return true
                }
                return handled ? nil : event
            }
        }
    }

    func detach() {
        endDrag()
        stopZoomAnimation()
        scrollAnchor = nil
        removeCloseObserver()
        removeKeyMonitor()
        previewLayer.removeFromSuperlayer()
    }

    private func removeCloseObserver() {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}
