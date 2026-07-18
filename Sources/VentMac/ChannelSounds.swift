import AppKit

/// Sound/speech preference keys, read in ConnectionStore's event path and
/// bound by SettingsView — one place for the key strings so they can't drift.
/// Convention: every preference here defaults to ON when unset.
enum SoundPref: String {
    case connect = "sounds.connect"
    case joinLeave = "sounds.channelJoinLeave"
    case pageSpeech = "sounds.pageSpeech"
    case ttsReceive = "sounds.ttsReceive"

    var enabled: Bool {
        UserDefaults.standard.object(forKey: rawValue) as? Bool ?? true
    }
}

/// Subtle cues when someone enters or leaves your channel. Uses quiet built-in
/// macOS system sounds at reduced volume — deliberately unobtrusive.
@MainActor
final class ChannelSounds {
    enum Cue { case connect, join, leave, page }

    /// 0…1. Kept low so the cues are noticeable but never loud.
    var volume: Float = 0.35

    func play(_ cue: Cue) {
        // A fresh NSSound per play so rapid cues can overlap.
        let name: String
        switch cue {
        case .connect: name = "Submarine"   // small, soft "you're online" ping
        case .join:    name = "Tink"
        case .leave:   name = "Pop"
        case .page:    name = "Glass"       // attention-getting but not harsh
        }
        guard let sound = NSSound(named: name) else { return }
        sound.volume = volume
        sound.play()
    }
}
