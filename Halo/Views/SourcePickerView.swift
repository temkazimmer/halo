import HaloCapture
import SwiftUI

/// Choose what to record. Displays are selectable; windows are listed but not yet
/// a capture target, and say so rather than silently doing nothing.
struct SourcePickerView: View {
    @Environment(RecorderModel.self) private var recorder

    var body: some View {
        @Bindable var recorder = recorder

        VStack(alignment: .leading, spacing: 0) {
            header

            List(selection: $recorder.selectedDisplayID) {
                Section("Displays") {
                    if recorder.sources.displays.isEmpty {
                        Text("No displays found").foregroundStyle(.secondary)
                    } else {
                        ForEach(recorder.sources.displays) { display in
                            DisplayRow(display: display).tag(display.id)
                        }
                    }
                }

                Section {
                    ForEach(recorder.sources.windows) { WindowRow(window: $0) }
                } header: {
                    Text("Windows")
                } footer: {
                    Text("Window capture arrives in a later phase.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset)
            .alternatingRowBackgrounds()
            .disabled(recorder.phase != .idle)
        }
    }

    private var header: some View {
        HStack {
            Text("Sources")
                .font(.title3.weight(.semibold))
            Spacer()
            Button {
                Task { await recorder.loadSources() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(recorder.isLoadingSources || recorder.phase != .idle)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }
}

private struct DisplayRow: View {
    let display: DisplaySource

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "display")
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(display.name)
                Text(resolution)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer(minLength: 0)

            if display.isMain {
                Text("Main")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: .capsule)
            }
        }
        .padding(.vertical, 2)
    }

    private var resolution: String {
        let size = display.pixelSize
        return "\(Int(size.width)) × \(Int(size.height))  ·  \(display.scale)×"
    }
}

private struct WindowRow: View {
    let window: WindowSource

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "macwindow")
                .foregroundStyle(.tertiary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(window.title).lineLimit(1)
                Text(window.applicationName)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .foregroundStyle(.secondary)
        .selectionDisabled()
    }
}
