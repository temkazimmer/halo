import SwiftUI

/// The main window. Until every grant is in place there is nothing useful to
/// show, so onboarding takes the whole window rather than sitting in a sheet.
struct ControlPanelView: View {
    @Environment(PermissionsModel.self) private var permissions
    @State private var recorder = RecorderModel()

    var body: some View {
        Group {
            if permissions.isReady {
                VStack(spacing: 0) {
                    SourcePickerView()
                    Divider()
                    ScrollView {
                        VStack(spacing: 0) {
                            CameraSettingsView()
                            Divider()
                            AudioSettingsView()
                        }
                    }
                    .frame(maxHeight: 340)
                    Divider()
                    RecordingControlsView()
                }
                .environment(recorder)
                .task { await recorder.loadSources() }
            } else {
                OnboardingView()
            }
        }
        .frame(minWidth: 460, minHeight: 640)
    }
}
