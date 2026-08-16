import Foundation

/// The bubble's outline.
///
/// Every case is evaluated as a signed distance function in the fragment shader,
/// so shapes are resolution-independent, analytically antialiased, and free to
/// animate later — the parameters are just numbers in a uniform.
public enum BubbleShape: Equatable, Codable, Hashable, Sendable {
    case circle
    /// `2.0` is a circle, `4.0` is roughly Apple's continuous corner, `12.0` is
    /// nearly a square.
    case squircle(exponent: Double)
    /// Corner radius as a fraction of the half-extent, `0...1`.
    case roundedRect(cornerRadius: Double)
    case polygon(sides: Int, rounding: Double)
    case star(points: Int, innerRatio: Double, rounding: Double)
    case blob(lobes: Int, amplitude: Double, phase: Double, seed: UInt32)

    public static let allKinds: [BubbleShape] = [
        .circle,
        .squircle(exponent: 4),
        .roundedRect(cornerRadius: 0.35),
        .polygon(sides: 6, rounding: 0.1),
        .star(points: 5, innerRatio: 0.45, rounding: 0.06),
        .blob(lobes: 4, amplitude: 0.12, phase: 0, seed: 7),
    ]

    public var name: String {
        switch self {
        case .circle: "Circle"
        case .squircle: "Squircle"
        case .roundedRect: "Rounded Rect"
        case .polygon: "Polygon"
        case .star: "Star"
        case .blob: "Blob"
        }
    }

    /// Stable identity for picking in the UI, independent of parameter values.
    public var kindIndex: Int {
        switch self {
        case .circle: 0
        case .squircle: 1
        case .roundedRect: 2
        case .polygon: 3
        case .star: 4
        case .blob: 5
        }
    }

    /// Flat form handed to the shader.
    ///
    /// Packing every shape into four floats keeps the uniform struct small and
    /// fixed, so adding a shape never changes the Swift/Metal layout contract.
    /// The meaning of each slot is per-kind and documented in `Shaders.metal`.
    public var shaderParameters: (a: Float, b: Float, c: Float, d: Float) {
        switch self {
        case .circle:
            (0, 0, 0, 0)
        case .squircle(let exponent):
            (Float(exponent), 0, 0, 0)
        case .roundedRect(let cornerRadius):
            (Float(cornerRadius), 0, 0, 0)
        case .polygon(let sides, let rounding):
            (Float(sides), Float(rounding), 0, 0)
        case .star(let points, let innerRatio, let rounding):
            (Float(points), Float(innerRatio), Float(rounding), 0)
        case .blob(let lobes, let amplitude, let phase, let seed):
            // The seed only needs to decorrelate lobes, so folding it into a
            // small angle is enough and keeps it a float.
            (Float(lobes), Float(amplitude), Float(phase),
             Float(seed % 1000) / 1000 * 6.283_185)
        }
    }

    /// How far the outline reaches from the centre, in units of the nominal
    /// half-extent.
    ///
    /// Only a circle stays at 1. A blob's lobes push past it, and a squircle or
    /// rounded rect reaches out to its corners. The floating panel is sized by
    /// this, because a panel sized to 1.0 clips everything that exceeds it — and
    /// the clip is a straight window edge, so it reads as a rectangular box
    /// around the bubble.
    public var boundingRadius: Double {
        switch self {
        case .circle:
            return 1
        case .squircle(let exponent):
            // Superellipse |x|^n + |y|^n = 1 is furthest out along the diagonal,
            // at 2^(1/2 - 1/n): 1.0 at n = 2, rising towards sqrt(2).
            return pow(2, 0.5 - 1 / max(exponent, 2))
        case .roundedRect(let cornerRadius):
            let r = min(1, max(0, cornerRadius))
            return (1 - r) * 2.0.squareRoot() + r
        case .polygon, .star:
            // Both SDFs are built with a circumradius of 1, and the rounding
            // compensation preserves it.
            return 1
        case .blob(_, let amplitude, _, _):
            return 1 + max(0, amplitude)
        }
    }

    /// Clamps parameters into ranges the SDFs behave well over.
    ///
    /// Out-of-range values do not error, they just look wrong — a polygon with
    /// two sides, or a star whose inner radius exceeds its outer.
    public func clamped() -> BubbleShape {
        switch self {
        case .circle:
            .circle
        case .squircle(let exponent):
            .squircle(exponent: min(12, max(2, exponent)))
        case .roundedRect(let cornerRadius):
            .roundedRect(cornerRadius: min(1, max(0, cornerRadius)))
        case .polygon(let sides, let rounding):
            .polygon(sides: min(12, max(3, sides)), rounding: min(0.5, max(0, rounding)))
        case .star(let points, let innerRatio, let rounding):
            .star(
                points: min(12, max(3, points)),
                innerRatio: min(0.9, max(0.15, innerRatio)),
                rounding: min(0.5, max(0, rounding)))
        case .blob(let lobes, let amplitude, let phase, let seed):
            .blob(
                lobes: min(12, max(2, lobes)),
                amplitude: min(0.4, max(0, amplitude)),
                phase: phase,
                seed: seed)
        }
    }
}
