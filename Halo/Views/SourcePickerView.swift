import HaloCapture
import SwiftUI

/// Lists what can be recorded. Phase 0 only shows the inventory — choosing a
/// source starts mattering in Phase 1.
struct SourcePickerView: View {
    @State private var sources = ShareableSources()
    @State private var errorMessage: String?
    @State private var isLoading = false

    private let provider = ShareableContentProvider()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Sources")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    Task { await load() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            List {
                Section("Displays") {
                    if sources.displays.isEmpty {
                        Text("No displays found")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(sources.displays) { DisplayRow(display: $0) }
                    }
                }

                Section("Windows") {
                    if sources.windows.isEmpty {
                        Text("No windows found")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(sources.windows) { WindowRow(window: $0) }
                    }
                }
            }
            .listStyle(.inset)
            .alternatingRowBackgrounds()
        }
        .padding(24)
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            // Re-fetched every time: SCShareableContent snapshots go stale at once.
            sources = try await provider.fetch()
            errorMessage = nil
        } catch ShareableContentError.permissionDenied {
            errorMessage = "Screen Recording permission was revoked. Grant it again and relaunch Halo."
        } catch {
            errorMessage = error.localizedDescription
        }
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
                Text(window.title)
                    .lineLimit(1)
                Text(window.applicationName)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}
