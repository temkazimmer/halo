import CoreVideo
import HaloShapes
import Metal
import Testing

@testable import HaloComposite

/// Renders each shape and measures the mask it produces. The SDFs live in Metal,
/// so this is the only place their behaviour can actually be checked.
@Suite("Shape rendering")
struct ShapeRenderTests {
    private static let side = 256

    @Test("Every shape produces a mask that covers part, but not all, of its box")
    func allShapesProduceAPlausibleMask() throws {
        for shape in BubbleShape.allKinds {
            let coverage = try Self.coverage(of: shape)
            #expect(coverage > 0.05, "\(shape.name) produced an empty mask")
            #expect(coverage < 0.99, "\(shape.name) filled its entire box")
        }
    }

    @Test("Coverage ranks the way the geometry implies")
    func coverageMatchesGeometry() throws {
        let circle = try Self.coverage(of: .circle)
        let boxy = try Self.coverage(of: .squircle(exponent: 12))
        let star = try Self.coverage(of: .star(points: 5, innerRatio: 0.4, rounding: 0))
        let triangle = try Self.coverage(of: .polygon(sides: 3, rounding: 0))

        // A near-square superellipse encloses more of its box than a circle,
        // which in turn encloses more than a five-pointed star.
        #expect(boxy > circle)
        #expect(circle > star)
        // A triangle is the sparsest regular polygon.
        #expect(circle > triangle)
    }

    @Test("A squircle interpolates between circle and square as its exponent rises")
    func squircleExponentInterpolates() throws {
        let low = try Self.coverage(of: .squircle(exponent: 2))
        let mid = try Self.coverage(of: .squircle(exponent: 4))
        let high = try Self.coverage(of: .squircle(exponent: 12))

        #expect(mid > low)
        #expect(high > mid)
        // Exponent 2 is a circle by definition, so it should match one closely.
        let circle = try Self.coverage(of: .circle)
        #expect(abs(low - circle) < 0.01)
    }

    @Test("More star points means more, thinner arms")
    func starPointsChangeCoverage() throws {
        let five = try Self.coverage(of: .star(points: 5, innerRatio: 0.4, rounding: 0))
        let ten = try Self.coverage(of: .star(points: 10, innerRatio: 0.4, rounding: 0))
        #expect(ten > five)

        // A star whose inner radius approaches its outer approaches a polygon.
        let fat = try Self.coverage(of: .star(points: 5, innerRatio: 0.9, rounding: 0))
        #expect(fat > five)
    }

    @Test("Rounding a polygon keeps its size instead of inflating it")
    func roundingPreservesSize() throws {
        let sharp = try Self.coverage(of: .polygon(sides: 5, rounding: 0))
        let rounded = try Self.coverage(of: .polygon(sides: 5, rounding: 0.3))

        // Rounding an SDF shape is erode-then-dilate, a morphological opening,
        // which no plain distance offset can express — so area cannot simply
        // shrink. What matters for the control is that the bubble does not
        // change size when the slider moves: plain `d - r` inflated coverage by
        // more than half, which read as the bubble growing.
        #expect(rounded > sharp)
        #expect(rounded < sharp * 1.25)
    }

    @Test("Edge blur widens the falloff, and works on any shape")
    func edgeBlurSoftensAnyShape() throws {
        for shape in [BubbleShape.circle, .star(points: 5, innerRatio: 0.45, rounding: 0)] {
            let sharp = try Self.transitionWidth(of: shape, blur: 0)
            let soft = try Self.transitionWidth(of: shape, blur: 0.35)
            #expect(
                soft > sharp * 4,
                "\(shape.name) blurred barely wider than sharp: \(soft) vs \(sharp)")
        }
    }

    @Test("Raising blur widens the edge monotonically")
    func blurIsProgressive() throws {
        let none = try Self.transitionWidth(of: .circle, blur: 0)
        let some = try Self.transitionWidth(of: .circle, blur: 0.15)
        let lots = try Self.transitionWidth(of: .circle, blur: 0.4)
        #expect(some > none)
        #expect(lots > some)
    }

    /// How many pixels along a horizontal line through the centre are partially
    /// transparent — which is exactly what "how blurred is the edge" means.
    private static func transitionWidth(of shape: BubbleShape, blur: Double) throws -> Int {
        let compositor = try Compositor()
        let camera = try filled(red: 255, green: 255, blue: 255)
        var style = BubbleStyle(shape: shape, feather: 0)
        style.edgeBlur = blur

        let pixels = try renderPreview(compositor, camera: camera, style: style)
        var partial = 0
        for x in 0..<side {
            let alpha = sample(pixels, x: x, y: side / 2).alpha
            if alpha > 8 && alpha < 247 { partial += 1 }
        }
        return partial
    }

    @Test("A border draws a ring on the shape's own edge")
    func borderDrawsOnTheEdge() throws {
        let compositor = try Compositor()
        let camera = try Self.filled(red: 0, green: 0, blue: 0)

        var style = BubbleStyle(shape: .circle, feather: 0)
        style.border = BorderStyle(width: 10, color: .white)

        let pixels = try Self.renderPreview(compositor, camera: camera, style: style)

        // The bubble is inset by border width and shadow, so measure relative to
        // the mask itself: walk out from the centre and find the brightest ring.
        var brightestRadius = 0
        var brightest: Int = -1
        for radius in 0..<(Self.side / 2) {
            let value = Int(Self.sample(pixels, x: Self.side / 2 + radius, y: Self.side / 2).red)
            if value > brightest {
                brightest = value
                brightestRadius = radius
            }
        }

        // White border against a black camera: the brightest point must be well
        // out towards the rim rather than in the middle.
        #expect(brightest > 180)
        #expect(brightestRadius > Self.side / 5)
    }

    // MARK: - Helpers

    private struct Pixel {
        let red: UInt8
        let alpha: UInt8
    }

    /// Fraction of the layer the mask covers, measured from the preview's alpha.
    private static func coverage(of shape: BubbleShape) throws -> Double {
        let compositor = try Compositor()
        let camera = try filled(red: 255, green: 255, blue: 255)
        // No feather, border or shadow: measuring the shape alone.
        let style = BubbleStyle(shape: shape, feather: 0)
        let pixels = try renderPreview(compositor, camera: camera, style: style)

        var covered = 0
        for y in 0..<side {
            for x in 0..<side where sample(pixels, x: x, y: y).alpha > 127 {
                covered += 1
            }
        }
        return Double(covered) / Double(side * side)
    }

    private static func renderPreview(
        _ compositor: Compositor, camera: CVPixelBuffer, style: BubbleStyle
    ) throws -> [UInt8] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: side, height: side, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let target = compositor.device.makeTexture(descriptor: descriptor) else {
            throw CompositorError.textureCreationFailed
        }

        try compositor.renderPreview(
            camera: camera,
            cameraPixelFormat: kCVPixelFormatType_32BGRA,
            style: style,
            bubbleSize: CGFloat(side) * 0.8,
            pixelSize: CGSize(width: side, height: side),
            into: target)

        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        pixels.withUnsafeMutableBytes { raw in
            target.getBytes(
                raw.baseAddress!, bytesPerRow: side * 4,
                from: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0)
        }
        return pixels
    }

    private static func sample(_ pixels: [UInt8], x: Int, y: Int) -> Pixel {
        let offset = (y * side + x) * 4
        return Pixel(red: pixels[offset + 2], alpha: pixels[offset + 3])
    }

    private static func filled(red: UInt8, green: UInt8, blue: UInt8) throws -> CVPixelBuffer {
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, side, side, kCVPixelFormatType_32BGRA,
            attributes as CFDictionary, &buffer) == kCVReturnSuccess,
            let buffer
        else { throw CompositorError.textureCreationFailed }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw CompositorError.textureCreationFailed
        }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<side {
            for x in 0..<side {
                let offset = y * stride + x * 4
                bytes[offset] = blue
                bytes[offset + 1] = green
                bytes[offset + 2] = red
                bytes[offset + 3] = 255
            }
        }
        return buffer
    }
}
