import CoreAudio
import CoreGraphics
import IOKit

/// Live system controls read for pill alerts. All reads are cheap
/// and synchronous (no osascript, no permissions): caps lock flags,
/// CoreAudio volume/mute, IODisplay brightness. Each returns nil
/// when its source is unavailable (no volume device, no brightness
/// control), so callers simply never fire that trigger. Battery
/// lives separately in Battery.swift.

/// Caps Lock toggle state (latched, not momentary): true while caps
/// lock is engaged. Reading the current flags needs no Accessibility
/// permission (unlike intercepting key events).
enum CapsLock {
    static func fetch() -> Bool {
        CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift)
    }
}

/// Default output volume (0-1) + mute. Master volume scalar
/// first, channel 1 scalar as fallback (some devices expose no
/// master control). Mute is best effort: unreadable means not
/// muted.
enum Volume {
    static func fetch() -> (level: Double, muted: Bool)? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else {
            return nil
        }
        // The virtual-master selector is not exposed to Swift, so
        // the master scalar (element 0) is the primary read and
        // channel 1 is the fallback for devices with no master.
        var level: Float32 = 0
        size = UInt32(MemoryLayout<Float32>.size)
        address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &level)
        if status != noErr {
            address.mElement = 1
            status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &level)
            guard status == noErr else { return nil }
        }
        var muted: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var isMuted = false
        if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) == noErr {
            isMuted = muted != 0
        }
        return (level: Double(level), muted: isMuted)
    }
}

/// Built-in display brightness (0-1) via IODisplay. Iterates display
/// services and takes the first that reports a value (usually the
/// built-in panel; external displays without brightness control are
/// skipped). Nil when none reports.
enum Brightness {
    static func fetch() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            var value: Float = 0
            if IODisplayGetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, &value) == kIOReturnSuccess {
                let brightness = Double(value)
                IOObjectRelease(service)
                return brightness
            }
            let next = IOIteratorNext(iterator)
            IOObjectRelease(service)
            service = next
        }
        return nil
    }
}
