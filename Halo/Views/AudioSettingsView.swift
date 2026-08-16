import HaloCapture
import HaloExport
import SwiftUI

/// Audio sources, their gains, and live levels.
struct AudioSettingsView: View {
    @Environment(RecorderModel.self) private var recorder

    var body: some View {
        @Bindable var recorder = recorder

        VStack(alignment: .leading, spacing: 14) {
            Text("Audio")
                .font(.title3.weight(.semibold))

            AudioSourceRow(
                title: "System Audio",
                systemImage: "speaker.wave.2",
                isEnabled: $recorder.capturesSystemAudio,
                gain: $recorder.systemAudioGain,
                level: recorder.levels[.systemAudio] ?? 0)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                AudioSourceRow(
                    title: "Microphone",
                    systemImage: "mic",
                    isEnabled: $recorder.capturesMicrophone,
                    gain: $recorder.microphoneGain,
                    level: recorder.levels[.microphone] ?? 0)

                if recorder.capturesMicrophone {
                    Picker("Input", selection: $recorder.microphoneDeviceID) {
                        Text("System Default").tag(String?.none)
                        ForEach(recorder.audioInputDevices) { device in
                            Text(device.name).tag(String?.some(device.id))
                        }
                    }
                    .labelsHidden()
                    // The device cannot change mid-stream — SCK reads it when the
                    // stream is configured.
                    .disabled(recorder.phase != .idle)
                }
            }
        }
        .padding(20)
    }
}

private struct AudioSourceRow: View {
    let title: String
    let systemImage: String
    @Binding var isEnabled: Bool
    @Binding var gain: Float
    let level: Float

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Toggle(isOn: $isEnabled) {
                    Label(title, systemImage: systemImage)
                }
                .toggleStyle(.checkbox)

                Spacer(minLength: 0)

                LevelMeter(level: isEnabled ? level : 0)
                    .frame(width: 90, height: 6)
            }

            HStack(spacing: 10) {
                Image(systemName: "speaker.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Slider(value: $gain, in: 0...2)
                Text(String(format: "%.0f%%", gain * 100))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)
            }
            .disabled(!isEnabled)
            .opacity(isEnabled ? 1 : 0.4)
        }
    }
}

/// A peak meter. Gain is adjustable while recording, so this has to stay live
/// throughout, not just while armed.
private struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(level > 0.95 ? Color.red : .green)
                    .frame(width: proxy.size.width * CGFloat(min(1, max(0, level))))
            }
        }
        .animation(.linear(duration: 0.08), value: level)
    }
}
