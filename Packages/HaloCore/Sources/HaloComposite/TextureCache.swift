import CoreVideo
import Metal

/// A Metal texture plus the CoreVideo wrapper that owns its memory.
///
/// The `CVMetalTexture` must outlive every command buffer that reads the
/// texture; releasing it early gives corrupt or blank frames rather than a
/// crash, which is a miserable thing to debug.
struct CachedTexture {
    let texture: MTLTexture
    private let owner: CVMetalTexture

    init?(_ owner: CVMetalTexture) {
        guard let texture = CVMetalTextureGetTexture(owner) else { return nil }
        self.owner = owner
        self.texture = texture
    }
}

/// Wraps capture pixel buffers as Metal textures without copying.
///
/// Capture-delivered buffers are already IOSurface-backed, so this is genuinely
/// zero-copy — provided the buffer was allocated with
/// `kCVPixelBufferMetalCompatibilityKey`.
final class TextureCache {
    private let cache: CVMetalTextureCache

    init(device: any MTLDevice) throws {
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(
            kCFAllocatorDefault, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let cache else {
            throw CompositorError.textureCacheUnavailable(status)
        }
        self.cache = cache
    }

    /// Wraps one plane. Biplanar YCbCr needs two calls: plane 0 as `.r8Unorm`
    /// for luma, plane 1 as `.rg8Unorm` for interleaved chroma.
    func texture(
        from pixelBuffer: CVPixelBuffer,
        plane: Int,
        format: MTLPixelFormat
    ) -> CachedTexture? {
        let isPlanar = CVPixelBufferIsPlanar(pixelBuffer)
        let width = isPlanar
            ? CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
            : CVPixelBufferGetWidth(pixelBuffer)
        let height = isPlanar
            ? CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
            : CVPixelBufferGetHeight(pixelBuffer)

        var reference: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil,
            format, width, height, plane, &reference)

        guard status == kCVReturnSuccess, let reference else { return nil }
        return CachedTexture(reference)
    }

    /// Releases textures CoreVideo is holding for recycled buffers.
    func flush() {
        CVMetalTextureCacheFlush(cache, 0)
    }
}
