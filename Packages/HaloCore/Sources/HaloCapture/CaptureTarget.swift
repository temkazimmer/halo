import CoreGraphics

/// What a recording captures.
///
/// Neither `Sendable` nor `Hashable`, because a system-picker selection carries
/// an `SCContentFilter` that is neither. It is only ever used on the main actor,
/// and the UI selects on `id`.
public enum CaptureTarget: Identifiable {
    case display(DisplaySource)
    case window(WindowSource)
    /// Chosen through the macOS system picker, which hands back an opaque filter
    /// rather than a display or a window.
    case picked(PickedContent)

    public var id: String {
        switch self {
        case .display(let display): "display:\(display.id)"
        case .window(let window): "window:\(window.id)"
        case .picked(let picked): picked.id
        }
    }

    public var name: String {
        switch self {
        case .display(let display): display.name
        case .window(let window): window.title
        case .picked(let picked): picked.name
        }
    }

    /// Output dimensions, in native pixels.
    ///
    /// Fixed when recording starts. A window resized mid-recording keeps the
    /// same output size and is scaled into it by ScreenCaptureKit — changing the
    /// encoder's dimensions partway through is not possible.
    public var pixelSize: CGSize {
        switch self {
        case .display(let display):
            display.pixelSize
        case .window(let window):
            // Encoders reject odd dimensions, and a window can be any size.
            CGSize(
                width: Self.even(window.frame.width * CGFloat(window.scale)),
                height: Self.even(window.frame.height * CGFloat(window.scale)))
        case .picked(let picked):
            picked.pixelSize
        }
    }

    /// The origin of the captured area in screen points, which the bubble's
    /// position is measured from.
    public var originInScreenPoints: CGPoint? {
        switch self {
        case .display, .picked: nil  // resolved from the matching NSScreen
        case .window(let window): window.frame.origin
        }
    }

    public var scale: Int {
        switch self {
        case .display(let display): display.scale
        case .window(let window): window.scale
        case .picked(let picked): picked.scale
        }
    }

    private static func even(_ value: CGFloat) -> CGFloat {
        let rounded = max(2, value.rounded())
        return rounded.truncatingRemainder(dividingBy: 2) == 0 ? rounded : rounded - 1
    }
}
