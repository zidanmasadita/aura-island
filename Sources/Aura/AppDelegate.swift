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
        // Default closed size (plain music 180 wide); the view's
        // closedSize overrides it (lyrics mode is wider, pomodoro narrower).
        case .compact, .split: return NSSize(width: 180, height: 32)
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
    private var lyricTimer: Timer?
    private var eyeTimer: Timer?
    private var currentTrackKey: String?
    private var lastMediaLog: String?
    private var lastTabLog: String?
    private var jxaInFlight = false
    private var isHovering = false

    /// Previous readings for pill alert edges. Battery/caps are
    /// edge baselines (advance every tick); volume/brightness are
    /// level baselines (advance only when an alert fires, so slow
    /// drags accumulate instead of never crossing a per-tick
    /// threshold). Nil until the first read, so launching with an
    /// already-low battery (or muted volume) never fires a
    /// spurious alert.
    private var prevBattery: (percent: Double, charging: Bool)?
    private var prevCaps: Bool?
    private var prevVolume: (level: Double, muted: Bool)?
    private var prevBrightness: Double?
    /// How long a pill alert stays widened (wall clock).
    private let pillAlertDuration: TimeInterval = 1.5
    /// How long after a charger plug/unplug brightness changes are
    /// treated as the power change's auto-adjust (absorbed, not
    /// alerted): macOS re-adjusts brightness on power-source
    /// change, which would otherwise overwrite the charging alert.
    private let brightnessSuppressAfterPowerChange: TimeInterval = 2
    private var lastPowerChange: Date?
    /// When a brightness change was first noticed but held (see the
    /// brightness branch): a plug/unplug auto-adjusts brightness,
    /// and the power flip is sometimes polled a tick AFTER the
    /// brightness change, so showing at once would flash Brightness
    /// before Charging. Nil when nothing is held.
    private var brightnessHoldSince: Date?
    /// How long a brightness change is held before showing, to let
    /// a following power flip cancel it as auto-adjust.
    private let brightnessHold: TimeInterval = 0.75
    /// Connected Bluetooth devices (address -> name) at the last
    /// check; nil until the first check, so devices already
    /// connected at launch do not fire a false connect alert.
    private var prevBluetooth: [String: String]?
    /// Last Bluetooth check (throttled to 1s: connection itself
    /// takes seconds, and IOBluetooth need not be polled at 0.25s).
    private var lastBluetoothCheck: Date?
    private let bluetoothCheckInterval: TimeInterval = 1.0
    private var alertTimer: Timer?

    /// macOS 15.4+ denies direct MediaRemote reads to third-party
    /// clients (see NowPlayingJXA). Below that, the direct path works
    /// and keeps artwork + instant notifications.
    private let useJXA: Bool = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.majorVersion > 15 || (v.majorVersion == 15 && v.minorVersion >= 4)
    }()

    /// LAN sharing service (discovery + receiver + sender).
    private var lanShare: LANShare?

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
        islandView.onDragEnteredTray = { [weak self] in
            // Show tray first (sets the expanded size), then expand.
            self?.islandView.showTray()
            self?.setState(.expanded)
        }
        islandView.onTraySizeChanged = { [weak self] in
            // Re-apply the current state so windowSize (headroom
            // while hovering/bouncing, normal otherwise) is
            // animated to.
            guard let self else { return }
            self.setState(self.islandView.state)
        }
        islandView.onTrayShareAirDrop = { [weak self] file in
            self?.shareViaAirDrop(file)
        }
        islandView.onTrayShareLANPeer = { [weak self] file, peer in
            self?.sendViaLAN(file: file, to: peer)
        }
        islandView.onTrayShareCancel = { [weak self] in
            self?.lanShare?.cancelSend()
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
        // Screens changed (monitor plugged/unplugged, display moved):
        // re-detect the notch and re-layout the current state, so a
        // notched screen picked up later still gets the merged layout.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.animator.animate(to: self.windowSize(for: self.islandView.state))
        }
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
        // Alert triggers poll faster than the 1s session poll: the
        // 1s poll + 0.35s animation made battery alerts feel delayed
        // (~1.35s worst case). 0.25s + animation is ~0.6s. .common
        // modes so it fires during drags/scrolls too (the session
        // poll's .default mode pauses during tracking).
        alertTimer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.updatePillAlerts()
        }
        if let alertTimer { RunLoop.main.add(alertTimer, forMode: .common) }
        // Lyric line refresh, DynamicNotch cadence: the 1s session
        // poll alone made line changes lag up to a second. 0.35s
        // keeps the line in step with the vocal without touching
        // the sensor poll. It only re-evaluates when a session and
        // fetched lines exist; updateLyricLines is a no-op when the
        // line is unchanged, so this does not redraw needlessly.
        // .common modes so it fires during drags/scrolls too.
        lyricTimer = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in
            guard let self, self.sessions.current != nil, !self.lyricsLines.isEmpty else { return }
            self.refreshLyricLine()
        }
        if let lyricTimer { RunLoop.main.add(lyricTimer, forMode: .common) }
        // Idle-eyes cursor tracking: 0.1s, global mouse location,
        // only while the pill is zen (the eyes are only drawn
        // there). The look is smoothed toward the cursor direction
        // so pupils glide instead of snapping, and the view only
        // redraws when the look actually moved. Direction is
        // normalized over 300px horizontal / 200px vertical from
        // the pill center, so the pupils saturate at the edge of
        // their travel well before the cursor is far away. Screen
        // coords grow upward, view coords grow downward, so the
        // vertical sign flips: cursor below the pill = look down.
        eyeTimer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, self.islandView.state == .zen,
                  let window = self.islandView.window else { return }
            let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
            let mouse = NSEvent.mouseLocation
            let targetX = max(-1, min(1, (mouse.x - center.x) / 300))
            let targetY = max(-1, min(1, (center.y - mouse.y) / 200))
            let old = self.islandView.eyeLook
            let next = CGPoint(x: old.x + (targetX - old.x) * 0.25,
                               y: old.y + (targetY - old.y) * 0.25)
            guard abs(next.x - old.x) > 0.005 || abs(next.y - old.y) > 0.005 else { return }
            self.islandView.eyeLook = next
            self.islandView.needsDisplay = true
        }
        if let eyeTimer { RunLoop.main.add(eyeTimer, forMode: .common) }
        // LAN sharing: discover peers, receive shares, announce us.
        // Started once at launch so shares can arrive anytime, not
        // just while the tray is open.
        lanShare = LANShare()
        lanShare?.onPeersChanged = { [weak self] peers in
            self?.islandView.lanPeers = peers
        }
        lanShare?.start()
        tick()
        updatePillAlerts()
    }

    // MARK: - Tray sharing

    /// AirDrop one tray file via the system picker (the only public
    /// AirDrop path — the protocol itself is proprietary). The
    /// picker is system UI; the tray is already back to list mode.
    private func shareViaAirDrop(_ file: IslandView.TrayFile) {
        guard FileManager.default.fileExists(atPath: file.path),
              let service = NSSharingService(named: .sendViaAirDrop),
              service.canPerform(withItems: [file.url]) else { return }
        service.perform(withItems: [file.url])
    }

    /// LAN send to one peer (Aura-to-Aura). Directories are not
    /// sent over LAN in v1 (no zip yet); they report back instead
    /// of failing silently. Status/progress land in the tray's
    /// share view.
    private func sendViaLAN(file: IslandView.TrayFile, to peer: LANPeer) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir), !isDir.boolValue else {
            islandView.trayShareStatus = "Folders aren't supported over LAN yet"
            islandView.trayShareProgress = nil
            islandView.needsDisplay = true
            return
        }
        lanShare?.sendFile(to: peer, file: file.url,
            progress: { [weak self] fraction in
                // LANShare already calls back on main; the dispatch
                // is defensive (view state must never be set off-main).
                DispatchQueue.main.async {
                    self?.islandView.trayShareProgress = fraction
                    self?.islandView.trayShareStatus = "Sending... \(Int(round(fraction * 100)))%"
                }
            },
            completion: { [weak self] error in
                DispatchQueue.main.async {
                    self?.islandView.trayShareStatus = error ?? "Sent"
                    self?.islandView.trayShareProgress = nil
                }
            })
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
        } else if islandView.isShowingModal {
            // A modal dialog (add-task, water settings) is open, so
            // the mouse moving down to it is not leaving the card.
            // Collapsing here used to freeze the window at the expanded
            // size (the animator timer does not fire in modal mode)
            // while drawing closed content - the giant-curve pill in
            // the bug report. The card stays open; IslandView re-syncs
            // hover when the modal closes.
            return
        } else if islandView.isDraggingOut {
            // A drag-out is in flight (the file is being carried to
            // another app): the cursor leaving the card is the drag,
            // not a hover exit. Collapsing mid-drag would shrink the
            // source window under the drag session. IslandView
            // re-syncs hover when the drag ends.
            return
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
        // Opening a card cancels a live pill alert: the user's
        // action wins, and the alert must not resurrect when the
        // card closes (its timer would otherwise still be running).
        if state == .expanded { islandView.pillAlert = nil }
        // Leaving expanded cancels a running tray spring (drop bounce):
        // otherwise the spring transform runs through the close
        // animation and pushes closed content outside the small pill.
        // Only on a REAL leave: onTraySizeChanged calls setState with
        // the current (already closed) state during a first drag-enter,
        // and cancelling there killed the hover spring, leaving the
        // headroom window drawn left-aligned with a wide right margin
        // on first entry (later entries were already expanded, kept
        // the spring, and looked normal).
        if islandView.state == .expanded && state != .expanded { islandView.cancelTraySpring() }
        islandView.state = state
        // Expanded size follows the card's page (music 520x180,
        // lyrics 700x180 — same height, only the width grows —
        // pomodoro/water 640x180, todo/sources 640x220); zen uses its fixed size;
        // compact/split use the closed size (32 tall; plain music 180
        // wide, pomodoro 160, lyrics mode 360). Setting state first matters: leaving
        // expanded updates lyricsMode in didSet before closedSize is
        // read.
        animator.animate(to: windowSize(for: state))
    }

    /// Window size for a state. A live pill alert widens every
    /// closed pill to 360x32 — horizontal only, the height never
    /// changes for an alert. An expanded card is never overridden:
    /// alerts do not fire while one is open, and opening one
    /// cancels a live alert (see setState).
    private func windowSize(for state: IslandState) -> NSSize {
        // Base size lives in IslandView (single source of truth).
        // While a file drag hovers or a bounce runs, the window is
        // headroom-sized so the bouncing pill (up to ~1.12x) never
        // clips; the margin is transparent and the pill itself is
        // drawn from its nominal size (see IslandView.draw).
        var base = islandView.unbulgedSize(for: state)
        // Notched screen, closed pill only: never narrower than the
        // hardware notch, or the notch's edges would stick out on
        // both sides of the pill. Expanded cards are already wider
        // than any notch, so they are left alone.
        if state != .expanded {
            let notch = HardwareNotch.forMainScreen()
            if notch.hasNotch {
                base.width = max(base.width, notch.width)
            }
        }
        if islandView.trayDropHighlight || islandView.isTrayBouncing {
            return NSSize(width: base.width * IslandView.bounceHeadroomFactor,
                          height: base.height * IslandView.bounceHeadroomFactor)
        }
        return base
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
        let battery = Battery.fetch()
        if let battery {
            islandView.batteryPercent = battery.percent
            islandView.batteryCharging = battery.charging
        } else {
            islandView.batteryPercent = nil
        }
        refresh()
    }

    /// Pill alert edges, checked on the fast alert timer (0.25s):
    /// battery (plug/unplug, low/full crossings), caps lock toggle,
    /// volume change/mute, brightness change. One alert slot: a
    /// newer event replaces a live one (timer restarts). A live
    /// alert expires after pillAlertDuration and the pill shrinks
    /// back. Skipped while a card is expanded (alerts never
    /// interrupt an open card); baselines still advance while
    /// expanded, so missed changes are dropped, not queued. A
    /// source that reads nil (no battery, no volume device, no
    /// brightness control) simply never fires and leaves its
    /// baseline alone, so a transient failure never fakes an edge.
    /// Shows an alert unless a higher-priority one is currently
    /// displayed. Priority lives on PillAlert (lower wins): battery
    /// 0, volume 1, brightness 2, caps and everything else 3. Equal
    /// priority replaces (a new event of the same kind refreshes
    /// the display); lower priority is dropped. Returns whether
    /// the alert is now displayed - callers advance level baselines
    /// only on true, so a dropped change resurfaces later.
    private func presentAlert(_ alert: IslandView.PillAlert) -> Bool {
        if let current = islandView.pillAlert, Date() < current.until,
           alert.priority > current.priority {
            return false
        }
        islandView.pillAlert = alert
        return true
    }

    /// Bluetooth connect/disconnect alert, throttled to 1s. Returns
    /// nil when throttled, on first check (initializes silently),
    /// or when nothing changed. One alert per check; simultaneous
    /// changes beyond the first are recorded silently (single
    /// slot). The caller presents it only when no card is expanded;
    /// the baseline advances regardless, so a change during an open
    /// card is dropped, not queued (same rule as battery/caps).
    /// Texts are English, like every other pill alert.
    private func bluetoothAlert() -> IslandView.PillAlert? {
        let now = Date()
        if let last = lastBluetoothCheck, now.timeIntervalSince(last) < bluetoothCheckInterval {
            return nil
        }
        lastBluetoothCheck = now
        let current = Bluetooth.connectedDevices()
        var currentMap: [String: String] = [:]
        for device in current { currentMap[device.address] = device.name }
        guard let prev = prevBluetooth else {
            prevBluetooth = currentMap
            return nil
        }
        prevBluetooth = currentMap
        if let fresh = current.first(where: { prev[$0.address] == nil }) {
            let detail: IslandView.PillAlert.Detail
            if let battery = BluetoothBattery.fetch(deviceName: fresh.name) {
                let tint: NSColor = battery <= 20 ? .systemRed : .white
                detail = .text("Connected \u{00B7} \(battery)%", tint)
            } else {
                detail = .text("Connected", .white)
            }
            return IslandView.PillAlert(
                icon: .symbol(name: "bluetooth", fallback: "B", size: 20),
                message: fresh.name,
                detail: detail,
                until: Date() + pillAlertDuration,
                priority: 3)
        }
        if let goneAddress = prev.keys.first(where: { currentMap[$0] == nil }),
           let goneName = prev[goneAddress] {
            return IslandView.PillAlert(
                icon: .symbol(name: "bluetooth", fallback: "B", size: 20),
                message: goneName,
                detail: .text("Disconnected", .white),
                until: Date() + pillAlertDuration,
                priority: 3)
        }
        return nil
    }

    private func updatePillAlerts() {
        let battery = Battery.fetch()
        let caps = CapsLock.fetch()
        let volume = Volume.fetch()
        let brightness = Brightness.fetch()
        // Computed here (not inside the firing block below) so the
        // Bluetooth baseline advances even while a card is expanded;
        // the alert itself is presented only when no card is open.
        let btAlert = bluetoothAlert()
        // A charger plug/unplug also re-adjusts brightness (system
        // auto-adjust), which must not overwrite the charging
        // alert: remember the flip so brightness changes in the
        // next 2s are absorbed into the baseline, not alerted.
        if let battery, let prev = prevBattery, battery.charging != prev.charging {
            lastPowerChange = Date()
        }
        var fired = false
        if islandView.state != .expanded {
            if let alert = batteryAlert(for: battery) { fired = presentAlert(alert) || fired }
            if let alert = capsAlert(for: caps) { fired = presentAlert(alert) || fired }
            if let alert = volumeAlert(for: volume), presentAlert(alert) { fired = true; prevVolume = volume }
            if let powerChangeRecent = lastPowerChange, Date().timeIntervalSince(powerChangeRecent) < brightnessSuppressAfterPowerChange {
                // Suppressed: absorb the auto-adjust into the
                // baseline (a manual adjustment in this window is
                // also absorbed — a 2s, rare tradeoff for keeping
                // the charging alert visible). This also cancels a
                // held brightness change: it was the auto-adjust.
                if let brightness { prevBrightness = brightness }
                brightnessHoldSince = nil
            } else if let brightness, let prev = prevBrightness, abs(brightness - prev) >= 0.01 {
                // Hold before showing: the power flip is sometimes
                // polled a tick AFTER the brightness change, and
                // neither suppression (needs the flip first) nor
                // priority (only preempts after the flip) can prevent
                // a Brightness flash before Charging. Holding 0.75s
                // lets a following flip cancel it via the branch
                // above; a genuine manual change shows after the
                // hold with the latest level. A brightness alert
                // already on screen skips the hold, so drag
                // follow-ups stay responsive.
                let showingBrightness = islandView.pillAlert?.priority == 2
                    && Date() < (islandView.pillAlert?.until ?? .distantPast)
                if showingBrightness,
                   let alert = brightnessAlert(for: brightness), presentAlert(alert) {
                    fired = true; prevBrightness = brightness
                    brightnessHoldSince = nil
                } else if let since = brightnessHoldSince,
                          Date().timeIntervalSince(since) >= brightnessHold,
                          let alert = brightnessAlert(for: brightness), presentAlert(alert) {
                    fired = true; prevBrightness = brightness
                    brightnessHoldSince = nil
                } else if brightnessHoldSince == nil {
                    brightnessHoldSince = Date()
                }
                // Else: still holding, or presentAlert dropped it
                // (higher priority showing) — the hold stays expired
                // so the next tick retries, and the baseline is left
                // alone so the change resurfaces after expiry.
            } else {
                brightnessHoldSince = nil
            }
            if let alert = btAlert { fired = presentAlert(alert) || fired }
            if fired {
                animator.animate(to: windowSize(for: islandView.state))
            }
        }
        // Baselines: battery/caps advance every tick (edge
        // detection); volume/brightness advance on fire (level
        // tracking, so slow drags accumulate) — except while
        // expanded (sync them, dropping missed changes) and on
        // first read (initialize silently). A level change dropped
        // by presentAlert (lower priority than the displayed alert)
        // keeps its old baseline, so it resurfaces once the higher
        // alert expires instead of being lost.
        if let battery { prevBattery = battery }
        prevCaps = caps
        if islandView.state == .expanded || prevVolume == nil {
            if let volume { prevVolume = volume }
        }
        if islandView.state == .expanded || prevBrightness == nil {
            if let brightness { prevBrightness = brightness }
        }
        if islandView.state != .expanded, !fired,
           let alert = islandView.pillAlert, Date() >= alert.until {
            islandView.pillAlert = nil
            animator.animate(to: windowSize(for: islandView.state))
        }
    }

    /// Battery pill alert for a reading, or nil when it crosses
    /// nothing. Thresholds first, then plug/unplug, so a plug that
    /// lands exactly on 100% reports Fully Charged, not Charging.
    /// Nil on the first read (no previous reading to cross from).
    private func batteryAlert(for battery: (percent: Double, charging: Bool)?) -> IslandView.PillAlert? {
        guard let battery, let prev = prevBattery else { return nil }
        let message: String
        if battery.charging && battery.percent >= 1.0 && prev.percent < 1.0 {
            message = "Fully Charged"
        } else if battery.percent <= 0.20 && prev.percent > 0.20 {
            message = "Low Battery"
        } else if !prev.charging && battery.charging {
            message = "Charging"
        } else if prev.charging && !battery.charging {
            message = "Charger unplugged"
        } else {
            return nil
        }
        let tint = battery.charging ? NSColor.systemGreen
            : (battery.percent <= 0.20 ? NSColor.systemRed : NSColor.white)
        return IslandView.PillAlert(
            icon: .battery(percent: battery.percent, charging: battery.charging),
            message: message,
            detail: .text("\(Int(round(battery.percent * 100)))%", tint),
            until: Date() + pillAlertDuration,
            priority: 0)
    }

    /// Caps Lock pill alert on toggle, or nil when unchanged.
    /// Nil on the first read.
    private func capsAlert(for caps: Bool) -> IslandView.PillAlert? {
        guard let prev = prevCaps, caps != prev else { return nil }
        return IslandView.PillAlert(
            icon: .symbol(name: caps ? "capslock.fill" : "capslock", fallback: "A", size: 20),
            message: caps ? "Caps Lock On" : "Caps Lock Off",
            detail: nil,
            until: Date() + pillAlertDuration,
            priority: 3)
    }

    /// Volume pill alert on a level/mute change, or nil. Fires when
    /// the level moves at least 1% from the last fired value (so
    /// slow drags accumulate instead of never crossing a per-tick
    /// threshold) or mute flips. Nil on the first read.
    private func volumeAlert(for volume: (level: Double, muted: Bool)?) -> IslandView.PillAlert? {
        guard let volume, let prev = prevVolume else { return nil }
        guard volume.muted != prev.muted || abs(volume.level - prev.level) >= 0.01 else { return nil }
        if volume.muted {
            return IslandView.PillAlert(
                icon: .symbol(name: "speaker.slash", fallback: "♪", size: 20),
                message: "Muted",
                detail: nil,
                until: Date() + pillAlertDuration,
                priority: 1)
        }
        let symbol: String
        if volume.level <= 0 {
            symbol = "speaker"
        } else if volume.level < 0.5 {
            symbol = "speaker.wave.1"
        } else {
            symbol = "speaker.wave.2"
        }
        return IslandView.PillAlert(
            icon: .symbol(name: symbol, fallback: "♪", size: 20),
            message: "Volume",
            detail: .bar(volume.level),
            until: Date() + pillAlertDuration,
            priority: 1)
    }

    /// Brightness pill alert on a level change of at least 1% from
    /// the last fired value (same accumulation rule as volume), or
    /// nil. Nil on the first read. Note: with auto-brightness on,
    /// ambient-light changes fire too (they are real brightness
    /// changes); gating to key presses only is a follow-up if that
    /// gets noisy.
    private func brightnessAlert(for brightness: Double?) -> IslandView.PillAlert? {
        guard let brightness, let prev = prevBrightness,
              abs(brightness - prev) >= 0.01 else { return nil }
        return IslandView.PillAlert(
            icon: .symbol(name: "sun.max", fallback: "○", size: 20),
            message: "Brightness",
            detail: .bar(brightness),
            until: Date() + pillAlertDuration,
            priority: 2)
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
        // DynamicNotch lead-in: a line is shown 0.18s before its
        // timestamp, so the roll lands on the vocal instead of
        // after it. The per-track nudge (lyricsLines already
        // includes it) still applies on top if the user tuned one.
        let t = islandView.livePosition + 0.18
        var index: Int?
        for (i, entry) in lyricsLines.enumerated() where entry.time <= t {
            index = i
        }
        // Before the first vocal, index is nil and the panel showed
        // "Lyrics unavailable" (closed pill fell back to the title)
        // even though synced lines exist — the intro just has no
        // vocal yet. Show the first line immediately from the start
        // of the song instead of waiting for its timestamp: prev is
        // nil, current is line 0, next is line 1. Once its timestamp
        // passes, index stays 0, so nothing jumps or re-rolls.
        if index == nil, !lyricsLines.isEmpty {
            index = 0
        }
        islandView.updateLyricLines(
            prev: index.flatMap { $0 > 0 ? lyricsLines[$0 - 1].text : nil },
            current: index.map { lyricsLines[$0].text },
            next: index.flatMap { $0 + 1 < lyricsLines.count ? lyricsLines[$0 + 1].text : nil })
    }

    // MARK: - Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // Menu-bar (taskbar) icon: the Aura logo, not the "Aura"
        // text title. Falls back to the text title if the logo is
        // missing from the bundle (e.g. an old package script).
        if let path = Bundle.main.path(forResource: "AuraLogo", ofType: "png"),
           let logo = NSImage(contentsOfFile: path) {
            logo.size = NSSize(width: 18, height: 18)
            statusItem.button?.image = logo
            statusItem.button?.title = ""
        } else {
            statusItem.button?.title = "Aura"
        }
        let menu = NSMenu()
        let about = NSMenuItem(title: "About Aura Island", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        // One-click diagnostic: shows exactly what the sensors last
        // reported, so a detection problem can be diagnosed from a
        // screenshot without running from Terminal.
        let diag = NSMenuItem(title: "Detection Status", action: #selector(showDiagnostics), keyEquivalent: "")
        diag.target = self
        menu.addItem(diag)
        let auto = NSMenuItem(title: "Mode: Auto (follow the active one)", action: #selector(setAuto), keyEquivalent: "")
        auto.target = self
        menu.addItem(auto)
        let unpin = NSMenuItem(title: "Unpin session", action: #selector(unpinSession), keyEquivalent: "")
        unpin.target = self
        menu.addItem(unpin)
        let login = NSMenuItem(title: "Launch at login", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        // Manual lyric shift, per track, persisted: when a song's file
        // fits a slightly different recording, its lines sit a constant
        // amount early or late — one tap here moves the whole file.
        let nudgePlus = NSMenuItem(title: "Lyrics +1s (slower)", action: #selector(nudgeLyricPlus), keyEquivalent: "")
        nudgePlus.target = self
        menu.addItem(nudgePlus)
        let nudgeMinus = NSMenuItem(title: "Lyrics -1s (faster)", action: #selector(nudgeLyricMinus), keyEquivalent: "")
        nudgeMinus.target = self
        menu.addItem(nudgeMinus)
        let nudgeReset = NSMenuItem(title: "Reset this song's lyric offset", action: #selector(resetLyricNudge), keyEquivalent: "")
        nudgeReset.target = self
        menu.addItem(nudgeReset)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "Aura Island"
        alert.informativeText = "Dynamic island for Mac. Native, no webview.\nMedia: MediaRemote + Chrome extension bridge.\nLyrics: LRCLIB."
        alert.runModal()
    }

    @objc private func showDiagnostics() {
        let alert = NSAlert()
        alert.messageText = "Detection Status"
        let session = sessions.current
        let sessionText = session.map { "\($0.title) — \($0.artist) (\($0.isPlaying ? "playing" : "paused"))" } ?? "none"
        let tabText: String
        if let t = lastTabLog, !t.isEmpty {
            tabText = t
        } else {
            tabText = "none"
        }
        alert.informativeText = "Last MediaRemote: \(lastMediaLog ?? "no data yet")\nChrome tabs: \(tabText)\nActive session: \(sessionText)"
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
