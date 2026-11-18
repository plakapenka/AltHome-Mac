import AudioToolbox
import CoreAudio
import Foundation

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
        var level: Float32 = 0, size = UInt32(MemoryLayout<Float32>.size), writable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(device,&key,&writable) == noErr, writable.boolValue,
              AudioObjectGetPropertyData(device,&key,0,nil,&size,&level) == noErr else { return nil }
        return level
    }

    static func setVolume(_ value: Float, device: AudioDeviceID) -> Bool {
        var key = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume,output:true), level = value
        return AudioObjectSetPropertyData(device,&key,0,nil,UInt32(MemoryLayout.size(ofValue:level)),&level) == noErr
    }
}
