import SwiftUI

/// The main window. Until every grant is in place there is nothing useful to
/// show, so onboarding takes the whole window rather than sitting in a sheet.
struct ControlPanelView: View {
    @Environment(PermissionsModel.self) private var permissions
    @Environment(RecorderModel.self) private var recorder

    var body: some View {
        Group {
            if permissions.isReady {
                VStack(spacing: 0) {
                    SourcePickerView()
                    Divider()
                    ScrollView {
                        VStack(spacing: 0) {
                            CameraSettingsView()
                            if recorder.isBubbleVisible {
                                Divider()
                                ShapeInspectorView()
                            }
                            Divider()
                            AudioSettingsView()
                            Divider()
                            RecordingSettingsView()
                        }
                    }
                    .frame(maxHeight: 420)
                    Divider()
                    RecordingControlsView()
                }
                .task { await recorder.loadSources() }
                // Settings are saved as the window closes rather than on every
                // keystroke.
                .onDisappear { recorder.persistSettings() }
            } else {
                OnboardingView()
            }
        }
        .frame(minWidth: 460, minHeight: 640)
    }
}
