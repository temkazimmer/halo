import AVFoundation

public enum AudioError: Error, LocalizedError, Equatable {
    case unsupportedSourceFormat
    case converterUnavailable
    case conversionFailed(String)
    case sampleBufferCreationFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSourceFormat:
            "An audio source produced a format Halo cannot read."
        case .converterUnavailable:
            "Audio from that source could not be converted."
        case .conversionFailed(let reason):
            "Audio conversion failed: \(reason)"
        case .sampleBufferCreationFailed(let status):
            "Audio could not be packaged for writing (status \(status))."
        }
    }
}

public enum AudioFormats {
    public static let sampleRate: Double = 48_000
    public static let channelCount: AVAudioChannelCount = 2

    /// The one format everything is converted into before mixing.
    ///
    /// Interleaved float32 so the mix timeline can be a flat `[Float]`, which
    /// keeps the summing loop simple and the tests readable.
    public static let canonical = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: channelCount,
        interleaved: true)!

    /// Reads a capture sample buffer into an `AVAudioPCMBuffer` without copying.
    ///
    /// The returned buffer borrows the sample buffer's memory, so it must be
    /// consumed before the capture callback returns.
    public static func pcmBuffer(from sampleBuffer: CMSampleBuffer) throws -> AVAudioPCMBuffer {
        guard let formatDescription = sampleBuffer.formatDescription,
              let streamDescription = formatDescription.audioStreamBasicDescription
        else { throw AudioError.unsupportedSourceFormat }

        var asbd = streamDescription
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            throw AudioError.unsupportedSourceFormat
        }

        let frameCount = AVAudioFrameCount(sampleBuffer.numSamples)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw AudioError.unsupportedSourceFormat
        }
        buffer.frameLength = frameCount

        try sampleBuffer.withAudioBufferList { audioBufferList, _ in
            let destination = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            guard destination.count == audioBufferList.count else {
                throw AudioError.unsupportedSourceFormat
            }
            for index in 0..<audioBufferList.count {
                guard let source = audioBufferList[index].mData,
                      let target = destination[index].mData
                else { throw AudioError.unsupportedSourceFormat }
                let byteCount = Int(min(
                    audioBufferList[index].mDataByteSize, destination[index].mDataByteSize))
                target.copyMemory(from: source, byteCount: byteCount)
                destination[index].mDataByteSize = UInt32(byteCount)
            }
        }

        return buffer
    }

    /// Packages mixed audio for `AVAssetWriterInput`.
    public static func sampleBuffer(
        from buffer: AVAudioPCMBuffer,
        presentationTime: CMTime
    ) throws -> CMSampleBuffer {
        var formatDescription: CMAudioFormatDescription?
        var status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: buffer.format.streamDescription,
            layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription)
        guard status == noErr, let formatDescription else {
            throw AudioError.sampleBufferCreationFailed(status)
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(buffer.format.sampleRate)),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid)

        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: CMItemCount(buffer.frameLength),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sampleBuffer else {
            throw AudioError.sampleBufferCreationFailed(status)
        }

        status = CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: buffer.audioBufferList)
        guard status == noErr else {
            throw AudioError.sampleBufferCreationFailed(status)
        }

        return sampleBuffer
    }
}
