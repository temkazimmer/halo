import SwiftUI

/// Frame rate, countdown, and where recordings land.
struct RecordingSettingsView: View {
    @Environment(RecorderModel.self) private var recorder

    var body: some View {
        @Bindable var recorder = recorder

        VStack(alignment: .leading, spacing: 12) {
            Text("Recording")
                .font(.title3.weight(.semibold))

            HStack {
                Text("Frame Rate")
                    .font(.callout)
                    .frame(width: 96, alignment: .leading)
                Picker("", selection: $recorder.frameRate) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                    Text("120 fps").tag(120)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .disabled(recorder.phase.isBusy)
            }

            if recorder.frameRate == 120 {
                Text("120 fps doubles the encoder load and file size. Worth it for fast motion, rarely for a talking head.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text("Countdown")
                    .font(.callout)
                    .frame(width: 96, alignment: .leading)
                Picker("", selection: $recorder.countdownSeconds) {
                    Text("None").tag(0)
                    Text("3s").tag(3)
                    Text("5s").tag(5)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .disabled(recorder.phase.isBusy)
            }

            HStack {
                Text("Save To")
                    .font(.callout)
                    .frame(width: 96, alignment: .leading)
                Text(recorder.destinationName)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Button("Change…") { recorder.chooseDestinationFolder() }
                    .controlSize(.small)
            }

            Text("Recordings start with \(GlobalHotKey.displayName) from anywhere, without bringing Halo to the front.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
    }
}
