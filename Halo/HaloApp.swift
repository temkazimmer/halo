import SwiftUI

@main
struct HaloApp: App {
    /// Owned here so the menu bar and the window observe one source of truth.
    @State private var permissions = PermissionsModel()

    static let mainWindowID = "halo.main"

    var body: some Scene {
        Window("Halo", id: Self.mainWindowID) {
            ControlPanelView()
                .environment(permissions)
        }
        .defaultSize(width: 480, height: 720)
        .windowResizability(.contentMinSize)

        MenuBarExtra("Halo", systemImage: permissions.isReady ? "circle.dashed" : "exclamationmark.circle") {
            MenuBarContent()
                .environment(permissions)
        }
    }
}

private struct MenuBarContent: View {
    @Environment(PermissionsModel.self) private var permissions
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if !permissions.isReady {
            Text("Setup incomplete")
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
}
