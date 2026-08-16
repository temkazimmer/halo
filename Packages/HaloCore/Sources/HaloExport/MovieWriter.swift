import AVFoundation
import CoreVideo

/// Writes screen frames to an HEVC `.mp4`.
///
/// **Confinement contract.** `append(_:presentationTime:)` must be called only
/// from the capture queue, and it is called synchronously from inside the
/// `SCStream` callback — handing the frame to another queue first would keep its
/// `IOSurface` alive past the callback, and once `queueDepth` surfaces are held
/// ScreenCaptureKit stops delivering frames entirely.
///
/// `finish()` and `cancel()` may be called from anywhere, but only after the
/// stream has stopped *and* the capture queue has drained. `RecordingSession`
/// enforces that with a `queue.sync {}` barrier before it touches either.
///
/// The `@unchecked Sendable` conformance stands for exactly that invariant.
/// Swift has no way to express "confined to this DispatchQueue" short of a
/// custom executor, which cannot work here because `append` has to be
/// synchronous. This is the only such conformance in the capture path.
public final class MovieWriter: @unchecked Sendable {
    public enum Failure: Error, LocalizedError, Equatable {
        case cannotAddVideoInput
        case couldNotStartWriting(String)
        case noFramesWritten
        case writingFailed(String)

        public var errorDescription: String? {
            switch self {
            case .cannotAddVideoInput:
                "The video track could not be configured."
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

    /// Timestamp of the first frame, used to zero-base every later one.
    private var firstPresentationTime: CMTime?

    public private(set) var appendedFrameCount = 0
    /// Frames skipped because the encoder was not keeping up.
    public private(set) var droppedFrameCount = 0

    /// Whether the encoder can accept another frame right now.
    public var isReadyForMoreMediaData: Bool { videoInput.isReadyForMoreMediaData }

    public init(url: URL, settings: ExportSettings) throws {
        outputURL = url

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
    }

    /// Appends one frame. Safe to call only from the capture queue.
    ///
    /// Frames are retimed so the first lands at `.zero`. That removes all offset
    /// bookkeeping and makes pause/resume a matter of accumulating one offset.
    @discardableResult
    public func append(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) throws -> Bool {
        if firstPresentationTime == nil {
            guard writer.startWriting() else {
                throw Failure.couldNotStartWriting(
                    writer.error?.localizedDescription ?? "unknown error")
            }
            writer.startSession(atSourceTime: .zero)
            firstPresentationTime = presentationTime
        }

        guard let firstPresentationTime else { return false }

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

        let appended = adaptor.append(
            pixelBuffer, withPresentationTime: presentationTime - firstPresentationTime)
        if appended { appendedFrameCount += 1 }
        return appended
    }

    /// Finalises the file. The URL is only playable after this returns.
    public func finish() async throws -> URL {
        guard firstPresentationTime != nil else {
            writer.cancelWriting()
            throw Failure.noFramesWritten
        }

        videoInput.markAsFinished()
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
