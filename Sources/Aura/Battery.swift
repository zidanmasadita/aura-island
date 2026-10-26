import Foundation
import IOKit

/// Battery level via IOKit power sources. Returns nil on Macs without a
/// battery (desktops) or when the info is unavailable, so callers can
/// simply hide the ring.
enum Battery {
    static func fetch() -> (percent: Double, charging: Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as NSArray?,
              let source = list.firstObject as? CFTypeRef,
              let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] else {
            return nil
        }
        let current = desc[kIOPSCurrentCapacityKey as String] as? Int ?? 0
        let max = desc[kIOPSMaxCapacityKey as String] as? Int ?? 0
        guard max > 0 else { return nil }
        let charging = desc[kIOPSIsChargingKey as String] as? Bool ?? false
        return (percent: Double(current) / Double(max), charging: charging)
    }
}
