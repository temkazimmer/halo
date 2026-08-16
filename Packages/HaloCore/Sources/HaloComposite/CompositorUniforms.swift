import CoreGraphics
import simd

/// Per-frame parameters handed to the fragment shader.
///
/// **This must stay byte-identical to `Uniforms` in `Shaders.metal`.** The two
/// are declared separately because the shader is compiled from a package
/// resource rather than through a bridging header, so nothing enforces the
/// match at compile time — `CompositorUniformsTests` asserts size and alignment
/// instead, and a drift shows up as a failing test rather than corrupt video.
///
/// Field order follows Metal's alignment rules: `float2` is 8-byte aligned, so
/// the pairs come first and the scalars follow.
struct CompositorUniforms {
    var bubbleCentre: SIMD2<Float>
    var bubbleRadius: SIMD2<Float>
    var cornerAntialias: Float
    var feather: Float
    var cameraAspect: Float
    var zoom: Float
    var cameraOffset: SIMD2<Float>
    var mirrorCamera: UInt32
    var cameraIsYCbCr: UInt32
    var cameraIsFullRange: UInt32
    var hasCamera: UInt32
    var hasScreen: UInt32
}

/// Where the bubble sits within the output frame, and how the camera is framed
/// inside it. Phase 5 grows this into the full `BubbleStyle`.
public struct BubbleLayout: Equatable, Sendable {
    /// Bubble centre in output pixels.
    public var centre: CGPoint
    /// Bubble diameter in output pixels.
    public var size: CGFloat
    /// 1.0 fills the mask; higher crops in.
    public var zoom: CGFloat
    /// Pan within the mask, in units of the mask's half-extent.
    public var offset: CGPoint
    /// Extra edge softness beyond the analytic antialiasing, in pixels.
    public var feather: CGFloat
    /// Whether the *recording* is mirrored. Defaults to false: viewers expect
    /// text behind you to read correctly, even though you expect to see
    /// yourself mirrored in the preview.
    public var mirrored: Bool

    public init(
        centre: CGPoint,
        size: CGFloat,
        zoom: CGFloat = 1.0,
        offset: CGPoint = .zero,
        feather: CGFloat = 0.5,
        mirrored: Bool = false
    ) {
        self.centre = centre
        self.size = size
        self.zoom = zoom
        self.offset = offset
        self.feather = feather
        self.mirrored = mirrored
    }
}
