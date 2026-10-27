import Foundation
import IOBluetooth
import IOKit

/// Connected Bluetooth devices, via IOBluetooth. This reads the
/// local paired-device list (public API, no permission prompt and
/// no scanning); it does not discover new devices. Polled, not
/// notification-driven: connection itself takes seconds, so the
/// 1s throttle in AppDelegate is plenty and keeps every alert
/// trigger in one place.
enum Bluetooth {
    struct Device {
        let address: String
        let name: String
    }

    static func connectedDevices() -> [Device] {
        let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        return paired.compactMap { device in
            guard device.isConnected() else { return nil }
            // `as String?` tolerates the header's nullability
            // (String vs String! vs String?) on all three forms.
            guard let address = device.addressString as String?, !address.isEmpty else { return nil }
            let name = (device.name as String?) ?? "Unknown"
            return Device(address: address, name: name)
        }
    }
}

/// Best-effort battery percent for one connected device, from the
/// IORegistry BatteryPercent property that macOS publishes for
/// Bluetooth HID peripherals (Magic Mouse/Keyboard/Trackpad).
/// Returns nil when the device publishes nothing (many audio
/// devices do not expose battery this way) — the alert then shows
/// without battery rather than a wrong number. Matched by entry
/// name; nil-safe throughout, never crashes on a missing service.
enum BluetoothBattery {
    static func fetch(deviceName: String) -> Int? {
        for className in ["AppleBluetoothHIDDevice", "IOBluetoothDevice"] {
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else {
                continue
            }
            defer { IOObjectRelease(iterator) }
            var service = IOIteratorNext(iterator)
            while service != 0 {
                var nameBuffer = [CChar](repeating: 0, count: 128)
                let entryName: String
                if IORegistryEntryGetName(service, &nameBuffer) == KERN_SUCCESS {
                    entryName = String(cString: nameBuffer)
                } else {
                    entryName = ""
                }
                if entryName == deviceName,
                   let percent = IORegistryEntryCreateCFProperty(service, "BatteryPercent" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int {
                    IOObjectRelease(service)
                    return min(100, max(0, percent))
                }
                let next = IOIteratorNext(iterator)
                IOObjectRelease(service)
                service = next
            }
        }
        return nil
    }
}
