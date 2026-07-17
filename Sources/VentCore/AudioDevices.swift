import Foundation
import CoreAudio

/// A CoreAudio hardware device usable for input and/or output.
public struct AudioDevice: Identifiable, Hashable, Sendable {
    public let id: AudioDeviceID
    public let uid: String        // stable across reboots/reconnects; persist this
    public let name: String
    public let hasInput: Bool
    public let hasOutput: Bool
}

public enum AudioDevices {
    /// All hardware devices with at least one input or output channel.
    public static func all() -> [AudioDevice] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &addr, 0, nil, &dataSize) == noErr else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &dataSize, &ids) == noErr else { return [] }

        return ids.compactMap { device($0) }
    }

    public static func inputs() -> [AudioDevice] { all().filter(\.hasInput) }
    public static func outputs() -> [AudioDevice] { all().filter(\.hasOutput) }

    public static func device(uid: String) -> AudioDevice? {
        all().first { $0.uid == uid }
    }

    // MARK: - Per-device queries

    private static func device(_ id: AudioDeviceID) -> AudioDevice? {
        guard let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
              let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
        let hasInput = channelCount(id, scope: kAudioObjectPropertyScopeInput) > 0
        let hasOutput = channelCount(id, scope: kAudioObjectPropertyScopeOutput) > 0
        guard hasInput || hasOutput else { return nil }
        return AudioDevice(id: id, uid: uid, name: name, hasInput: hasInput, hasOutput: hasOutput)
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString? = nil
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return value as String?
    }

    private static func channelCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                              mScope: scope,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let bufListPtr = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                          alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bufListPtr.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, bufListPtr) == noErr else { return 0 }
        let listPtr = UnsafeMutableAudioBufferListPointer(bufListPtr.assumingMemoryBound(to: AudioBufferList.self))
        return listPtr.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        guard !uid.isEmpty else { return nil }
        return all().first { $0.uid == uid }?.id
    }

    public static func defaultInputDeviceID() -> AudioDeviceID? {
        systemDevice(kAudioHardwarePropertyDefaultInputDevice)
    }

    public static func defaultOutputDeviceID() -> AudioDeviceID? {
        systemDevice(kAudioHardwarePropertyDefaultOutputDevice)
    }

    /// The device to target for a given persisted UID: the named device if the
    /// UID is set and still present, otherwise the current system default — so
    /// choosing "System Default" (empty UID) actively reverts a prior pin.
    static func resolve(uid: String?, output: Bool) -> AudioDeviceID? {
        if let uid, !uid.isEmpty, let id = deviceID(forUID: uid) { return id }
        return output ? defaultOutputDeviceID() : defaultInputDeviceID()
    }

    private static func systemDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }
}
