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
    @Published var passwordPromptChannel: V3Channel?

    private let client = V3Client.shared
    private let player = V3AudioPlayer()
    private let transmitter = V3Transmitter()
    private var streamTask: Task<Void, Never>?

    var serverDisplayName: String = ""

    func connect(host: String, port: UInt16, username: String, password: String) {
        guard status == .disconnected else { return }
        status = .connecting
        lastError = nil
        roster = V3Roster()
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
                roster.apply(event)
                handle(event)
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
        guard status == .connected, !transmitting else { return }
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
            if let codec = client.codec(forChannel: 0) {
                serverCodec = "\(codec.name) @ \(codec.rate) Hz"
                warnIfUnsupported(codec)
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
        case .disconnected:
            status = .disconnected
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
