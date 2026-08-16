import CoreVideo
import Foundation
import Metal
import simd

public enum CompositorError: Error, LocalizedError {
    case noMetalDevice
    case shaderSourceMissing
    case shaderCompilationFailed(String)
    case pipelineCreationFailed(String)
    case textureCacheUnavailable(CVReturn)
    case textureCreationFailed
    case commandEncodingFailed

    public var errorDescription: String? {
        switch self {
        case .noMetalDevice: "No Metal device is available."
        case .shaderSourceMissing: "The compositor's shader source is missing from the bundle."
        case .shaderCompilationFailed(let reason): "Shader compilation failed: \(reason)"
        case .pipelineCreationFailed(let reason): "Render pipeline creation failed: \(reason)"
        case .textureCacheUnavailable(let status): "Metal texture cache unavailable (\(status))."
        case .textureCreationFailed: "A capture frame could not be wrapped as a texture."
        case .commandEncodingFailed: "The frame could not be encoded for the GPU."
        }
    }
}

/// Composites the camera bubble onto a screen frame on the GPU.
///
/// One compositor, two destinations: the same render feeds the encoder and the
/// on-screen preview, so what you see cannot drift from what is recorded. Two
/// code paths that "should look the same" is exactly the failure this design
/// exists to prevent.
///
/// Core Image would express this composite in one filter, but it re-analyses its
/// graph on every render — roughly 50% CPU against 20% for hand-written Metal on
/// equivalent work. Our graph is fixed and runs 60 times a second, so that
/// overhead is pure waste.
public final class Compositor {
    public let device: any MTLDevice

    private let commandQueue: any MTLCommandQueue
    private let pipeline: any MTLRenderPipelineState
    private let textureCache: TextureCache

    public init(device: (any MTLDevice)? = nil) throws {
        guard let device = device ?? MTLCreateSystemDefaultDevice() else {
            throw CompositorError.noMetalDevice
        }
        self.device = device

        guard let commandQueue = device.makeCommandQueue() else {
            throw CompositorError.noMetalDevice
        }
        self.commandQueue = commandQueue

        let library = try Self.makeLibrary(device: device)

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "fullscreenVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "compositeFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        do {
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw CompositorError.pipelineCreationFailed(error.localizedDescription)
        }

        textureCache = try TextureCache(device: device)
    }

    /// SwiftPM does not compile `.metal` sources, so the shader ships as a
    /// resource and is compiled once at start-up. The package's tests compile it
    /// too, so a broken shader fails the build rather than surfacing at runtime.
    private static func makeLibrary(device: any MTLDevice) throws -> any MTLLibrary {
        guard let url = Bundle.module.url(forResource: "Shaders", withExtension: "metal"),
              let source = try? String(contentsOf: url, encoding: .utf8)
        else { throw CompositorError.shaderSourceMissing }

        do {
            return try device.makeLibrary(source: source, options: nil)
        } catch {
            throw CompositorError.shaderCompilationFailed(error.localizedDescription)
        }
    }

    // MARK: - Rendering

    /// Renders one output frame.
    ///
    /// - Parameters:
    ///   - screen: the screen capture frame, BGRA.
    ///   - camera: the newest latched camera frame, or `nil` before one arrives.
    ///   - cameraPixelFormat: what the camera is actually delivering, which
    ///     decides how the shader decodes it.
    ///   - destination: an IOSurface-backed BGRA buffer, ideally from the
    ///     writer's own pool so the encoder needs no copy.
    public func render(
        screen: CVPixelBuffer,
        camera: CVPixelBuffer?,
        cameraPixelFormat: OSType,
        layout: BubbleLayout?,
        into destination: CVPixelBuffer
    ) throws {
        guard let target = textureCache.texture(
            from: destination, plane: 0, format: .bgra8Unorm),
            let screenTexture = textureCache.texture(
                from: screen, plane: 0, format: .bgra8Unorm)
        else { throw CompositorError.textureCreationFailed }

        var uniforms = Self.uniforms(
            layout: layout,
            outputWidth: CVPixelBufferGetWidth(destination),
            outputHeight: CVPixelBufferGetHeight(destination),
            camera: camera,
            cameraPixelFormat: cameraPixelFormat,
            hasScreen: true)

        let cameraTextures = try cameraTextures(
            for: layout == nil ? nil : camera, uniforms: &uniforms)

        try encode(
            into: target.texture,
            screen: screenTexture,
            cameraTextures: cameraTextures,
            uniforms: &uniforms,
            clear: false)
    }

    /// Renders the floating preview: the same mask, antialiasing and colour
    /// pipeline, with no screen layer, so the desktop shows through.
    ///
    /// The preview mirrors by default and the recording does not — people expect
    /// to see themselves mirrored, viewers expect text behind you to read.
    public func renderPreview(
        camera: CVPixelBuffer?,
        cameraPixelFormat: OSType,
        feather: CGFloat,
        zoom: CGFloat,
        offset: CGPoint,
        mirrored: Bool,
        pixelSize: CGSize,
        into target: any MTLTexture
    ) throws {
        // The bubble fills the whole layer, so it is centred with a half-extent
        // of one half in normalised space.
        let layout = BubbleLayout(
            centre: CGPoint(x: pixelSize.width / 2, y: pixelSize.height / 2),
            size: min(pixelSize.width, pixelSize.height),
            zoom: zoom, offset: offset, feather: feather, mirrored: mirrored)

        var uniforms = Self.uniforms(
            layout: layout,
            outputWidth: Int(pixelSize.width),
            outputHeight: Int(pixelSize.height),
            camera: camera,
            cameraPixelFormat: cameraPixelFormat,
            hasScreen: false)

        let cameraTextures = try cameraTextures(for: camera, uniforms: &uniforms)

        try encode(
            into: target,
            screen: nil,
            cameraTextures: cameraTextures,
            uniforms: &uniforms,
            clear: true)
    }

    // MARK: - Encoding

    private func cameraTextures(
        for camera: CVPixelBuffer?, uniforms: inout CompositorUniforms
    ) throws -> [CachedTexture] {
        guard let camera else {
            uniforms.hasCamera = 0
            return []
        }

        if uniforms.cameraIsYCbCr != 0 {
            // Biplanar YCbCr needs two textures: luma, then interleaved chroma.
            guard let luma = textureCache.texture(from: camera, plane: 0, format: .r8Unorm),
                  let chroma = textureCache.texture(from: camera, plane: 1, format: .rg8Unorm)
            else { throw CompositorError.textureCreationFailed }
            return [luma, chroma]
        }

        guard let rgb = textureCache.texture(from: camera, plane: 0, format: .bgra8Unorm)
        else { throw CompositorError.textureCreationFailed }
        return [rgb]
    }

    private func encode(
        into target: any MTLTexture,
        screen: CachedTexture?,
        cameraTextures: [CachedTexture],
        uniforms: inout CompositorUniforms,
        clear: Bool
    ) throws {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        // The screen layer covers every pixel; the preview does not.
        pass.colorAttachments[0].loadAction = clear ? .clear : .dontCare
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass)
        else { throw CompositorError.commandEncodingFailed }

        encoder.setRenderPipelineState(pipeline)
        if let screen { encoder.setFragmentTexture(screen.texture, index: 0) }
        if let first = cameraTextures.first {
            encoder.setFragmentTexture(first.texture, index: 1)
        }
        if cameraTextures.count > 1 {
            encoder.setFragmentTexture(cameraTextures[1].texture, index: 2)
        }
        encoder.setFragmentBytes(
            &uniforms, length: MemoryLayout<CompositorUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        // The CoreVideo wrappers must outlive the GPU's use of their textures.
        // Releasing one early yields corrupt or blank frames rather than a crash.
        withExtendedLifetime((screen, cameraTextures)) {
            commandBuffer.commit()
            // The encoder appends this buffer as soon as we return, so the render
            // has to have landed. At 60fps this waits well under a frame.
            commandBuffer.waitUntilCompleted()
        }
        textureCache.flush()
    }

    // MARK: - Uniforms

    private static func uniforms(
        layout: BubbleLayout?,
        outputWidth: Int,
        outputHeight: Int,
        camera: CVPixelBuffer?,
        cameraPixelFormat: OSType,
        hasScreen: Bool
    ) -> CompositorUniforms {
        let width = Float(max(outputWidth, 1))
        let height = Float(max(outputHeight, 1))

        guard let layout, let camera else {
            return CompositorUniforms(
                bubbleCentre: .zero, bubbleRadius: SIMD2(1, 1),
                cornerAntialias: 0, feather: 0, cameraAspect: 1, zoom: 1,
                cameraOffset: .zero, mirrorCamera: 0, cameraIsYCbCr: 0,
                cameraIsFullRange: 0, hasCamera: 0, hasScreen: hasScreen ? 1 : 0)
        }

        let cameraWidth = Float(CVPixelBufferGetWidth(camera))
        let cameraHeight = Float(max(CVPixelBufferGetHeight(camera), 1))
        let radius = Float(layout.size) / 2

        let isYCbCr = Self.isBiplanar(cameraPixelFormat)
        let isFullRange = Self.isFullRange(cameraPixelFormat)

        return CompositorUniforms(
            bubbleCentre: SIMD2(Float(layout.centre.x) / width, Float(layout.centre.y) / height),
            bubbleRadius: SIMD2(radius / width, radius / height),
            // Normalised floor for the antialias width, so a small bubble on a
            // large output still resolves cleanly.
            cornerAntialias: 1.0 / max(radius, 1),
            feather: Float(layout.feather) / max(radius, 1),
            cameraAspect: cameraWidth / cameraHeight,
            zoom: Float(max(layout.zoom, 0.01)),
            cameraOffset: SIMD2(Float(layout.offset.x), Float(layout.offset.y)),
            mirrorCamera: layout.mirrored ? 1 : 0,
            cameraIsYCbCr: isYCbCr ? 1 : 0,
            cameraIsFullRange: isFullRange ? 1 : 0,
            hasCamera: 1,
            hasScreen: hasScreen ? 1 : 0)
    }

    static func isBiplanar(_ format: OSType) -> Bool {
        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_Lossy_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_Lossy_420YpCbCr8BiPlanarVideoRange:
            true
        default:
            false
        }
    }

    /// Full and video range differ in how luma and chroma are packed. Decoding
    /// one as the other is the classic "everything looks washed out" bug.
    static func isFullRange(_ format: OSType) -> Bool {
        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_Lossy_420YpCbCr8BiPlanarFullRange:
            true
        default:
            false
        }
    }
}
