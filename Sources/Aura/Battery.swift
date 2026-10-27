import Foundation
import IOKit
// NOTE: the power-source APIs live in the IOKit.ps submodule, not the
// top-level IOKit module — plain `import IOKit` alone does not expose
// IOPSCopyPowerSourcesInfo and friends, hence the "cannot find" errors.
import IOKit.ps

/// Battery level via IOKit power sources. Returns nil on Macs without a
/// battery (desktops) or when the info is unavailable, so callers can
/// simply hide the icon.
///
/// `charging` means ON AC POWER (the power source state), not the
/// battery's IsCharging flag. IsCharging lags plug/unplug by seconds:
/// it only flips once USB-C PD negotiation finishes and the battery
/// actually starts charging, and it drops to false at full charge
/// (so an unplug at 100% would never alert, and a full battery
/// would fake a "Charger unplugged"). The power source state flips
/// the moment the adapter connects or disconnects, which is what
/// plug/unplug alerts need. Falls back to IsCharging if the state
/// key is ever absent, so behavior never regresses to nothing.
/// ("AC Power" is the kIOPSACPowerValue string.)
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
        let charging: Bool
        if let state = desc[kIOPSPowerSourceStateKey as String] as? String {
            charging = (state == "AC Power")
        } else {
            charging = desc[kIOPSIsChargingKey as String] as? Bool ?? false
        }
        return (percent: Double(current) / Double(max), charging: charging)
    }
}
