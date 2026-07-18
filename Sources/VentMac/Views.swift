import SwiftUI
import VentCore

// MARK: - Connect

struct ConnectView: View {
    @EnvironmentObject var store: ConnectionStore
    @AppStorage("server.host") private var host = ""
    @AppStorage("server.port") private var port = 3784
    @AppStorage("server.username") private var username = ""
    @State private var password = ""

    private var keychainAccount: String { "\(host):\(port)" }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("VentMac").font(.largeTitle.bold())
            Text("Connect to a Ventrilo 3 server").foregroundStyle(.secondary)

            Form {
                TextField("Host", text: $host, prompt: Text("vent.example.com"))
                TextField("Port", value: $port, format: .number.grouping(.never))
                TextField("Username", text: $username)
                SecureField("Server password (optional)", text: $password)
            }
            .formStyle(.grouped)
            .frame(maxWidth: 380)
            .onAppear(perform: loadPassword)

            if let error = store.lastError {
                Text(error)
                    .foregroundStyle(.red)
                    .frame(maxWidth: 380)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: connect) {
                if store.status == .connecting {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Connect").frame(minWidth: 120)
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(host.isEmpty || username.isEmpty || store.status == .connecting)
        }
        .padding(24)
    }

    private func loadPassword() {
        guard !host.isEmpty else { return }
        password = Keychain.password(account: keychainAccount) ?? ""
    }

    private func connect() {
        Keychain.setPassword(password, account: keychainAccount)
        store.connect(host: host, port: UInt16(clamping: port),
                      username: username, password: password)
    }
}

// MARK: - Main (channel tree)

struct MainView: View {
    @EnvironmentObject var store: ConnectionStore
    @EnvironmentObject var ptt: PTTManager
    @State private var channelPassword = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List(treeRows) { row in
                rowView(row)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.inset)
            Divider()
            footer
        }
        .sheet(item: $store.passwordPromptChannel) { channel in
            passwordSheet(channel)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(store.serverDisplayName).font(.headline)
                Text(store.serverCodec).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let ping = store.ping {
                let color: Color = ping < 80 ? .green : (ping < 200 ? .yellow : .red)
                Label("\(ping) ms", systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(color)
                    .help("Round-trip time to the server")
            }
            Button("Disconnect") { store.disconnect() }
        }
        .padding(12)
    }

    private var footer: some View {
        VStack(spacing: 6) {
            if let warning = store.codecWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if ptt.inputMonitoringMissing {
                HStack {
                    Label("Mouse PTT needs Input Monitoring permission", systemImage: "lock.shield")
                        .font(.caption)
                    Button("Open Settings") { PTTManager.openInputMonitoringSettings() }
                        .controlSize(.small)
                }
            }
            if let error = store.lastError, store.status == .connected {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Image(systemName: store.micMuted ? "mic.slash.fill" : (store.transmitting ? "mic.fill" : "mic.slash"))
                    .foregroundStyle(store.micMuted ? .orange : (store.transmitting ? .green : .secondary))
                Text(store.micMuted ? "Microphone muted"
                     : (store.transmitting ? "Transmitting" : "Hold \(ptt.binding.display) to talk"))
                    .font(.callout)
                Spacer()
                Text("\(store.roster.users.count) online")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack(spacing: 20) {
                Toggle("Mute Sound", isOn: $store.soundMuted)
                Toggle("Mute Microphone/Binds", isOn: $store.micMuted)
                Spacer()
            }
            .toggleStyle(.checkbox)
            .font(.callout)
        }
        .padding(12)
    }

    private func passwordSheet(_ channel: V3Channel) -> some View {
        VStack(spacing: 12) {
            Text("“\(channel.name)” requires a password").font(.headline)
            SecureField("Channel password", text: $channelPassword)
                .frame(width: 240)
            HStack {
                Button("Cancel") {
                    store.passwordPromptChannel = nil
                    channelPassword = ""
                }
                Button("Join") {
                    store.join(channel, password: channelPassword)
                    store.passwordPromptChannel = nil
                    channelPassword = ""
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
    }

    // MARK: Tree

    struct TreeRow: Identifiable {
        enum Kind {
            case channel(V3Channel)
            case user(V3User)
        }
        let id: String
        let depth: Int
        let kind: Kind
    }

    private var treeRows: [TreeRow] {
        store.roster.flattenedTree().map { depth, node in
            switch node {
            case .channel(let channel):
                return TreeRow(id: "c\(channel.id)", depth: depth, kind: .channel(channel))
            case .user(let user):
                return TreeRow(id: "u\(user.id)", depth: depth, kind: .user(user))
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: TreeRow) -> some View {
        switch row.kind {
        case .channel(let channel):
            HStack(spacing: 6) {
                Image(systemName: channel.isPasswordProtected ? "lock.fill" : "number")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Text(channel.name)
                    .fontWeight(channel.id == store.ownChannelID ? .bold : .regular)
                if channel.id == store.ownChannelID {
                    Image(systemName: "person.fill.checkmark")
                        .font(.caption).foregroundStyle(.tint)
                }
            }
            .padding(.leading, CGFloat(row.depth) * 18)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { store.join(channel) }
            .help("Double-click to join")
        case .user(let user):
            let isMe = user.id == store.ownUserID
            // The server doesn't echo our own TALK_START back to us, so light our
            // own row from the local transmit state instead.
            let isTalking = store.roster.talking.contains(user.id) || (isMe && store.transmitting)
            HStack(spacing: 6) {
                Image(systemName: isTalking ? "speaker.wave.2.fill" : "person")
                    .foregroundStyle(isTalking ? .green : .secondary)
                    .font(.caption)
                Text(user.name + (isMe ? " (you)" : ""))
            }
            .padding(.leading, CGFloat(row.depth) * 18)
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var ptt: PTTManager
    @EnvironmentObject var audio: AudioSettings
    @AppStorage("sounds.channelJoinLeave") private var joinLeaveSounds = true
    @AppStorage("sounds.connect") private var connectSound = true

    var body: some View {
        Form {
            Section("Sounds") {
                Toggle("Play a sound when you connect", isOn: $connectSound)
                Toggle("Play a sound when someone joins or leaves your channel", isOn: $joinLeaveSounds)
                Text("Quiet cues at low volume — a soft ping on connect, a chime on join, a pop on leave (your channel only).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Audio") {
                Picker("Microphone", selection: $audio.inputUID) {
                    Text("System Default").tag("")
                    ForEach(audio.inputs) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                Picker("Output", selection: $audio.outputUID) {
                    Text("System Default").tag("")
                    ForEach(audio.outputs) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                Button("Refresh Devices") { audio.refresh() }
                    .controlSize(.small)
            }
            Section("Push to Talk") {
                HStack {
                    Text("PTT key")
                    Spacer()
                    Button(ptt.isCapturingBinding ? "Press a key or mouse button…" : ptt.binding.display) {
                        ptt.isCapturingBinding ? ptt.endCapture() : ptt.beginCapture()
                    }
                }
                Text("Keyboard keys work everywhere with no permissions. Mouse side buttons need Input Monitoring (System Settings → Privacy & Security).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if ptt.inputMonitoringMissing {
                    Button("Grant Input Monitoring…") { PTTManager.openInputMonitoringSettings() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding()
    }
}
