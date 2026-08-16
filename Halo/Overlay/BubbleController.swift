import AppKit
import HaloCapture
import HaloComposite
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

    /// Fires whenever the bubble's frame changes, so the recording's layout can
    /// follow it — including while a recording is running.
    var onGeometryChanged: (() -> Void)?

    /// The bubble's frame in screen points, for mapping into output pixels.
    var frame: NSRect? { panel?.frame }

    private var panel: BubblePanel?
    private var view: BubbleView?
    private var anchor: SnapAnchor? = .bottomTrailing

    /// Drives both the panel's size and how the bubble is drawn.
    private(set) var style = BubbleStyle()

    /// Sized to the shape's true extent, not its nominal size — see
    /// `BubbleStyle.panelSize`.
    private var panelSize: CGFloat { CGFloat(style.panelSize) }
    /// The shape's extent, which is what the layout in the recording uses.
    var shapeSize: CGFloat { CGFloat(style.size) }

    private static let inset: CGFloat = 28
    /// How close a drop has to land before it snaps rather than staying free.
    private static let snapDistance: CGFloat = 110

    func show(compositor: Compositor, frameLatch: FrameLatch) {
        guard panel == nil else { return }

        let panel = BubblePanel(size: panelSize)
        let view = BubbleView(compositor: compositor, frameLatch: frameLatch)
        view.style = style
        view.frame = NSRect(x: 0, y: 0, width: panelSize, height: panelSize)
        panel.contentView = view

        view.onDragEnded = { [weak self] frame in self?.settle(after: frame) }
        view.onResize = { [weak self] newSize in self?.resize(to: newSize) }
        view.onGeometryChanged = { [weak self] in self?.onGeometryChanged?() }

        if let screen = NSScreen.main {
            panel.setFrameOrigin(
                (anchor ?? .bottomTrailing).origin(
                    in: screen.visibleFrame, size: panelSize, inset: Self.inset))
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

    func toggle(compositor: Compositor, frameLatch: FrameLatch) {
        isVisible ? hide() : show(compositor: compositor, frameLatch: frameLatch)
    }

    // MARK: - Placement

    /// Applies a new style live, including mid-recording.
    func apply(_ newStyle: BubbleStyle) {
        style = newStyle.clamped()
        view?.style = style
        resizePanel()
        onGeometryChanged?()
    }

    private func resize(to newSize: CGFloat) {
        style.size = Double(newSize)
        resizePanel()
        onGeometryChanged?()
    }

    private func resizePanel() {
        guard let panel else { return }
        let newSize = panelSize

        // Grow about the centre; resizing from the origin makes the bubble
        // appear to crawl across the screen.
        let centre = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        var frame = panel.frame
        frame.size = NSSize(width: newSize, height: newSize)
        frame.origin = NSPoint(x: centre.x - newSize / 2, y: centre.y - newSize / 2)
        panel.setFrame(frame, display: true)
        panel.contentView?.frame = NSRect(x: 0, y: 0, width: newSize, height: newSize)

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
            size: panelSize,
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
        } completionHandler: { [weak self] in
            // NSAnimationContext types this as @Sendable but delivers it on the
            // main thread.
            MainActor.assumeIsolated { self?.onGeometryChanged?() }
        }
    }
}
