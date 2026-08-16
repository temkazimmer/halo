import CoreVideo
import Synchronization

/// Holds the newest camera frame, discarding anything it replaces.
///
/// The camera runs at its own rate — commonly 30fps against a 60fps screen
/// capture — so frames must not drive output. The screen stream is the clock
/// master, and it consumes whatever is in this slot when it renders.
///
/// Frames are **copied** on the way in. The capture buffer's `IOSurface` is only
/// valid inside its callback, and holding it would stall delivery exactly as it
/// would on the screen side.
public final class FrameLatch: Sendable {
    /// CoreVideo types carry no `Sendable` annotation, though CF retain and
    /// release are thread-safe and every access to the contents here happens
    /// under this type's own lock.
    private struct Storage: @unchecked Sendable {
        var buffer: CVPixelBuffer?
        var pool: CVPixelBufferPool?
        var poolWidth = 0
        var poolHeight = 0
        var poolFormat: OSType = 0
        var droppedCount = 0
    }

    private let storage = Mutex(Storage())

    public init() {}

    /// Frames replaced before anything consumed them.
    public var droppedCount: Int { storage.withLock { $0.droppedCount } }

    public var hasFrame: Bool { storage.withLock { $0.buffer != nil } }

    /// Format of the latched frame, which the shader needs in order to decode it.
    public var pixelFormat: OSType { storage.withLock { $0.poolFormat } }

    /// The newest frame and its format together, so the two cannot be read at
    /// different moments and disagree after a mid-session format change.
    public func latestFrame() -> (buffer: CVPixelBuffer, format: OSType)? {
        storage.withLock { storage in
            guard let buffer = storage.buffer else { return nil }
            return (buffer, storage.poolFormat)
        }
    }

    public func clear() {
        storage.withLock { $0.buffer = nil }
    }

    /// Copies and latches. Call synchronously from the camera callback.
    public func store(_ pixelBuffer: CVPixelBuffer) {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)

        storage.withLock { storage in
            if storage.buffer != nil { storage.droppedCount += 1 }

            // The camera can change format mid-session (Continuity hand-off,
            // resolution change), so the pool is rebuilt when it does.
            if storage.pool == nil
                || storage.poolWidth != width
                || storage.poolHeight != height
                || storage.poolFormat != format {
                storage.pool = Self.makePool(width: width, height: height, format: format)
                storage.poolWidth = width
                storage.poolHeight = height
                storage.poolFormat = format
            }

            guard let pool = storage.pool,
                  let copy = Self.copy(pixelBuffer, using: pool)
            else { return }

            storage.buffer = copy
        }
    }

    /// The newest frame, or `nil` if none has arrived.
    ///
    /// Non-destructive: a 30fps camera against a 60fps capture is expected to
    /// have the same frame read twice, which is correct — the alternative is a
    /// bubble that flickers on alternate frames.
    public func latest() -> CVPixelBuffer? {
        storage.withLock { $0.buffer }
    }

    // MARK: - Copying

    private static func makePool(
        width: Int, height: Int, format: OSType
    ) -> CVPixelBufferPool? {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: format,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            // Required for zero-copy Metal interop on the consuming side.
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(
            kCFAllocatorDefault, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess
        else { return nil }
        return pool
    }

    private static func copy(
        _ source: CVPixelBuffer, using pool: CVPixelBufferPool
    ) -> CVPixelBuffer? {
        var destination: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault, pool, &destination) == kCVReturnSuccess,
            let destination
        else { return nil }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }

        let planeCount = max(1, CVPixelBufferGetPlaneCount(source))
        let isPlanar = CVPixelBufferIsPlanar(source)

        for plane in 0..<planeCount {
            let from = isPlanar
                ? CVPixelBufferGetBaseAddressOfPlane(source, plane)
                : CVPixelBufferGetBaseAddress(source)
            let to = isPlanar
                ? CVPixelBufferGetBaseAddressOfPlane(destination, plane)
                : CVPixelBufferGetBaseAddress(destination)
            guard let from, let to else { return nil }

            let sourceStride = isPlanar
                ? CVPixelBufferGetBytesPerRowOfPlane(source, plane)
                : CVPixelBufferGetBytesPerRow(source)
            let destinationStride = isPlanar
                ? CVPixelBufferGetBytesPerRowOfPlane(destination, plane)
                : CVPixelBufferGetBytesPerRow(destination)
            let rows = isPlanar
                ? CVPixelBufferGetHeightOfPlane(source, plane)
                : CVPixelBufferGetHeight(source)

            // Strides differ between pools, so copy row by row rather than in one
            // block — a straight memcpy would shear the image.
            let rowBytes = min(sourceStride, destinationStride)
            for row in 0..<rows {
                (to + row * destinationStride)
                    .copyMemory(from: from + row * sourceStride, byteCount: rowBytes)
            }
        }

        return destination
    }
}
