import Foundation
import SwiftUI
import AppKit
import Carbon.HIToolbox

/// Global push-to-talk binding.
struct PTTBinding: Codable, Equatable {
    enum Kind: String, Codable {
        case key    // keyboard key (+ optional modifiers) — Carbon hotkey, no TCC needed
        case mouse  // extra mouse button — CGEventTap, needs Input Monitoring
    }
    var kind: Kind
    var keyCode: UInt32 = 0
    var carbonModifiers: UInt32 = 0
    var mouseButton: Int64 = 0
    var display: String

    static let `default` = PTTBinding(kind: .key, keyCode: UInt32(kVK_F13), display: "F13")
}

/// Two-tier global PTT:
///  - Tier 1 (default): Carbon RegisterEventHotKey — press *and* release events,
///    works over fullscreen games, zero permissions.
///  - Tier 2: CGEventTap (listen-only session tap) for mouse side buttons —
///    requires Input Monitoring; we surface a guidance flag when denied.
final class PTTManager: ObservableObject {
    var onDown: (() -> Void)?
    var onUp: (() -> Void)?

    @Published var binding: PTTBinding {
        didSet {
            save()
            arm()
        }
    }
    @Published var inputMonitoringMissing = false
    @Published var isCapturingBinding = false

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var captureMonitor: Any?

    private static let defaultsKey = "pttBinding"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode(PTTBinding.self, from: data) {
            binding = saved
        } else {
            binding = .default
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(binding) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    // MARK: - Arming

    func arm() {
        disarm()
        switch binding.kind {
        case .key: armHotKey()
        case .mouse: armMouseTap()
        }
    }

    func disarm() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef); self.hotKeyRef = nil }
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef); self.eventHandlerRef = nil }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes); self.tapSource = nil }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); self.tap = nil }
    }

    fileprivate func fireDown() { DispatchQueue.main.async { self.onDown?() } }
    fileprivate func fireUp() { DispatchQueue.main.async { self.onUp?() } }

    // MARK: - Tier 1: Carbon hotkey

    private func armHotKey() {
        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return noErr }
            let manager = Unmanaged<PTTManager>.fromOpaque(userData).takeUnretainedValue()
            if GetEventKind(event) == UInt32(kEventHotKeyPressed) {
                manager.fireDown()
            } else {
                manager.fireUp()
            }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 2, &specs, selfPtr, &eventHandlerRef)

        let hotKeyID = EventHotKeyID(signature: OSType(0x564D_5054) /* "VMPT" */, id: 1)
        let status = RegisterEventHotKey(binding.keyCode, binding.carbonModifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            NSLog("PTT: RegisterEventHotKey failed (\(status))")
        }
    }

    // MARK: - Tier 2: mouse button event tap

    private func armMouseTap() {
        let mask: CGEventMask =
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue)
        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        let callback: CGEventTapCallBack = { _, type, event, userData in
            guard let userData else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<PTTManager>.fromOpaque(userData).takeUnretainedValue()
            switch type {
            case .tapDisabledByTimeout, .tapDisabledByUserInput:
                if let tap = manager.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            case .otherMouseDown, .otherMouseUp:
                let button = event.getIntegerValueField(.mouseEventButtonNumber)
                if button == manager.binding.mouseButton {
                    type == .otherMouseDown ? manager.fireDown() : manager.fireUp()
                }
            default:
                break
            }
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .listenOnly,
                                          eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: selfPtr) else {
            inputMonitoringMissing = true
            return
        }
        inputMonitoringMissing = false
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        tapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    static func openInputMonitoringSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Binding capture (Settings UI)

    /// Capture the next key press or extra mouse button click as the new binding.
    /// Uses local monitors — only sees events while VentMac is focused, no TCC.
    func beginCapture() {
        endCapture()
        isCapturingBinding = true
        captureMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .otherMouseDown]) { [weak self] event in
            guard let self else { return event }
            switch event.type {
            case .keyDown:
                let keyCode = UInt32(event.keyCode)
                let mods = carbonModifiers(from: event.modifierFlags)
                self.binding = PTTBinding(kind: .key, keyCode: keyCode,
                                          carbonModifiers: mods,
                                          display: describeKey(event: event))
            case .otherMouseDown:
                self.binding = PTTBinding(kind: .mouse,
                                          mouseButton: Int64(event.buttonNumber),
                                          display: "Mouse \(event.buttonNumber + 1)")
            default:
                return event
            }
            self.endCapture()
            return nil
        }
    }

    func endCapture() {
        if let captureMonitor { NSEvent.removeMonitor(captureMonitor); self.captureMonitor = nil }
        isCapturingBinding = false
    }
}

private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
    var mods: UInt32 = 0
    if flags.contains(.command) { mods |= UInt32(cmdKey) }
    if flags.contains(.option) { mods |= UInt32(optionKey) }
    if flags.contains(.control) { mods |= UInt32(controlKey) }
    if flags.contains(.shift) { mods |= UInt32(shiftKey) }
    return mods
}

private func describeKey(event: NSEvent) -> String {
    var parts: [String] = []
    let flags = event.modifierFlags
    if flags.contains(.control) { parts.append("⌃") }
    if flags.contains(.option) { parts.append("⌥") }
    if flags.contains(.shift) { parts.append("⇧") }
    if flags.contains(.command) { parts.append("⌘") }
    parts.append(keyName(forCode: Int(event.keyCode))
                 ?? event.charactersIgnoringModifiers?.uppercased()
                 ?? "key \(event.keyCode)")
    return parts.joined()
}

private func keyName(forCode code: Int) -> String? {
    let names: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14",
        kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18",
        kVK_Space: "Space", kVK_CapsLock: "Caps Lock", kVK_Tab: "Tab",
        kVK_ANSI_Grave: "`",
    ]
    return names[code]
}
