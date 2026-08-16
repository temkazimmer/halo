import HaloCapture
import SwiftUI

/// The record/stop bar along the bottom of the control panel.
struct RecordingControlsView: View {
    @Environment(RecorderModel.self) private var recorder

    var body: some View {
        VStack(spacing: 12) {
            if let errorMessage = recorder.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let result = recorder.lastResult {
                ResultSummary(result: result)
            }

            HStack(spacing: 12) {
                status
                Spacer(minLength: 0)
                actionButton
            }
        }
        .padding(20)
        .background(.bar)
    }

    @ViewBuilder
    private var status: some View {
        switch recorder.phase {
        case .idle:
            if let display = recorder.selectedDisplay {
                Text(display.name)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("Select a display")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

        case .recording:
            HStack(spacing: 8) {
                // Standing in for the persistent indicator App Review 2.5.14
                // requires; Phase 6 makes it unmissable and always visible.
                Circle()
                    .fill(.red)
                    .frame(width: 9, height: 9)
                Text(Self.format(recorder.elapsed))
                    .font(.callout.monospacedDigit())
            }

        case .finishing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Saving…").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch recorder.phase {
        case .idle:
            Button {
                Task { await recorder.startRecording() }
            } label: {
                Label("Record", systemImage: "record.circle")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!recorder.canRecord)

        case .recording:
            Button {
                Task { await recorder.stopRecording() }
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)

        case .finishing:
            Button("Stop") {}.disabled(true)
        }
    }

    private static func format(_ duration: Duration) -> String {
        let total = Int(duration.components.seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

private struct ResultSummary: View {
    @Environment(RecorderModel.self) private var recorder
    let result: RecordingResult

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: 2) {
                Text(result.url.lastPathComponent)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer(minLength: 0)

            Button("Show in Finder") { recorder.revealLastRecording() }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
    }

    private var detail: String {
        let seconds = Double(result.duration.components.seconds)
        var parts = ["\(result.frameCount) frames"]
        if seconds > 0 {
            parts.append(String(format: "%.1f fps", Double(result.frameCount) / seconds))
        }
        if result.droppedFrameCount > 0 {
            parts.append("\(result.droppedFrameCount) dropped")
        }
        return parts.joined(separator: "  ·  ")
    }
}
