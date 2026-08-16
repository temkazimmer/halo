import AVFoundation
import AppKit

/// The bubble's contents: a circular camera preview that can be dragged and
/// resized without ever activating the app.
///
/// Phase 5 replaces the circle with the SDF shape system, and Phase 4 replaces
/// this preview layer with the compositor's own texture so preview and
/// recording cannot drift apart.
final class BubbleView: NSView {
    /// Reports the panel's frame after a drag, so the controller can snap it.
    var onDragEnded: ((NSRect) -> Void)?
    /// Reports a requested new edge length.
    var onResize: ((CGFloat) -> Void)?

    static let minimumSize: CGFloat = 120
    static let maximumSize: CGFloat = 520

    private let previewLayer = AVCaptureVideoPreviewLayer()
    private var dragOrigin: NSPoint?
    private var windowOrigin: NSPoint?

    init(session: AVCaptureSession) {
        super.init(frame: .zero)

        wantsLayer = true
        layer?.masksToBounds = true

        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspectFill
        // People expect to see themselves mirrored. The *recording* is not
        // mirrored by default — that is the Phase 5 `mirrorOutput` setting.
        if let connection = previewLayer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        layer?.addSublayer(previewLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        // Implicit animations would make the preview lag behind the panel while
        // dragging or resizing.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
        CATransaction.commit()
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
        let current = window.frame.width
        let proposed = current + event.scrollingDeltaY
        onResize?(min(Self.maximumSize, max(Self.minimumSize, proposed)))
    }
}
