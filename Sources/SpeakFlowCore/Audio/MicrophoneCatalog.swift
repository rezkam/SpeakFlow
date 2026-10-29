import CoreAudio
import Foundation

@MainActor
public protocol MicrophoneCatalogProviding: AnyObject {
    func snapshot() throws -> MicrophoneSnapshot
}

public struct MicrophoneSnapshot: Equatable, Sendable {
    public let devices: [MicrophoneDevice]
    public let defaultID: UInt32

    public init(devices: [MicrophoneDevice], defaultID: UInt32) {
        self.devices = devices
        self.defaultID = defaultID
    }
}

public enum MicrophoneError: LocalizedError {
    case unavailable
    case hardware(OSStatus)
    case invalidFormat
    case noAudioFrames

    public var errorDescription: String? {
        switch self {
        case .unavailable: "No microphone is available. Connect an input device and try again."
        case .hardware: "The microphone could not be opened. Check the device connection and microphone permission."
        case .noAudioFrames: "The selected microphone is not sending audio. Check its connection or choose another input."
        case .invalidFormat: "The microphone has no usable audio format. Choose another input."
        }
    }
}

/// Reads input devices without opening a capture session or changing the system default.
@MainActor
public final class MicrophoneCatalog: MicrophoneCatalogProviding {
    public init() {}

    public func snapshot() throws -> MicrophoneSnapshot {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = property(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size))
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        if !ids.isEmpty {
            try ids.withUnsafeMutableBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                try check(AudioObjectGetPropertyData(system, &address, 0, nil, &size, base))
            }
        }
        let devices = ids.compactMap { id -> MicrophoneDevice? in
            guard flag(id, kAudioDevicePropertyDeviceIsAlive) != false,
                  flag(id, kAudioDevicePropertyIsHidden) != true,
                  hasInput(id),
                  let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            return MicrophoneDevice(id: id, uid: uid, name: name)
        }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        var defaultID: AudioObjectID = 0
        address = property(kAudioHardwarePropertyDefaultInputDevice)
        size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(system, &address, 0, nil, &size, &defaultID))
        return MicrophoneSnapshot(devices: devices, defaultID: defaultID)
    }

    private func hasInput(_ id: AudioObjectID) -> Bool {
        var address = property(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioBufferList>.size else { return false }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, memory) == noErr else { return false }
        let buffers = UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.contains { $0.mNumberChannels > 0 }
    }

    private func flag(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool? {
        var address = property(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout.size(ofValue: value))
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    private func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = property(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private func property(_ selector: AudioObjectPropertySelector,
                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private func check(_ status: OSStatus) throws {
        if status != noErr { throw MicrophoneError.hardware(status) }
    }
}
