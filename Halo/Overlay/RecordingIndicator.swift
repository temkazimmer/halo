import AppKit
import SwiftUI

/// A persistent, always-visible marker that Halo is capturing.
///
/// **Not optional.** App Review Guideline 2.5.14 requires "a clear visual and/or
/// audible indication when recording… includes any use of the device camera,
/// microphone, screen recordings." macOS shows its own orange dot while capture
/// is active, but that is the system's indicator, not ours, and does not
/// discharge the obligation.
///
/// Excluded from the capture by window ID, like the bubble — otherwise it would
/// be burned into every recording.
@MainActor
final class RecordingIndicatorController {
    private var panel: NSPanel?

    var windowID: CGWindowID? { panel.map { CGWindowID($0.windowNumber) } }
    var onWindowIDChanged: ((CGWindowID?) -> Void)?

    func show(elapsed: @escaping () -> String, onStop: @escaping () -> Void) {
        guard panel == nil else { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 132, height: 34),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false

        panel.contentView = NSHostingView(
            rootView: RecordingIndicatorView(elapsed: elapsed, onStop: onStop))

        // Top centre of the main screen, clear of the menu bar.
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(
                NSPoint(x: frame.midX - 66, y: frame.maxY - 46))
        }

        panel.orderFrontRegardless()
        self.panel = panel
        onWindowIDChanged?(windowID)
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        onWindowIDChanged?(nil)
    }
}

private struct RecordingIndicatorView: View {
    let elapsed: () -> String
    let onStop: () -> Void

    @State private var isPulsing = false
    @State private var text = "00:00"

    private let tick = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(.red)
                .frame(width: 9, height: 9)
                .opacity(isPulsing ? 0.35 : 1)
                .animation(.easeInOut(duration: 0.7).repeatForever(), value: isPulsing)

            Text(text)
                .font(.callout.monospacedDigit().weight(.medium))
                .foregroundStyle(.white)

            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(5)
                    .background(.white.opacity(0.18), in: .circle)
            }
            .buttonStyle(.plain)
            .help("Stop Recording")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.black.opacity(0.78), in: .capsule)
        .onAppear { isPulsing = true }
        .onReceive(tick) { _ in text = elapsed() }
    }
}
