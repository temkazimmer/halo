import HaloComposite
import Synchronization

/// Shares the bubble's placement between the main actor, which knows where the
/// panel is, and the capture queue, which needs it 60 times a second.
///
/// A lock rather than a captured value because the bubble moves *during*
/// recording — dragging it must change the recording, not just the preview.
public final class BubbleLayoutSlot: Sendable {
    private let storage = Mutex<BubbleLayout?>(nil)

    public init() {}

    public var value: BubbleLayout? {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }

    public func clear() {
        storage.withLock { $0 = nil }
    }
}
