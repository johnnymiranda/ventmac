import Foundation
import SwiftUI

struct SavedServer: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var host: String
    var port: Int = 3784
    var username: String

    var keychainAccount: String { "server.\(id.uuidString)" }
    var displayAddress: String { "\(host):\(port)" }
}

/// The saved server list (Ventrilo's server pulldown / Mangler's server list).
/// Passwords live in the Keychain keyed by entry id, never in defaults.
@MainActor
final class ServerList: ObservableObject {
    @Published var servers: [SavedServer] {
        didSet { persist() }
    }

    private static let key = "servers.list"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let list = try? JSONDecoder().decode([SavedServer].self, from: data) {
            servers = list
        } else {
            servers = []
        }
        migrateLegacySingleServer()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(servers) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    func password(for server: SavedServer) -> String {
        Keychain.password(account: server.keychainAccount) ?? ""
    }

    func setPassword(_ password: String, for server: SavedServer) {
        Keychain.setPassword(password, account: server.keychainAccount)
    }

    /// Insert or update by id, and store the password — the one write path
    /// for both "add" and "edit".
    func upsert(_ server: SavedServer, password: String) {
        if let idx = servers.firstIndex(where: { $0.id == server.id }) {
            servers[idx] = server
        } else {
            servers.append(server)
        }
        setPassword(password, for: server)
    }

    func remove(_ server: SavedServer) {
        Keychain.setPassword("", account: server.keychainAccount)  // deletes the item
        servers.removeAll { $0.id == server.id }
    }

    /// Pre-0.2.0 builds stored a single server in @AppStorage and its password
    /// under a "host:port" Keychain account. Fold that into the list once.
    private func migrateLegacySingleServer() {
        let defaults = UserDefaults.standard
        guard servers.isEmpty,
              let host = defaults.string(forKey: "server.host"), !host.isEmpty else { return }
        let port = defaults.object(forKey: "server.port") as? Int ?? 3784
        let username = defaults.string(forKey: "server.username") ?? ""
        var entry = SavedServer(name: host, host: host, port: port, username: username)
        entry.name = host
        servers.append(entry)
        if let legacy = Keychain.password(account: "\(host):\(port)"), !legacy.isEmpty {
            setPassword(legacy, for: entry)
        }
        defaults.removeObject(forKey: "server.host")
    }
}
