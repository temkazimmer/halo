import ScreenCaptureKit

/// A selection made in the macOS system picker.
///
/// The picker hands back an opaque `SCContentFilter` rather than a display or a
/// window, so the dimensions have to be read back from it — which is what
/// `SCShareableContent.info(for:)` is for.
///
/// `@unchecked Sendable` because `SCContentFilter` carries no annotation but is
/// an immutable description of what to capture, created once by the picker and
/// only read afterwards. The picker's callback arrives on an unspecified queue,
/// so this value has to reach the main actor somehow.
public struct PickedContent: Identifiable, @unchecked Sendable {
    public let id: String
    public let name: String
    public let filter: SCContentFilter
    public let pixelSize: CGSize
    public let scale: Int

    init?(filter: SCContentFilter, id: String) {
        let info = SCShareableContent.info(for: filter)
        let scale = CGFloat(info.pointPixelScale)
        let rect = info.contentRect
        guard rect.width > 0, rect.height > 0 else { return nil }

        self.id = id
        self.filter = filter
        self.scale = Int(scale.rounded())
        // Encoders reject odd dimensions and the picker can return any rect.
        self.pixelSize = CGSize(
            width: Self.even(rect.width * scale),
            height: Self.even(rect.height * scale))

        self.name = switch info.style {
        case .display: "Screen"
        case .window: "Window"
        case .application: "App"
        default: "Selection"
        }
    }

    private static func even(_ value: CGFloat) -> CGFloat {
        let rounded = max(2, value.rounded())
        return rounded.truncatingRemainder(dividingBy: 2) == 0 ? rounded : rounded - 1
    }
}

/// Wraps `SCContentSharingPicker`, the system panel for choosing what to share.
///
/// Apple's documented recommendation, and it satisfies Guideline 5.1.1(iii) data
/// minimisation: the app never enumerates what it was not given.
@MainActor
public final class ContentPicker: NSObject {
    /// Fired when the user picks something, or picks again while recording.
    public var onPick: ((PickedContent) -> Void)?
    public var onCancel: (() -> Void)?
    public var onFailure: ((String) -> Void)?

    private var isObserving = false

    public override init() {
        super.init()
    }

    deinit {
        // `removeObserver` is safe from any thread and the picker is a singleton
        // that outlives us either way.
        SCContentSharingPicker.shared.remove(self)
    }

    /// Shows the system panel.
    ///
    /// - Parameter excludedWindowIDs: Halo's own overlays, so they cannot be
    ///   chosen as a recording target.
    public func present(excludedWindowIDs: [CGWindowID] = []) {
        let picker = SCContentSharingPicker.shared

        var configuration = SCContentSharingPickerConfiguration()
        configuration.excludedWindowIDs = excludedWindowIDs.map(Int.init)
        // Letting the selection change mid-stream is the picker's own affordance
        // for switching source without stopping.
        configuration.allowsChangingSelectedContent = true
        picker.defaultConfiguration = configuration

        if !isObserving {
            picker.add(self)
            isObserving = true
        }
        // Must be active before presenting, or nothing appears.
        picker.isActive = true
        picker.present()
    }

    /// Leaves the picker out of Control Center once we no longer need it.
    public func deactivate() {
        SCContentSharingPicker.shared.isActive = false
    }
}

extension ContentPicker: SCContentSharingPickerObserver {
    public nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        // Delivery queue is unspecified, so hop rather than assume — and build
        // the value here, because the filter itself cannot cross.
        guard let picked = PickedContent(filter: filter, id: "picked:\(UUID().uuidString)")
        else {
            Task { @MainActor in onFailure?("That selection could not be measured.") }
            return
        }
        Task { @MainActor in onPick?(picked) }
    }

    public nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didCancelFor stream: SCStream?
    ) {
        Task { @MainActor in onCancel?() }
    }

    public nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        let message = error.localizedDescription
        Task { @MainActor in onFailure?(message) }
    }
}
