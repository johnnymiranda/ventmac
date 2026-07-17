import AppKit

/// Subtle cues when someone enters or leaves your channel. Uses quiet built-in
/// macOS system sounds at reduced volume — deliberately unobtrusive.
@MainActor
final class ChannelSounds {
    enum Cue { case join, leave }

    /// 0…1. Kept low so the cues are noticeable but never loud.
    var volume: Float = 0.35

    func play(_ cue: Cue) {
        // A fresh NSSound per play so rapid joins/leaves can overlap.
        let name = cue == .join ? "Tink" : "Pop"
        guard let sound = NSSound(named: name) else { return }
        sound.volume = volume
        sound.play()
    }
}
