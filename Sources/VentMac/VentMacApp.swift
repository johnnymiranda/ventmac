import SwiftUI
import AppKit

@main
struct VentMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = ConnectionStore()
    @StateObject private var ptt = PTTManager()

    var body: some Scene {
        WindowGroup("VentMac") {
            ContentView()
                .environmentObject(store)
                .environmentObject(ptt)
                .frame(minWidth: 420, minHeight: 520)
                .onAppear {
                    ptt.onDown = { [weak store] in store?.startTalking() }
                    ptt.onUp = { [weak store] in store?.stopTalking() }
                    ptt.arm()
                }
        }
        Settings {
            SettingsView()
                .environmentObject(ptt)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched via `swift run` (no bundle): behave like a real app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ContentView: View {
    @EnvironmentObject var store: ConnectionStore

    var body: some View {
        switch store.status {
        case .connected:
            MainView()
        default:
            ConnectView()
        }
    }
}
