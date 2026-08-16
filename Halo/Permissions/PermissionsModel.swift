import AVFoundation
import AppKit
import CoreGraphics
import Observation

enum PermissionStatus: Sendable, Equatable {
    case notDetermined
    case denied
    case granted
}

/// Which privacy grant a row in the onboarding UI is about.
enum Permission: String, CaseIterable, Identifiable, Sendable {
    case screenRecording, camera, microphone

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screenRecording: "Screen Recording"
        case .camera: "Camera"
        case .microphone: "Microphone"
        }
    }

    var rationale: String {
        switch self {
        case .screenRecording: "So Halo can record the display you choose."
        case .camera: "So Halo can show you in the overlay bubble."
        case .microphone: "So Halo can record your voice."
        }
    }

    /// Deep link to the relevant Privacy & Security pane.
    var settingsURL: URL? {
        let anchor = switch self {
        case .screenRecording: "Privacy_ScreenCapture"
        case .camera: "Privacy_Camera"
        case .microphone: "Privacy_Microphone"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }
}

@MainActor
@Observable
final class PermissionsModel {
    private(set) var screenRecording: PermissionStatus = .notDetermined
    private(set) var camera: PermissionStatus = .notDetermined
    private(set) var microphone: PermissionStatus = .notDetermined

    /// Screen Recording is granted but this process started before the grant, so
    /// ScreenCaptureKit will still refuse us until we restart. Apple documents the
    /// restart requirement; there is no way to pick up the grant in-process.
    private(set) var needsRelaunch = false

    /// `CGPreflightScreenCaptureAccess` cannot distinguish "never asked" from
    /// "denied", so remember whether we have ever prompted.
    private static let hasRequestedScreenKey = "halo.hasRequestedScreenRecording"

    init() {
        refresh()
        // Grants are usually made in System Settings, i.e. while we are inactive.
        // Re-check whenever the user comes back to us.
        //
        // Deliberately never unregistered: this model lives for the lifetime of
        // the process, and a `deinit` cannot touch main-actor state under Swift 6
        // isolation anyway. The `[weak self]` capture keeps it harmless either way.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    var allGranted: Bool {
        screenRecording == .granted && camera == .granted && microphone == .granted
    }

    /// True once everything is granted and the process can actually capture.
    var isReady: Bool { allGranted && !needsRelaunch }

    func status(of permission: Permission) -> PermissionStatus {
        switch permission {
        case .screenRecording: screenRecording
        case .camera: camera
        case .microphone: microphone
        }
    }

    // MARK: - Reading state

    func refresh() {
        let hasScreenAccess = CGPreflightScreenCaptureAccess()
        let hasAsked = UserDefaults.standard.bool(forKey: Self.hasRequestedScreenKey)

        screenRecording = if hasScreenAccess { .granted }
            else if hasAsked { .denied }
            else { .notDetermined }

        // If the grant arrived after we launched, capture stays broken until restart.
        if hasScreenAccess, hasAsked, !Self.processStartedWithScreenAccess {
            needsRelaunch = true
        }

        camera = Self.mediaStatus(for: .video)
        microphone = Self.mediaStatus(for: .audio)
    }

    /// Snapshotted once at launch: whether we already had access when the process
    /// started. Anything granted after this point needs a relaunch to take effect.
    private static let processStartedWithScreenAccess = CGPreflightScreenCaptureAccess()

    private static func mediaStatus(for mediaType: AVMediaType) -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }

    // MARK: - Requesting

    func request(_ permission: Permission) async {
        switch permission {
        case .screenRecording: requestScreenRecording()
        case .camera: await requestMedia(.video)
        case .microphone: await requestMedia(.audio)
        }
        refresh()
    }

    private func requestScreenRecording() {
        UserDefaults.standard.set(true, forKey: Self.hasRequestedScreenKey)
        // Shows the system prompt the first time only. Afterwards it returns false
        // without prompting, which is why we also offer a System Settings link.
        if CGRequestScreenCaptureAccess() {
            needsRelaunch = !Self.processStartedWithScreenAccess
        }
    }

    private func requestMedia(_ mediaType: AVMediaType) async {
        // Missing an Info.plist usage string here terminates the process, so both
        // NSCameraUsageDescription and NSMicrophoneUsageDescription must be present.
        _ = await AVCaptureDevice.requestAccess(for: mediaType)
    }

    func openSettings(for permission: Permission) {
        guard let url = permission.settingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Relaunch

    /// Starts a fresh instance and exits this one. Sandbox-safe: `NSWorkspace`
    /// opening our own bundle needs no entitlement, unlike spawning `open`.
    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true

        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration
        ) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
}
