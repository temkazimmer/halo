import AVFoundation

/// Converts one capture source into the canonical mix format.
///
/// System audio arrives in whatever `SCStreamConfiguration` asked for, while the
/// microphone arrives in *its device's native format* — Apple's own header says
/// so. The two therefore differ in sample rate and channel count, which is
/// exactly why they cannot share a writer input untouched.
///
/// A mid-stream format change rebuilds the converter. It must never be handled
/// by swapping writer inputs: that produces a container players cannot open.
public final class AudioSourceConverter {
    private let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    public private(set) var formatChangeCount = 0

    public init(outputFormat: AVAudioFormat = AudioFormats.canonical) {
        self.outputFormat = outputFormat
    }

    public func convert(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        if input.format == outputFormat { return input }

        if inputFormat != input.format {
            if inputFormat != nil { formatChangeCount += 1 }
            inputFormat = input.format
            converter = AVAudioConverter(from: input.format, to: outputFormat)
        }
        guard let converter else { throw AudioError.converterUnavailable }

        // Resampling changes the frame count; leave headroom for the converter's
        // internal filter delay rather than computing it exactly.
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity)
        else { throw AudioError.converterUnavailable }

        // AVAudioConverter types its input block as @Sendable, but calls it
        // synchronously on this thread before `convert` returns — nothing escapes.
        nonisolated(unsafe) let source = input
        nonisolated(unsafe) var consumed = false

        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return source
        }

        switch status {
        case .haveData, .inputRanDry:
            return output
        case .endOfStream:
            output.frameLength = 0
            return output
        case .error:
            throw AudioError.conversionFailed(
                conversionError?.localizedDescription ?? "unknown error")
        @unknown default:
            throw AudioError.conversionFailed("unexpected converter status")
        }
    }
}
