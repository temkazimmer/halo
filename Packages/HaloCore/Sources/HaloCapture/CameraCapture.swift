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

        session.commitConfiguration()
        activeDeviceID = device.uniqueID
        startRunning()
    }

    public func stop() {
        // See `startRunning` — same confinement, same reason.
        nonisolated(unsafe) let confined = session
        sessionQueue.async {
            if confined.isRunning { confined.stopRunning() }
        }
        activeDeviceID = nil
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
