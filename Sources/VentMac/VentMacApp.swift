import SwiftUI
import AppKit
import AVFoundation

@main
struct VentMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = ConnectionStore()
    @StateObject private var ptt = PTTManager()
    @StateObject private var audio = AudioSettings()
    @StateObject private var serverList = ServerList()

    var body: some Scene {
        WindowGroup("VentMac") {
            ContentView()
                .environmentObject(store)
                .environmentObject(ptt)
                .environmentObject(audio)
                .environmentObject(serverList)
                .frame(minWidth: 420, minHeight: 520)
                .onAppear {
                    store.bind(audio: audio)
                    ptt.onDown = { [weak store] in store?.startTalking() }
                    ptt.onUp = { [weak store] in store?.stopTalking() }
                    ptt.arm()
                }
        }
        Settings {
            SettingsView()
                .environmentObject(store)
                .environmentObject(ptt)
                .environmentObject(audio)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched via `swift run` (no bundle): behave like a real app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        requestMicrophoneAccess()
    }

    /// Ask for the microphone up front rather than waiting for the first
    /// transmit. Relying on the implicit prompt is fragile: it only fires deep
    /// inside AVAudioEngine, and if the grant is ever lost (a re-signed build
    /// invalidates it) the failure looks exactly like "nobody can hear me" with
    /// no prompt and nothing in the log. Asking here makes the state explicit.
    private func requestMicrophoneAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                if !granted {
                    DispatchQueue.main.async { self.showMicrophoneDeniedAlert() }
                }
            }
        case .denied, .restricted:
            showMicrophoneDeniedAlert()
        @unknown default:
            return
        }
    }

    private func showMicrophoneDeniedAlert() {
        let alert = NSAlert()
        alert.messageText = "VentMac can't use your microphone"
        alert.informativeText = """
            Microphone access is turned off, so you'll hear everyone else but nobody will hear you.

            Enable VentMac under Privacy & Security → Microphone, then relaunch.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ContentView: View {
    @EnvironmentObject var store: ConnectionStore

    var body: some View {
        switch store.status {
        case .connected, .reconnecting:
            MainView()
        default:
            ConnectView()
        }
    }
}
