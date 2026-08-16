import AppKit

/// The floating camera bubble.
///
/// A panel rather than a window, and non-activating, so showing it never steals
/// focus from whatever is being recorded.
final class BubblePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(size: CGFloat) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: size, height: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)

        // `.floating` is not high enough to clear fullscreen apps.
        level = .screenSaver
        collectionBehavior = [
            .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
        ]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = false

        // Defence in depth for legacy CoreGraphics capture paths only. This does
        // NOT hide the panel from ScreenCaptureKit — all windows are composited
        // into one framebuffer before SCK sees them, so exclusion has to happen
        // in the content filter, by windowID.
        sharingType = .none
    }
}
