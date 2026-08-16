import CoreGraphics

/// What a recording captures.
public enum CaptureTarget: Identifiable, Hashable, Sendable {
    case display(DisplaySource)
    case window(WindowSource)

    public var id: String {
        switch self {
        case .display(let display): "display:\(display.id)"
        case .window(let window): "window:\(window.id)"
        }
    }

    public var name: String {
        switch self {
        case .display(let display): display.name
        case .window(let window): window.title
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
        }
    }

    /// The origin of the captured area in screen points, which the bubble's
    /// position is measured from.
    public var originInScreenPoints: CGPoint? {
        switch self {
        case .display: nil  // resolved from the matching NSScreen
        case .window(let window): window.frame.origin
        }
    }

    public var scale: Int {
        switch self {
        case .display(let display): display.scale
        case .window(let window): window.scale
        }
    }

    private static func even(_ value: CGFloat) -> CGFloat {
        let rounded = max(2, value.rounded())
        return rounded.truncatingRemainder(dividingBy: 2) == 0 ? rounded : rounded - 1
    }
}
