import Foundation

/// Voice-activated transmission gate — pure DSP, no platform APIs, unit-testable.
///
/// Feed it the same 16-bit PCM chunks the capture tap produces. It measures each
/// chunk's level (RMS → dBFS) and runs a hysteresis + hangover + min-on-time
/// state machine, returning what to do: nothing, "just opened — flush this
/// pre-roll then transmit", "keep transmitting", or "just closed — stop".
///
/// Time is advanced from the chunks themselves (each chunk's duration), so the
/// gate is deterministic and testable without a wall clock.
public final class VoxGate {
    public struct Config: Sendable, Equatable {
        /// Level at/above which a closed gate opens.
        public var openThresholdDBFS: Float = -40
        /// Level below which an open gate begins its hangover countdown.
        /// Lower than `open` → hysteresis, so it doesn't chatter around one level.
        public var closeThresholdDBFS: Float = -50
        /// Keep transmitting this long after the level drops, so word tails and
        /// short pauses aren't clipped.
        public var hangoverMs: Double = 300
        /// Minimum time the gate stays open once triggered (anti-chatter).
        public var minOnMs: Double = 150
        /// How much audio just *before* the trigger to prepend, so the first
        /// syllable isn't lost.
        public var preRollMs: Double = 150
        public init() {}
    }

    public struct Chunk: Sendable, Equatable {
        public let pcm: Data
        public let rate: UInt32
        public init(pcm: Data, rate: UInt32) { self.pcm = pcm; self.rate = rate }
    }

    public enum Action: Sendable, Equatable {
        case idle                 // gate closed; send nothing
        case open([Chunk])        // just opened; transmit these (pre-roll + current) in order
        case transmit(Chunk)      // gate open; transmit this chunk
        case close                // just closed; stop transmitting
    }

    public var config: Config
    /// Hard mute overrides the gate entirely (used by a mute button).
    public var muted = false { didSet { if muted && isOpen { pendingCloseFromMute = true } } }

    public private(set) var isOpen = false
    public private(set) var lastLevelDBFS: Float = -120

    private var clockMs: Double = 0
    private var openedAtMs: Double = 0
    private var lastAboveCloseMs: Double = 0
    private var preroll: [(chunk: Chunk, endMs: Double)] = []
    private var pendingCloseFromMute = false

    public init(config: Config = Config()) { self.config = config }

    public func reset() {
        isOpen = false; clockMs = 0; openedAtMs = 0; lastAboveCloseMs = 0
        preroll.removeAll(); pendingCloseFromMute = false; lastLevelDBFS = -120
    }

    public func process(pcm: Data, rate: UInt32) -> Action {
        let samples = pcm.count / 2
        let durMs = rate > 0 ? Double(samples) / Double(rate) * 1000 : 0
        clockMs += durMs
        lastLevelDBFS = Self.levelDBFS(pcm)
        let chunk = Chunk(pcm: pcm, rate: rate)

        if muted {
            preroll.removeAll()
            if isOpen || pendingCloseFromMute { isOpen = false; pendingCloseFromMute = false; return .close }
            return .idle
        }

        if !isOpen {
            preroll.append((chunk, clockMs))
            while let first = preroll.first, clockMs - first.endMs > config.preRollMs {
                preroll.removeFirst()
            }
            guard lastLevelDBFS >= config.openThresholdDBFS else { return .idle }
            isOpen = true
            openedAtMs = clockMs
            lastAboveCloseMs = clockMs
            let flush = preroll.map(\.chunk)   // includes the current chunk
            preroll.removeAll()
            return .open(flush)
        }

        if lastLevelDBFS >= config.closeThresholdDBFS { lastAboveCloseMs = clockMs }
        let heldFor = clockMs - openedAtMs
        let sinceAbove = clockMs - lastAboveCloseMs
        if sinceAbove > config.hangoverMs && heldFor > config.minOnMs {
            isOpen = false
            return .close
        }
        return .transmit(chunk)
    }

    /// RMS of a 16-bit little-endian PCM buffer, in dBFS. Returns a floor for silence.
    public static func levelDBFS(_ pcm: Data) -> Float {
        let n = pcm.count / 2
        guard n > 0 else { return -120 }
        var sumSq = 0.0
        pcm.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            for i in 0..<n { let v = Double(s[i]) / 32768.0; sumSq += v * v }
        }
        let rms = (sumSq / Double(n)).squareRoot()
        return rms > 0 ? Float(20 * log10(rms)) : -120
    }
}
