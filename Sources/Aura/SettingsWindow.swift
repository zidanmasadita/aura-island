import AppKit
import SwiftUI

/// The settings window: SwiftUI content in a plain titled
/// NSWindow, opened from the menu-bar "Settings...". Sections are
/// added slice by slice; slice 1 ships General + Appearance.
/// (Ideas only taken from DynamicNotch's settings; no code from it.)
final class SettingsWindowController {
    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: SettingsRootView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "Aura Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 720, height: 480))
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general, appearance

    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        }
    }
    var icon: String {
        switch self {
        case .general: "gear"
        case .appearance: "paintbrush"
        }
    }
}

private struct SettingsRootView: View {
    @State private var selection: SettingsSection? = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.icon)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            switch selection ?? .general {
            case .general: GeneralSettingsView()
            case .appearance: AppearanceSettingsView()
            }
        }
        .frame(minWidth: 720, minHeight: 480)
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject private var settings = AuraSettings.shared

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at login", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.launchAtLogin = $0 }
                ))
                if let error = settings.launchAtLoginError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
            Section("Hover") {
                HStack {
                    Text("Auto-expand delay")
                    Slider(value: Binding(
                        get: { settings.hoverDelay },
                        set: { settings.hoverDelay = $0 }
                    ), in: 0...1, step: 0.05)
                    Text(String(format: "%.2fs", settings.hoverDelay))
                        .frame(width: 52, alignment: .trailing)
                        .monospacedDigit()
                }
            }
            Section("Pill") {
                Toggle("Hide pill under other apps' content", isOn: Binding(
                    get: { settings.overlapHideEnabled },
                    set: { settings.overlapHideEnabled = $0 }
                ))
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
        .padding()
    }
}

private struct AppearanceSettingsView: View {
    @ObservedObject private var settings = AuraSettings.shared

    private func toggle(_ get: @escaping () -> Bool,
                        _ set: @escaping (Bool) -> Void) -> Binding<Bool> {
        Binding(get: get, set: set)
    }

    var body: some View {
        Form {
            Section("Compact pill") {
                Toggle("Clock", isOn: toggle({ settings.showClock }, { settings.showClock = $0 }))
                Toggle("Battery", isOn: toggle({ settings.showBattery }, { settings.showBattery = $0 }))
                Toggle("Waveform", isOn: toggle({ settings.showWaveform }, { settings.showWaveform = $0 }))
            }
            Section("Lyrics") {
                Toggle("Cover-dominant gradient", isOn: toggle({ settings.lyricsGradient }, { settings.lyricsGradient = $0 }))
            }
            Section("Idle eyes") {
                HStack {
                    Text("Flinch distance")
                    Slider(value: Binding(
                        get: { settings.eyeFlinchRange },
                        set: { settings.eyeFlinchRange = $0 }
                    ), in: 40...160, step: 5)
                    Text("\(Int(settings.eyeFlinchRange)) px")
                        .frame(width: 52, alignment: .trailing)
                        .monospacedDigit()
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Appearance")
        .padding()
    }
}
