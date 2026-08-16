import AVFoundation
import CoreVideo
import Synchronization

/// Writes screen frames and mixed audio to an HEVC `.mp4`.
///
/// **Confinement contract.** `append(_:presentationTime:)` must be called only
/// from the video capture queue, and `appendAudio(_:)` only from the audio queue,
/// each synchronously inside its capture callback — handing a video frame to
/// another queue first would keep its `IOSurface` alive past the callback, and
/// once `queueDepth` surfaces are held ScreenCaptureKit stops delivering frames.
/// `AVAssetWriter` permits concurrent appends to *different* inputs, which is why
/// those two queues do not contend; the session origin they share is behind a
/// lock.
///
/// `finish()` and `cancel()` may be called from anywhere, but only after the
/// stream has stopped *and* the capture queues have drained. `RecordingSession`
/// enforces that with a `queue.sync {}` barrier before it touches either.
///
/// The `@unchecked Sendable` conformance stands for exactly those invariants.
/// Swift has no way to express "confined to this DispatchQueue" short of a
/// custom executor, which cannot work here because the appends have to be
/// synchronous. This is the only such conformance in the capture path.
public final class MovieWriter: @unchecked Sendable {
    public enum Failure: Error, LocalizedError, Equatable {
        case cannotAddVideoInput
        case cannotAddAudioInput
        case couldNotStartWriting(String)
        case noFramesWritten
        case writingFailed(String)

        public var errorDescription: String? {
            switch self {
            case .cannotAddVideoInput:
                "The video track could not be configured."
            case .cannotAddAudioInput:
                "The audio track could not be configured."
            case .couldNotStartWriting(let reason):
                "Recording could not start: \(reason)"
            case .noFramesWritten:
                "No frames were captured, so there is nothing to save."
            case .writingFailed(let reason):
                "The recording could not be written: \(reason)"
            }
        }
    }

    public let outputURL: URL

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audioInput: AVAssetWriterInput?

    /// Shared by both tracks. Whichever medium produces the first buffer sets the
    /// origin, and everything is retimed against it — audio and video must not
    /// zero-base independently or they drift apart from the very first frame.
    private struct Session {
        var started = false
        var origin: CMTime?
    }
    private let session = Mutex(Session())

    /// CoreVideo pool types carry no `Sendable` annotation; CF retain and release
    /// are thread-safe and this one is only reached through its own lock.
    private struct PoolBox: @unchecked Sendable {
        var pool: CVPixelBufferPool?
    }
    private let fallbackPoolBox = Mutex(PoolBox())
    private let pixelBufferAttributes: [String: any Sendable]

    public private(set) var appendedFrameCount = 0
    /// Frames skipped because the encoder was not keeping up.
    public private(set) var droppedFrameCount = 0
    private let appendedAudioBuffers = Mutex<Int>(0)

    public var appendedAudioBufferCount: Int { appendedAudioBuffers.withLock { $0 } }

    /// Whether the encoder can accept another video frame right now.
    public var isReadyForMoreMediaData: Bool { videoInput.isReadyForMoreMediaData }

    public init(url: URL, settings: ExportSettings, includesAudio: Bool = false) throws {
        outputURL = url
        pixelBufferAttributes = settings.pixelBufferAttributes

        // AVAssetWriter refuses to overwrite. NSSavePanel has already taken the
        // user's consent to replace by this point.
        try? FileManager.default.removeItem(at: url)

        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        videoInput = AVAssetWriterInput(
            mediaType: .video, outputSettings: settings.videoOutputSettings)
        videoInput.expectsMediaDataInRealTime = true

        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: settings.pixelBufferAttributes)

        guard writer.canAdd(videoInput) else { throw Failure.cannotAddVideoInput }
        writer.add(videoInput)

        if includesAudio {
            // Exactly one audio input, always. Two inputs would give a valid file
            // with two tracks, but QuickTime and browsers play only the first,
            // so half the audio would silently vanish for the user.
            let input = AVAssetWriterInput(
                mediaType: .audio, outputSettings: settings.audioOutputSettings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw Failure.cannotAddAudioInput }
            writer.add(input)
            audioInput = input
        } else {
            audioInput = nil
        }
    }

    // MARK: - Destination buffers

    /// A buffer for the compositor to render into.
    ///
    /// Prefers the adaptor's own pool, so appending needs no copy. That pool only
    /// exists once writing has started, hence the fallback — which requests the
    /// same attributes, so it is still IOSurface-backed and Metal-compatible.
    public func makeDestinationBuffer() throws -> CVPixelBuffer {
        if let pool = adaptor.pixelBufferPool {
            var buffer: CVPixelBuffer?
            if CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
                == kCVReturnSuccess, let buffer {
                return buffer
            }
        }

        let pool = try fallbackPoolBox.withLock { box -> CVPixelBufferPool in
            if let existing = box.pool { return existing }
            var created: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(
                kCFAllocatorDefault, nil,
                pixelBufferAttributes as CFDictionary, &created) == kCVReturnSuccess,
                let created
            else { throw Failure.writingFailed("could not allocate an output buffer pool") }
            box.pool = created
            return created
        }

        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
            == kCVReturnSuccess, let buffer
        else { throw Failure.writingFailed("could not allocate an output buffer") }
        return buffer
    }

    // MARK: - Session

    /// Starts the writing session on the first buffer of any medium.
    private func origin(startingAt presentationTime: CMTime) throws -> CMTime {
        try session.withLock { session in
            if !session.started {
                guard writer.startWriting() else {
                    throw Failure.couldNotStartWriting(
                        writer.error?.localizedDescription ?? "unknown error")
                }
                writer.startSession(atSourceTime: .zero)
                session.started = true
                session.origin = presentationTime
            }
            return session.origin ?? presentationTime
        }
    }

    private var hasStarted: Bool { session.withLock { $0.started } }

    // MARK: - Video

    /// Appends one frame. Safe to call only from the video capture queue.
    ///
    /// Frames are retimed so the session's first buffer lands at `.zero`. That
    /// removes all offset bookkeeping and makes pause/resume a matter of
    /// accumulating one offset.
    @discardableResult
    public func append(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) throws -> Bool {
        let origin = try origin(startingAt: presentationTime)

        guard writer.status == .writing else {
            throw Failure.writingFailed(
                writer.error?.localizedDescription ?? "writer stopped unexpectedly")
        }

        // Real-time capture: if the encoder is behind, drop rather than block the
        // capture queue and stall frame delivery.
        guard videoInput.isReadyForMoreMediaData else {
            droppedFrameCount += 1
            return false
        }

        let appended = adaptor.append(pixelBuffer, withPresentationTime: presentationTime - origin)
        if appended { appendedFrameCount += 1 }
        return appended
    }

    // MARK: - Audio

    /// Appends one mixed audio buffer, retimed against the same origin as video.
    @discardableResult
    public func appendAudio(_ sampleBuffer: CMSampleBuffer) throws -> Bool {
        guard let audioInput else { return false }

        let presentationTime = sampleBuffer.presentationTimeStamp
        let origin = try origin(startingAt: presentationTime)

        guard writer.status == .writing else {
            throw Failure.writingFailed(
                writer.error?.localizedDescription ?? "writer stopped unexpectedly")
        }
        guard audioInput.isReadyForMoreMediaData else { return false }

        let retimed = try CMSampleBuffer(
            copying: sampleBuffer,
            withNewTiming: [CMSampleTimingInfo(
                duration: sampleBuffer.duration,
                presentationTimeStamp: presentationTime - origin,
                decodeTimeStamp: .invalid)])

        let appended = audioInput.append(retimed)
        if appended { appendedAudioBuffers.withLock { $0 += 1 } }
        return appended
    }

    // MARK: - Finishing

    /// Finalises the file. The URL is only playable after this returns.
    public func finish() async throws -> URL {
        guard hasStarted else {
            writer.cancelWriting()
            throw Failure.noFramesWritten
        }

        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        await writer.finishWriting()

        if writer.status == .failed {
            throw Failure.writingFailed(
                writer.error?.localizedDescription ?? "unknown error")
        }
        return outputURL
    }

    /// Abandons the recording and deletes any partial file.
    public func cancel() {
        if writer.status == .writing { writer.cancelWriting() }
        try? FileManager.default.removeItem(at: outputURL)
    }
}
