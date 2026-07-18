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

        if let dbg = ProcessInfo.processInfo.environment["V3_DEBUG"] {
            var mask = V3_DEBUG_INFO | V3_DEBUG_SOCKET | V3_DEBUG_ERROR
            if dbg == "2" { mask |= V3_DEBUG_INTERNAL | V3_DEBUG_PACKET | V3_DEBUG_PACKET_PARSE }
            if dbg == "3" { mask |= V3_DEBUG_INTERNAL | V3_DEBUG_EVENT | V3_DEBUG_MUTEX }
            v3_debuglevel(UInt32(mask))
        }

        let feeder = Thread { [weak self] in
            let s = strdup(server); let u = strdup(username)
            let p = strdup(password); let ph = strdup(phonetic)
            defer { free(s); free(u); free(p); free(ph) }
            guard let self else { return }
            // Initialize libventrilo3's event queue BEFORE login. v3_queue_event
            // silently drops (frees) every event while eventq_mutex is NULL, and
            // that mutex is lazily created only on the first v3_get_event() call.
            // Without this, all events queued during v3_login — channel/user list
            // AND V3_EVENT_LOGIN_COMPLETE — are discarded, so the client never
            // learns it finished logging in. This forces the mutex to exist first;
            // login events then accumulate in the queue and the consumer drains
            // them in order below.
            _ = v3_get_event(V3_NONBLOCK)
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
        case V3_EVENT_CHAT_JOIN.rawValue:
            return .chatJoined(userID: e.user.id)
        case V3_EVENT_CHAT_LEAVE.rawValue:
            return .chatLeft(userID: e.user.id)
        case V3_EVENT_CHAT_MESSAGE.rawValue:
            return .chatMessage(userID: e.user.id, message: eventChatMessage(e))
        case V3_EVENT_PRIVATE_CHAT_START.rawValue:
            return .privateChatStarted(peer: privchatPeer(e))
        case V3_EVENT_PRIVATE_CHAT_END.rawValue:
            return .privateChatEnded(peer: privchatPeer(e))
        case V3_EVENT_PRIVATE_CHAT_MESSAGE.rawValue:
            // user2 is the message's sender; user1/user2 are the session pair.
            return .privateChatMessage(peer: privchatPeer(e),
                                       fromSelf: e.user.privchat_user2 == v3_get_user_id(),
                                       message: eventChatMessage(e))
        case V3_EVENT_PRIVATE_CHAT_AWAY.rawValue:
            return .privateChatAway(peer: privchatPeer(e))
        case V3_EVENT_PRIVATE_CHAT_BACK.rawValue:
            return .privateChatBack(peer: privchatPeer(e))
        case V3_EVENT_USER_PAGE.rawValue:
            return .paged(fromUser: e.user.id)
        case V3_EVENT_TEXT_TO_SPEECH_MESSAGE.rawValue:
            return .ttsMessage(userID: e.user.id, message: eventChatMessage(e))
        case V3_EVENT_USER_GLOBAL_MUTE_CHANGED.rawValue, V3_EVENT_USER_CHANNEL_MUTE_CHANGED.rawValue:
            // Refetch so the roster picks up the new mute flags.
            guard let u = v3_get_user(e.user.id) else { return nil }
            defer { v3_free_user(u) }
            return .userUpserted(V3User(c: u.pointee))
        case V3_EVENT_DISCONNECT.rawValue:
            return .disconnected
        default:
            return nil
        }
    }

    /// The chat text lives in the event-data union's `chatmessage` array,
    /// which sits at offset 0 like the other union members we read.
    private static func eventChatMessage(_ e: v3_event) -> String {
        guard let d = e.data else { return "" }
        return String(cString: UnsafeRawPointer(d).assumingMemoryBound(to: CChar.self))
    }

    /// Private-chat events carry the session's (user1, user2) pair; the peer is
    /// whichever one isn't us.
    private static func privchatPeer(_ e: v3_event) -> UInt16 {
        let me = v3_get_user_id()
        return e.user.privchat_user1 == me ? e.user.privchat_user2 : e.user.privchat_user1
    }
}

// MARK: - Text chat / pages / phantoms / presence

extension V3Client {
    public func joinChat() { v3_join_chat() }
    public func leaveChat() { v3_leave_chat() }

    public func sendChatMessage(_ message: String) {
        guard !message.isEmpty else { return }
        let m = strdup(message); defer { free(m) }
        v3_send_chat_message(m)
    }

    public func startPrivateChat(with userID: UInt16) { v3_start_privchat(userID) }
    public func endPrivateChat(with userID: UInt16) { v3_end_privchat(userID) }

    public func sendPrivateChatMessage(to userID: UInt16, _ message: String) {
        guard !message.isEmpty else { return }
        let m = strdup(message); defer { free(m) }
        v3_send_privchat_message(userID, m)
    }

    public func sendPage(to userID: UInt16) { v3_send_user_page(userID) }

    public func addPhantom(in channelID: UInt16) { v3_phantom_add(channelID) }
    public func removePhantom(in channelID: UInt16) { v3_phantom_remove(channelID) }

    /// Set our comment / URL shown next to our name in everyone's tree.
    /// `silent` suppresses the server's TTS/event announcement of the change.
    public func setText(comment: String, url: String, silent: Bool = true) {
        let c = strdup(comment); let u = strdup(url); let i = strdup("")
        defer { free(c); free(u); free(i) }
        v3_set_text(c, u, i, silent ? 1 : 0)
    }

    /// Per-user playback volume, applied by the library at decode time.
    /// 0…158, 79 = unity (matches the original client's slider range).
    public func setUserVolume(_ userID: UInt16, level: Int32) {
        v3_set_volume_user(userID, level)
    }

    public func userVolume(_ userID: UInt16) -> UInt8 {
        v3_get_volume_user(userID)
    }
}

// MARK: - Transmitter

/// Owns the microphone-capture → encode → network transmit pairing so every
/// frontend shares the same start/stop invariant and failure rollback.
public final class V3Transmitter {
    public private(set) var isTransmitting = false
    private let client: V3Client
    private let capture = V3AudioCapture()

    /// Preferred microphone device UID (empty/nil = system default).
    public var preferredInputUID: String? {
        didSet { capture.preferredInputUID = preferredInputUID }
    }

    public init(client: V3Client = .shared) {
        self.client = client
    }

    /// Begins transmitting. Capture starts asynchronously (off the main thread),
    /// so this returns immediately and never blocks the UI on a slow device.
    @discardableResult
    public func start() -> String? {
        guard !isTransmitting else { return nil }
        client.startTransmit()
        let client = self.client
        capture.start { pcm, rate in
            client.sendPCM(pcm, rate: rate)
        }
        isTransmitting = true
        return nil
    }

    public func stop() {
        guard isTransmitting else { return }
        capture.stop()
        client.stopTransmit()
        isTransmitting = false
    }
}

// MARK: - Voice-activated transmitter

/// Continuous-capture transmitter gated by VoxGate: the mic runs the whole
/// time it's enabled, but audio only goes to the server while the gate is
/// open (level above threshold, plus hysteresis/hangover/pre-roll).
public final class V3VoxTransmitter {
    public private(set) var isRunning = false
    private let client: V3Client
    private let capture = V3AudioCapture()
    private let gate = VoxGate()
    private var gateOpen = false

    /// Mic level (dBFS) and gate state, delivered on the audio thread —
    /// marshal to the main thread before touching UI.
    public var onLevel: ((Float, Bool) -> Void)?

    public var preferredInputUID: String? {
        didSet { capture.preferredInputUID = preferredInputUID }
    }

    /// Open threshold in dBFS; close threshold trails by 10 dB for hysteresis.
    public var sensitivityDBFS: Float {
        get { gate.config.openThresholdDBFS }
        set {
            gate.config.openThresholdDBFS = newValue
            gate.config.closeThresholdDBFS = newValue - 10
        }
    }

    /// Hard mute: closes the gate (stopping transmit) but keeps metering.
    public var muted: Bool {
        get { gate.muted }
        set { gate.muted = newValue }
    }

    public init(client: V3Client = .shared) {
        self.client = client
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        gate.reset()
        gateOpen = false
        capture.start { [weak self] pcm, rate in
            guard let self else { return }
            let action = self.gate.process(pcm: pcm, rate: rate)
            switch action {
            case .idle:
                break
            case .open(let chunks):
                self.client.startTransmit()
                self.gateOpen = true
                for chunk in chunks { self.client.sendPCM(chunk.pcm, rate: chunk.rate) }
            case .transmit(let chunk):
                self.client.sendPCM(chunk.pcm, rate: chunk.rate)
            case .close:
                self.client.stopTransmit()
                self.gateOpen = false
            }
            self.onLevel?(self.gate.lastLevelDBFS, self.gateOpen)
        }
    }

    public func stop() {
        guard isRunning else { return }
        capture.stop()
        if gateOpen {
            client.stopTransmit()
            gateOpen = false
        }
        isRunning = false
    }
}
