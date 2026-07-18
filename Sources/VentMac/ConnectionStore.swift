import Foundation
import SwiftUI
import VentCore

@MainActor
final class ConnectionStore: ObservableObject {
    enum Status: Equatable {
        case disconnected
        case connecting
        case connected
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

    /// "Mute Sound" — silence all incoming audio.
    @Published var soundMuted = false { didSet { player.setMuted(soundMuted) } }
    /// "Mute Microphone/Binds" — block transmit and disable PTT binds.
    @Published var micMuted = false { didSet { if micMuted { stopTalking() } } }

    private let client = V3Client.shared
    private let player = V3AudioPlayer()
    private let transmitter = V3Transmitter()
    private let sounds = ChannelSounds()
    private var soundsArmed = false   // suppress cues during the initial roster load
    private var streamTask: Task<Void, Never>?

    var serverDisplayName: String = ""

    /// Wire audio-device selection: apply the persisted choice now and on change.
    func bind(audio: AudioSettings) {
        let apply: (String) -> String? = { $0.isEmpty ? nil : $0 }
        transmitter.preferredInputUID = apply(audio.inputUID)
        player.preferredOutputUID = apply(audio.outputUID)
        audio.onInputChange = { [weak self] uid in self?.transmitter.preferredInputUID = apply(uid) }
        audio.onOutputChange = { [weak self] uid in self?.player.setOutputDevice(uid: apply(uid)) }
    }

    func connect(host: String, port: UInt16, username: String, password: String) {
        guard status == .disconnected else { return }
        status = .connecting
        lastError = nil
        roster = V3Roster()
        soundsArmed = false
        serverDisplayName = "\(host):\(port)"

        // Voice frames go straight to the player from the consumer thread —
        // they never touch the MainActor event loop below.
        let player = self.player
        client.audioSink = { userID, rate, channels, pcm in
            player.play(userID: userID, rate: rate, channels: channels, pcm: pcm)
        }

        streamTask = Task {
            let stream = client.connect(host: host, port: port,
                                        username: username, password: password)
            for await event in stream {
                let before = roster
                roster.apply(event)
                handle(event)
                channelCue(for: event, before: before)
            }
            stopTalking()
            player.shutdown()
            if status != .disconnected {
                status = .disconnected
            }
        }
    }

    func disconnect() {
        stopTalking()
        client.disconnect()
    }

    func join(_ channel: V3Channel) {
        if channel.isPasswordProtected {
            passwordPromptChannel = channel
        } else {
            client.joinChannel(channel.id)
        }
    }

    func join(_ channel: V3Channel, password: String) {
        client.joinChannel(channel.id, password: password)
    }

    func startTalking() {
        guard status == .connected, !transmitting, !micMuted else { return }
        if let error = transmitter.start() {
            lastError = error
        } else {
            transmitting = true
        }
    }

    func stopTalking() {
        guard transmitting else { return }
        transmitter.stop()
        transmitting = false
    }

    private func handle(_ event: V3CoreEvent) {
        switch event {
        case .loginCompleted:
            status = .connected
            ownUserID = client.ownUserID
            if UserDefaults.standard.object(forKey: "sounds.connect") as? Bool ?? true {
                sounds.play(.connect)
            }
            if let codec = client.codec(forChannel: 0) {
                serverCodec = "\(codec.name) @ \(codec.rate) Hz"
                warnIfUnsupported(codec)
            }
            // Arm join/leave cues only after the initial user list has settled,
            // so connecting to a populated channel isn't a burst of sounds.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                self?.soundsArmed = true
            }
        case .loginFailed(let message):
            lastError = message
            status = .disconnected
        case .errorMessage(let message, let disconnected):
            lastError = message
            if disconnected { status = .disconnected }
        case .channelPasswordRejected(let id):
            lastError = "Wrong password for \(roster.channelName(id))"
        case .movedToChannel(let id):
            ownChannelID = id
            if let codec = client.codec(forChannel: id) { warnIfUnsupported(codec) }
        case .ping(let ms):
            ping = ms == 0xffff ? nil : ms   // 0xffff = no measurement yet
        case .disconnected:
            status = .disconnected
            ping = nil
        default:
            break
        }
    }

    /// Play a subtle cue when another user enters or leaves *your* channel.
    /// Gated by the user's preference and armed only after the initial roster load.
    private func channelCue(for event: V3CoreEvent, before: V3Roster) {
        guard soundsArmed,
              UserDefaults.standard.object(forKey: "sounds.channelJoinLeave") as? Bool ?? true
        else { return }
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

    /// GSM/Opus/CELT channels would be silent in this Speex-only build —
    /// say so instead of failing silently. (ISC-34)
    private func warnIfUnsupported(_ codec: V3Codec) {
        codecWarning = codec.isSupported
            ? nil
            : "This channel uses \(codec.name) — this build only decodes Speex, so voice will be silent here."
    }
}
