import SwiftUI

/// First-run surface: the three grants Halo needs, and the relaunch that macOS
/// requires before a fresh Screen Recording grant takes effect.
struct OnboardingView: View {
    @Environment(PermissionsModel.self) private var permissions

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            VStack(spacing: 0) {
                ForEach(Array(Permission.allCases.enumerated()), id: \.element) { index, permission in
                    if index > 0 { Divider() }
                    PermissionRow(permission: permission)
                }
            }
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))

            if permissions.needsRelaunch {
                relaunchNotice
            }

            Spacer(minLength: 0)
        }
        .padding(24)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Welcome to Halo")
                .font(.title2.weight(.semibold))
            Text("Halo records entirely on this Mac. Nothing is uploaded, and the app makes no network requests at all.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var relaunchNotice: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .font(.title2)
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 4) {
                Text("Relaunch to finish")
                    .font(.callout.weight(.semibold))
                Text("macOS only applies a new Screen Recording grant to a freshly started app.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Button("Relaunch") { permissions.relaunch() }
                .buttonStyle(.borderedProminent)
        }
        .padding(14)
        .background(.tint.opacity(0.1), in: .rect(cornerRadius: 10))
    }
}

private struct PermissionRow: View {
    @Environment(PermissionsModel.self) private var permissions
    let permission: Permission

    private var status: PermissionStatus { permissions.status(of: permission) }

    var body: some View {
        HStack(spacing: 12) {
            statusIcon
                .font(.title3)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title)
                    .font(.callout.weight(.medium))
                Text(permission.rationale)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            action
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .granted:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .denied:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .notDetermined:
            Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var action: some View {
        switch status {
        case .granted:
            EmptyView()
        case .notDetermined:
            Button("Grant") {
                Task { await permissions.request(permission) }
            }
        case .denied:
            // The system prompt only ever appears once, so past that point the
            // only route back is System Settings.
            Button("Open Settings…") {
                permissions.openSettings(for: permission)
            }
        }
    }
}
