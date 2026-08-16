import AppKit
import HaloCapture
import HaloComposite
import HaloExport
import HaloShapes
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class RecorderModel {
    enum Phase: Equatable {
        case idle
        /// Counting down before capture starts, so you can get out of the way.
        case counting(Int)
        case recording
        case finishing

        var isRecording: Bool { self == .recording }
        var isBusy: Bool { self != .idle }
    }

    private(set) var phase: Phase = .idle
    private(set) var sources = ShareableSources()
    private(set) var lastResult: RecordingResult?
    private(set) var errorMessage: String?
    private(set) var elapsed: Duration = .zero
    private(set) var isLoadingSources = false
    private(set) var audioInputDevices: [AudioInputDevice] = []
    private(set) var levels: [AudioMixer.Source: Float] = [:]

    var selectedTargetID: String?
    var frameRate = 60
    var countdownSeconds = 3
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

    /// Applied live to the floating bubble, including during a recording.
    var style = BubbleStyle() {
        didSet {
            guard style != oldValue else { return }
            bubble.apply(style)
        }
    }
    private(set) var presets = ShapePresetLibrary.builtIn()

    private let session = RecordingSession()
    private let provider = ShareableContentProvider()
    let destinations = DestinationStore()
    @ObservationIgnored private var hotKey: GlobalHotKey?
    private let indicator = RecordingIndicatorController()

    /// Persisted so the app comes back the way it was left.
    private enum Key {
        static let presets = "halo.shapePresets"
        static let style = "halo.bubbleStyle"
        static let frameRate = "halo.frameRate"
        static let countdown = "halo.countdownSeconds"
        static let camera = "halo.cameraDeviceID"
        static let microphone = "halo.microphoneDeviceID"
        static let systemAudio = "halo.capturesSystemAudio"
        static let micEnabled = "halo.capturesMicrophone"
    }
    private let camera = CameraCapture()
    private let bubble = BubbleController()
    /// One compositor for both the preview and the recording — see Compositor.
    /// Not UI state, so it stays out of observation.
    @ObservationIgnored private var compositor: Compositor?
    private var tickTask: Task<Void, Never>?

    init() {
        if let data = UserDefaults.standard.data(forKey: Key.presets),
           let stored = ShapePresetLibrary.decoded(from: data) {
            presets = stored
        }
        restoreSettings()
        cameraDevices = camera.devices
        if selectedCameraID == nil || !camera.devices.contains(where: { $0.id == selectedCameraID }) {
            selectedCameraID = camera.devices.first?.id
        }

        // Works system-wide, sandboxed, with no entitlement and no TCC grant.
        hotKey = GlobalHotKey { [weak self] in
            Task { await self?.toggleRecording() }
        }

        // The indicator must not appear in the recording it is announcing.
        indicator.onWindowIDChanged = { [weak self] _ in
            guard let self else { return }
            Task { await self.syncExcludedWindows(self.bubbleWindowID) }
        }

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

    // MARK: - Shape and presets

    func applyPreset(_ preset: ShapePreset) {
        style = preset.style
    }

    func savePreset(named name: String) {
        presets.add(ShapePreset(name: name, style: style))
        persistPresets()
    }

    func removePreset(id: ShapePreset.ID) {
        presets.remove(id: id)
        persistPresets()
    }

    func movePresets(fromOffsets source: IndexSet, toOffset destination: Int) {
        presets.move(fromOffsets: source, toOffset: destination)
        persistPresets()
    }

    func preset(forShortcutIndex index: Int) -> ShapePreset? {
        presets.preset(forShortcutIndex: index)
    }

    private func persistPresets() {
        guard let data = try? presets.encoded() else { return }
        UserDefaults.standard.set(data, forKey: Key.presets)
    }

    /// Maps the panel's frame from AppKit screen points into output pixels.
    ///
    /// Two conversions, both easy to get wrong: AppKit's y grows upward while
    /// video's grows downward, and the panel is in points while the recording is
    /// in native Retina pixels.
    private func updateBubbleLayout() {
        guard bubble.isVisible,
              let frame = bubble.frame,
              let display = referenceDisplay,
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
            // The shape's own extent, not the panel's — the panel is larger by
            // whatever room the border and shadow need.
            size: bubble.shapeSize * scale,
            style: style,
            mirrored: style.mirrorOutput)
    }

    /// Everything that can be recorded, displays first.
    var targets: [CaptureTarget] {
        sources.displays.map(CaptureTarget.display) + sources.windows.map(CaptureTarget.window)
    }

    var selectedTarget: CaptureTarget? {
        targets.first { $0.id == selectedTargetID }
    }

    /// The display the bubble's position is measured against. Window capture
    /// still needs one, to convert screen points into pixels.
    var referenceDisplay: DisplaySource? {
        switch selectedTarget {
        case .display(let display): display
        default: sources.displays.first { $0.isMain } ?? sources.displays.first
        }
    }

    var canRecord: Bool { phase == .idle && selectedTarget != nil }

    var destinationName: String { destinations.folderName ?? "Ask every time" }

    func chooseDestinationFolder() {
        _ = destinations.chooseFolder()
    }

    // MARK: - Sources

    func loadSources() async {
        isLoadingSources = true
        defer { isLoadingSources = false }

        audioInputDevices = AudioInputDevices.available()

        do {
            sources = try await provider.fetch()
            // Keep any existing choice; otherwise default to the main display.
            if selectedTarget == nil {
                let main = sources.displays.first { $0.isMain } ?? sources.displays.first
                selectedTargetID = main.map { CaptureTarget.display($0).id }
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

    private var bubbleWindowID: CGWindowID? { bubble.windowID }

    /// Everything Halo puts on screen has to stay out of the recording: the
    /// bubble because the compositor draws it, the indicator because it would
    /// otherwise be burned in.
    private func syncExcludedWindows(_ windowID: CGWindowID?) async {
        do {
            try await session.updateExcludedWindows(overlayWindowIDs)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Settings

    private func restoreSettings() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Key.style),
           let stored = try? JSONDecoder().decode(BubbleStyle.self, from: data) {
            style = stored
        }
        if let rate = defaults.object(forKey: Key.frameRate) as? Int { frameRate = rate }
        if let seconds = defaults.object(forKey: Key.countdown) as? Int {
            countdownSeconds = seconds
        }
        selectedCameraID = defaults.string(forKey: Key.camera)
        microphoneDeviceID = defaults.string(forKey: Key.microphone)
        if let value = defaults.object(forKey: Key.systemAudio) as? Bool {
            capturesSystemAudio = value
        }
        if let value = defaults.object(forKey: Key.micEnabled) as? Bool {
            capturesMicrophone = value
        }
    }

    func persistSettings() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(style) {
            defaults.set(data, forKey: Key.style)
        }
        defaults.set(frameRate, forKey: Key.frameRate)
        defaults.set(countdownSeconds, forKey: Key.countdown)
        defaults.set(selectedCameraID, forKey: Key.camera)
        defaults.set(microphoneDeviceID, forKey: Key.microphone)
        defaults.set(capturesSystemAudio, forKey: Key.systemAudio)
        defaults.set(capturesMicrophone, forKey: Key.micEnabled)
    }

    /// The elapsed time as the indicator shows it.
    func elapsedText() -> String {
        let total = Int(elapsed.components.seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    // MARK: - Recording

    /// Starts after the countdown, so you can get out of the way first.
    func beginRecording(saveAs: Bool = false) async {
        guard phase == .idle, selectedTarget != nil else { return }
        guard let url = destinationURL(saveAs: saveAs) else { return }

        errorMessage = nil
        lastResult = nil
        // A menu-bar app's window may never close, so onDisappear alone is not
        // enough to persist settings.
        persistSettings()

        // Shown before the countdown, and so before any content filter is built.
        // SCContentFilter can only exclude windows that are already in the
        // SCShareableContent snapshot, and a window created in the same instant
        // has not been published by the window server yet — it would be silently
        // excluded from nothing and recorded.
        showIndicator()

        for remaining in stride(from: countdownSeconds, through: 1, by: -1) {
            phase = .counting(remaining)
            try? await Task.sleep(for: .seconds(1))
            // Cancelled mid-countdown.
            guard case .counting = phase else {
                indicator.hide()
                return
            }
        }

        // With no countdown there is still a window-server round trip to wait
        // for, so give it one before the filter is built.
        if countdownSeconds == 0 {
            try? await Task.sleep(for: .milliseconds(150))
        }

        await startRecording(to: url)
    }

    func cancelCountdown() {
        guard case .counting = phase else { return }
        phase = .idle
        indicator.hide()
    }

    private func showIndicator() {
        indicator.show(
            elapsed: { [weak self] in self?.elapsedText() ?? "00:00" },
            onStop: { [weak self] in Task { await self?.stopRecording() } })
    }

    /// Everything Halo floats over the screen, which all has to stay out of the
    /// recording.
    private var overlayWindowIDs: [CGWindowID] {
        [bubble.windowID, indicator.windowID].compactMap(\.self)
    }

    private func startRecording(to url: URL) async {
        guard let target = selectedTarget else { return }

        updateBubbleLayout()

        do {
            try await session.start(
                target: target,
                to: url,
                options: RecordingOptions(
                    frameRate: frameRate,
                    capturesSystemAudio: capturesSystemAudio,
                    capturesMicrophone: capturesMicrophone,
                    microphoneDeviceID: microphoneDeviceID,
                    // Still excluded: the compositor draws the bubble into the
                    // frame, so capturing the panel as well would record it
                    // twice, and the indicator would be burned in.
                    excludedWindowIDs: overlayWindowIDs),
                camera: bubble.isVisible ? camera.frameLatch : nil,
                compositor: bubble.isVisible ? compositor : nil)
            phase = .recording
            startTicking()
            // Belt and braces: re-apply the exclusions against a fresh snapshot,
            // in case either overlay was published late.
            await syncExcludedWindows(bubble.windowID)
        } catch {
            indicator.hide()
            errorMessage = error.localizedDescription
        }
    }

    /// One entry point for the hotkey and the menu bar: whatever state we are
    /// in, the shortcut does the obvious thing.
    func toggleRecording() async {
        switch phase {
        case .idle: await beginRecording()
        case .counting: cancelCountdown()
        case .recording: await stopRecording()
        case .finishing: break
        }
    }

    func stopRecording() async {
        guard phase == .recording else { return }
        phase = .finishing
        stopTicking()
        indicator.hide()

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

    /// The panels run out of process under the sandbox and extend our sandbox to
    /// whatever the user picks. A hand-built path would simply fail.
    private func destinationURL(saveAs: Bool) -> URL? {
        let name = Self.defaultFileName()
        if !saveAs, let url = destinations.nextURL(defaultName: name) { return url }
        if !saveAs, destinations.folderURL == nil, destinations.chooseFolder(),
           let url = destinations.nextURL(defaultName: name) {
            return url
        }
        return destinations.chooseFile(defaultName: name)
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
