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
    case general, appearance, musicLyrics, sections, pillAlerts, permissions, about

    // The List selection binds SettingsSection itself, so the
    // identity must be the enum (not its raw String) or the
    // sidebar rows never select — the Appearance-that-wouldn't-open bug.
    var id: Self { self }
    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .musicLyrics: "Music & Lyrics"
        case .sections: "Sections"
        case .pillAlerts: "Pill Alerts"
        case .permissions: "Permissions"
        case .about: "About"
        }
    }
    var icon: String {
        switch self {
        case .general: "gear"
        case .appearance: "paintbrush"
        case .musicLyrics: "music.note"
        case .sections: "square.grid.2x2"
        case .pillAlerts: "bell"
        case .permissions: "checkmark.seal"
        case .about: "info.circle"
        }
    }
    var tint: Color {
        switch self {
        case .general: .gray
        case .appearance: .blue
        case .musicLyrics: .pink
        case .sections: .purple
        case .pillAlerts: .orange
        case .permissions: .green
        case .about: .gray
        }
    }
}

private struct SettingsRootView: View {
    @State private var selection: SettingsSection? = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection) { section in
                Label {
                    Text(section.title)
                } icon: {
                    Image(systemName: section.icon)
                        .foregroundColor(.white)
                        .frame(width: 28, height: 28)
                        .background(section.tint)
                        .cornerRadius(7)
                        .padding(.trailing, 6)
                }
                .padding(.vertical, 3)
                .padding(.leading, 6)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            switch selection ?? .general {
            case .general: GeneralSettingsView()
            case .appearance: AppearanceSettingsView()
            case .musicLyrics: MusicLyricsSettingsView()
            case .sections: SectionsSettingsView()
            case .pillAlerts: PillAlertsSettingsView()
            case .permissions: PermissionsSettingsView()
            case .about: AboutSettingsView()
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
                Toggle("Open on hover", isOn: Binding(
                    get: { settings.openOnHover },
                    set: { settings.openOnHover = $0 }
                ))
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
                .disabled(!settings.openOnHover)
                Text("When off, click the pill to open it.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Section("Pill") {
                Toggle("Hide pill under other apps' content", isOn: Binding(
                    get: { settings.overlapHideEnabled },
                    set: { settings.overlapHideEnabled = $0 }
                ))
                DisplayPickerView()
                Text("Pin the pill to a display instead of following the active monitor.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .tint(.red)
        .navigationTitle("General")
        .padding()
    }
}

/// Visual display picker for the pill's display: the real monitor
/// arrangement as clickable rectangles (like System Settings), plus
/// an "Active monitor" row. No dropdown.
private struct DisplayPickerView: View {
    @ObservedObject private var settings = AuraSettings.shared

    private struct DisplayItem {
        let index: Int
        let rect: CGRect
        let screenSize: CGSize
        let isMain: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Active-monitor mode: a full-width radio row.
            Button {
                settings.notchScreen = 0
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: settings.notchScreen == 0
                          ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(settings.notchScreen == 0 ? .red : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Active monitor")
                        Text("The pill follows the focused app.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Pinned displays: the actual arrangement, clickable.
            GeometryReader { geo in
                ZStack {
                    ForEach(displayRects(in: geo.size), id: \.index) { item in
                        let selected = settings.notchScreen == item.index + 1
                        Button {
                            settings.notchScreen = item.index + 1
                        } label: {
                            ZStack {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(selected ? Color.red.opacity(0.22)
                                                  : Color.gray.opacity(0.18))
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(selected ? Color.red : Color.gray.opacity(0.6),
                                            lineWidth: selected ? 2.5 : 1.5)
                                VStack(spacing: 2) {
                                    Text("Display \(item.index + 1)")
                                        .font(.caption)
                                        .fontWeight(selected ? .semibold : .regular)
                                    Text("\(Int(item.screenSize.width))×\(Int(item.screenSize.height))")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                // Mini pill: where Aura will sit.
                                if selected || (settings.notchScreen == 0 && item.isMain) {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.black)
                                        .frame(width: 26, height: 6)
                                        .position(x: item.rect.width / 2, y: 9)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .frame(width: item.rect.width, height: item.rect.height)
                        .position(x: item.rect.midX, y: item.rect.midY)
                    }
                }
            }
            .frame(height: 160)
        }
    }

    /// Display rects in view coordinates, preserving the real
    /// arrangement (flipped Y, scaled to fit, centered).
    private func displayRects(in size: CGSize) -> [DisplayItem] {
        let screens = NSScreen.screens
        guard !screens.isEmpty, size.width > 0, size.height > 0 else { return [] }
        let minX = screens.map { $0.frame.minX }.min() ?? 0
        let maxX = screens.map { $0.frame.maxX }.max() ?? 1
        let minY = screens.map { $0.frame.minY }.min() ?? 0
        let maxY = screens.map { $0.frame.maxY }.max() ?? 1
        let totalW = max(maxX - minX, 1)
        let totalH = max(maxY - minY, 1)
        let scale = min(size.width / totalW, size.height / totalH)
        let ox = (size.width - totalW * scale) / 2
        let oy = (size.height - totalH * scale) / 2
        let main = NSScreen.main
        return screens.enumerated().map { i, s in
            let f = s.frame
            return DisplayItem(
                index: i,
                rect: CGRect(
                    x: ox + (f.minX - minX) * scale,
                    y: oy + (maxY - f.maxY) * scale,
                    width: max(f.width * scale, 24),
                    height: max(f.height * scale, 16)),
                screenSize: f.size,
                isMain: s == main)
        }
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
        .tint(.red)
        .navigationTitle("Appearance")
        .padding()
    }
}

private struct MusicLyricsSettingsView: View {
    @ObservedObject private var settings = AuraSettings.shared
    @State private var nudgeResetMessage: String?

    var body: some View {
        Form {
            Section("Lyrics") {
                Toggle("Show lyrics", isOn: Binding(
                    get: { settings.lyricsEnabled },
                    set: { settings.lyricsEnabled = $0 }
                ))
                Toggle("Dynamic pill width", isOn: Binding(
                    get: { settings.lyricsDynamicWidth },
                    set: { settings.lyricsDynamicWidth = $0 }
                ))
                Text("The compact lyrics pill resizes to fit each line.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Toggle("Show mascot", isOn: Binding(
                    get: { settings.lyricsShowMascot },
                    set: { settings.lyricsShowMascot = $0 }
                ))
                HStack {
                    Text("Global timing offset")
                    Slider(value: Binding(
                        get: { settings.lyricGlobalOffset },
                        set: { settings.lyricGlobalOffset = $0 }
                    ), in: -5...5, step: 0.5)
                    Text(String(format: "%+.1fs", settings.lyricGlobalOffset))
                        .frame(width: 52, alignment: .trailing)
                        .monospacedDigit()
                }
                HStack {
                    Button("Reset per-song timing adjustments") {
                        settings.resetLyricNudges()
                        nudgeResetMessage = "Cleared."
                    }
                    if let nudgeResetMessage {
                        Text(nudgeResetMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .tint(.red)
        .navigationTitle("Music & Lyrics")
        .padding()
    }
}

private func sectionDisplayName(_ page: IslandView.CardPage) -> String {
    switch page {
    case .music: "Music"
    case .pomodoro: "Pomodoro"
    case .todo: "Todo"
    case .water: "Water"
    case .tray: "Tray"
    case .removeBg: "Remove BG"
    case .convert: "Convert"
    case .lyrics: "Lyrics"
    case .sources: "Sources"
    }
}

private struct SectionsSettingsView: View {
    @ObservedObject private var settings = AuraSettings.shared

    var body: some View {
        List {
            Section("Card sections") {
                // On macOS, .onMove on a ForEach enables drag-reorder
                // directly — no edit mode needed (unlike iOS). The
                // grip icon marks each row as draggable.
                ForEach(settings.orderedToggleableSections, id: \.self) { page in
                    HStack {
                        Image(systemName: "line.3.horizontal")
                            .foregroundColor(.secondary)
                        Toggle(sectionDisplayName(page), isOn: Binding(
                            get: { settings.isSectionEnabled(page) },
                            set: { settings.setSectionEnabled(page, $0) }
                        ))
                    }
                    .padding(.vertical, 6)
                }
                .onMove { from, to in
                    var order = settings.sectionOrder
                    order.move(fromOffsets: from, toOffset: to)
                    settings.sectionOrder = order
                }
            }
            Section {
                Text("Drag rows to reorder. The dots and swipe follow this order. Hidden sections disappear from the dots and swipe; if every section is hidden, Music stays as a fallback.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .tint(.red)
        .navigationTitle("Sections")
        .padding()
    }
}

private struct PillAlertsSettingsView: View {
    @ObservedObject private var settings = AuraSettings.shared

    private func toggle(_ get: @escaping () -> Bool,
                        _ set: @escaping (Bool) -> Void) -> Binding<Bool> {
        Binding(get: get, set: set)
    }

    var body: some View {
        Form {
            Section {
                Toggle("Show pill alerts", isOn: toggle({ settings.pillAlertsEnabled }, { settings.pillAlertsEnabled = $0 }))
                HStack {
                    Text("Alert duration")
                    Slider(value: Binding(
                        get: { settings.pillAlertDuration },
                        set: { settings.pillAlertDuration = $0 }
                    ), in: 0.5...4, step: 0.25)
                    Text(String(format: "%.2fs", settings.pillAlertDuration))
                        .frame(width: 52, alignment: .trailing)
                        .monospacedDigit()
                }
            }
            Section("Alert types") {
                Toggle("Battery", isOn: toggle({ settings.alertBattery }, { settings.alertBattery = $0 }))
                Toggle("Volume", isOn: toggle({ settings.alertVolume }, { settings.alertVolume = $0 }))
                Toggle("Brightness", isOn: toggle({ settings.alertBrightness }, { settings.alertBrightness = $0 }))
                Toggle("Caps Lock", isOn: toggle({ settings.alertCapsLock }, { settings.alertCapsLock = $0 }))
                Toggle("Bluetooth", isOn: toggle({ settings.alertBluetooth }, { settings.alertBluetooth = $0 }))
            }
        }
        .formStyle(.grouped)
        .tint(.red)
        .navigationTitle("Pill Alerts")
        .padding()
    }
}

private struct PermissionsSettingsView: View {
    @ObservedObject private var settings = AuraSettings.shared

    private func openPane(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    var body: some View {
        Form {
            Section("Accessibility") {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Accessibility")
                        Text("Needed for overlap-hide and the media keys.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Text(settings.accessibilityGranted ? "Granted" : "Not granted")
                        .foregroundColor(settings.accessibilityGranted ? .green : .red)
                    Button("Open System Settings") {
                        openPane("Privacy_Accessibility")
                    }
                }
            }
            Section("Automation") {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Google Chrome")
                        Text("Needed for seeking from the progress bar.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Open System Settings") {
                        openPane("Privacy_Automation")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Permissions")
        .padding()
    }
}

private struct AboutSettingsView: View {
    @ObservedObject private var settings = AuraSettings.shared
    @State private var confirmReset = false
    @State private var resetDone = false

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Aura Island")
                        .font(.headline)
                    Spacer()
                    Text(appVersion)
                        .foregroundColor(.secondary)
                }
                Text("Dynamic island for Mac. Native, no webview.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Section("Settings") {
                HStack {
                    Button(confirmReset ? "Click again to confirm" : "Reset all settings") {
                        if confirmReset {
                            settings.resetAllSettings()
                            confirmReset = false
                            resetDone = true
                        } else {
                            confirmReset = true
                            resetDone = false
                        }
                    }
                    if resetDone {
                        Text("Defaults restored.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("About")
        .padding()
    }
}
