import AudioToolbox
import CoreAudio
import Foundation
import Combine

struct AudioOutput: Identifiable {
    let id: AudioDeviceID
    let name: String
}

enum ShelfAudio {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static func address(_ selector: AudioObjectPropertySelector, output: Bool = false) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector:selector,mScope:output ? kAudioDevicePropertyScopeOutput : kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
    }

    static var current: AudioDeviceID {
        var key = address(kAudioHardwarePropertyDefaultOutputDevice)
        var device: AudioDeviceID = 0, size = UInt32(MemoryLayout<AudioDeviceID>.size)
        _ = AudioObjectGetPropertyData(system,&key,0,nil,&size,&device)
        return device
    }

    static func outputs() -> [AudioOutput] {
        var key = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system,&key,0,nil,&size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating:0,count:Int(size)/MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system,&key,0,nil,&size,&ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streams = address(kAudioDevicePropertyStreams,output:true), bytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id,&streams,0,nil,&bytes) == noErr, bytes > 0 else { return nil }
            var key = address(kAudioObjectPropertyName), name: Unmanaged<CFString>?
            bytes = UInt32(MemoryLayout.size(ofValue:name))
            guard AudioObjectGetPropertyData(id,&key,0,nil,&bytes,&name) == noErr, let name else { return nil }
            return AudioOutput(id:id,name:name.takeRetainedValue() as String)
        }
    }

    static func select(_ id: AudioDeviceID) -> Bool {
        var key = address(kAudioHardwarePropertyDefaultOutputDevice), value = id
        return AudioObjectSetPropertyData(system,&key,0,nil,UInt32(MemoryLayout.size(ofValue:value)),&value) == noErr
    }

    static func volume(_ device: AudioDeviceID) -> Float? {
        var key = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume,output:true)
        var writable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(device,&key,&writable) == noErr, writable.boolValue else { return nil }
        return readVolume(device, key: key)
    }

    private static func readVolume(_ device: AudioDeviceID, key: AudioObjectPropertyAddress) -> Float? {
        var key = key, level: Float32 = 0, size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device,&key,0,nil,&size,&level) == noErr, level.isFinite else { return nil }
        return level
    }

    static func speakerSymbol(volume: Float?, muted: Bool) -> String {
        if muted { return "speaker.slash" }
        guard let volume else { return "speaker" }
        if volume <= 0 { return "speaker.slash" }
        if volume <= 1.0 / 3 { return "speaker.wave.1" }
        if volume <= 2.0 / 3 { return "speaker.wave.2" }
        return "speaker.wave.3"
    }

    static func speakerSymbol(for device: AudioDeviceID) -> String {
        var muteKey = address(kAudioDevicePropertyMute, output: true)
        var muted: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        let hasMute = AudioObjectGetPropertyData(device, &muteKey, 0, nil, &size, &muted) == noErr
        let volume = readVolume(device, key: address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, output: true))
            ?? readVolume(device, key: address(kAudioDevicePropertyVolumeScalar, output: true))
        return speakerSymbol(volume: volume, muted: hasMute && muted != 0)
    }

    static func setVolume(_ value: Float, device: AudioDeviceID) -> Bool {
        var key = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume,output:true), level = value
        return AudioObjectSetPropertyData(device,&key,0,nil,UInt32(MemoryLayout.size(ofValue:level)),&level) == noErr
    }
}

// Observe the selected output only. Core Audio can deliver a pending callback after a route change,
// so refresh always reads the current output instead of the device that sent the notification.
final class OutputVolumeIndicator: ObservableObject {
    static let shared = OutputVolumeIndicator()
    @Published private(set) var symbol = "speaker"
    private var device = AudioDeviceID(kAudioObjectUnknown)
    private var subscriptions: [AudioObjectPropertyAddress] = []
    private lazy var changed: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refresh() }

    private init() {
        var key = ShelfAudio.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(ShelfAudio.system, &key, .main, changed)
        refresh()
    }

    private func refresh() {
        let current = ShelfAudio.current
        if current != device {
            for var key in subscriptions {
                AudioObjectRemovePropertyListenerBlock(device, &key, .main, changed)
            }
            subscriptions.removeAll()
            device = current
            if current != kAudioObjectUnknown {
                for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
                    var key = ShelfAudio.address(selector, output: true)
                    key.mElement = kAudioObjectPropertyElementWildcard
                    if AudioObjectAddPropertyListenerBlock(current, &key, .main, changed) == noErr {
                        subscriptions.append(key)
                    }
                }
            }
        }
        let next = current == kAudioObjectUnknown ? "speaker" : ShelfAudio.speakerSymbol(for: current)
        if next != symbol { symbol = next }
    }
}
