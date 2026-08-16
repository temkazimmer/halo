import SwiftUI

/// The main window. Until every grant is in place there is nothing useful to
/// show, so onboarding takes the whole window rather than sitting in a sheet.
struct ControlPanelView: View {
    @Environment(PermissionsModel.self) private var permissions

    var body: some View {
        Group {
            if permissions.isReady {
                SourcePickerView()
            } else {
                OnboardingView()
            }
        }
        .frame(minWidth: 420, minHeight: 480)
    }
}
