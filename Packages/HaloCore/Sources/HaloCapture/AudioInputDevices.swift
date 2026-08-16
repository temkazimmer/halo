import AVFoundation

public struct AudioInputDevice: Identifiable, Hashable, Sendable {
    /// The device's `uniqueID`, which is what
    /// `SCStreamConfiguration.microphoneCaptureDeviceID` expects.
    public let id: String
    public let name: String
    public let isSystemDefault: Bool

    public init(id: String, name: String, isSystemDefault: Bool) {
        self.id = id
        self.name = name
        self.isSystemDefault = isSystemDefault
    }
}

public enum AudioInputDevices {
    /// Microphones available right now.
    ///
    /// `.builtInMicrophone` is deprecated in favour of `.microphone`; both it and
    /// `.external` are macOS 14.0+. Deduplicated by `uniqueID`, because discovery
    /// sessions report devices whose type was not requested.
    public static func available() -> [AudioInputDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified)

        let systemDefaultID = AVCaptureDevice.default(for: .audio)?.uniqueID

        var seen = Set<String>()
        return discovery.devices.compactMap { device in
            guard seen.insert(device.uniqueID).inserted else { return nil }
            return AudioInputDevice(
                id: device.uniqueID,
                name: device.localizedName,
                isSystemDefault: device.uniqueID == systemDefaultID)
        }
    }
}
