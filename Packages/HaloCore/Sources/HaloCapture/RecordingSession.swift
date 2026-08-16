import CoreMedia
import Foundation
import HaloExport
import Synchronization

/// What a finished recording produced.
public struct RecordingResult: Sendable, Equatable {
    public let url: URL
    public let frameCount: Int
    public let droppedFrameCount: Int
    public let duration: Duration
}

/// Drives one recording end to end: screen frames in, an `.mp4` out.
///
/// From Phase 4 the frame handler will render through the compositor rather than
/// handing the screen buffer straight to the writer; the ownership and threading
/// shape here is built for that.
@MainActor
public final class RecordingSession {
    public enum State: Sendable, Equatable {
        case idle
        case recording
        case finishing
    }

    public private(set) var state: State = .idle

    /// Owned here rather than by `ScreenCapture` so that `stop()` can barrier on
    /// it and prove no frame callback is still running before touching the writer.
    private let queue = DispatchQueue(
        label: "com.temazimmer.Halo.capture", qos: .userInitiated)

    private var capture: ScreenCapture?
    private var startedAt: ContinuousClock.Instant?
    private var writer: MovieWriter?

    /// Set from the capture queue, read on the main actor at `stop()`. A lock
    /// rather than a bare `nonisolated(unsafe)` var, because this really is
    /// written and read from different threads.
    private let failure = FailureSlot()

    public enum Failure: Error, LocalizedError, Equatable {
        case captureFailed(String)

        public var errorDescription: String? {
            switch self {
            case .captureFailed(let reason): reason
            }
        }
    }

    public init() {}

    public func start(
        display: DisplaySource,
        to url: URL,
        frameRate: Int = 60,
        showsCursor: Bool = true,
        excludedWindowIDs: [CGWindowID] = []
    ) async throws {
        guard state == .idle else { return }

        let size = display.pixelSize
        // Built before the stream starts, so no frame can arrive without a writer.
        let writer = try MovieWriter(
            url: url,
            settings: ExportSettings(
                width: Int(size.width), height: Int(size.height), frameRate: frameRate))

        self.writer = writer
        failure.reset()

        let failure = self.failure
        let capture = ScreenCapture(
            queue: queue,
            onFrame: { pixelBuffer, presentationTime in
                // On `queue`. Appending synchronously is what keeps us from
                // retaining the frame's IOSurface past the callback.
                guard failure.message == nil else { return }
                do {
                    try writer.append(pixelBuffer, presentationTime: presentationTime)
                } catch {
                    failure.record(error.localizedDescription)
                }
            },
            onError: { error in
                failure.record(error.localizedDescription)
            })
        self.capture = capture

        do {
            try await capture.start(
                ScreenCapture.Configuration(
                    display: display,
                    frameRate: frameRate,
                    showsCursor: showsCursor,
                    excludedWindowIDs: excludedWindowIDs))
        } catch {
            // Leave nothing half-started behind.
            writer.cancel()
            self.writer = nil
            self.capture = nil
            throw error
        }

        state = .recording
        startedAt = ContinuousClock.now
    }

    @discardableResult
    public func stop() async throws -> RecordingResult {
        guard state == .recording, let writer else { throw MovieWriter.Failure.noFramesWritten }
        state = .finishing
        defer { state = .idle }

        try? await capture?.stop()
        // Barrier: after this returns, no frame callback is still in flight, so
        // the writer is safe to touch from the main actor again.
        queue.sync {}
        capture = nil

        let duration = startedAt.map { ContinuousClock.now - $0 } ?? .zero
        startedAt = nil
        self.writer = nil

        if let message = failure.message {
            writer.cancel()
            throw Failure.captureFailed(message)
        }

        let url = try await writer.finish()
        return RecordingResult(
            url: url,
            frameCount: writer.appendedFrameCount,
            droppedFrameCount: writer.droppedFrameCount,
            duration: duration)
    }

    /// Abandons a recording without producing a file.
    public func cancel() async {
        guard state != .idle else { return }
        try? await capture?.stop()
        queue.sync {}
        capture = nil
        writer?.cancel()
        writer = nil
        startedAt = nil
        state = .idle
    }
}
