import AVFoundation
import Testing

@testable import HaloExport

@Test("Output is HEVC, not H.264, which fails above 4096x2304")
func codecIsHEVC() {
    let settings = ExportSettings(width: 3456, height: 2234)
    let codec = settings.videoOutputSettings[AVVideoCodecKey] as? AVVideoCodecType
    #expect(codec == .hevc)
}

@Test("Colour is tagged P3-D65 with 709 transfer and matrix")
func colourTagsMatchCapture() throws {
    // Capture hands us Display P3 frames; mislabelling here is invisible until
    // playback, and then subtly wrong everywhere.
    let settings = ExportSettings(width: 1920, height: 1080)
    let colour = try #require(
        settings.videoOutputSettings[AVVideoColorPropertiesKey] as? [String: Any])

    #expect(colour[AVVideoColorPrimariesKey] as? String == AVVideoColorPrimaries_P3_D65)
    #expect(colour[AVVideoTransferFunctionKey] as? String == AVVideoTransferFunction_ITU_R_709_2)
    #expect(colour[AVVideoYCbCrMatrixKey] as? String == AVVideoYCbCrMatrix_ITU_R_709_2)
}

@Test("Frame reordering is off so real-time capture is not delayed by B-frames")
func noFrameReordering() throws {
    let settings = ExportSettings(width: 1920, height: 1080)
    let compression = try #require(
        settings.videoOutputSettings[AVVideoCompressionPropertiesKey] as? [String: Any])
    #expect(compression[AVVideoAllowFrameReorderingKey] as? Bool == false)
}

@Test("Pixel buffers are IOSurface-backed, or every frame costs a CPU copy")
func pixelBuffersAreIOSurfaceBacked() {
    let settings = ExportSettings(width: 1920, height: 1080)
    let attributes = settings.pixelBufferAttributes

    #expect(attributes[kCVPixelBufferIOSurfacePropertiesKey as String] != nil)
    #expect(attributes[kCVPixelBufferMetalCompatibilityKey as String] as? Bool == true)
    #expect(
        attributes[kCVPixelBufferPixelFormatTypeKey as String] as? OSType
            == kCVPixelFormatType_32BGRA)
}

@Test("Dimensions carry through to the encoder settings")
func dimensionsCarryThrough() {
    let settings = ExportSettings(width: 3456, height: 2234)
    #expect(settings.videoOutputSettings[AVVideoWidthKey] as? Int == 3456)
    #expect(settings.videoOutputSettings[AVVideoHeightKey] as? Int == 2234)
    #expect(settings.pixelBufferAttributes[kCVPixelBufferWidthKey as String] as? Int == 3456)
}
