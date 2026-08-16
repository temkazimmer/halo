import SwiftUI

@main
struct HaloApp: App {
    /// Owned here so the menu bar and the window observe one source of truth.
    @State private var permissions = PermissionsModel()
    @State private var recorder = RecorderModel()

    static let mainWindowID = "halo.main"

    var body: some Scene {
        Window("Halo", id: Self.mainWindowID) {
            ControlPanelView()
                .environment(permissions)
                .environment(recorder)
        }
        .defaultSize(width: 480, height: 760)
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MenuBarContent()
                .environment(permissions)
                .environment(recorder)
        } label: {
            // The menu bar carries the state: idle, armed, counting down,
            // recording, saving.
            Image(systemName: menuBarSymbol)
        }
    }

    private var menuBarSymbol: String {
        guard permissions.isReady else { return "exclamationmark.circle" }
        switch recorder.phase {
        case .idle: return recorder.canRecord ? "circle.dashed" : "circle.dotted"
        case .counting: return "timer"
        case .recording: return "record.circle.fill"
        case .finishing: return "arrow.down.circle"
        }
    }
}

private struct MenuBarContent: View {
    @Environment(PermissionsModel.self) private var permissions
    @Environment(RecorderModel.self) private var recorder
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if !permissions.isReady {
            Text("Setup incomplete")
            Divider()
        } else {
            Text(statusLine)
            Divider()

            switch recorder.phase {
            case .idle:
                Button("Start Recording (\(GlobalHotKey.displayName))") {
                    Task { await recorder.beginRecording() }
                }
                .disabled(!recorder.canRecord)

            case .counting:
                Button("Cancel Countdown") { recorder.cancelCountdown() }

            case .recording:
                Button("Stop Recording (\(GlobalHotKey.displayName))") {
                    Task { await recorder.stopRecording() }
                }

            case .finishing:
                Text("Saving…")
            }

            Button(recorder.isBubbleVisible ? "Hide Camera Bubble" : "Show Camera Bubble") {
                recorder.toggleBubble()
            }
            .disabled(recorder.cameraDevices.isEmpty)

            if recorder.lastResult != nil {
                Divider()
                Button("Show Last Recording in Finder") { recorder.revealLastRecording() }
            }

            Divider()
        }

        Button("Open Halo") {
            openWindow(id: HaloApp.mainWindowID)
            NSApp.activate(ignoringOtherApps: true)
        }

        Divider()

        Button("Quit Halo") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusLine: String {
        switch recorder.phase {
        case .idle:
            recorder.selectedTarget.map { "Ready · \($0.name)" } ?? "No source selected"
        case .counting(let remaining):
            "Starting in \(remaining)…"
        case .recording:
            "Recording · \(recorder.elapsedText())"
        case .finishing:
            "Saving…"
        }
    }
}
