import Foundation
import VentCore

// ventctl — headless Ventrilo 3 smoke-test client.
//
//   ventctl -h host:port -u username [-p password] [-c channel_id] [--stay] [--talk]
//
// Default: connect, print server info + channel tree, disconnect.
//   --stay   remain connected, play incoming voice, stream events to stdout
//   --talk   with --stay: press Enter to toggle transmit on/off (PTT toggle)
//   V3_DEBUG=1 env var enables libventrilo3 debug output

struct Options {
    var host = ""
    var port: UInt16 = 3784
    var username = ""
    var password = ""
    var channel: UInt16?
    var stay = false
    var talk = false
}

func usage() -> Never {
    print("usage: ventctl -h host[:port] -u username [-p password] [-c channel_id] [--stay] [--talk]")
    exit(1)
}

func parseOptions() -> Options {
    var o = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let a = args.removeFirst()
        switch a {
        case "-h":
            guard !args.isEmpty else { usage() }
            let hp = args.removeFirst().split(separator: ":", maxSplits: 1)
            o.host = String(hp[0])
            if hp.count > 1, let p = UInt16(hp[1]) { o.port = p }
        case "-u":
            guard !args.isEmpty else { usage() }
            o.username = args.removeFirst()
        case "-p":
            guard !args.isEmpty else { usage() }
            o.password = args.removeFirst()
        case "-c":
            guard !args.isEmpty, let c = UInt16(args.first!) else { usage() }
            o.channel = c; args.removeFirst()
        case "--stay": o.stay = true
        case "--talk": o.stay = true; o.talk = true
        default: usage()
        }
    }
    if o.host.isEmpty || o.username.isEmpty { usage() }
    return o
}

let opts = parseOptions()
let client = V3Client.shared
let player = V3AudioPlayer()
let transmitter = V3Transmitter()
var roster = V3Roster()

if opts.stay {
    client.audioSink = { userID, rate, channels, pcm in
        player.play(userID: userID, rate: rate, channels: channels, pcm: pcm)
    }
}

func printTree() {
    print("\n── Channel tree ──────────────────────────")
    for (depth, node) in roster.flattenedTree() {
        let indent = String(repeating: "   ", count: depth)
        switch node {
        case .channel(let ch):
            let lock = ch.isPasswordProtected ? " 🔒" : ""
            let codec = client.codec(forChannel: ch.id).map { " [\($0.name)]" } ?? ""
            print("\(indent)▸ \(ch.name) (id \(ch.id))\(lock)\(codec)")
        case .user(let u):
            print("\(indent)• \(u.name)")
        }
    }
    print("──────────────────────────────────────────")
}

func toggleTalk() {
    if transmitter.isTransmitting {
        transmitter.stop()
        print(">>> stopped transmitting — press Enter to talk")
    } else if let error = transmitter.start() {
        print(">>> \(error)")
    } else {
        print(">>> TRANSMITTING — press Enter to stop")
    }
}

if opts.talk {
    Thread {
        while readLine() != nil {
            DispatchQueue.main.async { toggleTalk() }
        }
    }.start()
}

signal(SIGINT, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler {
    print("\ndisconnecting…")
    client.disconnect()  // stream finishes via V3_EVENT_DISCONNECT → exit below
}
sigint.resume()

print("connecting to \(opts.host):\(opts.port) as \(opts.username)…")

Task {
    let stream = client.connect(host: opts.host, port: opts.port,
                                username: opts.username, password: opts.password)
    for await ev in stream {
        defer { roster.apply(ev) }
        switch ev {
        case .status(let pct, let msg):
            print("[\(pct)%] \(msg)")
        case .loginFailed(let msg):
            print("LOGIN FAILED: \(msg)")
            exit(2)
        case .errorMessage(let msg, let disconnected):
            print("SERVER ERROR: \(msg)\(disconnected ? " (disconnected)" : "")")
            if disconnected { exit(2) }
        case .loginCompleted:
            print("login complete — user id \(client.ownUserID)")
            if let codec = client.codec(forChannel: 0) {
                let supported = codec.isSupported ? "" : "  ⚠️ NOT SUPPORTED by this build (Speex only)"
                print("server default codec: \(codec.name) @ \(codec.rate) Hz\(supported)")
            }
            printTree()
            if let ch = opts.channel {
                print("joining channel \(roster.channelName(ch))…")
                client.joinChannel(ch)
            }
            if !opts.stay {
                client.disconnect()
            } else if opts.talk {
                print("press Enter to toggle transmit")
            }
        case .channelPasswordRejected(let id):
            print("bad password for channel \(roster.channelName(id))")
        case .userUpserted(let u):
            if client.isLoggedIn && !u.name.isEmpty {
                print("\(u.name) → \(roster.channelName(u.channelID))")
            }
        case .userRemoved(let id):
            if let u = roster.users[id] { print("\(u.name) logged out") }
        case .movedToChannel(let id):
            print("you are now in \(roster.channelName(id))")
            if let codec = client.codec(forChannel: id), !codec.isSupported {
                print("⚠️ channel codec \(codec.name) is NOT supported by this build (Speex only) — voice will be silent")
            }
        case .talkStarted(let id, _):
            if opts.stay { print("🎙 \(roster.users[id]?.name ?? "#\(id)") talking") }
        case .talkEnded(let id):
            if opts.stay { print("   \(roster.users[id]?.name ?? "#\(id)") stopped") }
        case .motd(let motd):
            let text = motd.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { print("MOTD: \(text.prefix(500))") }
        case .disconnected:
            print("disconnected")
        case .channelUpserted, .channelRemoved, .audio, .ping:
            break
        }
    }
    // Stream finished — connection is fully torn down.
    exit(0)
}

dispatchMain()
