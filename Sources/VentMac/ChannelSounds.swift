import AppKit

/// Subtle cues when someone enters or leaves your channel. Uses quiet built-in
/// macOS system sounds at reduced volume — deliberately unobtrusive.
@MainActor
final class ChannelSounds {
    enum Cue { case connect, join, leave }

    /// 0…1. Kept low so the cues are noticeable but never loud.
    var volume: Float = 0.35

    func play(_ cue: Cue) {
        // A fresh NSSound per play so rapid cues can overlap.
        let name: String
        switch cue {
        case .connect: name = "Submarine"   // small, soft "you're online" ping
        case .join:    name = "Tink"
        case .leave:   name = "Pop"
        }
        guard let sound = NSSound(named: name) else { return }
        sound.volume = volume
        sound.play()
    }
}
