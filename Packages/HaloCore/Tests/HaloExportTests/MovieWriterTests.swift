import AVFoundation
import CoreVideo
import Testing

@testable import HaloExport

/// Exercises the real encoder end to end with synthetic frames, so the writer
/// path is verified without needing Screen Recording permission or a display.
@Suite("MovieWriter")
struct MovieWriterTests {

    @Test("Writes a playable HEVC file with the expected duration and size")
    func writesPlayableFile() async throws {
        let url = Self.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let settings = ExportSettings(width: 640, height: 480, frameRate: 30)
        let writer = try MovieWriter(url: url, settings: settings)

        let frameCount = 30
        for index in 0..<frameCount {
            let buffer = try Self.makePixelBuffer(width: 640, height: 480)
            try Self.waitForReadiness(writer)
            try writer.append(
                buffer, presentationTime: CMTime(value: CMTimeValue(index), timescale: 30))
        }

        let output = try await writer.finish()
        #expect(FileManager.default.fileExists(atPath: output.path))
        #expect(writer.appendedFrameCount == frameCount)

        let asset = AVURLAsset(url: output)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try #require(tracks.first)

        let duration = try await asset.load(.duration)
        // 30 frames at 30fps, allowing for the encoder's final frame duration.
        #expect(duration.seconds >= 0.9 && duration.seconds <= 1.1)

        let size = try await track.load(.naturalSize)
        #expect(size == CGSize(width: 640, height: 480))

        let descriptions = try await track.load(.formatDescriptions)
        let codec = try #require(descriptions.first).mediaSubType
        #expect(codec == CMFormatDescription.MediaSubType(rawValue: kCMVideoCodecType_HEVC))
    }

    @Test("The first frame is retimed to zero regardless of its capture timestamp")
    func firstFrameIsZeroBased() async throws {
        let url = Self.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try MovieWriter(
            url: url, settings: ExportSettings(width: 320, height: 240, frameRate: 30))

        // Screen capture timestamps are host-clock based and start at an
        // arbitrarily large value; the file must still start at zero.
        let offset = CMTime(value: 987_654, timescale: 30)
        for index in 0..<10 {
            let buffer = try Self.makePixelBuffer(width: 320, height: 240)
            try Self.waitForReadiness(writer)
            try writer.append(
                buffer,
                presentationTime: offset + CMTime(value: CMTimeValue(index), timescale: 30))
        }

        let output = try await writer.finish()
        let asset = AVURLAsset(url: output)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let range = try await track.load(.timeRange)

        #expect(range.start == .zero)
        #expect(try await asset.load(.duration).seconds < 1.0)
    }

    @Test("Finishing with no frames reports that rather than writing an empty file")
    func noFramesIsAnError() async throws {
        let url = Self.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try MovieWriter(
            url: url, settings: ExportSettings(width: 320, height: 240))

        await #expect(throws: MovieWriter.Failure.noFramesWritten) {
            _ = try await writer.finish()
        }
    }

    // MARK: - Helpers

    private static func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "halo-test-\(UUID().uuidString).mp4")
    }

    /// `expectsMediaDataInRealTime` means the input can briefly refuse data.
    /// Tests feed frames far faster than real time, so wait rather than drop.
    private static func waitForReadiness(_ writer: MovieWriter) throws {
        for _ in 0..<200 where !writer.isReadyForMoreMediaData {
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    private static func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            attributes as CFDictionary, &buffer)

        guard status == kCVReturnSuccess, let buffer else {
            throw CocoaError(.fileWriteUnknown)
        }
        return buffer
    }
}
