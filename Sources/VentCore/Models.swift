import Foundation
import CVentrilo3

/// Convert a fixed-size C char-array (imported as a tuple) to String.
func fixedCString<T>(_ tuple: T) -> String {
    withUnsafeBytes(of: tuple) { raw in
        String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
    }
}

extension String {
    init(optionalCString pointer: UnsafeMutablePointer<CChar>?) {
        self = pointer.map { String(cString: $0) } ?? ""
    }
}

public struct V3Channel: Identifiable, Hashable, Sendable {
    public let id: UInt16
    public let parent: UInt16
    public let name: String
    public let phonetic: String
    public let comment: String
    public let isPasswordProtected: Bool
    public let codec: UInt16
    public let codecFormat: UInt16

    init(c: v3_channel) {
        id = c.id
        parent = c.parent
        name = String(optionalCString: c.name)
        phonetic = String(optionalCString: c.phonetic)
        comment = String(optionalCString: c.comment)
        isPasswordProtected = c.password_protected != 0
        codec = c.channel_codec
        codecFormat = c.channel_format
    }
}

public struct V3User: Identifiable, Hashable, Sendable {
    public let id: UInt16
    public let channelID: UInt16
    public let name: String
    public let phonetic: String
    public let comment: String
    public let rankID: UInt16

    init(c: v3_user) {
        id = c.id
        channelID = c.channel
        name = String(optionalCString: c.name)
        phonetic = String(optionalCString: c.phonetic)
        comment = String(optionalCString: c.comment)
        rankID = c.rank_id
    }
}

public struct V3Codec: Sendable {
    public let codecID: UInt8
    public let name: String
    public let rate: UInt32
    public let frameSize: UInt16

    /// Codec IDs this build can encode/decode (matches the HAVE_* flags in
    /// Package.swift). 3 = Speex. GSM (0) / Opus (1,2) would need their libs
    /// vendored and the corresponding HAVE_ defines enabled.
    public static let supportedCodecIDs: Set<UInt8> = [3]

    public var isSupported: Bool { Self.supportedCodecIDs.contains(codecID) }

    init?(c: UnsafePointer<v3_codec>?) {
        guard let c = c?.pointee else { return nil }
        codecID = c.codec
        name = fixedCString(c.name)
        rate = c.rate
        frameSize = c.pcmframesize
    }
}

public enum V3CoreEvent: Sendable {
    case status(percent: UInt8, message: String)
    case loginCompleted
    case loginFailed(String)
    case errorMessage(String, disconnected: Bool)
    case channelUpserted(V3Channel)
    case channelRemoved(UInt16)
    case channelPasswordRejected(UInt16)
    case userUpserted(V3User)
    case userRemoved(UInt16)
    case movedToChannel(UInt16)
    case talkStarted(userID: UInt16, rate: UInt32)
    case talkEnded(userID: UInt16)
    case audio(userID: UInt16, rate: UInt32, channels: UInt8, pcm: Data)
    case motd(String)
    case ping(UInt16)
    case disconnected
}

// MARK: - Roster

/// Shared channel/user/talking state machine — apply every V3CoreEvent to it
/// so all frontends share identical bookkeeping rules.
public struct V3Roster: Sendable {
    public private(set) var channels: [UInt16: V3Channel] = [:]
    public private(set) var users: [UInt16: V3User] = [:]
    public private(set) var talking: Set<UInt16> = []

    public init() {}

    public mutating func apply(_ event: V3CoreEvent) {
        switch event {
        case .channelUpserted(let channel):
            channels[channel.id] = channel
        case .channelRemoved(let id):
            channels.removeValue(forKey: id)
        case .userUpserted(let user):
            users[user.id] = user
        case .userRemoved(let id):
            users.removeValue(forKey: id)
            talking.remove(id)
        case .talkStarted(let id, _):
            talking.insert(id)
        case .talkEnded(let id):
            talking.remove(id)
        case .disconnected:
            talking = []
        default:
            break
        }
    }

    // MARK: Tree flattening

    public enum TreeNode: Sendable {
        case channel(V3Channel)
        case user(V3User)
    }

    /// Depth-first flatten of the channel tree with users under their channel,
    /// lobby (channel 0) users first. Sorted by name; nameless phantom users
    /// are skipped.
    public func flattenedTree() -> [(depth: Int, node: TreeNode)] {
        let byParent = Dictionary(grouping: channels.values, by: \.parent)
        let usersByChannel = Dictionary(grouping: users.values, by: \.channelID)
        var rows: [(depth: Int, node: TreeNode)] = []

        func addUsers(of channelID: UInt16, depth: Int) {
            for user in (usersByChannel[channelID] ?? []).sorted(by: { $0.name < $1.name })
            where !user.name.isEmpty {
                rows.append((depth, .user(user)))
            }
        }
        func addChannels(parent: UInt16, depth: Int) {
            for channel in (byParent[parent] ?? []).sorted(by: { $0.name < $1.name }) {
                rows.append((depth, .channel(channel)))
                addUsers(of: channel.id, depth: depth + 1)
                addChannels(parent: channel.id, depth: depth + 1)
            }
        }
        addUsers(of: 0, depth: 0)
        addChannels(parent: 0, depth: 0)
        return rows
    }

    public func channelName(_ id: UInt16) -> String {
        id == 0 ? "(lobby)" : (channels[id]?.name ?? "#\(id)")
    }
}
