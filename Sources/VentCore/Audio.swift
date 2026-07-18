import Foundation
import AVFoundation
#if os(macOS)
import CoreAudio
#endif

/// Plays per-user PCM streams from V3_EVENT_PLAY_AUDIO events.
/// libventrilo3 hands us decoded 16-bit signed PCM at the codec rate.
public final class V3AudioPlayer {
    private let engine = AVAudioEngine()
    private var started = false

    /// Preferred output device UID (empty/nil = system default). Applied on the
    /// next engine start; use `setOutputDevice` to switch while playing.
    public var preferredOutputUID: String?

    private struct Voice {
        let node: AVAudioPlayerNode
        let format: AVAudioFormat
    }
    private var voices: [UInt16: Voice] = [:]
    private var mutedFlag = false
    private let lock = NSLock()

    public init() {
        // Recover when the output device's config changes underneath us — e.g.
        // AirPods flipping between A2DP (stereo, output-only) and HFP (mono, with
        // mic) when transmit turns the mic on/off. Without this the engine dies
        // silently and you stop hearing everyone.
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleConfigChange),
            name: .AVAudioEngineConfigurationChange, object: engine)
        #if os(macOS)
        watchDefaultOutputDevice()
        #endif
    }

    @objc private func handleConfigChange(_ note: Notification) {
        lock.lock(); defer { lock.unlock() }
        let wasStarted = started
        engine.stop()
        started = false
        // Drop the voices; the device's sample rate may have changed, so let
        // the next incoming audio rebuild them at the correct format.
        voices.values.forEach { $0.node.stop(); engine.detach($0.node) }
        voices.removeAll()
        guard wasStarted else { return }
        applyOutputDevice()
        engine.prepare()
        do { try engine.start(); started = true }
        catch { NSLog("V3AudioPlayer: config-change restart failed: \(error)") }
    }

    #if os(macOS)
    /// Follow the system default output when the user hasn't pinned a device, so
    /// switching to AirPods after login routes voice to them (the engine
    /// otherwise stays bound to whatever was default when it started).
    private func watchDefaultOutputDevice() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main
        ) { [weak self] _, _ in
            guard let self else { return }
            let pinned = self.preferredOutputUID
            if pinned == nil || pinned?.isEmpty == true {
                self.setOutputDevice(uid: nil)   // re-resolve to the new default + restart
            }
        }
    }
    #endif

    /// "Mute Sound": drop all incoming audio while muted. Thread-safe.
    public func setMuted(_ muted: Bool) {
        lock.lock(); mutedFlag = muted; lock.unlock()
    }

    /// Switch the output device live. Safe to call while connected.
    public func setOutputDevice(uid: String?) {
        lock.lock(); defer { lock.unlock() }
        preferredOutputUID = uid
        guard started else { return }
        engine.stop()
        started = false
        applyOutputDevice()
        do { try engine.start(); started = true }
        catch { NSLog("V3AudioPlayer: restart failed: \(error)") }
    }

    private func applyOutputDevice() {
        // Always target a device — the chosen one, or the system default when
        // "System Default" is selected — so a prior pin is actively reverted.
        guard let id = AudioDevices.resolve(uid: preferredOutputUID, output: true) else { return }
        do { try engine.outputNode.auAudioUnit.setDeviceID(id) }
        catch { NSLog("V3AudioPlayer: setDeviceID failed: \(error)") }
    }

    public func play(userID: UInt16, rate: UInt32, channels: UInt8, pcm: Data) {
        guard !pcm.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        if mutedFlag { return }

        let ch = AVAudioChannelCount(max(1, channels))
        let voice = voiceFor(userID: userID, rate: Double(rate), channels: ch)
        guard let buffer = makeBuffer(pcm: pcm, format: voice.format) else { return }

        startEngineIfNeeded()
        if !voice.node.isPlaying { voice.node.play() }
        voice.node.scheduleBuffer(buffer)
    }

    public func shutdown() {
        lock.lock(); defer { lock.unlock() }
        voices.values.forEach { $0.node.stop() }
        voices.removeAll()
        if started { engine.stop(); started = false }
    }

    private func voiceFor(userID: UInt16, rate: Double, channels: AVAudioChannelCount) -> Voice {
        if let v = voices[userID], v.format.sampleRate == rate, v.format.channelCount == channels {
            return v
        }
        if let old = voices[userID] {
            old.node.stop()
            engine.detach(old.node)
        }
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        let voice = Voice(node: node, format: format)
        voices[userID] = voice
        return voice
    }

    private func startEngineIfNeeded() {
        guard !started else { return }
        applyOutputDevice()
        engine.prepare()
        do {
            try engine.start()
            started = true
        } catch {
            NSLog("V3AudioPlayer: engine start failed: \(error)")
        }
    }

    private func makeBuffer(pcm: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let channels = Int(format.channelCount)
        let sampleCount = pcm.count / 2 / channels
        guard sampleCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(sampleCount)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(sampleCount)
        pcm.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let samples = raw.bindMemory(to: Int16.self)
            for c in 0..<channels {
                let dst = buffer.floatChannelData![c]
                for i in 0..<sampleCount {
                    dst[i] = Float(samples[i * channels + c]) / 32768.0
                }
            }
        }
        return buffer
    }
}

/// Captures microphone input and delivers 16-bit signed mono PCM chunks at
/// the hardware sample rate. libventrilo3 resamples to the codec rate.
public final class V3AudioCapture {
    private let engine = AVAudioEngine()
    private var running = false

    /// Preferred input device UID (empty/nil = system default). Applied on the
    /// next `start()`.
    public var preferredInputUID: String?

    public init() {}

    /// Start capturing; `onChunk(pcm, rate)` fires on an audio thread.
    public func start(onChunk: @escaping (Data, UInt32) -> Void) throws {
        guard !running else { return }
        let input = engine.inputNode
        // Target the chosen mic, or the system default when "System Default" is
        // selected — so a reused capture instance reverts a prior device pin.
        if let id = AudioDevices.resolve(uid: preferredInputUID, output: false) {
            try? input.auAudioUnit.setDeviceID(id)
        }
        let hwFormat = input.outputFormat(forBus: 0)
        let sampleRate = UInt32(hwFormat.sampleRate)

        // ~40ms chunks.
        let frames = AVAudioFrameCount(hwFormat.sampleRate * 0.04)
        input.installTap(onBus: 0, bufferSize: frames, format: hwFormat) { buffer, _ in
            guard let floats = buffer.floatChannelData?[0] else { return }
            let n = Int(buffer.frameLength)
            guard n > 0 else { return }
            var pcm = Data(count: n * 2)
            pcm.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
                let out = raw.bindMemory(to: Int16.self)
                for i in 0..<n {
                    let v = max(-1.0, min(1.0, floats[i]))
                    out[i] = Int16(v * 32767.0)
                }
            }
            onChunk(pcm, sampleRate)
        }
        engine.prepare()
        try engine.start()
        running = true
    }

    public func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
    }
}
