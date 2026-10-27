import AppKit
import ApplicationServices
import Foundation

/// One playable source shown in the island, no matter where it comes from.
struct DisplaySession {
    let id: String
    let label: String
    let title: String
    let artist: String
    let isPlaying: Bool
    let position: Double
    let duration: Double
    let artwork: NSImage?
    /// Extension tabs support play/pause only in v1; system sessions
    /// support full transport through the macOS media keys.
    let supportsNextPrev: Bool

    /// Copy with artwork attached (used for the system artwork fetch:
    /// the JXA sensor reports no artwork in its poll, so AppDelegate
    /// attaches the fetched cover at display time without fighting
    /// the per-tick sensor update).
    func withArtwork(_ image: NSImage?) -> DisplaySession {
        DisplaySession(id: id, label: label, title: title, artist: artist,
                       isPlaying: isPlaying, position: position, duration: duration,
                       artwork: image, supportsNextPrev: supportsNextPrev)
    }
}

struct NowPlaying {
    let title: String
    let artist: String
    let isPlaying: Bool
    let position: Double
    let duration: Double
    let artwork: NSImage?
}

/// Unified session list + pin ("pilih active") logic.
/// - Auto: follow whatever is playing, else the first available session.
/// - Pin: stick to the chosen session until it disappears or is released.
final class SessionStore {
    private(set) var pinnedId: String?
    private var system: NowPlaying?
    private var extensionTabs: [String: ExtensionTab] = [:]

    var current: DisplaySession? {
        let all = allSessions
        if let pinnedId, let pinned = all.first(where: { $0.id == pinnedId }) {
            return pinned
        }
        if pinnedId != nil {
            // Pinned source is gone: fall back to Auto.
            pinnedId = nil
            UserDefaults.standard.removeObject(forKey: "pinnedSessionId")
        }
        return all.first(where: { $0.isPlaying }) ?? all.first
    }

    var allSessions: [DisplaySession] {
        var out: [DisplaySession] = []
        if let system {
            out.append(DisplaySession(
                id: "system",
                label: "Sistem (app aktif)",
                title: system.title,
                artist: system.artist,
                isPlaying: system.isPlaying,
                position: system.position,
                duration: system.duration,
                artwork: system.artwork,
                supportsNextPrev: true
            ))
        }
        for tab in extensionTabs.values.sorted(by: { $0.tabId < $1.tabId }) {
            out.append(DisplaySession(
                id: "tab:\(tab.tabId)",
                label: "Chrome: \(tab.host)",
                title: tab.title,
                artist: tab.artist,
                isPlaying: tab.playbackState == "playing",
                position: tab.position,
                duration: tab.duration,
                artwork: nil,
                supportsNextPrev: false
            ))
        }
        return out
    }

    init() {
        pinnedId = UserDefaults.standard.string(forKey: "pinnedSessionId")
    }

    func updateSystem(_ now: NowPlaying) {
        system = now
    }

    func clearSystem() {
        system = nil
    }

    func refreshExtensionTabs(_ tabs: [String: ExtensionTab]) {
        extensionTabs = tabs
    }

    func pin(id: String) {
        pinnedId = id
        UserDefaults.standard.set(id, forKey: "pinnedSessionId")
    }

    func unpin() {
        pinnedId = nil
        UserDefaults.standard.removeObject(forKey: "pinnedSessionId")
    }

    // MARK: - Transport

    func togglePlayPause() {
        guard let current else { return }
        if current.id.hasPrefix("tab:") {
            ExtensionBridge.shared?.queueCommand(tabId: String(current.id.dropFirst(4)), command: "playpause")
        } else {
            sendMediaKey(16) // NX_KEYTYPE_PLAY
        }
    }

    func nextTrack() {
        guard let current, current.supportsNextPrev else { return }
        sendMediaKey(17) // NX_KEYTYPE_NEXT
    }

    func previousTrack() {
        guard let current, current.supportsNextPrev else { return }
        sendMediaKey(18) // NX_KEYTYPE_PREVIOUS
    }

    /// Sends a system media key through the HID event tap.
    /// This targets the system's active media client. If the pinned
    /// session differs from the active client, the key still goes to
    /// the active one; that is a documented v1 limitation.
    ///
    /// Posting to the HID tap needs Accessibility trust: without it
    /// the events are silently dropped, which is why the card buttons
    /// did nothing before this prompt existed (the app never asked).
    /// The prompt is shown once per launch, on the first control
    /// press; after granting in System Settings, the next press works
    /// (no restart needed). The log line tells the user (and any
    /// bug report) whether trust is the blocker or the key itself is.
    private static var accessibilityPrompted = false
    private func sendMediaKey(_ key: Int32) {
        let trusted = AXIsProcessTrusted()
        if !trusted && !Self.accessibilityPrompted {
            Self.accessibilityPrompted = true
            _ = AXIsProcessTrustedWithOptions(
                [kAXTrustedCheckOptionPrompt as String: true] as CFDictionary)
        }
        print("[Aura] media key \(key), Accessibility trusted: \(trusted)")
        func post(_ down: Bool) {
            let data1 = (Int(key) << 16) | (down ? 0xa00 : 0xb00)
            if let event = NSEvent.otherEvent(
                with: .applicationDefined,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8, // NX_SUBTYPE_AUX_CONTROL_BUTTONS
                data1: data1,
                data2: -1
            ) {
                event.cgEvent?.post(tap: .cghidEventTap)
            }
        }
        post(true)
        post(false)
    }
}
