import CoreGraphics

/// An RGBA colour, kept free of AppKit so the model stays testable and Codable.
public struct BubbleColor: Equatable, Codable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let white = BubbleColor(red: 1, green: 1, blue: 1)
    public static let black = BubbleColor(red: 0, green: 0, blue: 0)
}

public struct BorderStyle: Equatable, Codable, Hashable, Sendable {
    /// Width in points, drawn centred on the shape's edge.
    public var width: Double
    public var color: BubbleColor

    public init(width: Double = 3, color: BubbleColor = .white) {
        self.width = width
        self.color = color
    }
}

public struct ShadowStyle: Equatable, Codable, Hashable, Sendable {
    /// Falloff distance in points.
    public var radius: Double
    public var opacity: Double
    public var offset: CGPoint
    public var color: BubbleColor

    public init(
        radius: Double = 24,
        opacity: Double = 0.35,
        offset: CGPoint = CGPoint(x: 0, y: 8),
        color: BubbleColor = .black
    ) {
        self.radius = radius
        self.opacity = opacity
        self.offset = offset
        self.color = color
    }
}

/// Everything about how the bubble looks and how the camera sits inside it.
public struct BubbleStyle: Equatable, Codable, Hashable, Sendable {
    public var shape: BubbleShape

    // Geometry
    /// Long edge, in points.
    public var size: Double
    /// Squashes any shape. 1.0 is unsquashed.
    public var aspect: Double
    /// Rotation in radians.
    public var rotation: Double

    // Camera framing inside the mask
    public var zoom: Double
    /// Pan within the mask, in units of its half-extent.
    public var offset: CGPoint
    /// People expect to see themselves mirrored...
    public var mirrorPreview: Bool
    /// ...but viewers expect text behind you to read correctly. Getting this
    /// pair backwards is the classic webcam-app complaint.
    public var mirrorOutput: Bool

    // Edge
    /// Softness beyond the analytic antialiasing, in points.
    public var feather: Double
    public var border: BorderStyle?
    public var shadow: ShadowStyle?

    public init(
        shape: BubbleShape = .circle,
        size: Double = 220,
        aspect: Double = 1,
        rotation: Double = 0,
        zoom: Double = 1,
        offset: CGPoint = .zero,
        mirrorPreview: Bool = true,
        mirrorOutput: Bool = false,
        feather: Double = 0.5,
        border: BorderStyle? = nil,
        shadow: ShadowStyle? = nil
    ) {
        self.shape = shape
        self.size = size
        self.aspect = aspect
        self.rotation = rotation
        self.zoom = zoom
        self.offset = offset
        self.mirrorPreview = mirrorPreview
        self.mirrorOutput = mirrorOutput
        self.feather = feather
        self.border = border
        self.shadow = shadow
    }

    /// Extra room the panel needs around the shape so a border or shadow is not
    /// clipped by the window edge.
    public var decorationPadding: Double {
        let borderWidth = border?.width ?? 0
        guard let shadow else { return borderWidth }
        let drift = max(abs(shadow.offset.x), abs(shadow.offset.y))
        return borderWidth + shadow.radius + drift
    }

    public func clamped() -> BubbleStyle {
        var copy = self
        copy.shape = shape.clamped()
        copy.size = min(520, max(120, size))
        copy.aspect = min(2, max(0.5, aspect))
        copy.zoom = min(3, max(1, zoom))
        copy.feather = min(8, max(0, feather))
        copy.offset = CGPoint(
            x: min(1, max(-1, offset.x)), y: min(1, max(-1, offset.y)))
        return copy
    }
}
