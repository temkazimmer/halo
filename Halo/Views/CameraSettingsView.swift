import HaloCapture
import SwiftUI

/// Camera bubble controls. The bubble itself is an `NSPanel`, not part of this
/// window — this only turns it on and picks the device.
struct CameraSettingsView: View {
    @Environment(RecorderModel.self) private var recorder

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Camera")
                    .font(.title3.weight(.semibold))
                Spacer()
                Toggle("Show Bubble", isOn: Binding(
                    get: { recorder.isBubbleVisible },
                    set: { _ in recorder.toggleBubble() }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(recorder.cameraDevices.isEmpty)
            }

            if recorder.cameraDevices.isEmpty {
                Text("No camera found.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Device", selection: Binding(
                    get: { recorder.selectedCameraID },
                    set: { recorder.selectCamera($0) })
                ) {
                    ForEach(recorder.cameraDevices) { device in
                        Text(device.name).tag(String?.some(device.id))
                    }
                }
                .labelsHidden()

                Text("Drag the bubble to move it, scroll over it to resize. It snaps to the nearest corner or edge.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
    }
}
