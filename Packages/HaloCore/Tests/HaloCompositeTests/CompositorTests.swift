import CoreVideo
import HaloShapes
import Metal
import Testing
import simd

@testable import HaloComposite

/// Renders real frames on the GPU and reads the pixels back. This is what makes
/// the shader itself testable despite being compiled from a resource: a syntax
/// error, a broken pipeline, or an inverted mask all fail here.
@Suite("Compositor")
struct CompositorTests {

    @Test("The shader compiles and the pipeline builds")
    func compositorInitialises() throws {
        _ = try Compositor()
    }

    @Test("Swift and Metal uniform layouts agree")
    func uniformLayoutIsStable() {
        // 2 float4 (16 each) + 4 float2 (8 each) + 15 float + 6 uint (4 each)
        // = 32 + 32 + 60 + 24. Guards the hand-maintained match with `Uniforms`
        // in Shaders.metal: adding a field on one side only shows up here rather
        // than as corrupt video.
        #expect(MemoryLayout<CompositorUniforms>.size == 148)
        #expect(MemoryLayout<CompositorUniforms>.alignment == 16)
        #expect(MemoryLayout<CompositorUniforms>.stride == 160)
    }

    @Test("The preview renders the same mask with a transparent surround")
    func previewIsPremultipliedAndTransparentOutside() throws {
        let compositor = try Compositor()
        let camera = try Self.buffer(width: 256, height: 256, red: 20, green: 40, blue: 240)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 256, height: 256, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let target = try #require(compositor.device.makeTexture(descriptor: descriptor))

        try compositor.renderPreview(
            camera: camera,
            cameraPixelFormat: kCVPixelFormatType_32BGRA,
            style: BubbleStyle(),
            bubbleSize: 200,
            pixelSize: CGSize(width: 256, height: 256),
            into: target)

        var pixels = [UInt8](repeating: 0, count: 256 * 256 * 4)
        pixels.withUnsafeMutableBytes { raw in
            target.getBytes(
                raw.baseAddress!, bytesPerRow: 256 * 4,
                from: MTLRegionMake2D(0, 0, 256, 256), mipmapLevel: 0)
        }

        // Centre of the bubble: opaque camera.
        let centre = (128 * 256 + 128) * 4
        #expect(pixels[centre + 3] == 255)
        #expect(pixels[centre] > pixels[centre + 2])  // blue channel dominant

        // Corner, outside the circle: fully transparent, so the desktop shows.
        let corner = (4 * 256 + 4) * 4
        #expect(pixels[corner + 3] == 0)
    }

    @Test("With no camera frame, the output is the screen untouched")
    func screenPassesThroughUnchanged() throws {
        let compositor = try Compositor()
        let screen = try Self.buffer(width: 128, height: 96, red: 230, green: 40, blue: 40)
        let destination = try Self.buffer(width: 128, height: 96, red: 0, green: 0, blue: 0)

        try compositor.render(
            screen: screen, camera: nil,
            cameraPixelFormat: kCVPixelFormatType_32BGRA,
            layout: nil, into: destination)

        let centre = try Self.pixel(destination, x: 64, y: 48)
        // Every pixel round-trips sRGB -> linear -> sRGB, so this has to be
        // essentially lossless. A wrong transfer exponent shows up here and
        // nowhere else — it once cost 18 code points on the blue channel.
        #expect(abs(Int(centre.red) - 230) <= 1)
        #expect(abs(Int(centre.green) - 40) <= 1)
        #expect(abs(Int(centre.blue) - 40) <= 1)
    }

    @Test("The camera fills the bubble and nothing outside it")
    func bubbleIsMaskedToItsCircle() throws {
        let compositor = try Compositor()
        let screen = try Self.buffer(width: 256, height: 256, red: 240, green: 30, blue: 30)
        let camera = try Self.buffer(width: 256, height: 256, red: 20, green: 40, blue: 240)
        let destination = try Self.buffer(width: 256, height: 256, red: 0, green: 0, blue: 0)

        let layout = BubbleLayout(centre: CGPoint(x: 128, y: 128), size: 120)
        try compositor.render(
            screen: screen, camera: camera,
            cameraPixelFormat: kCVPixelFormatType_32BGRA,
            layout: layout, into: destination)

        // Middle of the bubble: camera. Blue dominates even after the 709 -> P3
        // conversion shifts the exact values.
        let inside = try Self.pixel(destination, x: 128, y: 128)
        #expect(inside.blue > inside.red)
        #expect(inside.blue > 150)

        // Corner, far outside the circle: untouched screen.
        let outside = try Self.pixel(destination, x: 8, y: 8)
        #expect(outside.red > 200)
        #expect(outside.blue < 80)

        // Just beyond the radius on the same row — catches a mask that is the
        // right shape but the wrong size.
        let justOutside = try Self.pixel(destination, x: 128 + 75, y: 128)
        #expect(justOutside.red > 200)
    }

    @Test("The mask edge is antialiased rather than a hard step")
    func edgeIsAntialiased() throws {
        let compositor = try Compositor()
        let screen = try Self.buffer(width: 256, height: 256, red: 255, green: 255, blue: 255)
        let camera = try Self.buffer(width: 256, height: 256, red: 0, green: 0, blue: 0)
        let destination = try Self.buffer(width: 256, height: 256, red: 0, green: 0, blue: 0)

        try compositor.render(
            screen: screen, camera: camera,
            cameraPixelFormat: kCVPixelFormatType_32BGRA,
            layout: BubbleLayout(centre: CGPoint(x: 128, y: 128), size: 120),
            into: destination)

        // Walk across the rim itself — centre 128, size 120, so the edge is at
        // x = 188 — and count values that are neither fully camera nor fully
        // screen. A hard-edged mask produces none.
        var intermediate = 0
        for x in 180...196 {
            let value = try Self.pixel(destination, x: x, y: 128).red
            if value > 20 && value < 235 { intermediate += 1 }
        }
        #expect(intermediate >= 1)
    }

    @Test("Camera pixel formats are classified for the right decode path")
    func classifiesPixelFormats() {
        #expect(Compositor.isBiplanar(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange))
        #expect(Compositor.isBiplanar(kCVPixelFormatType_Lossy_420YpCbCr8BiPlanarVideoRange))
        #expect(!Compositor.isBiplanar(kCVPixelFormatType_32BGRA))

        // Decoding full range as video range is the classic washed-out bug.
        #expect(Compositor.isFullRange(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange))
        #expect(!Compositor.isFullRange(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange))
    }

    // MARK: - Helpers

    private struct Pixel {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
    }

    private static func buffer(
        width: Int, height: Int, red: UInt8, green: UInt8, blue: UInt8
    ) throws -> CVPixelBuffer {
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            attributes as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            throw CompositorError.textureCreationFailed
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw CompositorError.textureCreationFailed
        }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)

        for y in 0..<height {
            for x in 0..<width {
                let offset = y * stride + x * 4
                // 32BGRA is laid out blue, green, red, alpha.
                bytes[offset] = blue
                bytes[offset + 1] = green
                bytes[offset + 2] = red
                bytes[offset + 3] = 255
            }
        }
        return buffer
    }

    private static func pixel(_ buffer: CVPixelBuffer, x: Int, y: Int) throws -> Pixel {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw CompositorError.textureCreationFailed
        }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let offset = y * stride + x * 4
        return Pixel(red: bytes[offset + 2], green: bytes[offset + 1], blue: bytes[offset])
    }
}
