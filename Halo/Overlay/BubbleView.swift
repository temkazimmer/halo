import AppKit
import HaloCapture
import HaloComposite
import Metal
import QuartzCore

/// The bubble's contents: the camera, masked and coloured by the *same*
/// compositor that renders the recording.
///
/// This is the whole reason for the Metal path. A second, SwiftUI-drawn preview
/// would inevitably drift from the encoded output — different antialiasing,
/// different colour handling — and the difference would show up exactly on the
/// rim, where it is most visible.
final class BubbleView: NSView {
    /// Reports the panel's frame after a drag, so the controller can snap it.
    var onDragEnded: ((NSRect) -> Void)?
    /// Reports a requested new edge length.
    var onResize: ((CGFloat) -> Void)?
    /// Fires whenever the bubble moves, so the recording follows it live.
    var onGeometryChanged: (() -> Void)?

    static let minimumSize: CGFloat = 120
    static let maximumSize: CGFloat = 520

    private let compositor: Compositor
    private let frameLatch: FrameLatch
    private let metalLayer = CAMetalLayer()
    private var displayLink: CADisplayLink?

    private var dragOrigin: NSPoint?
    private var windowOrigin: NSPoint?

    init(compositor: Compositor, frameLatch: FrameLatch) {
        self.compositor = compositor
        self.frameLatch = frameLatch
        super.init(frame: .zero)

        wantsLayer = true
        layer = metalLayer
        metalLayer.device = compositor.device
        metalLayer.pixelFormat = .bgra8Unorm
        // The mask's transparent surround has to let the desktop through.
        metalLayer.isOpaque = false
        metalLayer.backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - Display link

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            displayLink?.invalidate()
            displayLink = nil
        } else if displayLink == nil {
            // Driven by the screen's actual refresh, so the preview matches the
            // display rather than a guessed timer interval.
            let link = displayLink(target: self, selector: #selector(step))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        metalLayer.frame = bounds
        metalLayer.drawableSize = CGSize(
            width: bounds.width * scale, height: bounds.height * scale)
        CATransaction.commit()
    }

    @objc private func step() {
        guard metalLayer.drawableSize.width > 0,
              let frame = frameLatch.latestFrame(),
              let drawable = metalLayer.nextDrawable()
        else { return }

        do {
            try compositor.renderPreview(
                camera: frame.buffer,
                cameraPixelFormat: frame.format,
                feather: 0.5,
                zoom: 1.0,
                offset: .zero,
                // People expect to see themselves mirrored; the recording is not.
                mirrored: true,
                pixelSize: metalLayer.drawableSize,
                into: drawable.texture)
            drawable.present()
        } catch {
            // A dropped preview frame is not worth interrupting a recording for.
        }
    }

    // MARK: - Dragging
    //
    // `super` is deliberately never called: the default handling would activate
    // the app, which is precisely what a non-activating panel exists to avoid.

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        dragOrigin = NSEvent.mouseLocation
        windowOrigin = window.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let dragOrigin, let windowOrigin else { return }
        let now = NSEvent.mouseLocation
        window.setFrameOrigin(
            NSPoint(
                x: windowOrigin.x + (now.x - dragOrigin.x),
                y: windowOrigin.y + (now.y - dragOrigin.y)))
        // Dragging during a recording must move the bubble in the recording too.
        onGeometryChanged?()
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragOrigin = nil
            windowOrigin = nil
        }
        guard let window, dragOrigin != nil else { return }
        onDragEnded?(window.frame)
    }

    // MARK: - Resizing

    override func scrollWheel(with event: NSEvent) {
        guard let window else { return }
        let proposed = window.frame.width + event.scrollingDeltaY
        onResize?(min(Self.maximumSize, max(Self.minimumSize, proposed)))
    }
}
