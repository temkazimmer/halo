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
    /// Fine softness beyond the analytic antialiasing, in points. Small by
    /// nature — for a visible soft edge use `edgeBlur`.
    public var feather: Double
    /// Wide, soft falloff as a fraction of the bubble's half-extent, 0...1.
    ///
    /// Relative rather than absolute so a blurred bubble looks the same at any
    /// size — an edge measured in points would tighten as the bubble grew.
    public var edgeBlur: Double
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
        edgeBlur: Double = 0,
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
        self.edgeBlur = edgeBlur
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

    /// The panel's edge length: enough for the shape at its true extent, plus
    /// room for any border and shadow.
    ///
    /// Sizing to `size` alone clips every shape that reaches past radius 1 — a
    /// high-amplitude blob most obviously — and because the clip follows the
    /// window edge it appears as a rectangle around the bubble.
    public var panelSize: Double {
        // Blur spreads outwards from the edge, so it needs room just as a border
        // or shadow does — otherwise the falloff is cut off square by the panel.
        let blurSpread = size / 2 * edgeBlur
        return size * shape.boundingRadius + (decorationPadding + blurSpread) * 2
    }

    /// Decoded field by field so a style saved before a parameter existed still
    /// loads — synthesised `Decodable` requires every key, which would silently
    /// discard the user's saved presets on the first update that adds one.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = BubbleStyle()
        shape = try container.decodeIfPresent(BubbleShape.self, forKey: .shape) ?? fallback.shape
        size = try container.decodeIfPresent(Double.self, forKey: .size) ?? fallback.size
        aspect = try container.decodeIfPresent(Double.self, forKey: .aspect) ?? fallback.aspect
        rotation = try container.decodeIfPresent(Double.self, forKey: .rotation) ?? fallback.rotation
        zoom = try container.decodeIfPresent(Double.self, forKey: .zoom) ?? fallback.zoom
        offset = try container.decodeIfPresent(CGPoint.self, forKey: .offset) ?? fallback.offset
        mirrorPreview = try container.decodeIfPresent(Bool.self, forKey: .mirrorPreview)
            ?? fallback.mirrorPreview
        mirrorOutput = try container.decodeIfPresent(Bool.self, forKey: .mirrorOutput)
            ?? fallback.mirrorOutput
        feather = try container.decodeIfPresent(Double.self, forKey: .feather) ?? fallback.feather
        edgeBlur = try container.decodeIfPresent(Double.self, forKey: .edgeBlur) ?? fallback.edgeBlur
        border = try container.decodeIfPresent(BorderStyle.self, forKey: .border)
        shadow = try container.decodeIfPresent(ShadowStyle.self, forKey: .shadow)
    }

    public func clamped() -> BubbleStyle {
        var copy = self
        copy.shape = shape.clamped()
        copy.size = min(520, max(120, size))
        copy.aspect = min(2, max(0.5, aspect))
        copy.zoom = min(3, max(1, zoom))
        copy.feather = min(8, max(0, feather))
        copy.edgeBlur = min(1, max(0, edgeBlur))
        copy.offset = CGPoint(
            x: min(1, max(-1, offset.x)), y: min(1, max(-1, offset.y)))
        return copy
    }
}
