import Foundation
import SwiftUI
import AVFoundation
import VentCore

// MARK: - Chat models

struct ChatEntry: Identifiable {
    enum Kind {
        case message(name: String, text: String)
        case notice(String)
    }
    let id = UUID()
    let time = Date()
    let kind: Kind
}

/// One open private-chat session, keyed by the remote peer's user ID.
struct PrivateChatSession: Identifiable {
    let peer: UInt16
    var name: String
    var log: [ChatEntry] = []
    var closedByPeer = false
    var id: UInt16 { peer }
}

@MainActor
final class ConnectionStore: ObservableObject {
    enum Status: Equatable {
        case disconnected
        case connecting
        case connected
        case reconnecting
    }

    enum TransmitMode: String {
        case ptt
        case vox
    }

    @Published var status: Status = .disconnected
    @Published var roster = V3Roster()
    @Published var ownChannelID: UInt16 = 0
    @Published var ownUserID: UInt16 = 0
    @Published var lastError: String?
    @Published var codecWarning: String?
    @Published var transmitting = false
    @Published var serverCodec: String = ""
    @Published var ping: UInt16?            // round-trip ms to the server
    @Published var passwordPromptChannel: V3Channel?
    @Published var connectStatus: String = ""   // login progress text
    @Published var reconnectAttempt = 0
    @Published var motd: MOTDText?

    // Text chat
    @Published var chatOpen = false {
        didSet {
            guard chatOpen != oldValue, status == .connected else { return }
            chatOpen ? client.joinChat() : client.leaveChat()
        }
    }
    @Published var chatLog: [ChatEntry] = []
    @Published var privChats: [PrivateChatSession] = []
    @Published var activeChatTab: UInt16?   // nil = channel chat, else priv peer

    // Local per-user audio state (persisted per server by user *name*,
    // since IDs are per-session).
    @Published var mutedUserIDs: Set<UInt16> = []
    /// Channels we currently hold a phantom in (session-scoped).
    @Published var phantomChannels: Set<UInt16> = []

    /// "Mute Sound" — silence all incoming audio.
    @Published var soundMuted = false { didSet { player.setMuted(soundMuted) } }
    /// "Mute Microphone/Binds" — block transmit and disable PTT binds.
    @Published var micMuted = false {
        didSet {
            if micMuted { stopTalking() }
            vox.muted = micMuted
        }
    }

    // Voice activation
    @Published var transmitMode: TransmitMode {
        didSet {
            UserDefaults.standard.set(transmitMode.rawValue, forKey: "transmit.mode")
            updateVoxState()
        }
    }
    @Published var voxSensitivity: Double {
        didSet {
            UserDefaults.standard.set(voxSensitivity, forKey: "transmit.voxSensitivity")
            vox.sensitivityDBFS = Float(voxSensitivity)
        }
    }
    /// Mic level lives in its own observable so the ~25 Hz updates only
    /// re-render the meter in Settings, not the whole main window.
    let voxMeter = VoxMeterModel()

    @MainActor
    final class VoxMeterModel: ObservableObject {
        @Published var levelDBFS: Float = -120
    }

    struct MOTDText: Identifiable {
        let id = UUID()
        let text: String
    }

    private let client = V3Client.shared
    private let player = V3AudioPlayer()
    private let transmitter = V3Transmitter()
    private let vox = V3VoxTransmitter()
    private let sounds = ChannelSounds()
    private let speech = AVSpeechSynthesizer()
    private var soundsArmed = false   // suppress cues during the initial roster load
    private var streamTask: Task<Void, Never>?

    // Reconnect state
    private var wantDisconnect = false
    private var connParams: (host: String, port: UInt16, username: String, password: String)?
    private var lastChannelID: UInt16 = 0
    private var channelPasswords: [UInt16: String] = [:]   // session cache for rejoin
    private static let maxReconnectAttempts = 20

    var serverDisplayName: String = ""
    private var serverKey: String = ""   // host:port — persistence namespace

    init() {
        transmitMode = TransmitMode(rawValue: UserDefaults.standard.string(forKey: "transmit.mode") ?? "") ?? .ptt
        let sens = UserDefaults.standard.object(forKey: "transmit.voxSensitivity") as? Double
        voxSensitivity = sens ?? -40
        vox.sensitivityDBFS = Float(voxSensitivity)
        vox.onLevel = { [weak self] level, open in
            DispatchQueue.main.async {
                guard let self else { return }
                self.voxMeter.levelDBFS = level
                if self.transmitMode == .vox && self.transmitting != open {
                    self.transmitting = open
                }
            }
        }
    }

    /// Wire audio-device selection: apply the persisted choice now and on change.
    func bind(audio: AudioSettings) {
        let apply: (String) -> String? = { $0.isEmpty ? nil : $0 }
        transmitter.preferredInputUID = apply(audio.inputUID)
        vox.preferredInputUID = apply(audio.inputUID)
        player.preferredOutputUID = apply(audio.outputUID)
        audio.onInputChange = { [weak self] uid in
            guard let self else { return }
            self.transmitter.preferredInputUID = apply(uid)
            self.vox.preferredInputUID = apply(uid)
            if self.vox.isRunning {   // restart so the new device takes effect
                self.vox.stop()
                self.vox.start()
            }
        }
        audio.onOutputChange = { [weak self] uid in self?.player.setOutputDevice(uid: apply(uid)) }
    }

    func connect(host: String, port: UInt16, username: String, password: String) {
        guard status == .disconnected else { return }
        connParams = (host, port, username, password)
        wantDisconnect = false
        reconnectAttempt = 0
        status = .connecting
        lastError = nil
        connectStatus = ""
        serverDisplayName = "\(host):\(port)"
        serverKey = serverDisplayName
        chatLog = []
        privChats = []
        loadPersistedUserAudio()
        runSession()
    }

    private func runSession() {
        guard let p = connParams else { return }
        roster = V3Roster()
        soundsArmed = false
        // User IDs and phantoms are per-session — reset every derived set,
        // including the player's, so stale IDs can't mute the wrong person.
        mutedUserIDs = []
        player.clearUserMutes()
        phantomChannels = []

        // Voice frames go straight to the player from the consumer thread —
        // they never touch the MainActor event loop below.
        let player = self.player
        client.audioSink = { userID, rate, channels, pcm in
            player.play(userID: userID, rate: rate, channels: channels, pcm: pcm)
        }

        streamTask = Task {
            let stream = client.connect(host: p.host, port: p.port,
                                        username: p.username, password: p.password)
            for await event in stream {
                let before = roster
                roster.apply(event)
                handle(event)
                channelCue(for: event, before: before)
            }
            handleStreamEnd()
        }
    }

    /// The connection stream finished — either a requested disconnect, a login
    /// failure, or an unexpected drop (auto-reconnect, like Vent's persistent
    /// connection).
    private func handleStreamEnd() {
        stopTalking()
        vox.stop()
        player.shutdown()
        ping = nil

        // .connecting here means the *initial* connect failed — don't retry that,
        // and don't retry a user-requested disconnect.
        if wantDisconnect || connParams == nil || status == .connecting {
            status = .disconnected
            return
        }
        guard reconnectAttempt < Self.maxReconnectAttempts else {
            lastError = "Gave up reconnecting after \(Self.maxReconnectAttempts) attempts."
            status = .disconnected
            return
        }
        status = .reconnecting
        reconnectAttempt += 1
        let delay = min(pow(2.0, Double(reconnectAttempt)), 30)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !self.wantDisconnect, self.status == .reconnecting else { return }
            self.runSession()
        }
    }

    func disconnect() {
        wantDisconnect = true
        stopTalking()
        if status == .reconnecting {
            // No live connection to tear down; just stop the retry loop.
            status = .disconnected
        } else {
            client.disconnect()
        }
    }

    func join(_ channel: V3Channel) {
        if channel.isPasswordProtected && channelPasswords[channel.id] == nil {
            passwordPromptChannel = channel
        } else {
            client.joinChannel(channel.id, password: channelPasswords[channel.id] ?? "")
        }
    }

    func join(_ channel: V3Channel, password: String) {
        channelPasswords[channel.id] = password
        client.joinChannel(channel.id, password: password)
    }

    // MARK: Transmit

    func startTalking() {
        guard status == .connected, transmitMode == .ptt, !transmitting, !micMuted else { return }
        if let error = transmitter.start() {
            lastError = error
        } else {
            transmitting = true
        }
    }

    func stopTalking() {
        guard transmitMode == .ptt, transmitting else { return }
        transmitter.stop()
        transmitting = false
    }

    private func updateVoxState() {
        if status == .connected && transmitMode == .vox {
            transmitter.stop()
            transmitting = false
            vox.start()
        } else {
            vox.stop()
            if transmitMode == .ptt { transmitting = false }
        }
    }

    // MARK: Chat

    func sendChat(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let peer = activeChatTab {
            client.sendPrivateChatMessage(to: peer, text)
            appendPriv(peer: peer, entry: ChatEntry(kind: .message(name: ownName, text: text)))
        } else {
            client.sendChatMessage(text)
            // The server echoes channel chat back to the sender; if it didn't,
            // we'd append locally here. Echo dedup happens in handle().
        }
    }

    func openPrivateChat(with user: V3User) {
        if !privChats.contains(where: { $0.peer == user.id }) {
            client.startPrivateChat(with: user.id)
            privChats.append(PrivateChatSession(peer: user.id, name: user.name))
        }
        activeChatTab = user.id
        chatOpen = true
    }

    func closePrivateChat(peer: UInt16) {
        client.endPrivateChat(with: peer)
        privChats.removeAll { $0.peer == peer }
        if activeChatTab == peer { activeChatTab = nil }
    }

    private func appendPriv(peer: UInt16, entry: ChatEntry) {
        guard let idx = privChats.firstIndex(where: { $0.peer == peer }) else { return }
        privChats[idx].log.append(entry)
        if privChats[idx].log.count > 500 { privChats[idx].log.removeFirst() }
    }

    private func appendChat(_ entry: ChatEntry) {
        chatLog.append(entry)
        if chatLog.count > 500 { chatLog.removeFirst() }
    }

    private var ownName: String { roster.users[ownUserID]?.name ?? "me" }

    // MARK: Pages / user actions

    func page(_ user: V3User) {
        client.sendPage(to: user.id)
    }

    func togglePhantom(in channel: V3Channel) {
        if phantomChannels.contains(channel.id) {
            client.removePhantom(in: channel.id)
            phantomChannels.remove(channel.id)
        } else {
            client.addPhantom(in: channel.id)
            phantomChannels.insert(channel.id)
        }
    }

    // MARK: Per-user volume / mute (persisted by name per server)

    func userVolume(_ user: V3User) -> Int {
        Int(client.userVolume(user.id))
    }

    func setUserVolume(_ user: V3User, level: Int) {
        client.setUserVolume(user.id, level: Int32(level))
        if level == 79 { savedVolumes.removeValue(forKey: user.name) } else { savedVolumes[user.name] = level }
        UserDefaults.standard.set(savedVolumes, forKey: volumesKey)
        objectWillChange.send()
    }

    func isUserMuted(_ user: V3User) -> Bool { mutedUserIDs.contains(user.id) }

    func toggleUserMute(_ user: V3User) {
        let muted = !mutedUserIDs.contains(user.id)
        if muted { mutedUserIDs.insert(user.id) } else { mutedUserIDs.remove(user.id) }
        player.setUserMuted(user.id, muted)
        if muted { savedMutes.insert(user.name) } else { savedMutes.remove(user.name) }
        UserDefaults.standard.set(Array(savedMutes), forKey: mutesKey)
    }

    private var volumesKey: String { "userVolumes.\(serverKey)" }
    private var mutesKey: String { "mutedUsers.\(serverKey)" }
    // Session cache of the persisted per-user prefs — applyPersistedUserAudio
    // runs on every roster event and must not hit UserDefaults each time.
    private var savedVolumes: [String: Int] = [:]
    private var savedMutes: Set<String> = []

    func loadPersistedUserAudio() {
        savedVolumes = UserDefaults.standard.dictionary(forKey: volumesKey) as? [String: Int] ?? [:]
        savedMutes = Set(UserDefaults.standard.stringArray(forKey: mutesKey) ?? [])
    }

    /// Re-apply persisted per-user volume/mute when a user (re)appears.
    private func applyPersistedUserAudio(_ user: V3User) {
        guard !user.name.isEmpty else { return }
        if let level = savedVolumes[user.name], client.userVolume(user.id) != UInt8(clamping: level) {
            client.setUserVolume(user.id, level: Int32(level))
        }
        if savedMutes.contains(user.name), !mutedUserIDs.contains(user.id) {
            mutedUserIDs.insert(user.id)
            player.setUserMuted(user.id, true)
        }
    }

    // MARK: Identity (comment / URL)

    func applyIdentityText() {
        guard status == .connected else { return }
        let comment = UserDefaults.standard.string(forKey: "identity.comment") ?? ""
        let url = UserDefaults.standard.string(forKey: "identity.url") ?? ""
        client.setText(comment: comment, url: url)
    }

    // MARK: Event handling

    private func handle(_ event: V3CoreEvent) {
        switch event {
        case .status(_, let message):
            connectStatus = message
        case .loginCompleted:
            let wasReconnect = status == .reconnecting
            status = .connected
            reconnectAttempt = 0
            connectStatus = ""
            ownUserID = client.ownUserID
            if SoundPref.connect.enabled {
                sounds.play(.connect)
            }
            if let codec = client.codec(forChannel: 0) {
                serverCodec = "\(codec.name) @ \(codec.rate) Hz"
                warnIfUnsupported(codec)
            }
            applyIdentityText()
            if chatOpen { client.joinChat() }
            if wasReconnect, lastChannelID != 0 {
                client.joinChannel(lastChannelID, password: channelPasswords[lastChannelID] ?? "")
            }
            updateVoxState()
            // Arm join/leave cues only after the initial user list has settled,
            // so connecting to a populated channel isn't a burst of sounds.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                self?.soundsArmed = true
            }
        case .loginFailed(let message):
            lastError = message
        case .errorMessage(let message, let disconnected):
            lastError = message
            if disconnected { wantDisconnect = true }   // server kicked us on purpose
        case .channelPasswordRejected(let id):
            channelPasswords.removeValue(forKey: id)
            lastError = "Wrong password for \(roster.channelName(id))"
        case .movedToChannel(let id):
            ownChannelID = id
            lastChannelID = id
            if let codec = client.codec(forChannel: id) { warnIfUnsupported(codec) }
        case .userUpserted(let u):
            applyPersistedUserAudio(u)
        case .ping(let ms):
            ping = ms == 0xffff ? nil : ms   // 0xffff = no measurement yet
        case .motd(let text):
            presentMOTD(text)
        case .chatJoined(let uid):
            if let name = roster.users[uid]?.name, uid != ownUserID {
                appendChat(ChatEntry(kind: .notice("\(name) joined chat")))
            }
        case .chatLeft(let uid):
            if let name = roster.users[uid]?.name, uid != ownUserID {
                appendChat(ChatEntry(kind: .notice("\(name) left chat")))
            }
        case .chatMessage(let uid, let text):
            let name = uid == 0 ? "[server]" : (roster.users[uid]?.name ?? "#\(uid)")
            appendChat(ChatEntry(kind: .message(name: name, text: text)))
        case .privateChatStarted(let peer):
            let name = roster.users[peer]?.name ?? "#\(peer)"
            if !privChats.contains(where: { $0.peer == peer }) {
                privChats.append(PrivateChatSession(peer: peer, name: name))
                appendPriv(peer: peer, entry: ChatEntry(kind: .notice("\(name) opened a private chat")))
                sounds.play(.join)
                chatOpen = true
                if activeChatTab == nil { activeChatTab = peer }
            }
        case .privateChatEnded(let peer):
            if let idx = privChats.firstIndex(where: { $0.peer == peer }) {
                privChats[idx].closedByPeer = true
                privChats[idx].log.append(ChatEntry(kind: .notice("\(privChats[idx].name) closed the chat")))
            }
        case .privateChatMessage(let peer, let fromSelf, let text):
            guard !fromSelf else { break }   // we already appended our own sends
            let name = roster.users[peer]?.name ?? "#\(peer)"
            appendPriv(peer: peer, entry: ChatEntry(kind: .message(name: name, text: text)))
            if activeChatTab != peer || !chatOpen { sounds.play(.join) }
        case .privateChatAway(let peer):
            appendPriv(peer: peer, entry: ChatEntry(kind: .notice("away")))
        case .privateChatBack(let peer):
            appendPriv(peer: peer, entry: ChatEntry(kind: .notice("back")))
        case .paged(let uid):
            let name = roster.users[uid]?.name ?? "someone"
            sounds.play(.page)
            if SoundPref.pageSpeech.enabled {
                speak("Page from \(name)")
            }
            appendChat(ChatEntry(kind: .notice("📟 Page from \(name)")))
        case .ttsMessage(_, let text):
            if SoundPref.ttsReceive.enabled {
                speak(text)
            }
        case .disconnected:
            // handleStreamEnd decides whether this becomes a reconnect.
            break
        default:
            break
        }
    }

    private func presentMOTD(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Compare the stored text itself — String.hashValue is seeded per
        // process, so a hash would never match after a relaunch. Re-shows
        // automatically when the server's MOTD changes.
        guard trimmed != UserDefaults.standard.string(forKey: "motd.ignore.\(serverKey)") else { return }
        motd = MOTDText(text: trimmed)
    }

    func ignoreCurrentMOTD() {
        guard let motd else { return }
        UserDefaults.standard.set(motd.text, forKey: "motd.ignore.\(serverKey)")
    }

    private func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        speech.speak(utterance)
    }

    /// Play a subtle cue when another user enters or leaves *your* channel.
    /// Gated by the user's preference and armed only after the initial roster load.
    private func channelCue(for event: V3CoreEvent, before: V3Roster) {
        guard soundsArmed, SoundPref.joinLeave.enabled else { return }
        switch event {
        case .userUpserted(let u):
            guard u.id != ownUserID else { return }
            let wasHere = before.users[u.id]?.channelID == ownChannelID
            let isHere = u.channelID == ownChannelID
            if isHere && !wasHere { sounds.play(.join) }
            else if wasHere && !isHere { sounds.play(.leave) }
        case .userRemoved(let id):
            guard id != ownUserID, before.users[id]?.channelID == ownChannelID else { return }
            sounds.play(.leave)
        default:
            break
        }
    }

    /// Warn when a channel uses a codec this build can't decode, instead of
    /// failing silently. (ISC-34)
    private func warnIfUnsupported(_ codec: V3Codec) {
        codecWarning = codec.isSupported
            ? nil
            : "This channel uses \(codec.name) — this build can't decode it, so voice will be silent here."
    }
}
