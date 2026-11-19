import CoreAudio
import Foundation

/// Thin helpers over the Core Audio object API.
enum HAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let global = kAudioObjectPropertyScopeGlobal

    struct Device: Equatable {
        let id: AudioObjectID
        let uid: String
    }

    static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = global) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func read<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = global, initial: T) -> T? {
        var address = address(selector, scope)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    static func readObjects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                            scope: AudioObjectPropertyScope = global) -> [AudioObjectID] {
        var address = address(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: kAudioObjectUnknown, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return Array(objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    static func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        guard let value = read(object, selector, initial: Unmanaged<CFString>?.none) ?? nil else { return nil }
        return value.takeRetainedValue() as String
    }

    @discardableResult
    static func addListener(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                            scope: AudioObjectPropertyScope = global, _ block: @escaping AudioObjectPropertyListenerBlock) -> Bool {
        var address = address(selector, scope)
        return AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr
    }

    static func removeListener(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                               scope: AudioObjectPropertyScope = global, _ block: @escaping AudioObjectPropertyListenerBlock) {
        var address = address(selector, scope)
        AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
    }

    // MARK: Devices

    /// The output device whose name contains `model` (the screen's own audio).
    static func outputDevice(named model: String) -> Device? {
        for device in readObjects(system, kAudioHardwarePropertyDevices) {
            guard let name = readString(device, kAudioObjectPropertyName),
                  name.localizedCaseInsensitiveContains(model),
                  !readObjects(device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput).isEmpty,
                  let uid = readString(device, kAudioDevicePropertyDeviceUID)
            else { continue }
            return Device(id: device, uid: uid)
        }
        return nil
    }

    /// True when macOS can set the device's volume itself (then the native keys already work).
    static func hasOwnVolume(_ device: AudioObjectID) -> Bool {
        for element in [kAudioObjectPropertyElementMain, 1] {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                                     mScope: kAudioObjectPropertyScopeOutput, mElement: element)
            var settable: DarwinBoolean = false
            if AudioObjectHasProperty(device, &address),
               AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue {
                return true
            }
        }
        return false
    }

    static func defaultOutputDevice() -> AudioObjectID? {
        read(system, kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(kAudioObjectUnknown))
    }

    /// True when every input and output stream of `device` carries interleaved 32-bit float samples,
    /// the only layout the mixer handles. Fails closed: no streams also means false.
    static func streamsAreFloat32(_ device: AudioObjectID) -> Bool {
        for scope in [kAudioObjectPropertyScopeInput, kAudioObjectPropertyScopeOutput] {
            let streams = readObjects(device, kAudioDevicePropertyStreams, scope: scope)
            guard !streams.isEmpty else { return false }
            for stream in streams {
                guard let format = read(stream, kAudioStreamPropertyVirtualFormat, initial: AudioStreamBasicDescription()),
                      format.mFormatID == kAudioFormatLinearPCM,
                      format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                      format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0,
                      format.mBitsPerChannel == 32
                else { return false }
            }
        }
        return true
    }

    static func channelCount(of stream: AudioStreamID) -> Int? {
        read(stream, kAudioStreamPropertyVirtualFormat, initial: AudioStreamBasicDescription()).map { Int($0.mChannelsPerFrame) }
    }

    /// The zero-based channels macOS plays stereo on (Audio MIDI Setup can change them); -1 for none.
    static func stereoPair(of device: AudioObjectID) -> (left: Int, right: Int) {
        let pair = readObjects(device, kAudioDevicePropertyPreferredChannelsForStereo, scope: kAudioObjectPropertyScopeOutput)
        guard pair.count == 2 else { return (0, 1) }
        guard pair[0] >= 1, pair[1] >= 1, pair[0] != pair[1] else { return (-1, -1) }
        return (Int(pair[0]) - 1, Int(pair[1]) - 1)
    }

    // MARK: Processes

    static func processObject(pid: pid_t) -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(system, &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    static func processObjects() -> [AudioObjectID] {
        readObjects(system, kAudioHardwarePropertyProcessObjectList)
    }

    /// True while `process` is sending sound to `device`.
    static func isPlaying(_ process: AudioObjectID, on device: AudioObjectID) -> Bool {
        read(process, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0)) == 1
            && readObjects(process, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput).contains(device)
    }
}
