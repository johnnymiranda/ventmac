import Foundation

/// Real-time voice changer — pure DSP, no platform APIs, unit-testable.
///
/// Feed it the same 16-bit PCM chunks the capture tap produces, in order; it
/// returns a transformed chunk of the *same length*, so it drops into the
/// capture path without disturbing chunk timing, the VOX gate, or the codec.
///
/// Two effects, both classic and cheap:
///
/// * **Pitch** — a two-tap delay-line shifter. A read pointer runs through a
///   circular buffer at `2^(semitones/12)` times write speed, which shifts pitch
///   without changing duration. A single tap would click every time it laps the
///   write pointer, so a second tap runs half a buffer out of phase and the two
///   are crossfaded equal-power (`sin²+cos²=1`), putting each tap's gain at zero
///   exactly where its own discontinuity falls. That trade — warble instead of
///   clicks — is what makes it sound like a voice changer rather than a studio
///   pitch shifter, which is the intent.
/// * **Robot** — a ring modulator: multiply by a low-frequency sine. `depth`
///   blends dry→modulated, so it's a mix control rather than an on/off.
///
/// State (buffer, read position, oscillator phase) persists across chunks, so
/// call this from one thread only — the capture queue.
public final class VoiceChanger {
    public struct Config: Sendable, Equatable {
        /// Master switch. When false, `process` returns the input untouched.
        public var enabled: Bool = false
        /// Pitch shift in semitones; 0 = unchanged. ±12 is one octave.
        public var semitones: Float = 0
        /// Ring-modulator mix, 0...1. 0 = dry (no robot).
        public var robotDepth: Float = 0
        /// Ring-modulator carrier frequency in Hz. Low values (40-80) give the
        /// classic robot rasp; higher values turn metallic.
        public var robotHz: Float = 55

        public init() {}

        /// True when the settings would actually change the audio — lets the
        /// capture path skip the work when the effect is on but neutral.
        public var isActive: Bool {
            enabled && (abs(semitones) > 0.01 || robotDepth > 0.001)
        }
    }

    /// Settings are written from the UI thread and read on the audio thread, so
    /// they go through a lock. `process` takes it once per chunk, never per
    /// sample, so the cost is noise next to the DSP itself.
    public var config: Config {
        get { lock.lock(); defer { lock.unlock() }; return _config }
        set { lock.lock(); _config = newValue; lock.unlock() }
    }
    private var _config = Config()
    private let lock = NSLock()

    // Pitch state
    private var buffer: [Float] = []
    private var writeIndex = 0
    private var readPos: Float = 0
    private var configuredRate: UInt32 = 0

    // Ring-mod state
    private var oscPhase: Float = 0

    public init() {}

    /// Discard buffered audio. Call when transmission stops so the next
    /// transmission doesn't lead with a tail of the previous one.
    public func reset() {
        for i in buffer.indices { buffer[i] = 0 }
        writeIndex = 0
        readPos = 0
        oscPhase = 0
    }

    /// Transform one chunk of 16-bit signed little-endian PCM.
    /// Returns a chunk of identical length; returns the input unchanged when
    /// the effect is disabled or neutral.
    public func process(pcm: Data, rate: UInt32) -> Data {
        let cfg = config
        guard cfg.isActive, rate > 0, !pcm.isEmpty else { return pcm }

        // A ~50 ms delay line: long enough that the warble sits below speech
        // rate, short enough to not add audible latency to push-to-talk.
        if configuredRate != rate || buffer.isEmpty {
            let n = max(256, Int(Double(rate) * 0.05))
            buffer = [Float](repeating: 0, count: n)
            writeIndex = 0
            readPos = 0
            configuredRate = rate
        }

        let n = buffer.count
        let half = Float(n) / 2
        let ratio = powf(2, cfg.semitones / 12)
        let oscStep = 2 * Float.pi * cfg.robotHz / Float(rate)
        let depth = min(max(cfg.robotDepth, 0), 1)
        let shifting = abs(cfg.semitones) > 0.01

        var out = Data(count: pcm.count)
        pcm.withUnsafeBytes { (rawIn: UnsafeRawBufferPointer) in
            let input = rawIn.bindMemory(to: Int16.self)
            out.withUnsafeMutableBytes { (rawOut: UnsafeMutableRawBufferPointer) in
                let output = rawOut.bindMemory(to: Int16.self)

                for i in 0..<input.count {
                    var sample = Float(input[i]) / 32768

                    if shifting {
                        buffer[writeIndex] = sample
                        writeIndex = (writeIndex + 1) % n

                        // Tap A at readPos, tap B half a buffer away.
                        let a = interpolate(at: readPos, n: n)
                        var posB = readPos + half
                        if posB >= Float(n) { posB -= Float(n) }
                        let b = interpolate(at: posB, n: n)

                        // Equal-power crossfade: each tap is silent exactly
                        // where it laps the write pointer.
                        let fracA = readPos / Float(n)
                        let wA = sinf(.pi * fracA)
                        let wB = sqrtf(max(0, 1 - wA * wA))
                        sample = a * wA + b * wB

                        readPos += ratio
                        while readPos >= Float(n) { readPos -= Float(n) }
                        while readPos < 0 { readPos += Float(n) }
                    }

                    if depth > 0 {
                        let carrier = sinf(oscPhase)
                        oscPhase += oscStep
                        if oscPhase > 2 * .pi { oscPhase -= 2 * .pi }
                        sample = sample * (1 - depth) + sample * carrier * depth
                    }

                    output[i] = Int16(max(-1, min(1, sample)) * 32767)
                }
            }
        }
        return out
    }

    /// Linear interpolation into the circular buffer at a fractional index.
    private func interpolate(at pos: Float, n: Int) -> Float {
        let i0 = Int(pos)
        let frac = pos - Float(i0)
        let a = buffer[i0 % n]
        let b = buffer[(i0 + 1) % n]
        return a + (b - a) * frac
    }
}
