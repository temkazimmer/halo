import Synchronization

/// A first-failure slot shared between the capture queue and the main actor.
///
/// `Mutex` is non-copyable, so it cannot be captured directly by the frame
/// callback; wrapping it in a reference type gives the callback and the session
/// a shared handle to the same lock.
///
/// Only the first failure is kept — once capture has gone wrong, every later
/// frame tends to fail the same way, and the first one is the useful diagnosis.
final class FailureSlot: Sendable {
    private let storage = Mutex<String?>(nil)

    var message: String? { storage.withLock { $0 } }

    func record(_ message: String) {
        storage.withLock { if $0 == nil { $0 = message } }
    }

    func reset() {
        storage.withLock { $0 = nil }
    }
}
