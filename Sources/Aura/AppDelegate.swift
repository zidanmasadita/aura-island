import AppKit
import ServiceManagement

/// Island states, mirroring the Nusa-style notch states.
/// - zen: thin pill, idle.
/// - compact: mini media strip (title/artist/progress).
/// - split: kept for parity with the earlier scaffold; behaves like compact.
/// - expanded: full card (lyrics, controls, session picker).
enum IslandState {
    case zen
    case compact
    case split
    case expanded

    var size: NSSize {
        switch self {
        case .zen: return NSSize(width: 140, height: 32)
        // Default closed size (plain music 160 wide); the view's
        // closedSize overrides it (lyrics mode is wider).
        case .compact, .split: return NSSize(width: 160, height: 32)
        case .expanded: return NSSize(width: 640, height: 220)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: IslandWindow!
    private var islandView: IslandView!
    private var statusItem: NSStatusItem!
    private var animator: IslandAnimator!

    let sessions = SessionStore()
    private let mediaRemote = MediaRemote()
    private let bridge = ExtensionBridge()
    private let lyrics = LyricsClient()
    private var pollTimer: Timer?
    private var currentTrackKey: String?
    private var lastMediaLog: String?
    private var lastTabLog: String?
    private var jxaInFlight = false
    private var isHovering = false

    /// macOS 15.4+ denies direct MediaRemote reads to third-party
    /// clients (see NowPlayingJXA). Below that, the direct path works
    /// and keeps artwork + instant notifications.
    private let useJXA: Bool = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.majorVersion > 15 || (v.majorVersion == 15 && v.minorVersion >= 4)
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let initial = NSRect(x: 0, y: 0, width: 140, height: 32)
        window = IslandWindow(contentRect: initial)
        islandView = IslandView(frame: initial)
        islandView.onHoverChanged = { [weak self] hovering in
            self?.isHovering = hovering
            self?.handleHover(hovering)
        }
        islandView.onClicked = { [weak self] in
            self?.handleClick()
        }
        islandView.onSessionPicked = { [weak self] id in
            self?.sessions.pin(id: id)
        }
        islandView.onUnpin = { [weak self] in
            self?.sessions.unpin()
        }
        islandView.onPlayPause = { [weak self] in
            self?.sessions.togglePlayPause()
        }
        islandView.onNext = { [weak self] in
            self?.sessions.nextTrack()
        }
        islandView.onPrevious = { [weak self] in
            self?.sessions.previousTrack()
        }
        islandView.onExpandedSizeChanged = { [weak self] size in
            // Only while expanded: music/sources are the 640 card,
            // lyrics the slightly wider 700 card. Other states own
            // their own size.
            guard self?.islandView.state == .expanded else { return }
            self?.animator.animate(to: size)
        }
        window.contentView = islandView
        animator = IslandAnimator(window: window)
        window.placeAtTopCenter()
        window.orderFrontRegardless()

        setupStatusItem()
        // Event-driven refresh from the system sensor, so the island
        // reacts the moment playback starts, pauses, or changes track,
        // instead of only on the next poll.
        mediaRemote.onInfoChanged = { [weak self] now in
            guard let self else { return }
            if let now {
                self.sessions.updateSystem(now)
            } else {
                self.sessions.clearSystem()
            }
            self.refresh()
        }
        bridge.onTabsChanged = { [weak self] in
            self?.refresh()
        }
        bridge.start()

        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        tick()
    }

    // MARK: - Interaction

    private func handleHover(_ hovering: Bool) {
        if hovering {
            // Hover opens the card directly, no click needed — but
            // only when there is something to show. Idle (no session)
            // keeps the old hover-to-compact behaviour, so hovering
            // an idle pill never opens an empty card.
            if islandView.state != .expanded {
                if sessions.current != nil {
                    setState(.expanded)
                } else {
                    setState(.compact)
                }
            }
        } else {
            // Leaving the island always closes it — including an expanded
            // card, so closing never needs a second click. Playing music
            // falls back to the closed (compact) state, silence to zen —
            // unless a pomodoro is live, which keeps the pill compact.
            setState((sessions.current?.isPlaying == true || islandView.isPomodoroActive) ? .compact : .zen)
        }
    }

    private func handleClick() {
        if islandView.state == .expanded {
            setState(.compact)
        } else {
            setState(.expanded)
        }
        window.ignoresMouseEvents = false
    }

    func setState(_ state: IslandState) {
        islandView.state = state
        // Expanded size follows the card's page (music 520x180,
        // lyrics 700x180 — same height, only the width grows —
        // pomodoro 640x180, sources 640x220); zen uses its fixed size;
        // compact/split use the closed size (32 tall; plain music and
        // pomodoro 160 wide, lyrics mode 360). Setting state first matters: leaving
        // expanded updates lyricsMode in didSet before closedSize is
        // read.
        let size: NSSize
        switch state {
        case .expanded: size = islandView.expandedSize
        case .zen: size = state.size
        case .compact, .split: size = islandView.closedSize
        }
        animator.animate(to: size)
    }

    // MARK: - Polling

    private func applySystemNowPlaying(_ now: NowPlaying?, logLabel: String, logKey: String) {
        // Diagnostic log, only when the detected state changes. Visible
        // when the app is run from Terminal; tells us whether the
        // system side sees the music at all.
        if logKey != lastMediaLog {
            lastMediaLog = logKey
            print("[Aura] \(logLabel): \(logKey)")
        }
        if let now {
            sessions.updateSystem(now)
        } else {
            sessions.clearSystem()
        }
        refresh()
    }

    private func tick() {
        if useJXA {
            // One osascript spawn per tick; never stack them if a fetch
            // is still running.
            if !jxaInFlight {
                jxaInFlight = true
                NowPlayingJXA.fetch { [weak self] now, client, failure in
                    guard let self else { return }
                    self.jxaInFlight = false
                    let key: String
                    if let now {
                        key = "\(now.title) | \(now.artist) | playing=\(now.isPlaying) | \(client)"
                    } else {
                        key = "(tidak ada: \(failure ?? "?"))"
                    }
                    self.applySystemNowPlaying(now, logLabel: "MediaRemote(JXA)", logKey: key)
                }
            }
        } else {
            mediaRemote.fetchNowPlaying { [weak self] now in
                guard let self else { return }
                let key = now.map { "\($0.title) | \($0.artist) | playing=\($0.isPlaying)" } ?? "(tidak ada)"
                self.applySystemNowPlaying(now, logLabel: "MediaRemote", logKey: key)
            }
        }
        sessions.refreshExtensionTabs(bridge.tabs)
        let tabKey = bridge.tabs.values
            .sorted(by: { $0.tabId < $1.tabId })
            .map { "\($0.tabId):\($0.title)(\($0.playbackState))" }
            .joined(separator: ", ")
        if tabKey != lastTabLog {
            lastTabLog = tabKey
            print("[Aura] Chrome tabs: \(tabKey.isEmpty ? "(tidak ada)" : tabKey)")
        }
        if let battery = Battery.fetch() {
            islandView.batteryPercent = battery.percent
            islandView.batteryCharging = battery.charging
        } else {
            islandView.batteryPercent = nil
        }
        refresh()
    }

    private func refresh() {
        guard let current = sessions.current else {
            islandView.session = nil
            islandView.clearLyricLines()
            // No session: fall back to idle eyes, unless the card is
            // open or the cursor is still hovering the island — or a
            // pomodoro is live, which keeps the pill compact.
            if (islandView.state == .compact || islandView.state == .split) && !isHovering && !islandView.isPomodoroActive {
                setState(.zen)
            }
            return
        }
        islandView.session = current
        // Album artwork: the JXA sensor cannot read it from the system
        // in the per-second poll, so fetch it from the playing app
        // itself (same nowPlayingInfo, once per track) when missing.
        // Never an online search — the cover is exactly what the app
        // reports. The lookup is cached per track; when it lands,
        // refresh() runs again and the cached cover is attached here.
        if current.artwork == nil {
            if let cached = ArtworkFetcher.shared.cachedArtwork(title: current.title, artist: current.artist, duration: current.duration) {
                islandView.session = current.withArtwork(cached)
            } else {
                ArtworkFetcher.shared.fetchArtwork(title: current.title, artist: current.artist, duration: current.duration) { [weak self] in
                    self?.refresh()
                }
            }
        }
        // Playback must visibly leave the idle eyes on its own: when
        // music starts, switch to compact without waiting for a hover;
        // when it stops, fall back to zen. Never touches an open
        // expanded card, and never yanks the island out from under a
        // hovering cursor. Without this, even a working sensor looks
        // broken, because the pill would keep showing eyes until hovered.
        if islandView.state == .zen && current.isPlaying {
            setState(.compact)
        } else if (islandView.state == .compact || islandView.state == .split) && !current.isPlaying && !isHovering && !islandView.isPomodoroActive {
            setState(.zen)
        }
        let key = "\(current.title)|\(current.artist)"
        if key != currentTrackKey {
            currentTrackKey = key
            // Drop the old song's lines at once, so the inactive
            // lyrics pill never keeps showing the previous song's
            // line for the new song (it falls back to the new title
            // until the new lyrics land).
            lyricsLinesRaw = []
            lyricsLines = []
            islandView.clearLyricLines()
            lyrics.fetchLyrics(title: current.title, artist: current.artist, duration: current.duration) { [weak self] lines in
                // A slow fetch for an older track must not overwrite
                // the current track's lines if the song changed again
                // while it was in flight.
                guard let self, self.currentTrackKey == key else { return }
                self.lyricsLinesRaw = lines
                self.applyLyricNudge()
            }
        }
        refreshLyricLine()
        islandView.sessionsForPicker = sessions.allSessions
        islandView.pinnedId = sessions.pinnedId
        islandView.needsDisplay = true
    }

    private var lyricsLines: [(time: Double, text: String)] = []
    /// Raw fetched lines, before the per-track nudge. The nudge is
    /// re-applied from this, never stacked on already-nudged lines.
    private var lyricsLinesRaw: [(time: Double, text: String)] = []

    /// Applies the current track's stored lyric shift (UserDefaults,
    /// seconds, 0 when unset) to the raw lines. Called when lyrics
    /// land and when the user nudges, so one tap shifts the whole
    /// file at once. A version mismatch — the file's timestamps fit a
    /// slightly different recording than the one playing — shows up
    /// as a constant offset, and this is what corrects it per song.
    private func applyLyricNudge() {
        let nudge = currentTrackKey.map { UserDefaults.standard.double(forKey: "lyricNudge.\($0)") } ?? 0
        lyricsLines = lyricsLinesRaw.map { (time: max(0, $0.time + nudge), text: $0.text) }
        refreshLyricLine()
        // Redraw immediately: the inactive lyrics pill must show the
        // new song's line the moment it lands, without waiting for
        // the next poll or for the pill to be opened.
        islandView.needsDisplay = true
    }

    private func adjustLyricNudge(by delta: Double) {
        guard let key = currentTrackKey, !lyricsLinesRaw.isEmpty else { return }
        let current = UserDefaults.standard.double(forKey: "lyricNudge.\(key)")
        UserDefaults.standard.set(current + delta, forKey: "lyricNudge.\(key)")
        applyLyricNudge()
    }

    private func refreshLyricLine() {
        guard sessions.current != nil else {
            islandView.clearLyricLines()
            return
        }
        let t = islandView.livePosition
        var index: Int?
        for (i, entry) in lyricsLines.enumerated() where entry.time <= t {
            index = i
        }
        islandView.updateLyricLines(
            prev: index.flatMap { $0 > 0 ? lyricsLines[$0 - 1].text : nil },
            current: index.map { lyricsLines[$0].text },
            next: index.flatMap { $0 + 1 < lyricsLines.count ? lyricsLines[$0 + 1].text : nil })
    }

    // MARK: - Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.title = "Aura"
        let menu = NSMenu()
        let about = NSMenuItem(title: "Tentang Aura Island", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        // One-click diagnostic: shows exactly what the sensors last
        // reported, so a detection problem can be diagnosed from a
        // screenshot without running from Terminal.
        let diag = NSMenuItem(title: "Status Deteksi", action: #selector(showDiagnostics), keyEquivalent: "")
        diag.target = self
        menu.addItem(diag)
        let auto = NSMenuItem(title: "Mode: Auto (ikuti yang aktif)", action: #selector(setAuto), keyEquivalent: "")
        auto.target = self
        menu.addItem(auto)
        let unpin = NSMenuItem(title: "Lepas pin sesi", action: #selector(unpinSession), keyEquivalent: "")
        unpin.target = self
        menu.addItem(unpin)
        let login = NSMenuItem(title: "Jalankan saat login", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        // Manual lyric shift, per track, persisted: when a song's file
        // fits a slightly different recording, its lines sit a constant
        // amount early or late — one tap here moves the whole file.
        let nudgePlus = NSMenuItem(title: "Lirik +1 detik (lebih lambat)", action: #selector(nudgeLyricPlus), keyEquivalent: "")
        nudgePlus.target = self
        menu.addItem(nudgePlus)
        let nudgeMinus = NSMenuItem(title: "Lirik -1 detik (lebih cepat)", action: #selector(nudgeLyricMinus), keyEquivalent: "")
        nudgeMinus.target = self
        menu.addItem(nudgeMinus)
        let nudgeReset = NSMenuItem(title: "Reset geseran lirik lagu ini", action: #selector(resetLyricNudge), keyEquivalent: "")
        nudgeReset.target = self
        menu.addItem(nudgeReset)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Keluar", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "Aura Island"
        alert.informativeText = "Pulau dinamis untuk Mac. Native, tanpa webview.\nMedia: MediaRemote + bridge ekstensi Chrome.\nLirik: LRCLIB."
        alert.runModal()
    }

    @objc private func showDiagnostics() {
        let alert = NSAlert()
        alert.messageText = "Status Deteksi"
        let session = sessions.current
        let sessionText = session.map { "\($0.title) — \($0.artist) (\($0.isPlaying ? "playing" : "paused"))" } ?? "tidak ada"
        let tabText: String
        if let t = lastTabLog, !t.isEmpty {
            tabText = t
        } else {
            tabText = "tidak ada"
        }
        alert.informativeText = "MediaRemote terakhir: \(lastMediaLog ?? "belum ada data")\nChrome tabs: \(tabText)\nSesi aktif: \(sessionText)"
        alert.runModal()
    }

    @objc private func setAuto() {
        sessions.unpin()
    }

    @objc private func nudgeLyricPlus() {
        adjustLyricNudge(by: 1)
    }

    @objc private func nudgeLyricMinus() {
        adjustLyricNudge(by: -1)
    }

    @objc private func resetLyricNudge() {
        guard let key = currentTrackKey else { return }
        UserDefaults.standard.removeObject(forKey: "lyricNudge.\(key)")
        applyLyricNudge()
    }

    @objc private func unpinSession() {
        sessions.unpin()
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            // Best effort; user can manage Login Items manually in System Settings.
        }
        setupStatusItem()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
