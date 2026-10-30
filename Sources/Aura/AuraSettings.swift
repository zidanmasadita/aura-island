import AppKit
import ServiceManagement

/// UserDefaults-backed settings for Aura, exposed as an
/// ObservableObject for the SwiftUI settings window. Every value
/// is read live at its use site, so most changes apply without
/// restarting the app. Sections are added slice by slice; slice 1
/// ships General + Appearance.
final class AuraSettings: ObservableObject {
    static let shared = AuraSettings()

    private let defaults = UserDefaults.standard
    private init() {}

    private func bool(_ key: String, default defaultValue: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? defaultValue
    }
    private func setBool(_ key: String, _ value: Bool) {
        defaults.set(value, forKey: key)
        objectWillChange.send()
    }
    private func double(_ key: String, default defaultValue: Double) -> Double {
        defaults.object(forKey: key) as? Double ?? defaultValue
    }
    private func setDouble(_ key: String, _ value: Double) {
        defaults.set(value, forKey: key)
        objectWillChange.send()
    }

    // MARK: - General

    /// Launch at login, via SMAppService. Read from the system
    /// (not a stored flag) so the toggle always reflects reality.
    /// An ad-hoc signature can make register() throw; the settings
    /// view surfaces that error.
    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                launchAtLoginError = error.localizedDescription
            }
            objectWillChange.send()
        }
    }
    @Published var launchAtLoginError: String?

    /// Seconds of sustained hover before the card auto-opens.
    var hoverDelay: Double {
        get { double("AuraSettings.hoverDelay", default: 0.3) }
        set { setDouble("AuraSettings.hoverDelay", min(1, max(0, newValue))) }
    }

    /// Whether a pill covered by another app's content hides to a
    /// 6px tip (detection needs Accessibility permission).
    var overlapHideEnabled: Bool {
        get { bool("AuraSettings.overlapHideEnabled", default: true) }
        set { setBool("AuraSettings.overlapHideEnabled", newValue) }
    }

    // MARK: - Appearance

    /// Compact-pill widgets. All on by default, matching the
    /// long-standing layout (battery + clock + waveform).
    var showClock: Bool {
        get { bool("AuraSettings.showClock", default: true) }
        set { setBool("AuraSettings.showClock", newValue) }
    }
    var showBattery: Bool {
        get { bool("AuraSettings.showBattery", default: true) }
        set { setBool("AuraSettings.showBattery", newValue) }
    }
    var showWaveform: Bool {
        get { bool("AuraSettings.showWaveform", default: true) }
        set { setBool("AuraSettings.showWaveform", newValue) }
    }

    /// Cover-dominant gradient on the lyrics card and the
    /// inactive lyrics pill.
    var lyricsGradient: Bool {
        get { bool("AuraSettings.lyricsGradient", default: true) }
        set { setBool("AuraSettings.lyricsGradient", newValue) }
    }

    /// Cursor distance (px) at which the zen eyes are fully open;
    /// they shut by 12px. Drives the proximity-blink falloff.
    var eyeFlinchRange: Double {
        get { double("AuraSettings.eyeFlinchRange", default: 110) }
        set { setDouble("AuraSettings.eyeFlinchRange", min(160, max(40, newValue))) }
    }
}
