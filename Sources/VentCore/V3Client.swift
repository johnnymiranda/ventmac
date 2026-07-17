import Foundation
import CVentrilo3

/// Swift wrapper around libventrilo3. The C library is a single global
/// connection, so this client is a singleton: one connection per process.
///
/// Canonical libventrilo3 usage (from lv3_test.c): a "feeder" thread runs
/// v3_login() then pumps _v3_recv()/_v3_process_message(); a "consumer"
/// thread drains v3_get_event(V3_BLOCK). We surface the consumer side as an
/// AsyncStream of V3CoreEvent.
///
/// Teardown ownership: before login succeeds, the feeder owns the stream
/// (yield .loginFailed, finish). After login succeeds it starts the consumer,
/// which becomes the sole owner — the C lib guarantees a V3_EVENT_DISCONNECT
/// on every close path (_v3_logout queues one), which ends the consumer loop.
public final class V3Client: @unchecked Sendable {
    public static let shared = V3Client()
    private init() {}

    private let stateLock = NSLock()
    private var running = false

    /// Realtime PCM delivery. When set, V3_EVENT_PLAY_AUDIO is delivered here
    /// directly on the consumer thread instead of through the event stream —
    /// keeps voice frames off the (typically MainActor-bound) stream consumer.
    public var audioSink: ((_ userID: UInt16, _ rate: UInt32, _ channels: UInt8, _ pcm: Data) -> Void)?

    /// Connect and log in. Returns a stream of events for this connection;
    /// the stream finishes on disconnect or login failure.
    public func connect(host: String, port: UInt16, username: String,
                        password: String = "", phonetic: String = "") -> AsyncStream<V3CoreEvent> {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !running else {
            return AsyncStream { $0.finish() }
        }
        running = true
        v3_clear_events()  // drop stale events from any previous attempt

        let server = "\(host):\(port)"
        let (stream, continuation) = AsyncStream.makeStream(of: V3CoreEvent.self,
                                                            bufferingPolicy: .unbounded)

        if ProcessInfo.processInfo.environment["V3_DEBUG"] != nil {
            v3_debuglevel(UInt32(V3_DEBUG_INFO | V3_DEBUG_SOCKET | V3_DEBUG_ERROR))
        }

        let feeder = Thread { [weak self] in
            let s = strdup(server); let u = strdup(username)
            let p = strdup(password); let ph = strdup(phonetic)
            defer { free(s); free(u); free(p); free(ph) }
            guard let self else { return }
            if v3_login(s, u, p, ph) == 0 {
                continuation.yield(.loginFailed(String(cString: v3_last_error())))
                self.finishConnection(continuation)
                return
            }
            self.startConsumer(continuation)
            while let msg = _v3_recv(V3_BLOCK) {
                _ = _v3_process_message(msg)
            }
        }
        feeder.name = "v3-feeder"
        feeder.stackSize = 1 << 21
        feeder.start()
        return stream
    }

    private func startConsumer(_ continuation: AsyncStream<V3CoreEvent>.Continuation) {
        let consumer = Thread { [weak self] in
            while let ev = v3_get_event(V3_BLOCK) {
                let translated = Self.translate(ev, audioSink: self?.audioSink)
                v3_free_event(ev)
                guard let event = translated else { continue }
                continuation.yield(event)
                if case .disconnected = event { break }
            }
            self?.finishConnection(continuation)
        }
        consumer.name = "v3-consumer"
        consumer.stackSize = 1 << 21
        consumer.start()
    }

    private func finishConnection(_ continuation: AsyncStream<V3CoreEvent>.Continuation) {
        stateLock.lock()
        running = false
        stateLock.unlock()
        // Order matters: `running` is cleared first so a consumer reacting to
        // the stream ending can immediately reconnect.
        continuation.finish()
    }

    public var isLoggedIn: Bool { v3_is_loggedin() != 0 }
    public var ownUserID: UInt16 { v3_get_user_id() }

    public func disconnect() {
        v3_logout()
    }

    public func joinChannel(_ id: UInt16, password: String = "") {
        let p = strdup(password); defer { free(p) }
        v3_change_channel(id, p)
    }

    public func channelRequiresPassword(_ id: UInt16) -> Bool {
        v3_channel_requires_password(id) != 0
    }

    /// Codec for a channel (channel 0 / lobby returns the server default).
    public func codec(forChannel id: UInt16) -> V3Codec? {
        V3Codec(c: v3_get_channel_codec(id))
    }

    public func channel(_ id: UInt16) -> V3Channel? {
        guard let c = v3_get_channel(id) else { return nil }
        defer { v3_free_channel(c) }
        return V3Channel(c: c.pointee)
    }

    public func user(_ id: UInt16) -> V3User? {
        guard let u = v3_get_user(id) else { return nil }
        defer { v3_free_user(u) }
        return V3User(c: u.pointee)
    }

    // MARK: - Voice transmit

    func startTransmit() {
        v3_start_audio(UInt16(V3_AUDIO_SENDTYPE_U2CCUR))
    }

    /// Send raw PCM (16-bit signed little-endian). Any sample rate — the
    /// library resamples to the channel codec rate internally (speexdsp).
    func sendPCM(_ pcm: Data, rate: UInt32, stereo: Bool = false) {
        guard !pcm.isEmpty else { return }
        pcm.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            _ = v3_send_audio(UInt16(V3_AUDIO_SENDTYPE_U2CCUR), rate,
                              UnsafeMutablePointer(mutating: base),
                              UInt32(pcm.count), stereo ? 1 : 0)
        }
    }

    func stopTransmit() {
        v3_stop_audio()
    }

    // MARK: - Event translation

    private static func translate(
        _ ev: UnsafeMutablePointer<v3_event>,
        audioSink: ((UInt16, UInt32, UInt8, Data) -> Void)?
    ) -> V3CoreEvent? {
        let e = ev.pointee
        switch UInt32(e.type) {
        case V3_EVENT_STATUS.rawValue:
            return .status(percent: e.status.percent, message: fixedCString(e.status.message))
        case V3_EVENT_LOGIN_COMPLETE.rawValue:
            return .loginCompleted
        case V3_EVENT_LOGIN_FAIL.rawValue:
            return .loginFailed(fixedCString(e.error.message))
        case V3_EVENT_ERROR_MSG.rawValue:
            return .errorMessage(fixedCString(e.error.message), disconnected: e.error.disconnected != 0)
        case V3_EVENT_CHAN_ADD.rawValue, V3_EVENT_CHAN_MODIFY.rawValue, V3_EVENT_CHAN_MODIFIED.rawValue:
            guard let c = v3_get_channel(e.channel.id) else { return nil }
            defer { v3_free_channel(c) }
            return .channelUpserted(V3Channel(c: c.pointee))
        case V3_EVENT_CHAN_REMOVE.rawValue, V3_EVENT_CHAN_REMOVED.rawValue:
            return .channelRemoved(e.channel.id)
        case V3_EVENT_CHAN_BADPASS.rawValue:
            return .channelPasswordRejected(e.channel.id)
        case V3_EVENT_USER_LOGIN.rawValue, V3_EVENT_USER_MODIFY.rawValue, V3_EVENT_USER_CHAN_MOVE.rawValue:
            guard let u = v3_get_user(e.user.id) else { return nil }
            defer { v3_free_user(u) }
            return .userUpserted(V3User(c: u.pointee))
        case V3_EVENT_USER_LOGOUT.rawValue:
            return .userRemoved(e.user.id)
        case V3_EVENT_CHANGE_CHANNEL.rawValue:
            return .movedToChannel(e.channel.id)
        case V3_EVENT_USER_TALK_START.rawValue:
            return .talkStarted(userID: e.user.id, rate: e.pcm.rate)
        case V3_EVENT_USER_TALK_END.rawValue, V3_EVENT_USER_TALK_MUTE.rawValue:
            return .talkEnded(userID: e.user.id)
        case V3_EVENT_PLAY_AUDIO.rawValue:
            guard let d = e.data else { return nil }
            // v3_event_data is a union; the PCM `sample` array sits at offset 0.
            let length = min(Int(e.pcm.length), MemoryLayout<v3_event_data>.size)
            let pcm = Data(bytes: UnsafeRawPointer(d), count: length)
            if let audioSink {
                audioSink(e.user.id, e.pcm.rate, e.pcm.channels, pcm)
                return nil
            }
            return .audio(userID: e.user.id, rate: e.pcm.rate, channels: e.pcm.channels, pcm: pcm)
        case V3_EVENT_DISPLAY_MOTD.rawValue:
            guard let d = e.data else { return nil }
            // Union: `motd` char array also sits at offset 0.
            let motd = String(cString: UnsafeRawPointer(d).assumingMemoryBound(to: CChar.self))
            return .motd(motd)
        case V3_EVENT_PING.rawValue:
            return .ping(e.ping)
        case V3_EVENT_DISCONNECT.rawValue:
            return .disconnected
        default:
            return nil
        }
    }
}

// MARK: - Transmitter

/// Owns the microphone-capture → encode → network transmit pairing so every
/// frontend shares the same start/stop invariant and failure rollback.
public final class V3Transmitter {
    public private(set) var isTransmitting = false
    private let client: V3Client
    private let capture = V3AudioCapture()

    public init(client: V3Client = .shared) {
        self.client = client
    }

    /// Returns an error message on failure (transmit is rolled back).
    @discardableResult
    public func start() -> String? {
        guard !isTransmitting else { return nil }
        client.startTransmit()
        do {
            let client = self.client
            try capture.start { pcm, rate in
                client.sendPCM(pcm, rate: rate)
            }
            isTransmitting = true
            return nil
        } catch {
            client.stopTransmit()
            return "Microphone capture failed: \(error.localizedDescription)"
        }
    }

    public func stop() {
        guard isTransmitting else { return }
        capture.stop()
        client.stopTransmit()
        isTransmitting = false
    }
}
