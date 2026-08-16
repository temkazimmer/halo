import AppKit
import HaloCapture
import HaloComposite
import HaloExport
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class RecorderModel {
    enum Phase: Equatable {
        case idle
        case recording
        case finishing
    }

    private(set) var phase: Phase = .idle
    private(set) var sources = ShareableSources()
    private(set) var lastResult: RecordingResult?
    private(set) var errorMessage: String?
    private(set) var elapsed: Duration = .zero
    private(set) var isLoadingSources = false
    private(set) var audioInputDevices: [AudioInputDevice] = []
    private(set) var levels: [AudioMixer.Source: Float] = [:]

    var selectedDisplayID: CGDirectDisplayID?
    var capturesSystemAudio = true
    var capturesMicrophone = true
    var microphoneDeviceID: String?

    var systemAudioGain: Float = 1 {
        didSet { session.mixer.setGain(systemAudioGain, for: .systemAudio) }
    }
    var microphoneGain: Float = 1 {
        didSet { session.mixer.setGain(microphoneGain, for: .microphone) }
    }

    private(set) var cameraDevices: [CameraDevice] = []
    private(set) var isBubbleVisible = false
    var selectedCameraID: String?

    private let session = RecordingSession()
    private let provider = ShareableContentProvider()
    private let camera = CameraCapture()
    private let bubble = BubbleController()
    /// One compositor for both the preview and the recording — see Compositor.
    /// Not UI state, so it stays out of observation.
    @ObservationIgnored private var compositor: Compositor?
    private var tickTask: Task<Void, Never>?

    init() {
        cameraDevices = camera.devices
        selectedCameraID = camera.devices.first?.id

        // Continuity Cameras come and go as the iPhone wakes and sleeps.
        camera.onDevicesChanged = { [weak self] in
            guard let self else { return }
            self.cameraDevices = self.camera.devices
            if let selected = self.selectedCameraID,
               !self.camera.devices.contains(where: { $0.id == selected }) {
                self.selectedCameraID = self.camera.devices.first?.id
                if self.isBubbleVisible { self.restartCamera() }
            }
        }

        // The bubble must never appear in the recording. Its window ID changes
        // whenever the panel is recreated, so a running stream is told each time.
        bubble.onWindowIDChanged = { [weak self] windowID in
            guard let self else { return }
            self.isBubbleVisible = self.bubble.isVisible
            self.updateBubbleLayout()
            Task { await self.syncExcludedWindows(windowID) }
        }

        // Dragging or resizing must move the bubble in the recording too, not
        // only in the preview.
        bubble.onGeometryChanged = { [weak self] in
            self?.updateBubbleLayout()
        }
    }

    /// Maps the panel's frame from AppKit screen points into output pixels.
    ///
    /// Two conversions, both easy to get wrong: AppKit's y grows upward while
    /// video's grows downward, and the panel is in points while the recording is
    /// in native Retina pixels.
    private func updateBubbleLayout() {
        guard bubble.isVisible,
              let frame = bubble.frame,
              let display = selectedDisplay,
              let screen = NSScreen.screens.first(where: {
                  ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                      as? NSNumber)?.uint32Value == display.id
              })
        else {
            session.bubbleLayout.clear()
            return
        }

        let scale = CGFloat(display.scale)
        let bounds = screen.frame
        session.bubbleLayout.value = BubbleLayout(
            centre: CGPoint(
                x: (frame.midX - bounds.minX) * scale,
                y: (bounds.maxY - frame.midY) * scale),
            size: frame.width * scale)
    }

    var selectedDisplay: DisplaySource? {
        sources.displays.first { $0.id == selectedDisplayID }
    }

    var canRecord: Bool { phase == .idle && selectedDisplay != nil }

    // MARK: - Sources

    func loadSources() async {
        isLoadingSources = true
        defer { isLoadingSources = false }

        audioInputDevices = AudioInputDevices.available()

        do {
            sources = try await provider.fetch()
            // Keep any existing choice; otherwise default to the main display.
            if selectedDisplay == nil {
                selectedDisplayID = sources.displays.first { $0.isMain }?.id
                    ?? sources.displays.first?.id
            }
            errorMessage = nil
        } catch ShareableContentError.permissionDenied {
            errorMessage = "Screen Recording permission was revoked. Grant it again and relaunch Halo."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Camera bubble

    func toggleBubble() {
        if bubble.isVisible {
            bubble.hide()
            camera.stop()
            return
        }

        do {
            let compositor = try makeCompositorIfNeeded()
            try camera.start(deviceID: selectedCameraID)
            bubble.show(compositor: compositor, frameLatch: camera.frameLatch)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func makeCompositorIfNeeded() throws -> Compositor {
        if let compositor { return compositor }
        let created = try Compositor()
        compositor = created
        return created
    }

    func selectCamera(_ deviceID: String?) {
        selectedCameraID = deviceID
        if bubble.isVisible { restartCamera() }
    }

    private func restartCamera() {
        do {
            try camera.start(deviceID: selectedCameraID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func syncExcludedWindows(_ windowID: CGWindowID?) async {
        do {
            try await session.updateExcludedWindows(windowID.map { [$0] } ?? [])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Recording

    func startRecording() async {
        guard let display = selectedDisplay, phase == .idle else { return }
        guard let url = await destinationURL() else { return }

        errorMessage = nil
        lastResult = nil

        updateBubbleLayout()

        do {
            try await session.start(
                display: display,
                to: url,
                options: RecordingOptions(
                    capturesSystemAudio: capturesSystemAudio,
                    capturesMicrophone: capturesMicrophone,
                    microphoneDeviceID: microphoneDeviceID,
                    // Still excluded: the compositor draws the bubble into the
                    // frame, so capturing the panel as well would record it twice.
                    excludedWindowIDs: bubble.windowID.map { [$0] } ?? []),
                camera: bubble.isVisible ? camera.frameLatch : nil,
                compositor: bubble.isVisible ? compositor : nil)
            phase = .recording
            startTicking()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stopRecording() async {
        guard phase == .recording else { return }
        phase = .finishing
        stopTicking()

        do {
            lastResult = try await session.stop()
        } catch {
            errorMessage = error.localizedDescription
        }
        elapsed = .zero
        levels = [:]
        phase = .idle
    }

    func revealLastRecording() {
        guard let url = lastResult?.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Destination

    /// The save panel runs out of process under the sandbox and extends our
    /// sandbox to whatever the user picks. A hand-built path would simply fail.
    private func destinationURL() async -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = Self.defaultFileName()
        panel.title = "Save Recording"
        panel.prompt = "Start Recording"

        return panel.runModal() == .OK ? panel.url : nil
    }

    private static func defaultFileName() -> String {
        let formatter = DateFormatter()
        // Mirrors the macOS screenshot naming convention.
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Halo \(formatter.string(from: Date())).mp4"
    }

    // MARK: - Meters and elapsed time

    private func startTicking() {
        elapsed = .zero
        levels = [:]

        tickTask = Task { [weak self] in
            let started = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(40))
                guard let self else { return }
                self.elapsed = ContinuousClock.now - started
                self.updateLevels()
            }
        }
    }

    /// The mixer reports the last peak it saw, which would simply stick if a
    /// source went quiet. Falling back towards the reported value gives the
    /// meters normal decay ballistics.
    private func updateLevels() {
        let reported = session.mixer.levels()
        for source in AudioMixer.Source.allCases {
            let current = reported[source] ?? 0
            let previous = levels[source] ?? 0
            levels[source] = max(current, previous * 0.82)
        }
    }

    private func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }
}
