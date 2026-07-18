import SwiftUI
import VentCore

// MARK: - Connect (saved server list)

struct ConnectView: View {
    @EnvironmentObject var store: ConnectionStore
    @EnvironmentObject var serverList: ServerList
    @State private var editing: SavedServer?
    @State private var selection: SavedServer.ID?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("VentMac").font(.largeTitle.bold())
            Text("Connect to a Ventrilo 3 server").foregroundStyle(.secondary)

            if serverList.servers.isEmpty {
                Text("No servers yet — add one to get started.")
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            } else {
                List(selection: $selection) {
                    ForEach(serverList.servers) { server in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.name).fontWeight(.medium)
                            Text("\(server.displayAddress)  ·  \(server.username)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(server.id)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { connect(server) }
                        .contextMenu {
                            Button("Connect") { connect(server) }
                            Button("Edit…") { editing = server }
                            Divider()
                            Button("Delete", role: .destructive) { serverList.remove(server) }
                        }
                    }
                }
                .frame(maxWidth: 420, minHeight: 140, maxHeight: 220)
                .scrollContentBackground(.hidden)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            }

            if !store.connectStatus.isEmpty, store.status == .connecting {
                Text(store.connectStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = store.lastError {
                Text(error)
                    .foregroundStyle(.red)
                    .frame(maxWidth: 420)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Add Server…") {
                    editing = SavedServer(name: "", host: "", username: "")
                }
                Button(action: { if let s = selected { editing = s } }) {
                    Text("Edit")
                }
                .disabled(selected == nil)
                Spacer().frame(width: 20)
                Button(action: { if let s = selected { connect(s) } }) {
                    if store.status == .connecting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Connect").frame(minWidth: 100)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selected == nil || store.status == .connecting)
            }
        }
        .padding(24)
        .sheet(item: $editing) { server in
            ServerEditorView(server: server) { saved, password in
                serverList.upsert(saved, password: password)
                selection = saved.id
            }
        }
        .onAppear { if selection == nil { selection = serverList.servers.first?.id } }
    }

    private var selected: SavedServer? {
        serverList.servers.first { $0.id == selection }
    }

    private func connect(_ server: SavedServer) {
        store.connect(host: server.host, port: UInt16(clamping: server.port),
                      username: server.username,
                      password: serverList.password(for: server))
    }
}

struct ServerEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var serverList: ServerList
    @State var server: SavedServer
    @State private var password = ""
    let onSave: (SavedServer, String) -> Void

    init(server: SavedServer, onSave: @escaping (SavedServer, String) -> Void) {
        _server = State(initialValue: server)
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 14) {
            Text(server.name.isEmpty ? "Add Server" : "Edit Server").font(.headline)
            Form {
                TextField("Name", text: $server.name, prompt: Text("Friends' server"))
                TextField("Host", text: $server.host, prompt: Text("vent.example.com"))
                TextField("Port", value: $server.port, format: .number.grouping(.never))
                TextField("Username", text: $server.username)
                SecureField("Server password (optional)", text: $password)
            }
            .formStyle(.grouped)
            HStack {
                Button("Cancel") { dismiss() }
                Button("Save") {
                    if server.name.isEmpty { server.name = server.host }
                    onSave(server, password)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(server.host.isEmpty || server.username.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { password = serverList.password(for: server) }
    }
}

// MARK: - Main (channel tree)

struct MainView: View {
    @EnvironmentObject var store: ConnectionStore
    @EnvironmentObject var ptt: PTTManager
    @State private var channelPassword = ""

    var body: some View {
        VStack(spacing: 0) {
            if store.status == .reconnecting {
                reconnectBanner
            }
            header
            Divider()
            List(treeRows) { row in
                rowView(row)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.inset)
            if store.chatOpen {
                Divider()
                ChatPane()
                    .frame(height: 200)
            }
            Divider()
            footer
        }
        .sheet(item: $store.passwordPromptChannel) { channel in
            passwordSheet(channel)
        }
        .sheet(item: $store.motd) { motd in
            motdSheet(motd)
        }
    }

    private var reconnectBanner: some View {
        HStack {
            ProgressView().controlSize(.small)
            Text("Connection lost — reconnecting (attempt \(store.reconnectAttempt))…")
                .font(.callout)
            Spacer()
            Button("Cancel") { store.disconnect() }
                .controlSize(.small)
        }
        .padding(10)
        .background(.orange.opacity(0.15))
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
            Button {
                store.chatOpen.toggle()
            } label: {
                Image(systemName: store.chatOpen ? "bubble.left.fill" : "bubble.left")
            }
            .help(store.chatOpen ? "Close chat" : "Open chat")
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
                Text(footerStatusText)
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

    private var footerStatusText: String {
        if store.micMuted { return "Microphone muted" }
        if store.transmitting { return "Transmitting" }
        return store.transmitMode == .vox
            ? "Voice activation on — speak to talk"
            : "Hold \(ptt.binding.display) to talk"
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

    private func motdSheet(_ motd: ConnectionStore.MOTDText) -> some View {
        VStack(spacing: 12) {
            Text("Message of the Day").font(.headline)
            ScrollView {
                Text(motd.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(width: 380, height: 180)
            HStack {
                Button("Don't Show Again") {
                    store.ignoreCurrentMOTD()
                    store.motd = nil
                }
                Spacer()
                Button("OK") { store.motd = nil }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
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
            channelRow(channel, depth: row.depth)
        case .user(let user):
            userRow(user, depth: row.depth)
        }
    }

    private func channelRow(_ channel: V3Channel, depth: Int) -> some View {
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
            if store.phantomChannels.contains(channel.id) {
                Image(systemName: "person.crop.circle.dashed")
                    .font(.caption).foregroundStyle(.purple)
                    .help("You have a phantom here")
            }
        }
        .padding(.leading, CGFloat(depth) * 18)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { store.join(channel) }
        .contextMenu {
            Button("Join") { store.join(channel) }
            if channel.id != store.ownChannelID {
                Button(store.phantomChannels.contains(channel.id) ? "Remove Phantom" : "Add Phantom") {
                    store.togglePhantom(in: channel)
                }
            }
        }
        .help("Double-click to join")
    }

    private func userRow(_ user: V3User, depth: Int) -> some View {
        let isMe = user.id == store.ownUserID
        // The server doesn't echo our own TALK_START back to us, so light our
        // own row from the local transmit state instead.
        let isTalking = store.roster.talking.contains(user.id) || (isMe && store.transmitting)
        let locallyMuted = store.isUserMuted(user)
        return HStack(spacing: 6) {
            Image(systemName: isTalking ? "speaker.wave.2.fill" : "person")
                .foregroundStyle(isTalking ? .green : .secondary)
                .font(.caption)
            Text(user.name + (isMe ? " (you)" : ""))
            if !user.comment.isEmpty {
                Text("(\(user.comment))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if locallyMuted {
                Image(systemName: "speaker.slash.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .help("Muted by you")
            }
            if user.globalMute || user.channelMute {
                Image(systemName: "speaker.slash")
                    .font(.caption).foregroundStyle(.red)
                    .help(user.globalMute ? "Globally muted by an admin" : "Muted in this channel by an admin")
            }
            if user.isPhantom {
                Image(systemName: "person.crop.circle.dashed")
                    .font(.caption).foregroundStyle(.purple)
                    .help("Phantom")
            }
        }
        .padding(.leading, CGFloat(depth) * 18)
        .contentShape(Rectangle())
        .contextMenu { if !isMe { userMenu(user) } }
    }

    @ViewBuilder
    private func userMenu(_ user: V3User) -> some View {
        Button(store.isUserMuted(user) ? "Unmute" : "Mute") { store.toggleUserMute(user) }
        Menu("Volume") {
            let current = store.userVolume(user)
            ForEach([("50%", 40), ("75%", 59), ("100%", 79), ("125%", 99), ("150%", 119), ("200%", 158)], id: \.1) { label, level in
                Button {
                    store.setUserVolume(user, level: level)
                } label: {
                    if abs(current - level) <= 2 {
                        Label(label, systemImage: "checkmark")
                    } else {
                        Text(label)
                    }
                }
            }
        }
        Divider()
        Button("Private Chat…") { store.openPrivateChat(with: user) }
            .disabled(!user.acceptsPrivateChat)
        Button("Send Page") { store.page(user) }
            .disabled(!user.acceptsPages)
        if !user.comment.isEmpty || !user.url.isEmpty {
            Divider()
            if !user.comment.isEmpty {
                Button("Copy Comment") { copyToPasteboard(user.comment) }
            }
            if !user.url.isEmpty {
                Button("Copy URL") { copyToPasteboard(user.url) }
                Button("Open URL") {
                    if let url = URL(string: user.url) { NSWorkspace.shared.open(url) }
                }
            }
        }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Chat pane

struct ChatPane: View {
    @EnvironmentObject var store: ConnectionStore
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(currentLog) { entry in
                            entryView(entry)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: currentLog.count) { _ in
                    if let last = currentLog.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            Divider()
            TextField(inputPrompt, text: $draft)
                .textFieldStyle(.plain)
                .padding(8)
                .focused($inputFocused)
                .onSubmit {
                    store.sendChat(draft)
                    draft = ""
                }
        }
        .onAppear { inputFocused = true }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            tabButton(title: "Channel", tag: nil)
            ForEach(store.privChats) { chat in
                tabButton(title: chat.name, tag: chat.peer, closable: true)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private func tabButton(title: String, tag: UInt16?, closable: Bool = false) -> some View {
        HStack(spacing: 4) {
            Button(title) { store.activeChatTab = tag }
                .buttonStyle(.plain)
                .fontWeight(store.activeChatTab == tag ? .semibold : .regular)
                .foregroundStyle(store.activeChatTab == tag ? Color.accentColor : .primary)
            if closable, let peer = tag {
                Button {
                    store.closePrivateChat(peer: peer)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(store.activeChatTab == tag ? Color.accentColor.opacity(0.12) : .clear,
                    in: Capsule())
    }

    private var currentLog: [ChatEntry] {
        if let peer = store.activeChatTab {
            return store.privChats.first { $0.peer == peer }?.log ?? []
        }
        return store.chatLog
    }

    private var inputPrompt: String {
        if let peer = store.activeChatTab,
           let chat = store.privChats.first(where: { $0.peer == peer }) {
            return chat.closedByPeer ? "\(chat.name) closed this chat" : "Message \(chat.name)…"
        }
        return "Message the channel…"
    }

    @ViewBuilder
    private func entryView(_ entry: ChatEntry) -> some View {
        switch entry.kind {
        case .message(let name, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Self.timeFormat.string(from: entry.time))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Text("\(name):").fontWeight(.semibold)
                Text(text).textSelection(.enabled)
            }
            .font(.callout)
            .id(entry.id)
        case .notice(let text):
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .id(entry.id)
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var ptt: PTTManager
    @EnvironmentObject var audio: AudioSettings
    @EnvironmentObject var store: ConnectionStore
    @AppStorage("sounds.channelJoinLeave") private var joinLeaveSounds = true
    @AppStorage("sounds.connect") private var connectSound = true
    @AppStorage("sounds.pageSpeech") private var pageSpeech = true
    @AppStorage("sounds.ttsReceive") private var ttsReceive = true
    @AppStorage("identity.comment") private var comment = ""
    @AppStorage("identity.url") private var url = ""

    var body: some View {
        Form {
            Section("Transmit") {
                Picker("Mode", selection: $store.transmitMode) {
                    Text("Push to Talk").tag(ConnectionStore.TransmitMode.ptt)
                    Text("Voice Activation").tag(ConnectionStore.TransmitMode.vox)
                }
                .pickerStyle(.segmented)
                if store.transmitMode == .vox {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Sensitivity")
                            Slider(value: $store.voxSensitivity, in: -70 ... -20)
                            Text("\(Int(store.voxSensitivity)) dB")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 50, alignment: .trailing)
                        }
                        VoxMeterView(meter: store.voxMeter,
                                     threshold: store.voxSensitivity,
                                     transmitting: store.transmitting)
                        Text(store.status == .connected
                             ? "Speak — the bar shows your mic level; it transmits while green."
                             : "Connect to a server to see your mic level.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
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
            Section("Identity") {
                TextField("Comment", text: $comment, prompt: Text("Shown next to your name"))
                    .onSubmit { store.applyIdentityText() }
                TextField("URL", text: $url, prompt: Text("https://…"))
                    .onSubmit { store.applyIdentityText() }
                Text("Visible to everyone on the server. Applied when you connect, or press Return to update live.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Sounds") {
                Toggle("Play a sound when you connect", isOn: $connectSound)
                Toggle("Play a sound when someone joins or leaves your channel", isOn: $joinLeaveSounds)
                Toggle("Speak incoming pages aloud", isOn: $pageSpeech)
                Toggle("Speak incoming TTS binds aloud", isOn: $ttsReceive)
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
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding()
    }
}

/// Live mic-level bar for tuning VOX sensitivity. Green while transmitting,
/// gray otherwise, with a tick at the threshold. Observes the level model
/// directly so its ~25 Hz updates only re-render this view.
struct VoxMeterView: View {
    @ObservedObject var meter: ConnectionStore.VoxMeterModel
    let threshold: Double     // dBFS
    let transmitting: Bool

    private func normalized(_ db: Double) -> Double {
        min(max((db + 70) / 70, 0), 1)   // -70 dB…0 dB → 0…1
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(.quaternary)
                RoundedRectangle(cornerRadius: 3)
                    .fill(transmitting ? Color.green : Color.secondary)
                    .frame(width: geo.size.width * normalized(Double(meter.levelDBFS)))
                    .animation(.linear(duration: 0.05), value: meter.levelDBFS)
                Rectangle()
                    .fill(Color.orange)
                    .frame(width: 2)
                    .offset(x: geo.size.width * normalized(threshold))
            }
        }
        .frame(height: 8)
    }
}
