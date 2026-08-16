import AVFoundation
import Synchronization

/// Sums system audio and microphone into a single stereo track.
///
/// Why a timeline rather than a queue: the two sources run on **independent
/// clocks** and arrive on separate queues, so their buffers interleave
/// unpredictably and neither can be treated as "next". Every buffer is placed at
/// the absolute frame position its timestamp implies, and blocks are emitted
/// only once they are old enough that both sources have had a chance to
/// contribute. That is what keeps voice and system audio in sync instead of
/// merely adjacent.
///
/// Buffers are emitted with absolute capture timestamps; `MovieWriter` does the
/// retiming, so audio and video share one origin.
public final class AudioMixer: Sendable {
    public enum Source: Sendable, Hashable, CaseIterable {
        case systemAudio
        case microphone
    }

    /// How far behind the newest sample the mixer emits, giving the slower
    /// source time to land. Trades a little latency for correct alignment.
    public static let defaultLatency: Double = 0.2
    private static let blockFrames = 1024

    /// Only `Sendable` value types live here. Converters are deliberately not
    /// among them: each source is fed from its own capture queue, so a converter
    /// is never used concurrently and belongs to that queue, not to this lock.
    private struct State {
        var gains: [Source: Float] = [.systemAudio: 1, .microphone: 1]
        var levels: [Source: Float] = [:]
        /// Interleaved stereo float samples starting at `baseFrame`.
        var timeline: [Float] = []
        var baseFrame: Int64 = 0
        var highestFrame: Int64 = 0
        var origin: CMTime?
        var lateBufferCount = 0
    }

    private let state = Mutex(State())
    private let channels = Int(AudioFormats.channelCount)

    public init() {}

    // MARK: - Controls

    public func setGain(_ gain: Float, for source: Source) {
        state.withLock { $0.gains[source] = max(0, gain) }
    }

    public func gain(for source: Source) -> Float {
        state.withLock { $0.gains[source] ?? 1 }
    }

    /// Most recent peak level per source, 0...1, for meters.
    public func levels() -> [Source: Float] {
        state.withLock { $0.levels }
    }

    /// Buffers that arrived after their position had already been written out.
    public var lateBufferCount: Int {
        state.withLock { $0.lateBufferCount }
    }

    public func reset() {
        state.withLock { $0 = State() }
    }

    // MARK: - Input

    /// Converts and accumulates one capture buffer.
    ///
    /// Called on that source's own capture queue, with that queue's converter —
    /// the mixer holds no converter state, so the two sources never contend for
    /// anything but the timeline itself.
    public func append(
        _ sampleBuffer: CMSampleBuffer,
        from source: Source,
        using converter: AudioSourceConverter
    ) throws {
        let presentationTime = sampleBuffer.presentationTimeStamp
        // Read out of the capture buffer before taking the lock: the sample
        // buffer's memory is only valid inside the callback.
        let input = try AudioFormats.pcmBuffer(from: sampleBuffer)
        let converted = try converter.convert(input)

        guard converted.frameLength > 0,
              let samples = converted.floatChannelData?[0]
        else { return }
        let frameCount = Int(converted.frameLength)

        state.withLock { state in
            if state.origin == nil { state.origin = presentationTime }
            guard let origin = state.origin else { return }

            let offset = (presentationTime - origin).seconds
            let startFrame = Int64((offset * AudioFormats.sampleRate).rounded())
            let gain = state.gains[source] ?? 1

            Self.mix(
                samples: samples,
                frameCount: frameCount,
                startFrame: startFrame,
                gain: gain,
                channels: channels,
                into: &state)

            state.levels[source] = Self.peak(samples, count: frameCount * channels) * gain
        }
    }

    /// Static so the `inout State` cannot be captured by anything outliving the
    /// lock — the compiler enforces that for us.
    private static func mix(
        samples: UnsafeMutablePointer<Float>,
        frameCount: Int,
        startFrame: Int64,
        gain: Float,
        channels: Int,
        into state: inout State
    ) {
        var frameCount = frameCount
        var startFrame = startFrame
        var sourceOffset = 0

        // Anything older than what has already been emitted is unusable.
        if startFrame < state.baseFrame {
            let skipped = Int(state.baseFrame - startFrame)
            guard skipped < frameCount else {
                state.lateBufferCount += 1
                return
            }
            state.lateBufferCount += 1
            sourceOffset = skipped * channels
            frameCount -= skipped
            startFrame = state.baseFrame
        }

        let relativeFrame = Int(startFrame - state.baseFrame)
        let required = (relativeFrame + frameCount) * channels
        if state.timeline.count < required {
            state.timeline.append(
                contentsOf: repeatElement(0, count: required - state.timeline.count))
        }

        let destinationOffset = relativeFrame * channels
        for index in 0..<(frameCount * channels) {
            state.timeline[destinationOffset + index] += samples[sourceOffset + index] * gain
        }

        state.highestFrame = max(state.highestFrame, startFrame + Int64(frameCount))
    }

    // MARK: - Output

    /// Emits every block old enough to be complete.
    ///
    /// - Parameter flush: emit everything regardless of the latency window, for
    ///   the end of a recording.
    public func drain(
        latency: Double = AudioMixer.defaultLatency,
        flush: Bool = false
    ) throws -> [CMSampleBuffer] {
        try state.withLock { state in
            guard let origin = state.origin else { return [] }

            let latencyFrames = Int64(latency * AudioFormats.sampleRate)
            let safeFrame = flush ? state.highestFrame : state.highestFrame - latencyFrames

            var output: [CMSampleBuffer] = []
            while state.baseFrame < safeFrame {
                let available = Int(safeFrame - state.baseFrame)
                let frames = flush ? min(Self.blockFrames, available) : Self.blockFrames
                guard available >= frames else { break }

                let buffer = try Self.makeBuffer(
                    from: state.timeline, frames: frames, channels: channels)
                let presentationTime = origin + CMTime(
                    value: state.baseFrame, timescale: CMTimeScale(AudioFormats.sampleRate))
                output.append(
                    try AudioFormats.sampleBuffer(from: buffer, presentationTime: presentationTime))

                state.timeline.removeFirst(min(frames * channels, state.timeline.count))
                state.baseFrame += Int64(frames)
            }
            return output
        }
    }

    private static func makeBuffer(
        from timeline: [Float], frames: Int, channels: Int
    ) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: AudioFormats.canonical, frameCapacity: AVAudioFrameCount(frames)),
            let destination = buffer.floatChannelData?[0]
        else { throw AudioError.converterUnavailable }

        buffer.frameLength = AVAudioFrameCount(frames)
        let count = frames * channels
        for index in 0..<count {
            // Hard-clip: summing two full-scale sources can exceed 1.0, and
            // wrapping would turn a loud moment into a burst of noise.
            destination[index] = max(-1, min(1, index < timeline.count ? timeline[index] : 0))
        }
        return buffer
    }

    private static func peak(_ samples: UnsafeMutablePointer<Float>, count: Int) -> Float {
        var peak: Float = 0
        for index in 0..<count { peak = max(peak, abs(samples[index])) }
        return min(1, peak)
    }
}
