import AVFoundation
import AppKit
import HaloShapes
import Observation

/// Owns the floating bubble panel: placement, snapping, and the window ID that
/// keeps it out of the recording.
@MainActor
@Observable
final class BubbleController {
    private(set) var isVisible = false

    /// `NSWindow.windowNumber` *is* the `CGWindowID`, which is what
    /// `SCContentFilter(display:excludingWindows:)` matches on.
    private(set) var windowID: CGWindowID?

    /// Fired when the bubble appears or disappears, so a running stream can
    /// rebuild its content filter rather than restart.
    var onWindowIDChanged: ((CGWindowID?) -> Void)?

    private var panel: BubblePanel?
    private var view: BubbleView?
    private var size: CGFloat = 220
    private var anchor: SnapAnchor? = .bottomTrailing

    private static let inset: CGFloat = 28
    /// How close a drop has to land before it snaps rather than staying free.
    private static let snapDistance: CGFloat = 110

    func show(session: AVCaptureSession) {
        guard panel == nil else { return }

        let panel = BubblePanel(size: size)
        let view = BubbleView(session: session)
        view.frame = NSRect(x: 0, y: 0, width: size, height: size)
        panel.contentView = view

        view.onDragEnded = { [weak self] frame in self?.settle(after: frame) }
        view.onResize = { [weak self] newSize in self?.resize(to: newSize) }

        if let screen = NSScreen.main {
            panel.setFrameOrigin(
                (anchor ?? .bottomTrailing).origin(
                    in: screen.visibleFrame, size: size, inset: Self.inset))
        }

        // Not makeKeyAndOrderFront: that would steal focus from whatever is
        // being recorded, which defeats the whole point of the panel.
        panel.orderFrontRegardless()

        self.panel = panel
        self.view = view
        isVisible = true
        windowID = CGWindowID(panel.windowNumber)
        onWindowIDChanged?(windowID)
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        view = nil
        isVisible = false
        windowID = nil
        onWindowIDChanged?(nil)
    }

    func toggle(session: AVCaptureSession) {
        isVisible ? hide() : show(session: session)
    }

    // MARK: - Placement

    private func resize(to newSize: CGFloat) {
        guard let panel else { return }
        size = newSize

        // Grow about the centre; resizing from the origin makes the bubble
        // appear to crawl across the screen.
        let centre = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        var frame = panel.frame
        frame.size = NSSize(width: newSize, height: newSize)
        frame.origin = NSPoint(x: centre.x - newSize / 2, y: centre.y - newSize / 2)
        panel.setFrame(frame, display: true)

        if let anchor, let screen = panel.screen ?? NSScreen.main {
            panel.setFrameOrigin(
                anchor.origin(in: screen.visibleFrame, size: newSize, inset: Self.inset))
        }
    }

    /// Snaps to the nearest of the nine anchors if the drop landed close to one,
    /// otherwise leaves the bubble where it was put.
    private func settle(after frame: NSRect) {
        guard let panel,
              let screen = panel.screen ?? NSScreen.main
        else { return }

        let best = SnapAnchor.nearest(
            to: CGPoint(x: frame.midX, y: frame.midY),
            in: screen.visibleFrame,
            size: size,
            inset: Self.inset)

        guard best.distance <= Self.snapDistance else {
            anchor = nil
            return
        }

        anchor = best.anchor
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrameOrigin(best.origin)
        }
    }
}
