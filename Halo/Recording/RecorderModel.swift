import AppKit
import HaloCapture
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

    var selectedDisplayID: CGDirectDisplayID?

    private let session = RecordingSession()
    private let provider = ShareableContentProvider()
    private var tickTask: Task<Void, Never>?

    var selectedDisplay: DisplaySource? {
        sources.displays.first { $0.id == selectedDisplayID }
    }

    var canRecord: Bool { phase == .idle && selectedDisplay != nil }

    // MARK: - Sources

    func loadSources() async {
        isLoadingSources = true
        defer { isLoadingSources = false }
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

    // MARK: - Recording

    func startRecording() async {
        guard let display = selectedDisplay, phase == .idle else { return }
        guard let url = await destinationURL(for: display) else { return }

        errorMessage = nil
        lastResult = nil

        do {
            try await session.start(display: display, to: url)
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
        phase = .idle
    }

    func revealLastRecording() {
        guard let url = lastResult?.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Destination

    /// The save panel runs out of process under the sandbox and extends our
    /// sandbox to whatever the user picks. A hand-built path would simply fail.
    private func destinationURL(for display: DisplaySource) async -> URL? {
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

    // MARK: - Elapsed time

    private func startTicking() {
        elapsed = .zero
        tickTask = Task { [weak self] in
            let started = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self else { return }
                self.elapsed = ContinuousClock.now - started
            }
        }
    }

    private func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }
}
