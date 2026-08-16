import AVFoundation

public struct CameraDevice: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let isContinuity: Bool

    public init(id: String, name: String, isContinuity: Bool) {
        self.id = id
        self.name = name
        self.isContinuity = isContinuity
    }
}

/// Owns the `AVCaptureSession` behind the camera bubble.
///
/// Phase 3 renders the preview straight from the session. Phase 4 adds an
/// `AVCaptureVideoDataOutput` and the frame latch, when there is a compositor to
/// consume the frames — the pixel-format choice belongs with the shader that
/// decodes it, not here.
@MainActor
public final class CameraCapture {
    public enum Failure: Error, LocalizedError, Equatable {
        case noCameraAvailable
        case deviceUnavailable
        case cannotAddInput(String)

        public var errorDescription: String? {
            switch self {
            case .noCameraAvailable: "No camera was found."
            case .deviceUnavailable: "That camera is no longer available."
            case .cannotAddInput(let reason): "The camera could not be started: \(reason)"
            }
        }
    }

    public let session = AVCaptureSession()
    public private(set) var devices: [CameraDevice] = []
    public private(set) var activeDeviceID: String?

    /// Newest camera frame, for the compositor to consume on its own schedule.
    public let frameLatch = FrameLatch()

    /// The format the camera is actually delivering, which the shader needs in
    /// order to decode it correctly.
    public private(set) var pixelFormat: OSType = kCVPixelFormatType_32BGRA

    private let videoOutput = AVCaptureVideoDataOutput()
    private let frameQueue = DispatchQueue(
        label: "com.temazimmer.Halo.camera-frames", qos: .userInitiated)
    private lazy var receiver = FrameReceiver(latch: frameLatch)

    /// Called when the device list changes — Continuity Cameras come and go as
    /// the iPhone wakes and sleeps.
    public var onDevicesChanged: (() -> Void)?

    private let discovery: AVCaptureDevice.DiscoverySession
    private var devicesObservation: NSKeyValueObservation?

    /// `startRunning()` blocks, so it must not run on the main actor.
    private let sessionQueue = DispatchQueue(label: "com.temazimmer.Halo.camera-session")

    public init() {
        // `.external` and `.continuityCamera` are macOS 14+; `.externalUnknown`
        // is deprecated and deliberately not used.
        discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
            mediaType: .video,
            position: .unspecified)

        refreshDevices()

        // KVO rather than polling, as the set genuinely changes at runtime.
        devicesObservation = discovery.observe(\.devices, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshDevices()
                self.onDevicesChanged?()
            }
        }
    }

    private func refreshDevices() {
        // Discovery sessions report devices whose type was not requested, and the
        // same camera can appear twice; uniqueID is the identity that matters.
        var seen = Set<String>()
        devices = discovery.devices.compactMap { device in
            guard seen.insert(device.uniqueID).inserted else { return nil }
            return CameraDevice(
                id: device.uniqueID,
                name: device.localizedName,
                isContinuity: device.deviceType == .continuityCamera)
        }
    }

    public var isRunning: Bool { session.isRunning }

    // MARK: - Lifecycle

    public func start(deviceID: String?) throws {
        let device: AVCaptureDevice? = if let deviceID {
            AVCaptureDevice(uniqueID: deviceID)
        } else {
            AVCaptureDevice.default(for: .video)
        }
        guard let device else {
            throw devices.isEmpty ? Failure.noCameraAvailable : Failure.deviceUnavailable
        }

        session.beginConfiguration()
        for input in session.inputs { session.removeInput(input) }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                throw Failure.cannotAddInput(device.localizedName)
            }
            session.addInput(input)
        } catch let error as Failure {
            throw error
        } catch {
            session.commitConfiguration()
            throw Failure.cannotAddInput(error.localizedDescription)
        }

        if !session.outputs.contains(videoOutput), session.canAddOutput(videoOutput) {
            // Late frames are worthless to a latch that only keeps the newest.
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(receiver, queue: frameQueue)
            session.addOutput(videoOutput)
        }

        session.commitConfiguration()

        // Must come after the output joins the session: the available formats are
        // empty until then.
        pixelFormat = Self.preferredPixelFormat(for: videoOutput)
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat
        ]
        // The recording is deliberately not mirrored — viewers expect text behind
        // you to read correctly. Only the preview layer mirrors.
        if let connection = videoOutput.connection(with: .video),
           connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }

        frameLatch.clear()
        activeDeviceID = device.uniqueID
        startRunning()
    }

    /// BGRA is not a native capture format: Apple notes it needs per-frame
    /// transcoding and about 2.6x the memory of `420v`. The lossy biplanar
    /// variants are visually identical to their uncompressed equivalents, so they
    /// are preferred; the shader does the YCbCr conversion either way.
    private static func preferredPixelFormat(for output: AVCaptureVideoDataOutput) -> OSType {
        let preferred: [OSType] = [
            kCVPixelFormatType_Lossy_420YpCbCr8BiPlanarFullRange,
            kCVPixelFormatType_Lossy_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_32BGRA,
        ]
        let available = output.availableVideoPixelFormatTypes
        return preferred.first(where: available.contains) ?? kCVPixelFormatType_32BGRA
    }

    public func stop() {
        // See `startRunning` — same confinement, same reason.
        nonisolated(unsafe) let confined = session
        sessionQueue.async {
            if confined.isRunning { confined.stopRunning() }
        }
        activeDeviceID = nil
        frameLatch.clear()
    }

    /// `AVCaptureSession.startRunning()` is documented as blocking, so Apple
    /// directs it off the main queue. The session is confined to `sessionQueue`
    /// for the call; everything else touches it on the main actor, and the two
    /// never overlap because configuration completes before this is dispatched.
    private func startRunning() {
        nonisolated(unsafe) let confined = session
        sessionQueue.async {
            if !confined.isRunning { confined.startRunning() }
        }
    }
}

/// Receives camera frames on the capture queue and latches the newest.
///
/// Separate from `CameraCapture` because that type is main-actor; this one only
/// ever runs on `frameQueue`, and holds nothing but a `Sendable` latch.
private final class FrameReceiver: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, Sendable {
    private let latch: FrameLatch

    init(latch: FrameLatch) {
        self.latch = latch
        super.init()
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Same rule as the screen side: nothing derived from this buffer may
        // outlive the callback, so the latch copies rather than retains.
        autoreleasepool {
            guard let pixelBuffer = sampleBuffer.imageBuffer else { return }
            latch.store(pixelBuffer)
        }
    }
}
