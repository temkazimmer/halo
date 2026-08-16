import CoreMedia
import Foundation
import HaloExport

/// What a finished recording produced.
public struct RecordingResult: Sendable, Equatable {
    public let url: URL
    public let frameCount: Int
    public let droppedFrameCount: Int
    public let audioBufferCount: Int
    public let duration: Duration
}

/// Options for one recording.
public struct RecordingOptions: Sendable, Equatable {
    public var frameRate: Int
    public var showsCursor: Bool
    public var capturesSystemAudio: Bool
    public var capturesMicrophone: Bool
    public var microphoneDeviceID: String?
    public var excludedWindowIDs: [CGWindowID]

    public init(
        frameRate: Int = 60,
        showsCursor: Bool = true,
        capturesSystemAudio: Bool = true,
        capturesMicrophone: Bool = true,
        microphoneDeviceID: String? = nil,
        excludedWindowIDs: [CGWindowID] = []
    ) {
        self.frameRate = frameRate
        self.showsCursor = showsCursor
        self.capturesSystemAudio = capturesSystemAudio
        self.capturesMicrophone = capturesMicrophone
        self.microphoneDeviceID = microphoneDeviceID
        self.excludedWindowIDs = excludedWindowIDs
    }

    public var capturesAnyAudio: Bool { capturesSystemAudio || capturesMicrophone }
}

/// Drives one recording end to end: screen frames and audio in, an `.mp4` out.
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

    public enum Failure: Error, LocalizedError, Equatable {
        case captureFailed(String)

        public var errorDescription: String? {
            switch self {
            case .captureFailed(let reason): reason
            }
        }
    }

    public private(set) var state: State = .idle

    /// Owned here rather than by `ScreenCapture` so that `stop()` can barrier on
    /// each and prove no callback is still running before touching the writer.
    private let videoQueue = DispatchQueue(
        label: "com.temazimmer.Halo.capture.video", qos: .userInitiated)
    private let systemAudioQueue = DispatchQueue(
        label: "com.temazimmer.Halo.capture.system-audio", qos: .userInitiated)
    private let microphoneQueue = DispatchQueue(
        label: "com.temazimmer.Halo.capture.microphone", qos: .userInitiated)

    /// Shared, and safe to touch from anywhere — every mutation is behind its
    /// own lock. Exposed so the UI can drive gains and read levels live.
    public let mixer = AudioMixer()

    private var capture: ScreenCapture?
    private var startedAt: ContinuousClock.Instant?
    private var writer: MovieWriter?
    private let failure = FailureSlot()

    public init() {}

    public func start(
        display: DisplaySource,
        to url: URL,
        options: RecordingOptions = RecordingOptions()
    ) async throws {
        guard state == .idle else { return }

        let size = display.pixelSize
        // Built before the stream starts, so no buffer can arrive without a writer.
        let writer = try MovieWriter(
            url: url,
            settings: ExportSettings(
                width: Int(size.width), height: Int(size.height),
                frameRate: options.frameRate),
            includesAudio: options.capturesAnyAudio)

        self.writer = writer
        failure.reset()
        mixer.reset()

        // One converter per source, each used only on that source's queue, so
        // they never contend and never need a lock.
        let systemAudioConverter = AudioSourceConverter()
        let microphoneConverter = AudioSourceConverter()
        let mixer = self.mixer
        let failure = self.failure

        let capture = ScreenCapture(
            videoQueue: videoQueue,
            systemAudioQueue: systemAudioQueue,
            microphoneQueue: microphoneQueue,
            onFrame: { pixelBuffer, presentationTime in
                // On videoQueue. Appending synchronously is what keeps us from
                // retaining the frame's IOSurface past the callback.
                guard failure.message == nil else { return }
                do {
                    try writer.append(pixelBuffer, presentationTime: presentationTime)
                    // Audio is drained here, on the one queue that also owns the
                    // video append — so the audio writer input is only ever
                    // touched from a single thread, even though two queues feed
                    // the mixer.
                    for buffer in try mixer.drain() {
                        try writer.appendAudio(buffer)
                    }
                } catch {
                    failure.record(error.localizedDescription)
                }
            },
            onAudio: { sampleBuffer, source in
                // On systemAudioQueue or microphoneQueue. Accumulate only —
                // never write from here.
                guard failure.message == nil else { return }
                do {
                    let converter = switch source {
                    case .systemAudio: systemAudioConverter
                    case .microphone: microphoneConverter
                    }
                    try mixer.append(sampleBuffer, from: source, using: converter)
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
                    frameRate: options.frameRate,
                    showsCursor: options.showsCursor,
                    excludedWindowIDs: options.excludedWindowIDs,
                    capturesSystemAudio: options.capturesSystemAudio,
                    capturesMicrophone: options.capturesMicrophone,
                    microphoneDeviceID: options.microphoneDeviceID))
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

    /// Keeps the camera bubble out of the recording while it is running.
    public func updateExcludedWindows(_ windowIDs: [CGWindowID]) async throws {
        guard state == .recording else { return }
        try await capture?.updateExcludedWindows(windowIDs)
    }

    @discardableResult
    public func stop() async throws -> RecordingResult {
        guard state == .recording, let writer else {
            throw MovieWriter.Failure.noFramesWritten
        }
        state = .finishing
        defer { state = .idle }

        try? await capture?.stop()
        // Barrier on every capture queue: after these return, no callback is in
        // flight, so the writer and mixer are safe to touch from here.
        videoQueue.sync {}
        systemAudioQueue.sync {}
        microphoneQueue.sync {}
        capture = nil

        let duration = startedAt.map { ContinuousClock.now - $0 } ?? .zero
        startedAt = nil
        self.writer = nil

        if let message = failure.message {
            writer.cancel()
            throw Failure.captureFailed(message)
        }

        // Whatever is still inside the mixer's latency window would otherwise be
        // lost — the tail of the recording, which is exactly where people speak.
        for buffer in try mixer.drain(flush: true) {
            try writer.appendAudio(buffer)
        }

        let url = try await writer.finish()
        return RecordingResult(
            url: url,
            frameCount: writer.appendedFrameCount,
            droppedFrameCount: writer.droppedFrameCount,
            audioBufferCount: writer.appendedAudioBufferCount,
            duration: duration)
    }

    /// Abandons a recording without producing a file.
    public func cancel() async {
        guard state != .idle else { return }
        try? await capture?.stop()
        videoQueue.sync {}
        systemAudioQueue.sync {}
        microphoneQueue.sync {}
        capture = nil
        writer?.cancel()
        writer = nil
        startedAt = nil
        state = .idle
    }
}
