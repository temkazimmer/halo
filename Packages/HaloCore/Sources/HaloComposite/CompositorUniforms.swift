import CoreGraphics
import HaloShapes
import simd

/// Per-frame parameters handed to the fragment shader.
///
/// **This must stay byte-identical to `Uniforms` in `Shaders.metal`.** The two
/// are declared separately because the shader is compiled from a package
/// resource rather than through a bridging header, so nothing enforces the match
/// at compile time — `CompositorTests` asserts size, alignment and stride
/// instead, and a drift shows up as a failing test rather than corrupt video.
///
/// Fields are ordered widest-first, following Metal's alignment rules: `float4`
/// is 16-byte aligned, `float2` is 8-byte aligned, scalars are 4.
struct CompositorUniforms {
    var borderColor: SIMD4<Float>
    var shadowColor: SIMD4<Float>

    var bubbleCentre: SIMD2<Float>
    var bubbleRadius: SIMD2<Float>
    var cameraOffset: SIMD2<Float>
    var shadowOffset: SIMD2<Float>

    var cornerAntialias: Float
    var feather: Float
    var cameraAspect: Float
    var zoom: Float
    var rotation: Float
    var aspect: Float
    var shapeA: Float
    var shapeB: Float
    var shapeC: Float
    var shapeD: Float
    var borderWidth: Float
    var shadowRadius: Float
    var shadowOpacity: Float
    /// Reserved: the shape system is static for now, but the SDFs would animate
    /// for free, so the uniform is plumbed through rather than retrofitted.
    var time: Float

    var shapeKind: UInt32
    var mirrorCamera: UInt32
    var cameraIsYCbCr: UInt32
    var cameraIsFullRange: UInt32
    var hasCamera: UInt32
    var hasScreen: UInt32
}

/// Where the bubble sits in the output frame, and how it looks there.
public struct BubbleLayout: Equatable, Sendable {
    /// Bubble centre in output pixels.
    public var centre: CGPoint
    /// Bubble long edge in output pixels.
    public var size: CGFloat
    public var style: BubbleStyle
    /// Whether *this* destination mirrors the camera. The preview does and the
    /// recording does not, so it is a per-destination decision rather than part
    /// of the shared style.
    public var mirrored: Bool

    public init(
        centre: CGPoint,
        size: CGFloat,
        style: BubbleStyle = BubbleStyle(),
        mirrored: Bool = false
    ) {
        self.centre = centre
        self.size = size
        self.style = style
        self.mirrored = mirrored
    }
}

extension SIMD4<Float> {
    init(_ color: BubbleColor) {
        self.init(
            Float(color.red), Float(color.green), Float(color.blue), Float(color.alpha))
    }
}
