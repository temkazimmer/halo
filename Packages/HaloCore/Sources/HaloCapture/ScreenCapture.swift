import CoreMedia
import CoreVideo
import HaloExport
import ScreenCaptureKit

/// Owns one `SCStream` and hands complete screen frames to a callback.
///
/// Lifecycle (`start`/`stop`) is main-actor. Frames arrive on a private serial
/// queue, which is what the callback is invoked on — see the note on `onFrame`.
@MainActor
public final class ScreenCapture: NSObject {
    public struct Configuration: Sendable, Equatable {
        public var target: CaptureTarget
        public var frameRate: Int
        public var showsCursor: Bool
        /// Windows to keep out of the capture. From Phase 3 this is how the camera
        /// bubble is excluded — `NSWindow.sharingType` does not work against SCK.
        public var excludedWindowIDs: [CGWindowID]
        public var capturesSystemAudio: Bool
        public var capturesMicrophone: Bool
        /// `AVCaptureDevice.uniqueID`; `nil` uses the system default input.
        public var microphoneDeviceID: String?

        public init(
            target: CaptureTarget,
            frameRate: Int = 60,
            showsCursor: Bool = true,
            excludedWindowIDs: [CGWindowID] = [],
            capturesSystemAudio: Bool = true,
            capturesMicrophone: Bool = true,
            microphoneDeviceID: String? = nil
        ) {
            self.target = target
            self.frameRate = frameRate
            self.showsCursor = showsCursor
            self.excludedWindowIDs = excludedWindowIDs
            self.capturesSystemAudio = capturesSystemAudio
            self.capturesMicrophone = capturesMicrophone
            self.microphoneDeviceID = microphoneDeviceID
        }

        public var capturesAnyAudio: Bool { capturesSystemAudio || capturesMicrophone }
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case displayUnavailable
        case permissionDenied

        public var errorDescription: String? {
            switch self {
            case .displayUnavailable:
                "That display or window is no longer available."
            case .permissionDenied:
                "Screen Recording permission is not granted. Grant it in System Settings, then relaunch Halo."
            }
        }
    }

    public typealias FrameHandler = (CVPixelBuffer, CMTime) -> Void
    public typealias AudioHandler = (CMSampleBuffer, AudioMixer.Source) -> Void
    public typealias ErrorHandler = (any Error) -> Void

    /// Invoked on `queue`, never on the main actor.
    ///
    /// `nonisolated(unsafe)` is deliberate and is the only such escape in the
    /// capture path. `SCStreamOutput` is an Objective-C protocol whose callback
    /// is delivered on the queue we hand to `addStreamOutput`, and Swift has no
    /// way to express "this value is confined to that queue". Both closures are
    /// immutable and set once at init, and they are called from nowhere else.
    nonisolated(unsafe) private let onFrame: FrameHandler
    nonisolated(unsafe) private let onAudio: AudioHandler
    nonisolated(unsafe) private let onError: ErrorHandler

    /// One queue per output type, as the media types have independent clocks and
    /// must not block each other. Supplied by the owner so it can also barrier on
    /// them — after `stop()`, a `sync` on each proves no callback is in flight.
    private let videoQueue: DispatchQueue
    private let systemAudioQueue: DispatchQueue
    private let microphoneQueue: DispatchQueue

    private var stream: SCStream?
    private var currentConfiguration: Configuration?

    public var isRunning: Bool { stream != nil }

    public init(
        videoQueue: DispatchQueue,
        systemAudioQueue: DispatchQueue,
        microphoneQueue: DispatchQueue,
        onFrame: @escaping FrameHandler,
        onAudio: @escaping AudioHandler,
        onError: @escaping ErrorHandler
    ) {
        self.videoQueue = videoQueue
        self.systemAudioQueue = systemAudioQueue
        self.microphoneQueue = microphoneQueue
        self.onFrame = onFrame
        self.onAudio = onAudio
        self.onError = onError
        super.init()
    }

    // MARK: - Lifecycle

    public func start(_ configuration: Configuration) async throws {
        guard stream == nil else { return }

        let filter = try await Self.makeFilter(for: configuration)
        let streamConfiguration = Self.makeStreamConfiguration(for: configuration)

        let stream = SCStream(
            filter: filter, configuration: streamConfiguration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        if configuration.capturesSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: systemAudioQueue)
        }
        if configuration.capturesMicrophone {
            try stream.addStreamOutput(
                self, type: .microphone, sampleHandlerQueue: microphoneQueue)
        }
        try await stream.startCapture()
        self.stream = stream
        currentConfiguration = configuration
    }

    /// Rebuilds the content filter on a running stream — no restart needed.
    ///
    /// Used when the camera bubble appears, disappears, or is recreated: its
    /// window has to be excluded, and `SCShareableContent` snapshots go stale
    /// immediately, so the filter is rebuilt from a fresh one each time.
    public func updateExcludedWindows(_ windowIDs: [CGWindowID]) async throws {
        guard let stream, var configuration = currentConfiguration else { return }
        configuration.excludedWindowIDs = windowIDs
        let filter = try await Self.makeFilter(for: configuration)
        try await stream.updateContentFilter(filter)
        currentConfiguration = configuration
    }

    public func stop() async throws {
        guard let stream else { return }
        self.stream = nil
        currentConfiguration = nil
        try await stream.stopCapture()
    }

    // MARK: - Configuration

    private static func makeFilter(for configuration: Configuration) async throws -> SCContentFilter {
        var content = try await fetchContent()

        // A window the snapshot has not published yet cannot be excluded, and the
        // failure is silent: the filter simply excludes nothing and the overlay
        // is recorded. Re-fetch once rather than accept that.
        if !configuration.excludedWindowIDs.isEmpty,
           !Self.contains(configuration.excludedWindowIDs, in: content) {
            try? await Task.sleep(for: .milliseconds(120))
            content = try await fetchContent()
        }

        switch configuration.target {
        case .display(let source):
            guard let display = content.displays.first(where: { $0.displayID == source.id })
            else { throw Failure.displayUnavailable }

            let excluded = content.windows.filter {
                configuration.excludedWindowIDs.contains($0.windowID)
            }
            return SCContentFilter(display: display, excludingWindows: excluded)

        case .window(let source):
            guard let window = content.windows.first(where: { $0.windowID == source.id })
            else { throw Failure.displayUnavailable }

            // Captures only that window, wherever it sits and whatever is in
            // front of it — so the bubble panel cannot intrude and needs no
            // exclusion here.
            return SCContentFilter(desktopIndependentWindow: window)
        }
    }

    /// Snapshots go stale instantly, so this is never cached — a filter built
    /// from a stale one silently captures the wrong thing.
    private static func fetchContent() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
        } catch let error as SCStreamError where error.code == .userDeclined {
            throw Failure.permissionDenied
        }
    }

    private static func contains(
        _ windowIDs: [CGWindowID], in content: SCShareableContent
    ) -> Bool {
        let published = Set(content.windows.map(\.windowID))
        return windowIDs.allSatisfy(published.contains)
    }

    private static func makeStreamConfiguration(
        for configuration: Configuration
    ) -> SCStreamConfiguration {
        let stream = SCStreamConfiguration()
        let size = configuration.target.pixelSize
        stream.width = Int(size.width)
        stream.height = Int(size.height)
        // Screen content is text-heavy; chroma subsampling here would soften every
        // glyph before the encoder ever sees the frame.
        stream.pixelFormat = kCVPixelFormatType_32BGRA
        stream.colorSpaceName = CGColorSpace.displayP3
        stream.minimumFrameInterval = CMTime(
            value: 1, timescale: CMTimeScale(configuration.frameRate))
        stream.queueDepth = 5  // must not exceed 8
        stream.showsCursor = configuration.showsCursor

        stream.capturesAudio = configuration.capturesSystemAudio
        stream.captureMicrophone = configuration.capturesMicrophone
        stream.microphoneCaptureDeviceID = configuration.microphoneDeviceID
        // Without this our own preview audio would be captured back, and any
        // future playback in-app would feed back on itself.
        stream.excludesCurrentProcessAudio = true
        // Applies to the system-audio stream only. The microphone arrives in its
        // device's native format regardless, which is why it must be converted.
        stream.sampleRate = Int(AudioFormats.sampleRate)
        stream.channelCount = Int(AudioFormats.channelCount)

        return stream
    }
}

// MARK: - SCStreamOutput

extension ScreenCapture: SCStreamOutput {
    public nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        // Nothing derived from this buffer may outlive the callback: holding its
        // IOSurface past return leaks, and once queueDepth surfaces are held
        // ScreenCaptureKit stops delivering frames altogether.
        autoreleasepool {
            guard sampleBuffer.isValid else { return }

            switch type {
            case .screen:
                guard Self.isComplete(sampleBuffer),
                      let pixelBuffer = sampleBuffer.imageBuffer
                else { return }
                onFrame(pixelBuffer, sampleBuffer.presentationTimeStamp)

            case .audio:
                onAudio(sampleBuffer, .systemAudio)

            case .microphone:
                onAudio(sampleBuffer, .microphone)

            @unknown default:
                return
            }
        }
    }

    /// An idle screen still produces frames, but they carry no new image. Only
    /// `.complete` frames have one.
    private nonisolated static func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus)
        else { return false }
        return status == .complete
    }
}

// MARK: - SCStreamDelegate

extension ScreenCapture: SCStreamDelegate {
    public nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        onError(error)
    }
}
