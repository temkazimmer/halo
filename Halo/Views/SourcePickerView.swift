import HaloCapture
import SwiftUI

/// Choose what to record: a whole display, or a single window.
struct SourcePickerView: View {
    @Environment(RecorderModel.self) private var recorder

    var body: some View {
        @Bindable var recorder = recorder

        VStack(alignment: .leading, spacing: 0) {
            header

            List(selection: $recorder.selectedTargetID) {
                Section("Displays") {
                    if recorder.sources.displays.isEmpty {
                        Text("No displays found").foregroundStyle(.secondary)
                    } else {
                        ForEach(recorder.sources.displays) { display in
                            DisplayRow(display: display)
                                .tag(CaptureTarget.display(display).id)
                        }
                    }
                }

                Section("Windows") {
                    if recorder.sources.windows.isEmpty {
                        Text("No windows found").foregroundStyle(.secondary)
                    } else {
                        ForEach(recorder.sources.windows) { window in
                            WindowRow(window: window)
                                .tag(CaptureTarget.window(window).id)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .alternatingRowBackgrounds()
            .disabled(recorder.phase.isBusy)
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
            .disabled(recorder.isLoadingSources || recorder.phase.isBusy)
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
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(window.title).lineLimit(1)
                Text("\(window.applicationName)  ·  \(size)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private var size: String {
        let pixels = CaptureTarget.window(window).pixelSize
        return "\(Int(pixels.width)) × \(Int(pixels.height))"
    }
}
