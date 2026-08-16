import AVFoundation

/// How a recording is encoded.
///
/// HEVC is not a preference: `AVAssetWriterInput` fails outright with H.264 above
/// 4096×2304, and a Retina display at scale 2 clears that immediately.
public struct ExportSettings: Sendable, Equatable {
    /// Output pixel dimensions. Must match the frames handed to the writer.
    public var width: Int
    public var height: Int
    public var frameRate: Int
    public var averageBitRate: Int
    /// Keyframe every N frames.
    public var maxKeyFrameInterval: Int

    public init(
        width: Int,
        height: Int,
        frameRate: Int = 60,
        averageBitRate: Int = 40_000_000,
        maxKeyFrameInterval: Int = 120
    ) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.averageBitRate = averageBitRate
        self.maxKeyFrameInterval = maxKeyFrameInterval
    }

    /// Encoder configuration.
    ///
    /// The colour tags are deliberate and must stay consistent with the capture
    /// side: ScreenCaptureKit hands us Display P3 frames, so the file is tagged
    /// P3-D65 primaries with the 709 transfer function and matrix. Mislabel this
    /// and playback is subtly but visibly wrong.
    public var videoOutputSettings: [String: any Sendable] {
        [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_P3_D65,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ] as [String: any Sendable],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: averageBitRate,
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoMaxKeyFrameIntervalKey: maxKeyFrameInterval,
                // Screen recording is a real-time capture; B-frames would only add
                // latency and reordering for no quality gain at this bitrate.
                AVVideoAllowFrameReorderingKey: false,
            ] as [String: any Sendable],
        ]
    }

    /// Attributes for the adaptor's pixel buffer pool.
    ///
    /// `kCVPixelBufferIOSurfacePropertiesKey` is required: without it the pool
    /// hands back malloc-backed buffers and every frame costs a CPU copy.
    public var pixelBufferAttributes: [String: any Sendable] {
        [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: any Sendable],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
    }
}
