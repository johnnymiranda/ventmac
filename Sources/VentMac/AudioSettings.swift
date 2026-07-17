import Foundation
import SwiftUI
import VentCore

/// Holds the available audio devices and the user's persisted input/output
/// choice. An empty UID means "system default". ConnectionStore binds to the
/// change callbacks to apply selections to the live capture/playback engines.
@MainActor
final class AudioSettings: ObservableObject {
    @Published var inputs: [AudioDevice] = []
    @Published var outputs: [AudioDevice] = []

    @Published var inputUID: String {
        didSet {
            UserDefaults.standard.set(inputUID, forKey: Self.inputKey)
            onInputChange?(inputUID)
        }
    }
    @Published var outputUID: String {
        didSet {
            UserDefaults.standard.set(outputUID, forKey: Self.outputKey)
            onOutputChange?(outputUID)
        }
    }

    var onInputChange: ((String) -> Void)?
    var onOutputChange: ((String) -> Void)?

    private static let inputKey = "audio.input.uid"
    private static let outputKey = "audio.output.uid"

    init() {
        inputUID = UserDefaults.standard.string(forKey: Self.inputKey) ?? ""
        outputUID = UserDefaults.standard.string(forKey: Self.outputKey) ?? ""
        refresh()
    }

    func refresh() {
        inputs = AudioDevices.inputs()
        outputs = AudioDevices.outputs()
    }
}
