import AVFoundation
import Testing

@testable import HaloExport

/// The plan calls mixing the single most common way this feature is got wrong,
/// so these tests target the failure precisely: two sources whose formats and
/// clocks genuinely differ, summed onto one timeline.
@Suite("AudioMixer")
struct AudioMixerTests {

    /// The exact shape of the trap: system audio arrives at 48kHz stereo,
    /// the microphone at its device's native format — here 44.1kHz mono.
    private static let systemFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true)!
    private static let microphoneFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: true)!

    @Test("Sources with different sample rates and channel counts sum into one track")
    func mixesMismatchedFormats() throws {
        let mixer = AudioMixer()
        let systemConverter = AudioSourceConverter()
        let microphoneConverter = AudioSourceConverter()

        try Self.feed(
            mixer, source: .systemAudio, using: systemConverter,
            format: Self.systemFormat, seconds: 0.5, amplitude: 0.25, startingAt: .zero)
        try Self.feed(
            mixer, source: .microphone, using: microphoneConverter,
            format: Self.microphoneFormat, seconds: 0.5, amplitude: 0.25, startingAt: .zero)

        let samples = try Self.drainSamples(mixer)
        #expect(!samples.isEmpty)

        // Both contribute 0.25, so the steady-state sum is 0.5. Sample from the
        // middle to skip the resampler's start-up ramp.
        let middle = samples[(samples.count / 2)..<(samples.count / 2 + 64)]
        for value in middle {
            #expect(abs(value - 0.5) < 0.05)
        }
    }

    @Test("A source that starts late lands at its timestamp, not at the front")
    func alignsSourcesByTimestamp() throws {
        let mixer = AudioMixer()
        let systemConverter = AudioSourceConverter()
        let microphoneConverter = AudioSourceConverter()

        // System audio runs for a full second from zero.
        try Self.feed(
            mixer, source: .systemAudio, using: systemConverter,
            format: Self.systemFormat, seconds: 1.0, amplitude: 0.25, startingAt: .zero)
        // The microphone joins half a second in — on its own clock.
        try Self.feed(
            mixer, source: .microphone, using: microphoneConverter,
            format: Self.microphoneFormat, seconds: 0.5, amplitude: 0.25,
            startingAt: CMTime(value: 500, timescale: 1000))

        let samples = try Self.drainSamples(mixer)
        let framesPerChannel = samples.count / 2
        #expect(framesPerChannel > 40_000)

        // A quarter of the way in: system audio only.
        let earlyIndex = (framesPerChannel / 4) * 2
        #expect(abs(samples[earlyIndex] - 0.25) < 0.05)

        // Three quarters in: both sources, so the sum has doubled. If alignment
        // were wrong this would still read 0.25.
        let lateIndex = (framesPerChannel * 3 / 4) * 2
        #expect(abs(samples[lateIndex] - 0.5) < 0.05)
    }

    @Test("Gain applies per source, so the mic can be ridden independently")
    func gainIsPerSource() throws {
        let mixer = AudioMixer()
        mixer.setGain(0, for: .microphone)

        try Self.feed(
            mixer, source: .systemAudio, using: AudioSourceConverter(),
            format: Self.systemFormat, seconds: 0.3, amplitude: 0.4, startingAt: .zero)
        try Self.feed(
            mixer, source: .microphone, using: AudioSourceConverter(),
            format: Self.microphoneFormat, seconds: 0.3, amplitude: 0.4, startingAt: .zero)

        let samples = try Self.drainSamples(mixer)
        let middle = samples[(samples.count / 2)..<(samples.count / 2 + 64)]
        // Muted mic contributes nothing; only the system's 0.4 survives.
        for value in middle {
            #expect(abs(value - 0.4) < 0.05)
        }
    }

    @Test("The summed signal is clipped rather than allowed to wrap")
    func sumsAreClipped() throws {
        let mixer = AudioMixer()
        try Self.feed(
            mixer, source: .systemAudio, using: AudioSourceConverter(),
            format: Self.systemFormat, seconds: 0.3, amplitude: 0.9, startingAt: .zero)
        try Self.feed(
            mixer, source: .microphone, using: AudioSourceConverter(),
            format: Self.microphoneFormat, seconds: 0.3, amplitude: 0.9, startingAt: .zero)

        let samples = try Self.drainSamples(mixer)
        #expect(!samples.isEmpty)
        for value in samples {
            #expect(value <= 1.0 && value >= -1.0)
        }
    }

    @Test("Without flush, the newest audio is held back inside the latency window")
    func latencyWindowHoldsBackNewestAudio() throws {
        let mixer = AudioMixer()
        try Self.feed(
            mixer, source: .systemAudio, using: AudioSourceConverter(),
            format: Self.systemFormat, seconds: 1.0, amplitude: 0.3, startingAt: .zero)

        let held = try mixer.drain()
        let heldFrames = held.reduce(0) { $0 + $1.numSamples }
        // One second in, minus the 200ms window that lets the other source land.
        #expect(heldFrames > 0)
        #expect(Double(heldFrames) < 48_000 * 0.85)

        let flushed = try mixer.drain(flush: true)
        let totalFrames = heldFrames + flushed.reduce(0) { $0 + $1.numSamples }
        #expect(Double(totalFrames) > 48_000 * 0.95)
    }

    @Test("Levels are reported per source for the meters")
    func reportsLevels() throws {
        let mixer = AudioMixer()
        try Self.feed(
            mixer, source: .systemAudio, using: AudioSourceConverter(),
            format: Self.systemFormat, seconds: 0.2, amplitude: 0.6, startingAt: .zero)

        let levels = mixer.levels()
        #expect((levels[.systemAudio] ?? 0) > 0.5)
        #expect(levels[.microphone] == nil)
    }

    // MARK: - Helpers

    /// Feeds a constant-amplitude signal in realistic 1024-frame chunks, with
    /// timestamps on that format's own clock.
    private static func feed(
        _ mixer: AudioMixer,
        source: AudioMixer.Source,
        using converter: AudioSourceConverter,
        format: AVAudioFormat,
        seconds: Double,
        amplitude: Float,
        startingAt start: CMTime
    ) throws {
        let chunk = 1024
        let totalFrames = Int(seconds * format.sampleRate)
        var frame = 0

        while frame < totalFrames {
            let frames = min(chunk, totalFrames - frame)
            let buffer = try makeBuffer(format: format, frames: frames, amplitude: amplitude)
            let offset = CMTime(
                value: CMTimeValue(frame), timescale: CMTimeScale(format.sampleRate))
            let sampleBuffer = try AudioFormats.sampleBuffer(
                from: buffer, presentationTime: start + offset)
            try mixer.append(sampleBuffer, from: source, using: converter)
            frame += frames
        }
    }

    private static func makeBuffer(
        format: AVAudioFormat, frames: Int, amplitude: Float
    ) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
            let data = buffer.floatChannelData?[0]
        else { throw AudioError.converterUnavailable }

        buffer.frameLength = AVAudioFrameCount(frames)
        for index in 0..<(frames * Int(format.channelCount)) {
            data[index] = amplitude
        }
        return buffer
    }

    private static func drainSamples(_ mixer: AudioMixer) throws -> [Float] {
        var samples: [Float] = []
        for sampleBuffer in try mixer.drain(flush: true) {
            let buffer = try AudioFormats.pcmBuffer(from: sampleBuffer)
            guard let data = buffer.floatChannelData?[0] else { continue }
            let count = Int(buffer.frameLength) * Int(buffer.format.channelCount)
            samples.append(contentsOf: UnsafeBufferPointer(start: data, count: count))
        }
        return samples
    }
}
