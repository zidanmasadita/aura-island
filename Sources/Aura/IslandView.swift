import AppKit
import UserNotifications

/// Draws the island in Nusa's visual language: solid black card, white
/// type, iOS battery icon, live-looking waveform, album art, and
/// expanded music/lyrics pages modelled on Nusa's music card.
///
/// Layouts (flipped coordinates, y grows downward):
/// - zen (140x32): the idle face — two white eyes.
/// - compact: the closed notch, boxy with a concave bezel sweep
///   (12pt tuck) — plain music 180x32 (battery icon + clock + waveform),
///   lyrics mode 360x32 (note icon + lyric line).
/// - expanded, wide and short (never tall): music is the dense Nusa
///   music card (520x180: header, artwork, title/artist, progress,
///   controls, dots); opening lyrics only widens the card
///   (700x180, same height) and compresses the music part, putting
///   the lyrics panel on the right, like Nusa; sources is the picker
///   on the 640x220 footprint; pomodoro is the timer on 640x180;
///   todo is the task list on 640x220; water is the intake tracker
///   on 640x180. The bubble toggles
///   music/lyrics, three-finger swipe moves to the previous/next
///   section, and the dots jump sections.
/// - closed pill in lyrics mode: once the card was closed from the
///   lyrics page, the inactive pill shows a note icon + the current
///   lyric line — never clock, battery icon, or waveform — until the
///   card is next closed from the music page.
///
/// Position is realtime, not sensor-bound: the sensor's elapsed value
/// (Chrome's especially) is a snapshot that does not advance while a
/// song plays, which is why progress used to sit still until the pill
/// was reopened. The view anchors each sensor reading and advances
/// the displayed position by wall clock between readings (see
/// livePosition), so the bar moves smoothly at the 10x/second redraw
/// while playing, and only re-anchors on track/state change, a seek,
/// or when the sensor runs ahead of the display.
/// Pasteboard writer for a tray drag-out (DynamicNotch-style:
/// a dedicated writer instead of NSURL). Provides the file URL
/// as .fileURL and .URL so Finder and other apps accept the drop.
private final class AuraTrayPasteboardWriter: NSObject, NSPasteboardWriting {
    private let url: URL
    init(url: URL) { self.url = url.standardizedFileURL }
    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        [.fileURL, .URL]
    }
    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        switch type {
        case .fileURL, .URL:
            return url.absoluteString
        default:
            return nil
        }
    }
}

final class IslandView: NSView, NSDraggingSource, NSTextFieldDelegate {
    var state: IslandState = .zen {
        didSet {
            // Remember whether the card was on lyrics when it closed:
            // the inactive pill then shows lyrics instead of clock/
            // battery/waveform, until the card is next closed from the
            // music page. Only a real exit from expanded snapshots this
            // — redundant sets (hover re-asserting compact) must not
            // clear it.
            if oldValue == .expanded && state != .expanded {
                lyricsMode = (cardPage == .lyrics)
            }
            // The page is NOT reset on close: reopening lands back on
            // the last page that was open (tray, todo, water, ...),
            // not back on music. A stale sources page is already
            // handled by currentPage (it falls back to music when
            // sessions drop to one).
            needsDisplay = true
        }
    }
    /// True when the card was last closed from the lyrics page: the
    /// inactive pill then shows lyrics, not clock/battery/waveform.
    private var lyricsMode = false
    /// Read by AppDelegate's overlap hiding: a pill in lyrics mode
    /// is never hidden, by request — the user opened lyrics
    /// precisely to keep seeing the lyric line on the closed pill.
    var isLyricsPill: Bool { lyricsMode }
    /// True while a card-modal dialog, picker, or menu is open.
    /// AppDelegate skips the leave-the-island collapse while this is
    /// set: moving the mouse down to the dialog is not leaving the
    /// card, and collapsing mid-modal used to freeze the window at
    /// the expanded size (the animator timer does not fire in modal
    /// mode) while the state already said closed - a 640x220 window
    /// drawing closed content with a height/2 corner radius, the
    /// giant-curve pill in the bug report. Cleared when the
    /// modal closes. Pickers/menus deliberately do NOT re-sync
    /// hover afterwards (see presentCardModal): after a pick
    /// the card stays open on purpose, and the next real hover
    /// exit collapses it normally.
    var isShowingModal = false
    var session: DisplaySession? {
        didSet {
            updatePositionAnchor()
            needsDisplay = true
        }
    }
    var lyricPrev: String?
    var lyricCurrent: String?
    var lyricNext: String?

    // MARK: - Lyrics slot-machine roll

    /// A slot-machine reel for the lyrics panel: the panel is a fixed
    /// window, and on a line change the strip of lines rolls upward
    /// through it — the previously active line moves up and out the
    /// top, the upcoming line rolls up from below into the center
    /// window, where it lands focused (bold, full opacity). The old
    /// "rise" (swap lines, then slide the new block 26px) did not
    /// read as a reel because the lines swapped instantly; here the
    /// lines themselves travel, continuously, with no swap mid-roll.
    ///
    /// How it works: AppDelegate calls updateLyricLines (never the
    /// three vars directly). On a one-line advance while the lyrics
    /// page is visible, the old triple (A=prev, B=current, C=next)
    /// and the new triple (B, C, D) are laid out as centered blocks;
    /// the roll strip [A, B, C, D] starts at the old block's
    /// positions and translates up by T, where T is chosen so C (the
    /// focus line) lands exactly on its new centered position. B and
    /// D may settle a few px at commit (dim lines, only when wrapping
    /// is asymmetric — typically 0-5px); C is always exact. Focus
    /// transfers during the roll: B shrinks (bold 19 -> 15 size) and
    /// dims (1.0 -> 0.35), C grows (15 -> bold 19 size) and brightens
    /// (0.45 -> 1.0), A fades out (0.35 -> 0), D fades in (0 -> 0.45).
    /// Sizes change via a scale transform about each line's center
    /// (never by swapping fonts mid-roll), so wrapped lines never
    /// reflow during the roll; C is drawn with its NEW font (bold 19)
    /// so its wrapped lines already match the commit. The divider
    /// stays fixed — it is the window's frame, not part of the reel.
    ///
    /// A change arriving mid-roll discards the in-flight strip and
    /// starts a fresh roll from the stored triple (which is already
    /// the previous roll's target) — a small jump, but only for fast
    /// lyrics, and a new roll starts immediately. A seek jump (new
    /// current is not the old next) does not roll at all — it jumps,
    /// which is correct for a skip.
    private struct RollLine {
        let lines: [String]
        let font: NSFont
        let startTop: CGFloat
        let height: CGFloat
        let scaleFrom: CGFloat
        let scaleTo: CGFloat
        let alphaFrom: CGFloat
        let alphaTo: CGFloat
    }
    private var rollLines: [RollLine] = []
    private var rollDistance: CGFloat = 0
    private var rollProgress: CGFloat = 0 // eased 0...1, for drawing
    private var rollStart: Date = Date()
    private var rollTimer: Timer?
    private let rollDuration: TimeInterval = 0.7
    private var isRolling: Bool { rollTimer != nil }

    /// Single entry point for lyric-line updates (AppDelegate calls
    /// this, never the three vars directly). Rolls on a one-line
    /// advance while the page is visible; otherwise just stores the
    /// lines. A tick with the same line leaves an in-flight roll
    /// alone — it finishes on its own and must not be aborted.
    func updateLyricLines(prev: String?, current: String?, next: String?) {
        // Defense: a lyric line must never contain a newline —
        // drawText renders it as extra visual rows, which broke the
        // closed pill (several rows in 32px) and overlapped the
        // panel's wrapped lines. parsePlain now splits lines, but
        // normalize here too so no source can ever reintroduce one.
        let prev = prev?.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let current = current?.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let next = next?.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let oldPrev = lyricPrev, oldCurrent = lyricCurrent, oldNext = lyricNext
        lyricPrev = prev
        lyricCurrent = current
        lyricNext = next
        guard current != oldCurrent else { return }
        // Changed: any in-flight roll is stale (its target is no
        // longer current) — cancel it, then maybe start a new one.
        cancelLyricRoll()
        guard let oldCurrent, let current, oldNext == current,
              state == .expanded, currentPage == .lyrics else {
            needsDisplay = true
            return
        }
        startLyricRoll(oldPrev: oldPrev, oldCurrent: oldCurrent, oldNext: oldNext,
                       newPrev: prev, newCurrent: current, newNext: next)
        needsDisplay = true
    }

    /// Clears the lyrics (no session, track change, no lines) and
    /// cancels any in-flight roll so stale lines never keep rolling.
    func clearLyricLines() {
        cancelLyricRoll()
        lyricPrev = nil
        lyricCurrent = nil
        lyricNext = nil
        needsDisplay = true
    }

    private func cancelLyricRoll() {
        rollTimer?.invalidate()
        rollTimer = nil
        rollLines = []
        rollProgress = 0
    }

    private func lyricLineHeight(_ font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }

    /// Centers a block of lyric lines in the panel (28..158, 130 tall)
    /// and returns each line's top Y, height, and the inter-line gap.
    /// Shared by the static panel and the roll, so both agree on
    /// positions.
    private func lyricBlockLayout(for lines: [(text: String, font: NSFont)]) -> (tops: [CGFloat], heights: [CGFloat], gap: CGFloat) {
        let width: CGFloat = 336
        var heights: [CGFloat] = []
        for line in lines {
            let w = wrappedLines(line.text, font: line.font, width: width, maxLines: 2)
            heights.append(CGFloat(w.count) * lyricLineHeight(line.font))
        }
        let textHeight = heights.reduce(0, +)
        let gapCount = max(0, lines.count - 1)
        let gap: CGFloat = gapCount > 0 ? min(10, max(0, (130 - textHeight) / CGFloat(gapCount))) : 0
        let blockTop = 28 + (130 - (textHeight + gap * CGFloat(gapCount))) / 2
        var tops: [CGFloat] = []
        var y = blockTop
        for h in heights {
            tops.append(y)
            y += h + gap
        }
        return (tops, heights, gap)
    }

    private func startLyricRoll(oldPrev: String?, oldCurrent: String, oldNext: String?,
                                newPrev: String?, newCurrent: String, newNext: String?) {
        cancelLyricRoll()
        let prevFont = NSFont.systemFont(ofSize: 15)
        let currentFont = NSFont.boldSystemFont(ofSize: 19)
        // Old block: [A?, B, C]; new block: [B, C, D?] (a one-line
        // advance, guaranteed by updateLyricLines: new current is the
        // old next, so new prev is the old current).
        var oldLines: [(text: String, font: NSFont)] = []
        if let oldPrev { oldLines.append((oldPrev, prevFont)) }
        oldLines.append((oldCurrent, currentFont))
        if let oldNext { oldLines.append((oldNext, prevFont)) }
        var newLines: [(text: String, font: NSFont)] = []
        if let newPrev { newLines.append((newPrev, prevFont)) }
        newLines.append((newCurrent, currentFont))
        if let newNext { newLines.append((newNext, prevFont)) }
        let oldLayout = lyricBlockLayout(for: oldLines)
        let newLayout = lyricBlockLayout(for: newLines)
        // C (the focus line) is last in the old block and at index 1
        // in the new block (after B, the new prev).
        let oldCIndex = oldLines.count - 1
        let newCIndex = 1
        guard oldCIndex >= 0, newCIndex < newLayout.tops.count else { return }
        let distance = oldLayout.tops[oldCIndex] - newLayout.tops[newCIndex]
        guard distance > 0 else { return }
        // Strip [A?, B, C, D?]: A and B keep their old fonts, C takes
        // its NEW font (bold 19) so its wrapped lines already match
        // the commit (no line-count snap for the focus line), D its
        // new font. Scales make the rendered sizes travel between the
        // old and new sizes: B bold 19 -> prev 15, C next 15 -> bold 19.
        var strip: [RollLine] = []
        var oldIndex = 0
        if let oldPrev {
            let w = wrappedLines(oldPrev, font: prevFont, width: 336, maxLines: 2)
            strip.append(RollLine(lines: w, font: prevFont,
                                  startTop: oldLayout.tops[oldIndex], height: oldLayout.heights[oldIndex],
                                  scaleFrom: 1.0, scaleTo: 1.0, alphaFrom: 0.35, alphaTo: 0.0))
            oldIndex += 1
        }
        let bWrapped = wrappedLines(oldCurrent, font: currentFont, width: 336, maxLines: 2)
        strip.append(RollLine(lines: bWrapped, font: currentFont,
                              startTop: oldLayout.tops[oldIndex], height: oldLayout.heights[oldIndex],
                              scaleFrom: 1.0, scaleTo: 15.0 / 19.0, alphaFrom: 1.0, alphaTo: 0.35))
        oldIndex += 1
        // C: old position (as next), new font (bold 19), growing.
        let cWrapped = wrappedLines(newCurrent, font: currentFont, width: 336, maxLines: 2)
        let cHeight = CGFloat(cWrapped.count) * lyricLineHeight(currentFont)
        let cTop = oldLayout.tops[oldIndex]
        strip.append(RollLine(lines: cWrapped, font: currentFont,
                              startTop: cTop, height: cHeight,
                              scaleFrom: 15.0 / 19.0, scaleTo: 1.0, alphaFrom: 0.45, alphaTo: 1.0))
        // D starts below C's roll block (old gap), fading in from
        // below the window.
        if let newNext {
            let dWrapped = wrappedLines(newNext, font: prevFont, width: 336, maxLines: 2)
            let dHeight = CGFloat(dWrapped.count) * lyricLineHeight(prevFont)
            strip.append(RollLine(lines: dWrapped, font: prevFont,
                                  startTop: cTop + cHeight + oldLayout.gap, height: dHeight,
                                  scaleFrom: 1.0, scaleTo: 1.0, alphaFrom: 0.0, alphaTo: 0.45))
        }
        rollLines = strip
        rollDistance = distance
        rollProgress = 0
        rollStart = Date()
        rollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.stepLyricRoll(timer: timer)
        }
        // Common modes: a mouse drag or menu tracking must never
        // stall the reel mid-spin (a default-mode timer pauses during
        // event tracking, which reads as a stutter).
        if let timer = rollTimer { RunLoop.main.add(timer, forMode: .common) }
    }

    private func stepLyricRoll(timer: Timer) {
        let p = min(1.0, Date().timeIntervalSince(rollStart) / rollDuration)
        // easeInOutCubic: the reel spins up and settles, like a real
        // slot machine, instead of lurching or stopping dead.
        rollProgress = p < 0.5 ? 4.0 * p * p * p : 1.0 - pow(-2.0 * p + 2.0, 3.0) / 2.0
        if p >= 1.0 {
            rollTimer?.invalidate()
            rollTimer = nil
            rollLines = []
            rollProgress = 0
        }
        needsDisplay = true
    }
    var sessionsForPicker: [DisplaySession] = []
    var pinnedId: String?
    var batteryPercent: Double?
    var batteryCharging: Bool = false

    /// A live pill alert: a temporary horizontally-widened pill
    /// (360x32, height unchanged) showing one trigger event, then
    /// shrinking back when it expires. Set and cleared by AppDelegate
    /// on trigger edges (battery, caps lock, volume, brightness);
    /// only one alert shows at a time — a newer event replaces a
    /// live one (timer restarts).
    struct PillAlert {
        /// How the icon is drawn: the custom iOS battery icon
        /// (battery events, snapshot values) or an SF Symbol in a
        /// square slot of its size (everything else).
        enum Icon {
            case battery(percent: Double, charging: Bool)
            case symbol(name: String, fallback: String, size: CGFloat)
        }
        let icon: Icon
        /// Trailing content: a tinted text (battery percent) or a
        /// level bar (volume, brightness). Nil for toggles (caps
        /// lock, mute).
        enum Detail {
            case text(String, NSColor)
            case bar(Double)
        }
        let message: String
        let detail: Detail?
        let until: Date
        /// Display priority, lower wins: 0 battery, 1 volume,
        /// 2 brightness, 3 caps lock and anything else. A new alert
        /// preempts a displayed one only when its priority is equal
        /// or higher; a lower-priority event is dropped (level
        /// alerts keep their old baseline, so they resurface once
        /// the higher alert expires - see presentAlert).
        let priority: Int
    }
    var pillAlert: PillAlert? {
        didSet { needsDisplay = true }
    }

    /// The expanded card's current page. View-internal display state;
    /// the dots, three-finger swipe, and bubble icon switch it, nothing else reads it.
    private var cardPage: CardPage = .music {
        didSet {
            if cardPage != .todo { cancelTodoEditing() }
            if cardPage == .water { ensureWaterStarted() }
            if state == .expanded { onExpandedSizeChanged?(expandedSize) }
            needsDisplay = true
        }
    }

    /// Window size for the expanded card, per page. The music card is
    /// the dense 520x180 card (shorter but packed: header, 56px cover,
    /// progress, controls, dots); lyrics only widens it to 700x180 —
    /// the height does not change, so switching pages never moves
    /// the music part vertically; sources stays 640x220; pomodoro is
    /// 640x180 (ring + timer + mode pills, like the reference); todo
    /// is 640x220 (task rows + add row, like sources); water is
    /// 640x180 (intake + progress + hourly chart, like Nusa's
    /// Water Reminder). tray is 640x280 (grid 4x2 + share, DynamicNotch-style).
    var expandedSize: NSSize {
        switch currentPage {
        case .music: return NSSize(width: 520, height: 180)
        case .lyrics: return NSSize(width: 700, height: 180)
        case .pomodoro: return NSSize(width: 640, height: 180)
        case .todo: return NSSize(width: 640, height: 220)
        case .water: return NSSize(width: 640, height: 180)
        case .tray: return NSSize(width: 640, height: 280)
        case .removeBg: return NSSize(width: 640, height: 280)
        case .convert: return NSSize(width: 640, height: 280)
        case .sources: return NSSize(width: 640, height: 220)
        }
    }

    /// Size of the closed (compact/split) pill: the plain music pill
    /// is 180x32 — a bit wider than the idle pill (140x32) so the
    /// battery icon + clock + waveform are not crammed (160 was too
    /// tight once the battery icon replaced the ring); the
    /// lyrics-mode pill stays wider (360x32) so the lyric line
    /// still fits. A live pomodoro keeps the 160x32 pill (its ring +
    /// countdown are roomy there), so starting/stopping it resizes
    /// the pill between 160 and 180 (animated, like lyrics mode).
    /// Compact lyrics pill layout: mascot left, the line centered
    /// in the remaining space.
    private var lyricsPillFont: NSFont { NSFont.systemFont(ofSize: 13, weight: .medium) }
    private let lyricsMascotDrawSize: CGFloat = 26
    private let lyricsTextX: CGFloat = 48 // 12 pad + 26 mascot + 10 gap
    private let lyricsTextRightPad: CGFloat = 16

    /// Width the closed lyrics pill wants. Fixed 360 unless the
    /// dynamic-width option is on, in which case it hugs the line —
    /// clamped so a one-word line never collapses the pill and a
    /// very long line never stretches it across the screen.
    var lyricsPillWidth: CGFloat {
        guard AuraSettings.shared.lyricsDynamicWidth else { return 360 }
        let line = lyricCurrent ?? session?.title ?? ""
        let textW = (line as NSString).size(withAttributes: [.font: lyricsPillFont]).width
        return min(max(lyricsTextX + min(textW, 380) + lyricsTextRightPad, 170), 444)
    }

    /// AppDelegate uses this instead of the fixed state size for
    /// compact/split.
    var closedSize: NSSize {
        if isPomodoroActive { return NSSize(width: 160, height: 32) }
        return lyricsMode ? NSSize(width: lyricsPillWidth, height: 32) : NSSize(width: 180, height: 32)
    }

    enum CardPage { case music, lyrics, pomodoro, todo, water, tray, removeBg, convert, sources }

    /// Sections the dots and three-finger swipe offer: music +
    /// pomodoro + todo + water + tray always, sources only when there is more than
    /// one session to choose from. Lyrics is NOT a section — it is a
    /// panel of the music section (via the bubble), so swipe and dots
    /// never land on it; that was the old chevron's mistake (it
    /// jumped to lyrics).
    private var availableSections: [CardPage] {
        let settings = AuraSettings.shared
        let ordered = settings.sectionOrder.compactMap { key -> CardPage? in
            guard let page = AuraSettings.toggleableSections.first(where: { "\($0)" == key }) else { return nil }
            return settings.isSectionEnabled(page) ? page : nil
        }
        var sections = ordered
        if sessionsForPicker.count > 1 { sections.append(.sources) }
        return sections.isEmpty ? [.music] : sections
    }

    /// The page actually drawn (lyrics included). Sources falls back
    /// to music when it stops being available (sessions drop to one).
    private var currentPage: CardPage {
        var page = cardPage
        if page == .sources && sessionsForPicker.count <= 1 { page = .music }
        if page == .lyrics && !AuraSettings.shared.lyricsEnabled { page = .music }
        if page != .lyrics && !availableSections.contains(page) {
            page = availableSections.first ?? .music
        }
        return page
    }

    /// The section the dots/swipe act on: lyrics counts as music
    /// (its panel belongs to the music section).
    private var sectionForDots: CardPage {
        currentPage == .lyrics ? .music : currentPage
    }

    /// Rects for the interactive elements of the expanded card.
    /// The bubble toggles music/lyrics. Sections switch by dots or
    /// three-finger swipe (the side arrows were removed: they
    /// overlapped content even with a gutter, and the MacBook way is
    /// swipe). The bubble sits further right than the card edge so
    /// it does not hug the corner. Both music pages share the dense
    /// row (controls at y140, bubble y126).
    private var musicBubbleRect: NSRect { NSRect(x: 42, y: 126, width: 28, height: 28) }

    // MARK: - Realtime position (aura-windows MediaTracker port)

    /// Monotonic realtime position tracker, ported from aura-windows
    /// `MediaTracker` (the reason Windows lyrics stay locked to the
    /// vocal). The old Mac anchor had three sync bugs:
    /// 1. It re-anchored to the raw reading at `Date()` of ARRIVAL, so
    ///    every osascript round-trip (100-400ms) and every stale
    ///    MediaRemote snapshot became a permanent lag.
    /// 2. It ignored a display that ran AHEAD of the sensor (only
    ///    "sensor ahead > 2s" re-anchored), so drift never corrected.
    /// 3. The 2s deadband let lyrics sit up to 2s off before fixing.
    /// Now: each reading is age-compensated (`now - sampledAt`), the
    /// display integrates on a monotonic clock (systemUptime, immune to
    /// wall-clock changes), small drift (< 1.0s) is eased in gradually
    /// (no visible jump), and a real seek (> 1.0s) snaps immediately.
    /// A frozen snapshot (sensor value not advancing while playing, no
    /// timestamp) is never allowed to drag the display backwards.
    private var positionAnchor: (key: String, position: Double, at: TimeInterval, playing: Bool)?
    private var lastRawReading: (position: Double, sampledAt: Date)?

    private static func monotonicNow() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Position to display right now (seconds).
    var livePosition: Double {
        guard let s = session else { return 0 }
        guard let a = positionAnchor, a.key == "\(s.title)|\(s.artist)" else { return s.position }
        var p = a.position
        if a.playing { p += Self.monotonicNow() - a.at }
        if s.duration > 0 { p = min(p, s.duration) }
        return max(0, p)
    }

    private func updatePositionAnchor() {
        guard let s = session else {
            positionAnchor = nil
            lastRawReading = nil
            return
        }
        let key = "\(s.title)|\(s.artist)"
        let now = Self.monotonicNow()
        // Sensor value advanced to "this instant" (Windows: Now - LastUpdatedTime).
        let age = s.isPlaying ? max(0, min(5, Date().timeIntervalSince(s.sampledAt))) : 0
        var reported = s.position + age
        if s.duration > 0 { reported = min(reported, s.duration) }

        guard let a = positionAnchor, a.key == key, a.playing == s.isPlaying else {
            // New track, first reading, or play/pause flip: hard anchor.
            positionAnchor = (key: key, position: reported, at: now, playing: s.isPlaying)
            lastRawReading = (s.position, s.sampledAt)
            return
        }

        // Ignore a re-delivery of the same sample (artwork attach,
        // extension tab refresh): it carries no new timing information.
        if let last = lastRawReading, last.sampledAt == s.sampledAt, last.position == s.position {
            return
        }

        let live = livePosition
        let drift = reported - live
        // Sensor frozen: raw value did not move between two different
        // samples while playing (a snapshot without timestamp).
        let frozen = s.isPlaying && (lastRawReading.map { abs($0.position - s.position) < 0.01 } ?? false)
        // Raw jumped relative to the wall time between samples = a seek.
        let seek: Bool = {
            guard let last = lastRawReading else { return false }
            let wall = s.isPlaying ? s.sampledAt.timeIntervalSince(last.sampledAt) : 0
            return abs((s.position - last.position) - wall) > 1.5
        }()
        lastRawReading = (s.position, s.sampledAt)

        if seek || drift > 1.0 || (drift < -1.0 && !frozen) {
            positionAnchor = (key: key, position: reported, at: now, playing: s.isPlaying)
        } else if !frozen && abs(drift) > 0.04 {
            // Ease 35% of the residual drift per reading: converges in a
            // few polls without a visible jump in the lyrics reel.
            positionAnchor = (key: key, position: live + drift * 0.35, at: now, playing: s.isPlaying)
        }
    }

    /// Progress-bar seek drag in flight: the bar rect being dragged
    /// and the track duration captured at press. While set, the bar
    /// shows the dragged position instead of the live one.
    private var progressDrag: (bar: NSRect, duration: Double)?
    /// Dragged position preview (seconds), shown by the bar while a
    /// seek drag runs. Nil otherwise.
    private var seekPreviewPosition: Double?

    /// Hit rect for the music progress bar (generous vertically so
    /// the 4pt bar is easy to grab). Geometry matches drawProgress:
    /// barX 96, y 104, 16 tall; width 324 (music) or 164 (lyrics).
    private func progressBarRect(lyricsOpen: Bool) -> NSRect {
        NSRect(x: 96, y: 104, width: lyricsOpen ? 164 : 324, height: 16)
    }

    /// Begin a progress-bar seek drag if the point is on the bar.
    /// Returns true when a drag started (caller returns).
    private func startProgressDrag(at point: CGPoint, lyricsOpen: Bool) -> Bool {
        guard let s = session, s.duration > 0 else { return false }
        let bar = progressBarRect(lyricsOpen: lyricsOpen)
        guard bar.contains(point) else { return false }
        let fraction = min(1.0, max(0.0, (point.x - bar.minX) / bar.width))
        progressDrag = (bar: bar, duration: s.duration)
        seekPreviewPosition = fraction * s.duration
        needsDisplay = true
        return true
    }

    /// Called after a seek lands: re-anchor the displayed position
    /// to the seek target so the bar stays there instead of snapping
    /// back until the next sensor poll (the poll's jump detection
    /// then re-anchors to the player's own reading).
    func noteSeekApplied(_ seconds: Double) {
        guard let s = session else { return }
        positionAnchor = (key: "\(s.title)|\(s.artist)", position: seconds, at: Self.monotonicNow(), playing: s.isPlaying)
        needsDisplay = true
    }

    /// Which control (0 = previous, 1 = play/pause, 2 = next) a point hits,
    /// given the control centers and the row's y range. Nil outside.
    private func controlHit(at point: CGPoint, centers: [CGFloat], yMin: CGFloat, yMax: CGFloat,
                            halfWidth: CGFloat = 20) -> Int? {
        guard point.y >= yMin && point.y <= yMax else { return nil }
        for (i, cx) in centers.enumerated() {
            if point.x >= cx - halfWidth && point.x <= cx + halfWidth { return i }
        }
        return nil
    }

    /// Visual rects of the page dots, a VERTICAL column on the
    /// right edge (navigation is vertical scroll, so the indicator
    /// is vertical too): active = tall dash (6x16), rest = dots
    /// Width/height the content is drawn in. While a tray spring
    /// runs, draw() maps base coords to window coords (headroom
    /// window, e.g. 736 wide for a 640 card), so any element anchored
    /// to bounds.width/height would land too far right / low — the
    /// right side of the pill looking wider than the left during a
    /// drag, while the left (fixed-coord content) stays correct.
    /// At rest the spring scale is 1.0 and base == bounds.
    /// True while the window is headroom-sized for the tray (drag
    /// hover or bounce running) but larger than the base card.
    private var isTrayHeadroom: Bool {
        guard state == .expanded, trayDropHighlight || isTrayBouncing else { return false }
        let base = unbulgedSize(for: state)
        return bounds.width > base.width + 0.5 || bounds.height > base.height + 0.5
    }
    private var drawingWidth: CGFloat {
        let s = state == .expanded ? traySpringScale(now: Date()) : 1.0
        return s != 1.0 || isTrayHeadroom ? unbulgedSize(for: state).width : bounds.width
    }
    private var drawingHeight: CGFloat {
        let s = state == .expanded ? traySpringScale(now: Date()) : 1.0
        return s != 1.0 || isTrayHeadroom ? unbulgedSize(for: state).height : bounds.height
    }
    /// Inverse of draw()'s spring transform: a mouse/drag point in
    /// window coords back to base coords, so hit tests and
    /// cursor-following drawing (badge, glow) sit on the same
    /// coordinates as the fixed-coord content.
    private func basePoint(from windowPoint: NSPoint) -> NSPoint {
        let s = state == .expanded ? traySpringScale(now: Date()) : 1.0
        let base = unbulgedSize(for: state)
        if s != 1.0 {
            return NSPoint(x: (windowPoint.x - bounds.midX) / s + base.width / 2,
                           y: windowPoint.y / s)
        }
        // Headroom window with scale 1: draw() centres the base pill
        // (translate only, no scale), so invert that translate.
        if isTrayHeadroom {
            return NSPoint(x: windowPoint.x - (bounds.midX - base.width / 2),
                           y: windowPoint.y)
        }
        return windowPoint
    }
    /// (6x6), each centered in an 18pt slot so the column never
    /// shifts when the active section changes. Drawn 18pt from the
    /// right edge (x W-24..W-18) so it never hugs the edge; the
    /// hit column is wider (x W-32..W-10) than the drawn marks.
    /// Content keeps clear: the lyrics panel ends at W-40 and the
    /// todo pills at W-40, so neither overlaps the hit column.
    private func dotRects() -> [NSRect] {
        let pages = availableSections
        let active = pages.firstIndex(of: sectionForDots) ?? 0
        let top = dotColumnTop
        let x = drawingWidth - 24
        return pages.indices.map { i in
            let y = top + CGFloat(i) * 18
            return i == active
                ? NSRect(x: x, y: y + 1, width: 6, height: 16)
                : NSRect(x: x, y: y + 6, width: 6, height: 6)
        }
    }

    /// Top of the vertical dot column, centered on the card height.
    private var dotColumnTop: CGFloat {
        (drawingHeight - CGFloat(availableSections.count) * 18) / 2
    }

    private func dotIndex(at point: CGPoint) -> Int? {
        // Mouse points arrive in window coords; dot rects are drawn
        // in base coords, so convert first (identity at rest).
        let p = basePoint(from: point)
        guard p.x >= drawingWidth - 32 && p.x <= drawingWidth - 10 else { return nil }
        let top = dotColumnTop
        guard p.y >= top && p.y <= top + CGFloat(availableSections.count) * 18 else { return nil }
        let index = Int((p.y - top) / 18)
        return (index >= 0 && index < availableSections.count) ? index : nil
    }

    var onHoverChanged: ((Bool) -> Void)?
    var onClicked: (() -> Void)?
    var onSessionPicked: ((String) -> Void)?
    var onUnpin: (() -> Void)?
    var onPlayPause: (() -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    /// Progress-bar seek commit (seconds into the track).
    var onSeek: ((Double) -> Void)?
    /// Fired when the expanded card's page changes, so the window can
    /// resize to the page (music 520, pomodoro/todo/sources 640, lyrics 700 wide).
    /// AppDelegate ignores it unless expanded.
    var onExpandedSizeChanged: ((NSSize) -> Void)?

    override var isFlipped: Bool { true }

    private var trackingArea: NSTrackingArea?
    /// Last mouse position in view coords while over the card
    /// (nil when the cursor is outside). Music-card buttons
    /// and the progress bar read it for their hover state.
    private var hoverPoint: CGPoint?
    /// Which music-card region the cursor is over. Only
    /// region CHANGES trigger redraws, not every move.
    private var hoverRegion: MusicHoverRegion = .none
    private enum MusicHoverRegion: Hashable {
        case none, bubble, control(Int), progress
    }
    /// Animated zoom per music button (1.0 = normal, 1.2 =
    /// hovered). A 60fps timer eases each value toward its
    /// target over 0.18s, so a button swells and shrinks
    /// smoothly instead of popping between sizes.
    private var buttonZoomCurrent: [MusicHoverRegion: CGFloat] = [:]
    private var buttonZoomFrom: [MusicHoverRegion: CGFloat] = [:]
    private var buttonZoomStart: Date?
    private var buttonZoomTimer: Timer?
    private var waveTimer: Timer?
    private var wavePhase: Double = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Drag-and-drop file tray: the island accepts file URLs.
        registerForDraggedTypes([.fileURL])
        // Waveform animation: redraw ~10x/second while something plays.
        // The bars are decorative (like Nusa's: no real audio analysis),
        // driven by a sine phase, flat when paused.
        waveTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, self.session?.isPlaying == true else { return }
            self.wavePhase += 1
            self.needsDisplay = true
        }
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
            owner: self,
            userInfo: nil
        )
        if let trackingArea {
            addTrackingArea(trackingArea)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        hoverPoint = nil
        setHoverRegion(.none)
        needsDisplay = true
        onHoverChanged?(false)
    }

    override func mouseMoved(with event: NSEvent) {
        guard state == .expanded else {
            hoverPoint = nil
            hoverRegion = .none
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        hoverPoint = point
        setHoverRegion(musicHoverRegion(at: point))
    }

    /// Hover-region change: retarget every button zoom (the
    /// hovered button to 1.2, the rest to 1.0) and animate.
    private func setHoverRegion(_ region: MusicHoverRegion) {
        guard region != hoverRegion else { return }
        hoverRegion = region
        buttonZoomFrom = buttonZoomCurrent
        buttonZoomStart = Date()
        guard buttonZoomTimer == nil else { return }
        buttonZoomTimer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self, let start = self.buttonZoomStart else {
                self?.buttonZoomTimer?.invalidate()
                self?.buttonZoomTimer = nil
                return
            }
            let p = min(1.0, Date().timeIntervalSince(start) / 0.18)
            let e = 1.0 - pow(1.0 - p, 3.0)
            for key in [MusicHoverRegion.bubble, .control(0), .control(1), .control(2)] {
                let target: CGFloat = (key == self.hoverRegion) ? 1.2 : 1.0
                let from = self.buttonZoomFrom[key] ?? 1.0
                self.buttonZoomCurrent[key] = from + (target - from) * e
            }
            self.needsDisplay = true
            if p >= 1.0 {
                self.buttonZoomTimer?.invalidate()
                self.buttonZoomTimer = nil
                self.buttonZoomStart = nil
            }
        }
        if let buttonZoomTimer { RunLoop.main.add(buttonZoomTimer, forMode: .common) }
        needsDisplay = true
    }

    /// Music-card hover region for a view point. Only the
    /// music and lyrics pages have hoverable controls, and
    /// only with a real session (placeholder buttons are
    /// inert, so they never highlight).
    private func musicHoverRegion(at point: CGPoint) -> MusicHoverRegion {
        guard state == .expanded, session != nil,
              currentPage == .music || currentPage == .lyrics else { return .none }
        if AuraSettings.shared.lyricsEnabled, musicBubbleRect.contains(point) { return .bubble }
        let centers: [CGFloat] = currentPage == .lyrics ? [118, 170, 222] : [208, 260, 312]
        if let hit = controlHit(at: point, centers: centers, yMin: 130, yMax: 150) {
            return .control(hit)
        }
        if progressBarRect(lyricsOpen: currentPage == .lyrics).contains(point) {
            return .progress
        }
        return .none
    }

    override func mouseDown(with event: NSEvent) {
        guard state == .expanded else {
            onClicked?()
            return
        }
        // While the todo input is active, the card is captured by
        // editing: clicks on dots, rows, or the add pill are ignored
        // (clicks inside the field itself go to the field subview
        // and never reach here). Editing ends only via Enter,
        // Escape, or focus loss — never via a stray card click.
        if todoEditingField != nil {
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        // Page dots (every card page has them now).
        if let index = dotIndex(at: point) {
            let sections = availableSections
            if index < sections.count {
                cardPage = sections[index]
                needsDisplay = true
            }
            return
        }
        switch currentPage {
        case .music:
            // Speech bubble opens lyrics (the card extends horizontally).
            // Sections switch by dots or three-finger swipe (no arrows).
            if AuraSettings.shared.lyricsEnabled, musicBubbleRect.contains(point) {
                cardPage = .lyrics
                needsDisplay = true
                return
            }
            if let hit = controlHit(at: point, centers: [208, 260, 312], yMin: 130, yMax: 150) {
                performControl(hit)
                return
            }
            if startProgressDrag(at: point, lyricsOpen: false) { return }
        case .lyrics:
            // Speech bubble goes back to the music card.
            if musicBubbleRect.contains(point) {
                cardPage = .music
                needsDisplay = true
                return
            }
            // Controls are the music card's own row, recentered on the
            // compressed music part (see drawMusicCard).
            if let hit = controlHit(at: point, centers: [118, 170, 222], yMin: 130, yMax: 150) {
                performControl(hit)
                return
            }
            if startProgressDrag(at: point, lyricsOpen: true) { return }
        case .pomodoro:
            let buttons = pomodoroButtonRects()
            if buttons.play.contains(point) {
                togglePomodoro()
                return
            }
            if buttons.reset.contains(point) {
                resetPomodoro()
                return
            }
            if buttons.shortBreak.contains(point) {
                setPomodoroMode(.shortBreak)
                return
            }
            if buttons.focus.contains(point) {
                setPomodoroMode(.focus)
                return
            }
        case .todo:
            for row in todoVisibleRows() {
                if row.deleteRect.contains(point) {
                    deleteTodoTask(id: row.task.id)
                    return
                }
                if row.rowRect.contains(point) {
                    toggleTodoTask(id: row.task.id)
                    return
                }
            }
            if todoAddPillRect().contains(point) {
                startTodoEditing()
                return
            }
        case .water:
            let buttons = waterButtonRects()
            if buttons.toggle.contains(point) {
                toggleWaterNotifications()
                return
            }
            if buttons.drink.contains(point) {
                drinkWater()
                return
            }
            if buttons.settings.contains(point) {
                showWaterSettingsAlert()
                return
            }
        case .sources:
            // Picker rows: header at y 64, rows from y 88, height 22, max 4.
            if point.y >= 88 {
                let index = Int((point.y - 88) / 22)
                if index >= 0 && index < min(sessionsForPicker.count, 4) {
                    let picked = sessionsForPicker[index]
                    if picked.id == pinnedId {
                        onUnpin?()
                    } else {
                        onSessionPicked?(picked.id)
                    }
                    return
                }
            }
        case .tray:
            if trayShareFile != nil {
                // Share mode: back cancels (and aborts a send).
                if trayShareBackRect().contains(point) {
                    onTrayShareCancel?()
                    clearTrayShare()
                    return
                }
                if traySharePeer == nil {
                    if trayShareMethod == nil {
                        let methods = trayShareMethodRects()
                        if methods.airDrop.contains(point) {
                            if let file = trayShareFile { onTrayShareAirDrop?(file) }
                            clearTrayShare()
                            return
                        }
                        if methods.lan.contains(point) {
                            trayShareMethod = .lan
                            needsDisplay = true
                            return
                        }
                        if methods.open.contains(point) {
                            if let file = trayShareFile, trayFileExists(file) {
                                NSWorkspace.shared.open(file.url)
                                clearTrayShare()
                            }
                            return
                        }
                    } else if trayShareMethod == .lan {
                        for row in traySharePeerRects() {
                            if row.rect.contains(point) {
                                if let file = trayShareFile {
                                    traySharePeer = row.peer
                                    trayShareStatus = "Waiting for approval..."
                                    trayShareProgress = nil
                                    needsDisplay = true
                                    onTrayShareLANPeer?(file, row.peer)
                                }
                                return
                            }
                        }
                    }
                }
                // Status view or unhandled share-mode click: fall
                // through to collapse (the send keeps running).
            } else {
                // Grid list mode.
                if !trayFiles.isEmpty {
                    if trayClearPillRect().contains(point) {
                        clearTray()
                        return
                    }
                    if trayGridPageCount() > 1 {
                        let arrows = trayGridArrowRects()
                        if arrows.left.contains(point) {
                            moveGridPage(by: -1)
                            return
                        }
                        if arrows.right.contains(point) {
                            moveGridPage(by: 1)
                            return
                        }
                        for (i, rect) in trayGridPageDotRects().enumerated() {
                            if rect.contains(point) {
                                trayGridPage = i
                                needsDisplay = true
                                return
                            }
                        }
                    }
                    for tile in trayGridTileRects() {
                        if tile.deleteRect.contains(point) {
                            deleteTrayFile(id: tile.file.id)
                            return
                        }
                        if tile.rect.contains(point) {
                            // Tap = share (on mouseUp); press-drag =
                            // drag-out. Stale tiles arm nothing.
                            if tile.exists {
                                trayPendingDrag = (file: tile.file, point: point)
                            }
                            return
                        }
                    }
                }
                // Empty tray or unhandled click: fall through to collapse.
            }
        case .removeBg:
            if removeBgProcessing {
                // A run already in flight: ignore pick/save
                // clicks and fall through to collapse (the upload
                // keeps running in the background).
            } else if removeBgResultData != nil, removeBgSaveRect(saving: removeBgSaving).contains(point) {
                saveRemoveBgResult()
                return
            } else if removeBgModelPillRect().contains(point) {
                showRemoveBgModelMenu(at: point)
                return
            } else if removeBgTrayPickerVisible(), removeBgTrayPickerRect().contains(point) {
                showRemoveBgTrayMenu(at: point)
                return
            } else if removeBgPickRect().contains(point) {
                pickRemoveBgImage()
                return
            } else if removeBgResult != nil, removeBgResultRect().contains(point) {
                // Pressing the result arms a drag-out (tray-tile
                // pattern); a plain tap without a drag does nothing
                // and leaves the card open.
                removeBgPendingDragPoint = point
                return
            }
        case .convert:
            let tool = convertActiveTool
            if convertState(for: tool).processing {
                // A run already in flight: ignore clicks and fall
                // through to collapse (the upload keeps running in
                // the background, like Remove BG).
            } else if convertState(for: tool).resultData != nil, removeBgSaveRect(saving: convertSavingTool == tool).contains(point) {
                saveConvertResult()
                return
            } else if tool == .mergePDF, removeBgSaveRect().contains(point) {
                startMerge()
                return
            } else if tool == .photo, convertFormatPillRect().contains(point) {
                showConvertFormatMenu(at: point)
                return
            } else if let picked = convertToolRowMetrics().rects.first(where: { $0.rect.contains(point) })?.tool {
                convertActiveTool = picked
                needsDisplay = true
                return
            } else if !convertTrayFiles(for: tool).isEmpty, convertFromTrayPillRect().contains(point) {
                if tool == .mergePDF {
                    showMergeTrayMenu(at: point)
                } else {
                    showConvertFromTrayMenu(at: point)
                }
                return
            } else if convertLeftRect().contains(point) {
                if tool == .mergePDF {
                    if let hit = mergeFileRemoveRects().first(where: { $0.rect.contains(point) }) {
                        removeMergeFile(at: hit.index)
                    } else if let row = mergeFileRowRects().first(where: { $0.rect.contains(point) }) {
                        // Arm a reorder drag; releasing without
                        // moving keeps the old tap behavior (the
                        // picker opens from mouseUp, not here).
                        mergeDragItem = mergeFiles[row.index]
                        mergeDragIndex = row.index
                        mergeDragPoint = point
                        mergeDragActive = false
                        mergeDragStartOrder = mergeFiles.map(\.name)
                    } else {
                        pickMergeFiles()
                    }
                } else {
                    pickConvertFile()
                }
                return
            } else if convertState(for: tool).resultData != nil, convertRightRect().contains(point) {
                convertPendingDrag = (tool: tool, point: point)
                return
            }
        }
        // Any other click on the expanded card collapses it. Without this
        // fallthrough there was no way to close the card by clicking: only
        // the controls, picker rows, pomodoro buttons, and todo rows responded, the
        // rest did nothing.
        onClicked?()
    }

    // MARK: - Tray drag and drop

    /// Drag-out: a press on a grid tile arms a pending drag; moving
    /// past 3px starts the session (so a plain press is a tap, and
    /// only tray tiles drag — other sections are untouched). The
    /// file stays in the tray (copy, not move).
    override func mouseDragged(with event: NSEvent) {
        if let drag = progressDrag {
            let point = convert(event.locationInWindow, from: nil)
            let fraction = min(1.0, max(0.0, (point.x - drag.bar.minX) / drag.bar.width))
            seekPreviewPosition = fraction * drag.duration
            needsDisplay = true
            return
        }
        if let startPoint = removeBgPendingDragPoint {
            let point = convert(event.locationInWindow, from: nil)
            guard abs(point.x - startPoint.x) > 3 || abs(point.y - startPoint.y) > 3 else { return }
            removeBgPendingDragPoint = nil
            guard let result = removeBgResult, removeBgResultData != nil else { return }
            guard let fileURL = ensureRemoveBgFile() else {
                removeBgStatusText = "Could not save the result to drag it."
                removeBgStatusIsError = true
                needsDisplay = true
                return
            }
            // Drag image: the result itself, fitted to 96pt (the
            // tray uses a 48pt icon; a photo reads better larger,
            // and 96 still fits under the cursor without covering
            // the drop target).
            let thumbSize = removeBgFitRect(for: result, in: NSRect(x: 0, y: 0, width: 96, height: 96)).size
            let thumb = NSImage(size: thumbSize)
            thumb.lockFocus()
            result.draw(in: NSRect(origin: .zero, size: thumbSize), from: .zero,
                        operation: .sourceOver, fraction: 1.0)
            thumb.unlockFocus()
            isDraggingOut = true
            let item = NSDraggingItem(pasteboardWriter: AuraTrayPasteboardWriter(url: fileURL))
            let dragFrame = NSRect(x: point.x - thumbSize.width / 2,
                                   y: point.y - thumbSize.height / 2,
                                   width: thumbSize.width, height: thumbSize.height)
            item.setDraggingFrame(dragFrame, contents: thumb)
            beginDraggingSession(with: [item], event: event, source: self)
            return
        }
        if let pendingConvert = convertPendingDrag {
            let point = convert(event.locationInWindow, from: nil)
            guard abs(point.x - pendingConvert.point.x) > 3 || abs(point.y - pendingConvert.point.y) > 3 else { return }
            let tool = pendingConvert.tool
            convertPendingDrag = nil
            guard convertState(for: tool).resultData != nil else { return }
            guard let fileURL = ensureConvertFile(for: tool) else {
                // Only surface the failure if the user is still
                // looking at this tool; otherwise it would overwrite
                // another tool's status.
                if convertActiveTool == tool {
                    var failed = convertState(for: tool)
                    failed.statusText = "Could not save the result to drag it."
                    failed.statusIsError = true
                    setConvertState(failed, for: tool)
                    needsDisplay = true
                }
                return
            }
            isDraggingOut = true
            let dragImage: NSImage
            let dragSize: NSSize
            if tool == .photo, let resultImage = convertState(for: tool).resultImage {
                let size = removeBgFitRect(for: resultImage, in: NSRect(x: 0, y: 0, width: 96, height: 96)).size
                let thumb = NSImage(size: size)
                thumb.lockFocus()
                resultImage.draw(in: NSRect(origin: .zero, size: size), from: .zero,
                                 operation: .sourceOver, fraction: 1.0)
                thumb.unlockFocus()
                dragImage = thumb
                dragSize = size
            } else {
                let icon = NSWorkspace.shared.icon(forFile: fileURL.path)
                dragSize = NSSize(width: 48, height: 48)
                dragImage = (icon.copy() as? NSImage) ?? icon
                dragImage.size = dragSize
            }
            let item = NSDraggingItem(pasteboardWriter: AuraTrayPasteboardWriter(url: fileURL))
            let dragFrame = NSRect(x: point.x - dragSize.width / 2,
                                   y: point.y - dragSize.height / 2,
                                   width: dragSize.width, height: dragSize.height)
            item.setDraggingFrame(dragFrame, contents: dragImage)
            beginDraggingSession(with: [item], event: event, source: self)
            return
        }
        if let dragged = mergeDragItem, let startPoint = mergeDragPoint,
           currentPage == .convert, convertActiveTool == .mergePDF {
            let point = convert(event.locationInWindow, from: nil)
            mergeDragCursor = point
            if !mergeDragActive {
                guard abs(point.x - startPoint.x) > 3 || abs(point.y - startPoint.y) > 3 else { return }
                mergeDragActive = true
            }
            // Live shuffle: drop the dragged file out, then
            // insert it at the row under the cursor (clamped to
            // the list ends). The dragged item is re-found by
            // name + bytes each move, so its index never goes
            // stale as the list mutates under it.
            guard let current = mergeFiles.firstIndex(where: { $0.name == dragged.name && $0.data == dragged.data }) else {
                mergeDragItem = nil
                mergeDragIndex = nil
                mergeDragPoint = nil
                mergeDragCursor = nil
                mergeDragActive = false
                return
            }
            var rest = mergeFiles
            rest.remove(at: current)
            let content = convertLeftContentRect()
            var target = Int((point.y - content.minY) / 18)
            target = max(0, min(target, rest.count))
            if target != current {
                mergeFiles = rest
                mergeFiles.insert(dragged, at: target)
            }
            mergeDragIndex = mergeFiles.firstIndex(where: { $0.name == dragged.name && $0.data == dragged.data })
            needsDisplay = true
            return
        }
        guard let pending = trayPendingDrag else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard abs(point.x - pending.point.x) > 3 || abs(point.y - pending.point.y) > 3 else { return }
        trayPendingDrag = nil
        guard trayFileExists(pending.file) else { return }
        isDraggingOut = true
        // DynamicNotch-style drag-out: a dedicated pasteboard
        // writer (file URL as .fileURL/.URL) plus an explicit
        // dragging frame + icon image — no NSURL writer and no
        // imageComponentsProvider, the two drag-start paths that
        // were in play when the segfault was reported.
        let item = NSDraggingItem(pasteboardWriter: AuraTrayPasteboardWriter(url: pending.file.url))
        let dragSize = NSSize(width: 48, height: 48)
        let dragFrame = NSRect(x: point.x - dragSize.width / 2,
                               y: point.y - dragSize.height / 2,
                               width: dragSize.width, height: dragSize.height)
        let icon = NSWorkspace.shared.icon(forFile: pending.file.path)
        let dragImage = (icon.copy() as? NSImage) ?? icon
        dragImage.size = dragSize
        item.setDraggingFrame(dragFrame, contents: dragImage)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if let drag = progressDrag {
            progressDrag = nil
            let seconds = seekPreviewPosition
            seekPreviewPosition = nil
            needsDisplay = true
            // Commit on release (a plain click seeks too). The
            // player applies it; onSeek's success path re-anchors
            // the bar, on failure the bar snaps back on next draw.
            if let seconds, drag.duration > 0 {
                onSeek?(seconds)
            }
        }
        if removeBgPendingDragPoint != nil {
            // Tap on the result without a drag: nothing, and the
            // card stays open (unlike an unhandled click, which
            // collapses it — the press already returned early).
            removeBgPendingDragPoint = nil
        }
        if convertPendingDrag != nil {
            // Tap on a Convert result without a drag: nothing,
            // card stays open (same as Remove BG).
            convertPendingDrag = nil
        }
        if mergeDragIndex != nil {
            let wasActive = mergeDragActive
            let startOrder = mergeDragStartOrder
            mergeDragItem = nil
            mergeDragIndex = nil
            mergeDragPoint = nil
            mergeDragCursor = nil
            mergeDragActive = false
            if !wasActive {
                // Tap without a drag: the old behavior, open the
                // picker (deferred here so a drag never opens it).
                if currentPage == .convert, convertActiveTool == .mergePDF,
                   !convertState(for: .mergePDF).processing {
                    pickMergeFiles()
                }
            } else if mergeFiles.map(\.name) != startOrder {
                // Order actually changed: the old merged result
                // no longer matches the list.
                var state = convertState(for: .mergePDF)
                state.resultData = nil
                state.resultImage = nil
                state.resultPDFPreview = nil
                state.resultFileName = nil
                state.savedURL = nil
                state.statusIsError = false
                state.statusText = mergeFiles.count == 1
                    ? "1 PDF - add at least 1 more, then press Merge."
                    : "\(mergeFiles.count) PDFs ready - press Merge."
                setConvertState(state, for: .mergePDF)
            }
            needsDisplay = true
        }
        // A press on a grid tile without a drag is a tap = share.
        // (After a real drag, pending is already nil — the drag
        // cleared it on start — so this never shares post-drag.)
        if let pending = trayPendingDrag {
            trayPendingDrag = nil
            trayShareFile = pending.file
            trayShareMethod = nil
            traySharePeer = nil
            trayShareStatus = nil
            trayShareProgress = nil
            needsDisplay = true
        }
    }

    /// Right-click a tile: context menu. Open uses the file's
    /// default app (Finder for folders); Share opens share mode
    /// for the file; Remove drops the reference. Missing files
    /// only get Remove.
    override func rightMouseDown(with event: NSEvent) {
        guard state == .expanded, cardPage == .tray, trayShareFile == nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        for tile in trayGridTileRects() where tile.rect.contains(point) {
            trayMenuFile = tile.file
            let menu = NSMenu()
            if tile.exists {
                let openItem = NSMenuItem(title: "Open", action: #selector(openTrayMenuFile), keyEquivalent: "")
                openItem.target = self
                menu.addItem(openItem)
                let shareItem = NSMenuItem(title: "Share...", action: #selector(shareTrayMenuFile), keyEquivalent: "")
                shareItem.target = self
                menu.addItem(shareItem)
            }
            let removeItem = NSMenuItem(title: "Remove", action: #selector(removeTrayMenuFile), keyEquivalent: "")
            removeItem.target = self
            menu.addItem(removeItem)
            presentCardModal { menu.popUp(positioning: nil, at: point, in: self) }
            return
        }
    }

    @objc private func openTrayMenuFile() {
        guard let file = trayMenuFile, trayFileExists(file) else { return }
        trayMenuFile = nil
        NSWorkspace.shared.open(file.url)
    }

    @objc private func shareTrayMenuFile() {
        guard let file = trayMenuFile else { return }
        trayMenuFile = nil
        trayShareFile = file
        trayShareMethod = nil
        traySharePeer = nil
        trayShareStatus = nil
        trayShareProgress = nil
        needsDisplay = true
    }

    @objc private func removeTrayMenuFile() {
        guard let file = trayMenuFile else { return }
        trayMenuFile = nil
        deleteTrayFile(id: file.id)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isDraggingOut = false
        // Defer the hover re-sync to the next run loop: resizing
        // the window synchronously inside drag teardown risks
        // re-entrancy (the drag image window is still being torn
        // down). The card collapses a tick later if the cursor is out.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let window = self.window, !window.frame.contains(NSEvent.mouseLocation) {
                self.onHoverChanged?(false)
            }
        }
    }

    /// Drag-in: file URLs only. Entering expands the card to the
    /// tray (so dropping onto the closed pill works, like
    /// DynamicNotch) and clears share mode (the drop zone takes
    /// over); the drop lands in the tray.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // The source's own drag-out is not a drag-in: without this,
        // starting a drag-out would highlight the drop zone and
        // re-expand the card mid-drag.
        guard !isDraggingOut else { return [] }
        guard sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [NSPasteboard.ReadingOptionKey.urlReadingFileURLsOnly: true]) else {
            return []
        }
        if state == .expanded, currentPage == .removeBg {
            // Dropping onto the open Remove BG card goes to
            // Remove BG, not the tray: do NOT call
            // onDragEnteredTray (it would switch to tray).
            removeBgDropHighlight = true
            return .copy
        }
        if state == .expanded, currentPage == .convert,
           let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [NSPasteboard.ReadingOptionKey.urlReadingFileURLsOnly: true]) as? [URL],
           urls.contains(where: { convertAccepts(url: $0, for: convertActiveTool) }) {
            // Matching file for the active Convert tool: drop
            // into Convert, not the tray. Mismatched files fall
            // through to the tray block below (they land in the
            // tray, like any other drop).
            convertDropHighlight = true
            return .copy
        }
        if trayShareFile != nil { clearTrayShare() }
        trayDragPoint = convert(sender.draggingLocation, from: nil)
        trayDropHighlight = true
        onDragEnteredTray?()
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !isDraggingOut else { return [] }
        guard sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [NSPasteboard.ReadingOptionKey.urlReadingFileURLsOnly: true]) else {
            return []
        }
        if state == .expanded, currentPage == .removeBg {
            return .copy
        }
        if state == .expanded, currentPage == .convert,
           let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [NSPasteboard.ReadingOptionKey.urlReadingFileURLsOnly: true]) as? [URL],
           urls.contains(where: { convertAccepts(url: $0, for: convertActiveTool) }) {
            return .copy
        }
        // Track the cursor so the "+ Copy" badge follows it.
        trayDragPoint = convert(sender.draggingLocation, from: nil)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        trayDragPoint = nil
        trayDropHighlight = false
        removeBgDropHighlight = false
        convertDropHighlight = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [NSPasteboard.ReadingOptionKey.urlReadingFileURLsOnly: true]) as? [URL] else {
            trayDragPoint = nil
            trayDropHighlight = false
            return false
        }
        if state == .expanded, currentPage == .removeBg {
            trayDragPoint = nil
            trayDropHighlight = false
            removeBgDropHighlight = false
            let imageExts: Set<String> = ["png", "jpg", "jpeg", "heic", "webp", "gif", "bmp", "tiff"]
            if let url = urls.first(where: { imageExts.contains($0.pathExtension.lowercased()) }) {
                startRemoveBg(with: url)
                return true
            }
            return false
        }
        if state == .expanded, currentPage == .convert {
            trayDragPoint = nil
            trayDropHighlight = false
            removeBgDropHighlight = false
            convertDropHighlight = false
            let tool = convertActiveTool
            if tool == .mergePDF {
                // Merge collects files, it never runs on drop:
                // the user may drop in batches, then press Merge.
                let pdfs = urls.filter { convertAccepts(url: $0, for: tool) }
                if !pdfs.isEmpty {
                    addMergeFiles(pdfs)
                    return true
                }
                return false
            }
            if let url = urls.first(where: { convertAccepts(url: $0, for: tool) }) {
                startConvert(with: url, tool: tool)
                return true
            }
            return false
        }
        let added = addTrayFiles(urls)
        trayDragPoint = nil
        trayDropHighlight = false
        if trayShareFile != nil { clearTrayShare() }
        return added > 0
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        trayDragPoint = nil
        trayDropHighlight = false
        removeBgDropHighlight = false
        convertDropHighlight = false
    }

    /// Three-finger swipe switches sections (the MacBook way):
    /// swipe left -> next section, swipe right -> previous.
    /// Uses the swipe event (not scrollWheel): AppKit delivers
    /// three-finger swipes as swipe events with deltaX -1 (left)
    /// or +1 (right). Only when expanded (the closed pill has no
    /// sections). NOTE: if the Mac's Trackpad setting "Swipe
    /// between full-screen apps" is set to 3 fingers (the default),
    /// the system intercepts three-finger swipes for space
    /// switching and Aura never sees them — set it to 4 fingers
    /// so three-finger swipes reach Aura. NOTE: the deltaX sign
    /// convention (left swipe = negative) could not be verified
    /// in this VM (no trackpad); if the direction feels backwards
    /// on the Mac, flip the two moveSection signs (one line each).
    override func swipe(with event: NSEvent) {
        guard state == .expanded else { return }
        if event.deltaX < 0 {
            moveSection(by: 1)
        } else if event.deltaX > 0 {
            moveSection(by: -1)
        }
    }

    /// Two-finger vertical scroll switches sections (no system
    /// setting needed: vertical scroll is never intercepted for
    /// spaces, unlike horizontal three-finger swipe). Scroll down ->
    /// next section, scroll up -> previous. Accumulates deltaY; a
    /// firm scroll (>= 80) switches once, then resets. Momentum
    /// (the coast after a scroll) is ignored so a fast scroll never
    /// switches twice. Only when expanded (the closed pill has no
    /// sections). NOTE: the deltaY sign convention (down = negative)
    /// could not be verified in this VM (no trackpad); if the
    /// direction feels backwards on the Mac, flip the two
    /// moveSection signs (one line each).
    private var scrollAccumulatedY: CGFloat = 0
    override func scrollWheel(with event: NSEvent) {
        guard state == .expanded else { return }
        guard event.momentumPhase.isEmpty else { return }
        if event.phase == .ended || event.phase == .cancelled {
            scrollAccumulatedY = 0
            return
        }
        scrollAccumulatedY += event.scrollingDeltaY
        if scrollAccumulatedY <= -80 {
            moveSection(by: 1)
            scrollAccumulatedY = 0
        } else if scrollAccumulatedY >= 80 {
            moveSection(by: -1)
            scrollAccumulatedY = 0
        }
    }

    private func performControl(_ hit: Int) {
        switch hit {
        case 0: onPrevious?()
        case 1: onPlayPause?()
        default: onNext?()
        }
    }

    /// Move to the previous/next section in dot order (music ->
    /// pomodoro -> todo -> water -> tray -> sources when available -> back to music),
    /// wrapping. Lyrics is not a section (it is a panel of music, via
    /// the bubble), so moving from lyrics uses the music section.
    /// Called by dots and three-finger swipe (the side arrows were
    /// removed).
    private func moveSection(by delta: Int) {
        let sections = availableSections
        guard !sections.isEmpty else { return }
        let current = sections.firstIndex(of: sectionForDots) ?? 0
        let next = (current + delta + sections.count) % sections.count
        cardPage = sections[next]
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = bounds
        // Notch shape, like the MacBook notch in the reference photo:
        // boxy body, concave sweeps where the top meets the bezel (the
        // sides tuck inward just below the top edge), convex rounding
        // at the bottom. Tangent-based arcs (not angle-based) so the
        // shape is correct in this flipped view regardless of angle
        // conventions.
        // The card stays boxy; the bezel-touching ends curve concave
        // like the original design (12pt tuck). The 1/4-height sweep
        // was too deep: it inset the sides so far that content laid
        // out for the full width (cover, header waveform, section arrows)
        // stuck out past the shape.
        // Spring scale is computed first: when a bounce runs, the
        // path is built from the NOMINAL card size (base), not from
        // bounds (the headroom window) — building from bounds would
        // scale an already-grown pill a second time, rendering it
        // clipped/misaligned (a "new pill" instead of the existing
        // one). The transform below maps base coords to window coords.
        // Spring only while expanded: closed content (drawClosed/drawPillAlert)
        // is laid out from bounds, so a running tray spring during a
        // close animation would map those bounds coords through the
        // spring transform a second time and push battery/clock/waveform
        // outside the small pill. Guarding here makes the close draw
        // follow the window animator (single pill, content inside).
        let springScale = state == .expanded ? traySpringScale(now: Date()) : 1.0
        let base = unbulgedSize(for: state)
        // Headroom window without a spring (e.g. first drag-enter if
        // the spring was ever cancelled) must still draw the base
        // pill centred, not fill the whole headroom window: filling
        // it left-aligns the fixed-coord content and leaves a wide
        // right margin — the first-entry right expansion.
        let useBaseRect = springScale != 1.0 || isTrayHeadroom
        let pathRect = useBaseRect
            ? NSRect(x: 0, y: 0, width: base.width, height: base.height)
            : rect
        let path = notchPath(
            rect: pathRect,
            tuck: 12,
            // Full cards keep the 28pt bottom rounding from the Nusa
            // reference; short pills (compact, music strip) are fully
            // rounded like the closed pill.
            bottomRadius: state == .expanded && pathRect.height > 100 ? 28 : pathRect.height / 2
        )
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // Clear first: this window is transparent and the view is
        // non-opaque, so AppKit does NOT erase previous frames — and
        // the card fill below is 0.98 black, not fully opaque, so
        // without an explicit clear every redraw leaves 2% of the old
        // text behind. At 10fps discrete updates that ghosting was
        // invisible, but the 60fps lyric slide moves the block 26px
        // over 0.45s, smearing it across its path — which is exactly
        // the overlapping lines in the screenshot (the lower line of
        // an earlier position showing through the upper line of a
        // later one). Clearing to transparent keeps the intended
        // 0.98 translucency (over the desktop, not over old text).
        ctx.clear(rect)
        // Bounce the EXISTING pill (background + content, both in
        // base coords) around the top-center (bezel), so it stays
        // glued to the menu bar and fits the headroom window.
        if springScale != 1.0 {
            ctx.translateBy(x: rect.midX, y: rect.minY)
            ctx.scaleBy(x: springScale, y: springScale)
            ctx.translateBy(x: -base.width / 2, y: 0)
        } else if isTrayHeadroom {
            ctx.translateBy(x: rect.midX, y: rect.minY)
            ctx.translateBy(x: -base.width / 2, y: 0)
        }
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.98).cgColor)
        ctx.fillPath()
        // Artwork gradient, lyrics only: the pill background
        // follows the cover's dominant color (black at the top down
        // to the darkened dominant color at the bottom) when the
        // lyrics page is the active card AND when the inactive pill
        // is in lyrics mode (closed from the lyrics page, showing the
        // lyric line). Every other card and pill stays plain black
        // (0.98), including the tray card and the music card.
        let lyricsGradientActive = AuraSettings.shared.lyricsGradient
            && ((state == .expanded && currentPage == .lyrics)
                || (state != .expanded && lyricsMode))
        if lyricsGradientActive, let bottomColor = gradientBottomColor() {
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            let colors = [NSColor.black.cgColor, bottomColor.cgColor] as CFArray
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                ctx.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: 0, y: pathRect.minY),
                    end: CGPoint(x: 0, y: pathRect.maxY),
                    options: []
                )
            }
            ctx.restoreGState()
        }
        ctx.addPath(path)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.15).cgColor)
        ctx.setLineWidth(0.5)
        ctx.strokePath()
        ctx.restoreGState()

        // Overlap-hidden tip: shape only, no content. Drawing eyes
        // or clock text into a 6px window would clip it into a
        // smeared slice; the strip alone is the marker.
        if isOverlapHidden { return }

        // A live pill alert takes over every closed pill (zen,
        // compact, split) with its widened horizontal layout; it
        // never touches an expanded card (alerts do not fire while
        // one is open, and opening one cancels a live alert).
        if pillAlert != nil && state != .expanded {
            drawPillAlert()
        } else {
            switch state {
            case .zen:
                drawEyes()
            case .compact, .split:
                drawClosed()
            case .expanded:
                drawExpanded()
            }
        }
    }

    /// Notch outline: boxy body, concave sweeps where the top meets the
    /// bezel, convex rounding at the bottom. Coordinates are this flipped
    /// view's (y grows down): rect.minY is the top edge, rect.maxY the
    /// bottom edge.
    /// - tuck: how far the sides tuck inward below the top edge, and how
    ///   tall the concave sweep is. The sweep is tangent to the top edge
    ///   at the full width and tangent to the tucked side edge, so the
    ///   notch reads as flowing out of the bezel rather than stuck onto
    ///   it.
    private func notchPath(rect: NSRect, tuck: CGFloat, bottomRadius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let x = rect.minX, y = rect.minY, w = rect.width, h = rect.height
        let t = min(tuck, w / 2, h / 2)
        let rb = min(bottomRadius, w / 2, h / 2)
        path.move(to: CGPoint(x: x, y: y))
        path.addLine(to: CGPoint(x: x + w, y: y))
        // Top-right: concave sweep into the bezel.
        path.addArc(tangent1End: CGPoint(x: x + w - t, y: y),
                    tangent2End: CGPoint(x: x + w - t, y: y + t), radius: t)
        path.addLine(to: CGPoint(x: x + w - t, y: y + h - rb))
        // Bottom-right: convex rounding.
        path.addArc(tangent1End: CGPoint(x: x + w - t, y: y + h),
                    tangent2End: CGPoint(x: x + w - t - rb, y: y + h), radius: rb)
        path.addLine(to: CGPoint(x: x + t + rb, y: y + h))
        // Bottom-left: convex rounding.
        path.addArc(tangent1End: CGPoint(x: x + t, y: y + h),
                    tangent2End: CGPoint(x: x + t, y: y + h - rb), radius: rb)
        path.addLine(to: CGPoint(x: x + t, y: y + t))
        // Top-left: concave sweep into the bezel.
        path.addArc(tangent1End: CGPoint(x: x + t, y: y),
                    tangent2End: CGPoint(x: x, y: y), radius: t)
        path.closeSubpath()
        return path
    }

    // MARK: - Text helpers

    private func drawText(_ text: String, font: NSFont, color: NSColor, at point: NSPoint) {
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
            .draw(at: point)
    }

    private func drawCentered(_ text: String, font: NSFont, color: NSColor, y: CGFloat) {
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        drawText(text, font: font, color: color, at: NSPoint(x: (bounds.width - width) / 2, y: y))
    }

    private func drawRightAligned(_ text: String, font: NSFont, color: NSColor, rightX: CGFloat, y: CGFloat) {
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        drawText(text, font: font, color: color, at: NSPoint(x: rightX - width, y: y))
    }

    private func truncated(_ text: String, toWidth width: CGFloat, font: NSFont) -> String {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        if (text as NSString).size(withAttributes: attrs).width <= width { return text }
        var result = text
        while !result.isEmpty {
            result = String(result.dropLast())
            let candidate = result + "…"
            if (candidate as NSString).size(withAttributes: attrs).width <= width {
                return candidate
            }
        }
        return "…"
    }

    private func formatTime(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private static let headerDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "EEE d MMM yyyy HH:mm"
        return formatter
    }()

    /// Clock for the closed music pill (HH:mm).
    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    // MARK: - Shared pieces

    /// Cursor-tracking look for the idle eyes: -1...1 in each axis
    /// (view coords: +x right, +y down, because the view is flipped).
    /// Updated by AppDelegate's eye timer from NSEvent.mouseLocation;
    /// smoothed there, so drawEyes just places the eyes.
    var eyeLook = CGPoint.zero

    /// True while a blink is in progress. Set by AppDelegate's eye
    /// timer on a random 2.5-5s cadence, for 0.2s at a time.
    var eyesClosed = false

    /// EMO expression for the zen eyes, derived by AppDelegate's
    /// eye timer: happy for 1s after the card closes back to
    /// zen, sleepy after 3 minutes untouched, else normal.
    enum EyeExpression { case normal, happy, sleepy }
    var eyeExpression = EyeExpression.normal

    /// One-eye wink, decided by AppDelegate's eye timer: 15% of
    /// blinks close one eye instead of both, for the same 0.2s
    /// window. Read by drawEyes only while the blink window is
    /// open; the timer clears it when the window ends.
    enum EyeWink { case left, right }
    var eyeWink: EyeWink?

    /// Per-eye openness for the cursor-proximity blink: 1 = fully
    /// open, 0 = shut into a line. AppDelegate's eye timer drives
    /// each eye from the cursor's 2D distance to that eye (the
    /// nearer eye leads), smoothed; drawEyes maps it to the eye's
    /// height. Only used in the normal expression.
    var eyeOpenness: [CGFloat] = [1, 1]

    /// EMO-style eyes for the zen face: two solid white rounded
    /// rectangles (no pupils - EMO's eyes are the glow itself),
    /// about 18x11 with radius 4, centered on the old oval
    /// centers (56.5/83.5, y 16). The whole shape shifts with
    /// eyeLook (at most 2px horizontally, 3px vertically), like
    /// the old pupils did. Expressions: normal = rectangles;
    /// happy = upward arcs; sleepy = downward arcs; wink =
    /// one eye a flat line, the other a rectangle. Blink
    /// (eyesClosed) still closes both eyes into flat lines.
    private func drawEyes() {
        let centers: [CGFloat] = [56.5, 83.5]
        let w: CGFloat = 18
        for (i, cx) in centers.enumerated() {
            // Proximity blink height: the eye shrinks toward the
            // flat blink line as the cursor gets close to it.
            let openness = eyeExpression == .normal ? eyeOpenness[i] : 1
            let h: CGFloat = 2.5 + (11 - 2.5) * openness
            let x = cx - w / 2 + eyeLook.x * 2
            let y = 16 - h / 2 + eyeLook.y * 3
            let rect = NSRect(x: x, y: y, width: w, height: h)
            let lineRect = NSRect(x: x, y: 16 - 1.25, width: w, height: 2.5)
            if eyesClosed {
                NSColor.white.setFill()
                NSBezierPath(roundedRect: lineRect, xRadius: 1.25, yRadius: 1.25).fill()
            } else if let wink = eyeWink, (wink == .left && i == 0) || (wink == .right && i == 1) {
                NSColor.white.setFill()
                NSBezierPath(roundedRect: lineRect, xRadius: 1.25, yRadius: 1.25).fill()
            } else {
                switch eyeExpression {
                case .normal:
                    NSColor.white.setFill()
                    let r = min(4, h / 2)
                    NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
                case .happy:
                    strokeEyeArc(in: rect, upward: true)
                case .sleepy:
                    strokeEyeArc(in: rect, upward: false)
                }
            }
        }
    }

    /// One EMO arc eye: a thick stroked curve across the eye
    /// rect. Flipped view: minY is the visual top, maxY the
    /// visual bottom, so happy is a cap (endpoints low, apex
    /// high) and sleepy is a cup (endpoints high, apex low).
    private func strokeEyeArc(in rect: NSRect, upward: Bool) {
        let yEnd = upward ? rect.maxY : rect.minY
        let yApex = upward ? rect.minY : rect.maxY
        let path = NSBezierPath()
        path.lineWidth = 3.5
        path.lineCapStyle = .round
        path.move(to: NSPoint(x: rect.minX, y: yEnd))
        path.curve(to: NSPoint(x: rect.maxX, y: yEnd),
                   controlPoint1: NSPoint(x: rect.minX + rect.width * 0.25, y: yApex),
                   controlPoint2: NSPoint(x: rect.maxX - rect.width * 0.25, y: yApex))
        NSColor.white.setStroke()
        path.stroke()
    }

    /// iOS battery icon (status-bar style): white outline + nub,
    /// fill proportional to the charge level. Fill is white, red
    /// at 20% and below (iOS low battery), green while charging.
    /// Hidden when there is no battery (desktops) or the level is
    /// unknown. Percent and charging are passed in so the battery
    /// alert can draw its snapshot instead of the live values.
    private func drawBatteryIcon(center: CGPoint, percent: Double?, charging: Bool) {
        guard let percent else { return }
        let level = max(0, min(1, percent))
        let width: CGFloat = 24
        let height: CGFloat = 12
        let x = center.x - width / 2
        let y = center.y - height / 2
        // Outline + nub (white).
        NSColor.white.setStroke()
        let outline = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: height),
                                   xRadius: 3.5, yRadius: 3.5)
        outline.lineWidth = 1.5
        outline.stroke()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: x + width + 1, y: center.y - 2.5, width: 2, height: 5),
                     xRadius: 1, yRadius: 1).fill()
        // Fill (inset 2pt, proportional to level).
        let fillColor = charging ? NSColor.systemGreen
            : (level <= 0.20 ? NSColor.systemRed : NSColor.white)
        let fillWidth = (width - 4) * level
        if fillWidth > 0 {
            fillColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: x + 2, y: y + 2, width: fillWidth, height: height - 4),
                         xRadius: min(1.5, fillWidth / 2), yRadius: min(1.5, fillWidth / 2)).fill()
        }
    }

    private var cachedDominantKey: String?
    private var cachedDominantColor: NSColor?

    /// Darkened dominant cover color at the bottom of the background
    /// gradient, or nil when there is no artwork (plain black pill).
    /// Cached per track so the 10x/second waveform redraw never
    /// re-samples the image.
    private func gradientBottomColor() -> NSColor? {
        guard let session, let artwork = session.artwork else {
            cachedDominantKey = nil
            cachedDominantColor = nil
            return nil
        }
        let key = "\(session.title)|\(session.artist)|art"
        if key != cachedDominantKey {
            cachedDominantKey = key
            cachedDominantColor = dominantColor(of: artwork).map { darkenForText($0) }
        }
        return cachedDominantColor
    }

    /// Average color of the image, sampled at 32x32.
    private func dominantColor(of image: NSImage) -> NSColor? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = 32, h = 32
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var r = 0, g = 0, b = 0
        for i in 0..<(w * h) {
            r += Int(px[i * 4])
            g += Int(px[i * 4 + 1])
            b += Int(px[i * 4 + 2])
        }
        let n = CGFloat(w * h)
        return NSColor(red: CGFloat(r) / n / 255.0,
                       green: CGFloat(g) / n / 255.0,
                       blue: CGFloat(b) / n / 255.0, alpha: 1.0)
    }

    /// Scales a color down so its luminance is at most 0.28 — white text
    /// on top stays readable even for bright covers. Hue is preserved.
    private func darkenForText(_ color: NSColor) -> NSColor {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return color }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getRed(&r, green: &g, blue: &b, alpha: &a)
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        guard luminance > 0.28 else { return color }
        let scale = 0.28 / luminance
        return NSColor(red: r * scale, green: g * scale, blue: b * scale, alpha: 1.0)
    }

    /// Animated bars; flat when paused, lively while playing.
    private func drawWaveform(in rect: NSRect) {
        let bars = 5
        let barWidth: CGFloat = 3
        let gap: CGFloat = 3
        let total = CGFloat(bars) * barWidth + CGFloat(bars - 1) * gap
        var x = rect.midX - total / 2
        let playing = session?.isPlaying == true
        for i in 0..<bars {
            let sine = sin(wavePhase * 0.9 + Double(i) * 1.7)
            let amplitude = playing ? (0.35 + 0.65 * (0.5 + 0.5 * sine)) : 0.18
            let height = rect.height * CGFloat(amplitude)
            let bar = NSBezierPath(
                roundedRect: NSRect(x: x, y: rect.midY - height / 2, width: barWidth, height: height),
                xRadius: 1.5, yRadius: 1.5)
            NSColor.white.setFill()
            bar.fill()
            x += barWidth + gap
        }
    }

    private func drawArtwork(_ image: NSImage?, in rect: NSRect, cornerRadius: CGFloat = 12) {
        let clip = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        NSGraphicsContext.saveGraphicsState()
        clip.setClip()
        if let image {
            // Aspect-fill crop so non-square art never stretches.
            let imgSize = image.size
            let scale = max(rect.width / imgSize.width, rect.height / imgSize.height)
            let srcW = rect.width / scale
            let srcH = rect.height / scale
            let src = NSRect(x: (imgSize.width - srcW) / 2, y: (imgSize.height - srcH) / 2,
                             width: srcW, height: srcH)
            // This view is flipped (y grows down), and NSImage drawing in
            // a flipped context flips the image vertically — covers
            // appeared upside down. Flipping the context around the rect
            // first cancels it, so the cover lands upright. The flip maps
            // the rect onto itself, so the rounded clip still fits.
            if let ctx = NSGraphicsContext.current?.cgContext {
                ctx.saveGState()
                ctx.translateBy(x: 0, y: rect.minY + rect.maxY)
                ctx.scaleBy(x: 1, y: -1)
                image.draw(in: rect, from: src, operation: .sourceOver, fraction: 1.0)
                ctx.restoreGState()
            } else {
                image.draw(in: rect, from: src, operation: .sourceOver, fraction: 1.0)
            }
        } else {
            NSColor.white.withAlphaComponent(0.12).setFill()
            clip.fill()
            let glyph = "♪"
            let font = NSFont.systemFont(ofSize: 28)
            let size = (glyph as NSString).size(withAttributes: [.font: font])
            drawText(glyph, font: font, color: NSColor.white.withAlphaComponent(0.7),
                     at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: - Closed (compact) state

    /// Pill alert (360x32, horizontal only): icon + message +
    /// optional detail, centered as one group. Battery icons use
    /// the alert's snapshot (not the live values); symbols draw
    /// white in a square slot of their size. Text details draw in
    /// their tint; bar details draw a 120x6 level bar (track white
    /// 0.15, fill white).
    private func drawPillAlert() {
        guard let alert = pillAlert else { return }
        let midY = bounds.height / 2
        let font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        let messageWidth = (alert.message as NSString).size(withAttributes: [.font: font]).width
        let detailWidth: CGFloat
        switch alert.detail {
        case .text(let text, _):
            detailWidth = (text as NSString).size(withAttributes: [.font: font]).width
        case .bar:
            detailWidth = 120
        case nil:
            detailWidth = 0
        }
        let iconWidth: CGFloat
        switch alert.icon {
        case .battery: iconWidth = 27
        case .symbol(_, _, let size): iconWidth = size
        }
        // Icon + 10pt gap + message + (8pt gap + detail).
        let total = iconWidth + 10 + messageWidth + (alert.detail != nil ? 8 + detailWidth : 0)
        let startX = (bounds.width - total) / 2
        switch alert.icon {
        case .battery(let percent, let charging):
            drawBatteryIcon(center: CGPoint(x: startX + 12, y: midY), percent: percent, charging: charging)
        case .symbol(let name, let fallback, let size):
            drawSymbol(name, size: size, center: CGPoint(x: startX + iconWidth / 2, y: midY), fallback: fallback)
        }
        let detailX = startX + iconWidth + 10 + messageWidth + 8
        drawText(alert.message, font: font, color: .white, at: NSPoint(x: startX + iconWidth + 10, y: midY - 8))
        switch alert.detail {
        case .text(let text, let tint):
            drawText(text, font: font, color: tint, at: NSPoint(x: detailX, y: midY - 8))
        case .bar(let level):
            let clamped = max(0, min(1, level))
            NSColor.white.withAlphaComponent(0.15).setFill()
            NSBezierPath(roundedRect: NSRect(x: detailX, y: midY - 3, width: 120, height: 6),
                         xRadius: 3, yRadius: 3).fill()
            let fillWidth = 120 * clamped
            if fillWidth > 0 {
                NSColor.white.setFill()
                NSBezierPath(roundedRect: NSRect(x: detailX, y: midY - 3, width: fillWidth, height: 6),
                             xRadius: min(3, fillWidth / 2), yRadius: min(3, fillWidth / 2)).fill()
            }
        case nil:
            break
        }
    }

    private func drawClosed() {
        // Positions follow the window height: the closed pill is 32
        // tall, and the collapse animation passes through intermediate
        // heights — fixed y values would drift off-center.
        let midY = bounds.height / 2
        // Pomodoro live (running or paused mid-countdown) takes the
        // pill over lyrics/music: a running timer is a live activity,
        // like DynamicNotch's timer indicator. Small ring (mode color,
        // remaining fraction) + countdown in the 160x32 pill — no
        // clock, battery, or waveform. Paused reads dimmer (frozen).
        if isPomodoroActive {
            let remaining = pomodoroRemainingNow()
            let fraction = pomodoroDuration > 0 ? max(0, min(1, remaining / pomodoroDuration)) : 0
            let dim = pomodoroIsRunning ? 1.0 : 0.5
            drawProgressRing(center: CGPoint(x: 30, y: midY), radius: 8, width: 2,
                             fraction: fraction, color: pomodoroColor.withAlphaComponent(dim))
            drawCentered(pomodoroTimeString(remaining),
                         font: NSFont.systemFont(ofSize: 15, weight: .semibold),
                         color: pomodoroIsRunning ? .white : NSColor.white.withAlphaComponent(0.7),
                         y: midY - 9)
            return
        }
        // Lyrics mode (card was closed from the lyrics page): mascot
        // + current lyric line, the line centered on the pill — never
        // clock, battery icon, or waveform. Without a synced line, the
        // song title stands in.
        if lyricsMode, let session {
            drawLyricsMascot(center: CGPoint(x: 12 + lyricsMascotDrawSize / 2, y: midY),
                             size: lyricsMascotDrawSize, playing: session.isPlaying)
            let line = lyricCurrent ?? session.title
            let font = lyricsPillFont
            let textW = bounds.width - lyricsTextX - lyricsTextRightPad
            let shown = truncated(line, toWidth: textW, font: font)
            let w = (shown as NSString).size(withAttributes: [.font: font]).width
            drawText(shown, font: font, color: .white,
                     at: NSPoint(x: lyricsTextX + (textW - w) / 2, y: midY - 8))
            return
        }
        // The plain music pill is 180 wide: battery icon + clock +
        // waveform, tightened to fit — smaller battery icon left,
        // clock centered, narrower waveform at the right edge. All
        // three stay inside the 12pt tuck (sides at 12 and width-12).
        // Padding: the battery icon sits 6pt inside the left edge
        // and the waveform ends 10pt before the right edge, so the
        // contents never hug the pill's border (at any width,
        // including mid-collapse-animation frames).
        let appearance = AuraSettings.shared
        if appearance.showBattery {
            drawBatteryIcon(center: CGPoint(x: 30, y: midY), percent: batteryPercent, charging: batteryCharging)
        }
        if appearance.showClock {
            drawCentered(Self.clockFormatter.string(from: Date()),
                         font: NSFont.systemFont(ofSize: 15, weight: .semibold),
                         color: .white, y: midY - 9)
        }
        if appearance.showWaveform {
            let waveHeight: CGFloat = bounds.height <= 40 ? 14 : 20
            drawWaveform(in: NSRect(x: bounds.width - 50, y: midY - waveHeight / 2, width: 28, height: waveHeight))
        }
    }

    // MARK: - Expanded card

    /// Placeholder session for the no-media music template: same
    /// layout as a real track, placeholder text, empty bar, dimmed
    /// (inert) controls.
    private var placeholderSession: DisplaySession {
        DisplaySession(id: "placeholder", label: "", title: "No music playing",
                       artist: "Start playback in any app", isPlaying: false,
                       position: 0, duration: 0, artwork: nil, supportsNextPrev: false)
    }

    private func drawExpanded() {
        // Pomodoro, todo, water, and tray work without music (their
        // own timer, list, reminder, and file shelf), so they bypass
        // the no-media guard every other page sits behind.
        if currentPage == .pomodoro {
            drawPomodoro()
        } else if currentPage == .todo {
            drawTodo()
        } else if currentPage == .water {
            drawWater()
        } else if currentPage == .tray {
            drawTray()
        } else if currentPage == .removeBg {
            drawRemoveBg()
        } else if currentPage == .convert {
            drawConvert()
        } else {
            guard let session else {
                // No session: the music pages keep their full
                // template with placeholders (cover box, title and
                // artist lines, empty bar, dimmed controls) instead
                // of a bare "No media playing" line. Other pages
                // keep the line: the sources picker has no template
                // to preserve.
                if currentPage == .music {
                    drawMusicCard(placeholderSession, placeholder: true)
                } else if currentPage == .lyrics {
                    drawMusicCard(placeholderSession, lyricsOpen: true, placeholder: true)
                    drawLyricsPanel()
                } else {
                    drawCentered("No media playing",
                                 font: NSFont.systemFont(ofSize: 13),
                                 color: NSColor.white.withAlphaComponent(0.7),
                                 y: bounds.height / 2 - 8)
                }
                // Still draw dots: without music the usable sections
                // are pomodoro, todo, and water, and the user reaches
                // them from here (their dots).
                drawPageDots()
                return
            }
            switch currentPage {
            case .music:
                drawMusicCard(session)
            case .lyrics:
                // 700x180: same height as the music card, only wider.
                // The music part compresses (title and progress narrower,
                // see drawMusicCard) and the lyrics panel takes the right
                // portion inside the same card, like Nusa. No header here:
                // the lyrics page shows no clock or waveform.
                drawMusicCard(session, lyricsOpen: true)
                drawLyricsPanel()
            case .sources:
                drawCardHeader()
                drawPicker(startY: 64)
            case .pomodoro, .todo, .water, .tray, .removeBg, .convert:
                break // handled above
            }
        }
        drawPageDots()
    }

    /// Header for the card pages, like Nusa's music card: green dot
    /// + date/time, waveform top-right. Used on the music, pomodoro, and sources
    /// pages; the lyrics page has no header at all — no
    /// clock, no waveform. No battery icon here — the reference card
    /// has none; the icon lives in the closed state.
    /// showWaveform defaults to true (music, pomodoro, tray,
    /// sources keep it). Tool sections (Remove BG, Convert) pass
    /// false: a decorative audio waveform does not belong on a
    /// non-audio tool, and on Remove BG it would sit behind the
    /// model pill at the top-right.
    private func drawCardHeader(width: CGFloat = 640, showWaveform: Bool = true) {
        let dateStr = Self.headerDateFormatter.string(from: Date())
        let dateFont = NSFont.systemFont(ofSize: 13, weight: .medium)
        let dateWidth = (dateStr as NSString).size(withAttributes: [.font: dateFont]).width
        let groupWidth = dateWidth + 16
        let groupX = (width - groupWidth) / 2
        NSColor.systemGreen.setFill()
        NSBezierPath(ovalIn: NSRect(x: groupX, y: 17, width: 8, height: 8)).fill()
        drawText(dateStr, font: dateFont, color: .white, at: NSPoint(x: groupX + 16, y: 14))
        if showWaveform {
            drawWaveform(in: NSRect(x: width - 68, y: 14, width: 48, height: 16))
        }
    }

    /// Music card, modelled on Nusa's music card: header, artwork,
    /// big title/artist, full-width progress, and controls. The dense
    /// 520x180 card — 56px artwork,
    /// tighter gaps — shorter but packed, shared by the music page
    /// and the lyrics page's music part (same vertical positions, so
    /// switching pages never moves it). The lyrics page reuses it
    /// with lyricsOpen: like Nusa, opening lyrics compresses the
    /// music part into 340px (title/artist 212, progress bar 172,
    /// controls centered on 170) and the lyrics panel takes the right
    /// portion of the slightly wider 700-wide card — and the header
    /// (clock + waveform) is omitted there. The right section
    /// arrow is omitted there too (the panel occupies that edge).
    /// One music-card button: symbol at its animated zoom size
    /// (20pt normal, up to 24pt hovered). No glow circle: the
    /// smooth swell alone signals hover.
    private func drawMusicButton(_ name: String, fallback: String, center: CGPoint,
                                 region: MusicHoverRegion, color: NSColor) {
        let size = 20 * (buttonZoomCurrent[region] ?? 1.0)
        drawSymbol(name, size: size, center: center, fallback: fallback, color: color)
    }

    private func drawMusicCard(_ session: DisplaySession, lyricsOpen: Bool = false, placeholder: Bool = false) {
        // No header on the lyrics page: no clock, no waveform.
        if !lyricsOpen {
            drawCardHeader(width: 520)
        }
        // Dense vertical layout, shared by both pages: cover 36,
        // progress 104, controls 140. Only the horizontal compression
        // differs (lyrics page: 340-wide music part).
        drawArtwork(artworkThumb(for: session), in: NSRect(x: 36, y: 36, width: 56, height: 56), cornerRadius: 12)
        let textWidth: CGFloat = lyricsOpen ? 212 : 340
        let titleFont = NSFont.boldSystemFont(ofSize: 25)
        drawText(truncated(session.title, toWidth: textWidth, font: titleFont),
                 font: titleFont, color: .white, at: NSPoint(x: 116, y: 36))
        let artistFont = NSFont.systemFont(ofSize: 16)
        drawText(truncated(session.artist, toWidth: textWidth, font: artistFont),
                 font: artistFont, color: NSColor.white.withAlphaComponent(0.65),
                 at: NSPoint(x: 116, y: 68))
        if lyricsOpen {
            drawProgress(session, elapsedX: 36, barX: 96, barWidth: 164, rightX: 320,
                         y: 104, font: NSFont.systemFont(ofSize: 12), barHeight: 4)
        } else {
            drawProgress(session, elapsedX: 36, barX: 96, barWidth: 324, rightX: 484,
                         y: 104, font: NSFont.systemFont(ofSize: 12), barHeight: 4)
        }
        // Hover aliveness: the hovered button swells smoothly
        // (animated zoom, no glow). Placeholder buttons are
        // dimmed and never highlight (they do nothing).
        let dim = placeholder ? NSColor.white.withAlphaComponent(0.35) : NSColor.white
        if AuraSettings.shared.lyricsEnabled {
            drawMusicButton("ellipsis.bubble.fill", fallback: "···", center: CGPoint(x: 56, y: 140),
                            region: placeholder ? .none : .bubble, color: dim)
        }
        let controls: [CGFloat] = lyricsOpen ? [118, 170, 222] : [208, 260, 312]
        let symbols = ["backward.fill", session.isPlaying ? "pause.fill" : "play.fill", "forward.fill"]
        let fallbacks = ["‹", session.isPlaying ? "❚❚" : "▶", "›"]
        for i in 0..<3 {
            drawMusicButton(symbols[i], fallback: fallbacks[i],
                            center: CGPoint(x: controls[i], y: 140),
                            region: placeholder ? .none : .control(i), color: dim)
        }
    }

    private var cachedThumbKey: String?
    private var cachedThumb: NSImage?

    /// 96px aspect-fill thumbnail of the session artwork, cached per
    /// track. Scaling the full 600px cover on every 10x/second waveform
    /// redraw is the most expensive part of a frame; the thumbnail
    /// makes redraws cheap, which is what stuttered when the pill opened.
    private func artworkThumb(for session: DisplaySession) -> NSImage? {
        guard let artwork = session.artwork else { return nil }
        let key = "\(session.title)|\(session.artist)"
        if key != cachedThumbKey || cachedThumb == nil {
            cachedThumbKey = key
            cachedThumb = aspectFillThumb(artwork, size: 96)
        }
        return cachedThumb
    }

    private func aspectFillThumb(_ image: NSImage, size: CGFloat) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        let imgSize = image.size
        let scale = max(size / imgSize.width, size / imgSize.height)
        let srcW = size / scale
        let srcH = size / scale
        let src = NSRect(x: (imgSize.width - srcW) / 2, y: (imgSize.height - srcH) / 2,
                         width: srcW, height: srcH)
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
                   from: src, operation: .sourceOver, fraction: 1.0)
        img.unlockFocus()
        return img
    }

    /// Lyrics panel for the lyrics page: a divider, then the lyrics
    /// column on the right of the compressed music part (x 352..660,
    /// 308 wide), inside the slightly extended 700-wide card. The
    /// divider sits beside the song title: the title ends at most at
    /// 328 (116 + 212), and the divider is at 340.
    /// A long lyric line wraps onto a second line instead of being
    /// cut off with "…", so no lyric is ever truncated mid-line.
    private func drawLyricsPanel() {
        // Divider between the compressed music part (left) and the panel.
        // 28..158: it spans the panel's text area (the dots are now
        // a vertical column on the right edge, so nothing crosses it).
        NSColor.white.withAlphaComponent(0.12).setFill()
        NSRect(x: 340, y: 28, width: 1, height: 130).fill()
        // Lyrics column: dim previous, bold current, dim next,
        // stacked as a block centered in the panel (28..158).
        // While a slot roll runs, the roll strip replaces this block
        // (see startLyricRoll); the divider above stays fixed — it
        // is the window's frame, not part of the reel.
        let x: CGFloat = 352
        let width: CGFloat = 308
        if isRolling {
            for line in rollLines {
                let y = line.startTop - rollDistance * rollProgress
                let scale = line.scaleFrom + (line.scaleTo - line.scaleFrom) * rollProgress
                let alpha = line.alphaFrom + (line.alphaTo - line.alphaFrom) * rollProgress
                let color = NSColor.white.withAlphaComponent(alpha)
                let centerY = y + line.height / 2
                if scale != 1.0, let ctx = NSGraphicsContext.current?.cgContext {
                    // Scale about the line's LEFT edge, not the panel
                    // center. Center scaling moved a shrinking line's
                    // left edge to the right during the roll, then it
                    // snapped back left at commit — the rightward
                    // shift the user reported on incoming/passed
                    // lines. Left-anchored, the focus line only zooms
                    // in place and passed lines only travel up and
                    // fade; no line ever moves right.
                    // Wrapped lines were fixed at roll start, so the
                    // scale never reflows text.
                    ctx.saveGState()
                    ctx.translateBy(x: x, y: centerY)
                    ctx.scaleBy(x: scale, y: scale)
                    ctx.translateBy(x: -x, y: -centerY)
                    var ly = y
                    for text in line.lines {
                        drawText(text, font: line.font, color: color, at: NSPoint(x: x, y: ly))
                        ly += lyricLineHeight(line.font)
                    }
                    ctx.restoreGState()
                } else {
                    var ly = y
                    for text in line.lines {
                        drawText(text, font: line.font, color: color, at: NSPoint(x: x, y: ly))
                        ly += lyricLineHeight(line.font)
                    }
                }
            }
            return
        }
        struct Entry { let lines: [String]; let font: NSFont; let color: NSColor }
        var entries: [Entry] = []
        if let prev = lyricPrev {
            let font = NSFont.systemFont(ofSize: 15)
            entries.append(Entry(lines: wrappedLines(prev, font: font, width: width, maxLines: 2),
                                 font: font, color: NSColor.white.withAlphaComponent(0.35)))
        }
        if let current = lyricCurrent {
            let font = NSFont.boldSystemFont(ofSize: 19)
            entries.append(Entry(lines: wrappedLines(current, font: font, width: width, maxLines: 2),
                                 font: font, color: .white))
        }
        if let next = lyricNext {
            let font = NSFont.systemFont(ofSize: 15)
            entries.append(Entry(lines: wrappedLines(next, font: font, width: width, maxLines: 2),
                                 font: font, color: NSColor.white.withAlphaComponent(0.45)))
        }
        guard !entries.isEmpty else {
            drawText("Lyrics unavailable",
                     font: NSFont.systemFont(ofSize: 14),
                     color: NSColor.white.withAlphaComponent(0.4),
                     at: NSPoint(x: x, y: 81))
            return
        }
        // Stack the entries with a small fixed gap that shrinks to
        // zero if every entry wraps to two lines (the caps keep the
        // text itself within the panel height).
        let textHeight = entries.reduce(0) { $0 + CGFloat($1.lines.count) * lyricLineHeight($1.font) }
        let gapCount = max(0, entries.count - 1)
        let gap: CGFloat = gapCount > 0 ? min(10, max(0, (130 - textHeight) / CGFloat(gapCount))) : 0
        var y = 28 + (130 - (textHeight + gap * CGFloat(gapCount))) / 2
        for entry in entries {
            for line in entry.lines {
                drawText(line, font: entry.font, color: entry.color, at: NSPoint(x: x, y: y))
                y += lyricLineHeight(entry.font)
            }
            y += gap
        }
    }

    /// Splits a lyric line into visual lines that fit `width`,
    /// wrapping on word boundaries (a single over-long word is broken
    /// by character). Capped at `maxLines`; any remainder is folded
    /// into an ellipsis on the last line, so a very long line still
    /// never exceeds the panel.
    private func wrappedLines(_ text: String, font: NSFont, width: CGFloat, maxLines: Int) -> [String] {
        let maxLines = max(1, maxLines)
        let normalized = text.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        func w(_ s: String) -> CGFloat { (s as NSString).size(withAttributes: attrs).width }
        guard w(normalized) > width else { return [normalized] }
        // Split over-long words by character so every piece fits.
        var pieces: [String] = []
        for word in normalized.split(separator: " ", omittingEmptySubsequences: true) {
            var remaining = String(word)
            while w(remaining) > width {
                var filled = ""
                for ch in remaining {
                    if w(filled + String(ch)) <= width { filled.append(ch) } else { break }
                }
                if filled.isEmpty { filled = String(remaining.prefix(1)) }
                pieces.append(filled)
                remaining = String(remaining.dropFirst(filled.count))
            }
            if !remaining.isEmpty { pieces.append(remaining) }
        }
        var lines: [String] = []
        var current = ""
        for piece in pieces {
            if current.isEmpty {
                current = piece
            } else if w(current + " " + piece) <= width {
                current += " " + piece
            } else {
                lines.append(current)
                if lines.count == maxLines {
                    // No room for more lines: the rest is signalled
                    // with an ellipsis on this last line.
                    var last = lines[lines.count - 1]
                    while !last.isEmpty && w(last + "…") > width { last = String(last.dropLast()) }
                    lines[lines.count - 1] = last + "…"
                    return lines
                }
                current = piece
            }
        }
        if !current.isEmpty {
            if lines.count < maxLines {
                lines.append(current)
            } else {
                var last = lines[lines.count - 1]
                while !last.isEmpty && w(last + "…") > width { last = String(last.dropLast()) }
                lines[lines.count - 1] = last + "…"
            }
        }
        return lines
    }

    private func drawProgress(_ session: DisplaySession, elapsedX: CGFloat, barX: CGFloat,
                              barWidth: CGFloat, rightX: CGFloat, y: CGFloat,
                              font: NSFont, barHeight: CGFloat) {
        // Realtime position, not the raw sensor snapshot (see
        // livePosition): the bar and times move between sensor polls.
        // During a seek drag the dragged preview wins.
        let pos = seekPreviewPosition ?? livePosition
        drawText(formatTime(pos), font: font, color: .white,
                 at: NSPoint(x: elapsedX, y: y))
        // Hover/drag state: a thicker bar, so the bar reads
        // as draggable. Only for seekable tracks (duration > 0).
        let barHit = NSRect(x: barX, y: y, width: barWidth, height: 16)
        let hoveringBar = session.duration > 0
            && (progressDrag != nil
                || (hoverPoint.map { barHit.contains($0) } ?? false))
        let h = hoveringBar ? barHeight + 2 : barHeight
        let barTop = y + 6 - (h - barHeight) / 2
        let bg = NSBezierPath(roundedRect: NSRect(x: barX, y: barTop, width: barWidth, height: h),
                              xRadius: h / 2, yRadius: h / 2)
        NSColor.white.withAlphaComponent(0.25).setFill()
        bg.fill()
        // No (or unknown) duration: the template still shows an
        // empty track (placeholder card, unknown-length streams)
        // instead of no bar at all.
        guard session.duration > 0 else {
            drawRightAligned("0:00", font: font, color: .white, rightX: rightX, y: y)
            return
        }
        drawRightAligned("-\(formatTime(session.duration - pos))",
                         font: font, color: .white, rightX: rightX, y: y)
        let filled = min(1.0, pos / session.duration)
        let fg = NSBezierPath(roundedRect: NSRect(x: barX, y: barTop, width: barWidth * CGFloat(filled), height: h),
                              xRadius: h / 2, yRadius: h / 2)
        NSColor.white.setFill()
        fg.fill()
    }

    private func drawPageDots() {
        let rects = dotRects()
        for (i, rect) in rects.enumerated() {
            if availableSections[i] == sectionForDots {
                let dash = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
                NSColor.white.setFill()
                dash.fill()
            } else {
                let dot = NSBezierPath(ovalIn: rect)
                NSColor.white.withAlphaComponent(0.3).setFill()
                dot.fill()
            }
        }
    }

    private static var symbolCache: [String: NSImage] = [:]

    /// Draws a white SF Symbol centered at a point, tinted from the
    /// symbol's alpha (SF Symbols rasterize black by default). Falls
    /// back to a text glyph if the symbol is unavailable.
    /// Draws an image upright in this flipped view. NSImage
    /// drawing in a flipped context flips the image vertically —
    /// the cover code already counter-flips for that reason, but
    /// drawSymbol never did, so every SF Symbol was upside down.
    /// Most symbols hide it (symmetric shapes), but the bell is
    /// asymmetric (dome on top, clapper below), so the water
    /// toggle's bell read as clearly inverted. Counter-flipping
    /// here fixes all symbols at once, bell included.
    private func drawImageUpright(_ img: NSImage, in rect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else {
            img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
            return
        }
        ctx.saveGState()
        ctx.translateBy(x: 0, y: rect.minY + rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
        ctx.restoreGState()
    }

    private func drawSymbol(_ name: String, size: CGFloat, center: CGPoint, fallback: String, color: NSColor = .white) {
        let key = "\(name)-\(Int(size))"
        let rect = NSRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
        if color == .white, let cached = Self.symbolCache[key] {
            drawImageUpright(cached, in: rect)
            return
        }
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
            drawCenteredText(fallback, font: NSFont.systemFont(ofSize: size), color: color, center: center)
            return
        }
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        base.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero,
                  operation: .sourceOver, fraction: 1.0)
        color.set()
        // Tint: source-in keeps the SOURCE color masked by the
        // symbol's alpha. destination-in would keep the DESTINATION
        // color — the symbol rasterizes black — which is why the
        // buttons rendered black-on-black and looked dim instead of
        // white. (The cached image is per-launch, so a fresh build
        // picks the white version up. Only white is cached; tinted
        // variants are drawn fresh each time so they never collide
        // in the cache.)
        NSRect(x: 0, y: 0, width: size, height: size).fill(using: .sourceIn)
        img.unlockFocus()
        if color == .white {
            Self.symbolCache[key] = img
        }
        drawImageUpright(img, in: rect)
    }

    /// Lyrics mascot: the white headset-wearing mascot, replacing
    /// the music-note glyph in the compact lyrics pill. Loaded once
    /// from the bundle; drawn clipped to a circle so its gray
    /// backdrop never shows as a tile on the black pill. Falls back
    /// to the note glyph when the asset is missing (old package script).
    private static var lyricsMascot: NSImage? = {
        guard let path = Bundle.main.path(forResource: "AuraLyricsMascot", ofType: "png"),
              let img = NSImage(contentsOfFile: path) else { return nil }
        return img
    }()

    /// Groove phase for the lyrics mascot; advances with
    /// wall-clock time while the song plays, freezing the nod
    /// mid-bob on pause.
    private var mascotPhase: Double = 0
    private var mascotLastTick: Date = Date()

    /// Mascot eye centers in image-normalized coordinates, measured
    /// from the asset (used for the blink overlay).
    private let mascotEyeL = CGPoint(x: 0.4343, y: 0.5131)
    private let mascotEyeR = CGPoint(x: 0.5638, y: 0.5131)
    private let mascotEyeRadius: CGFloat = 0.024

    /// The mascot, grooving: a vertical nod plus a slight rocking
    /// tilt while the song plays, and a quick blink every few
    /// seconds. The asset has a transparent background, so no clip
    /// is needed — it floats straight on the black pill.
    private func drawLyricsMascot(center: CGPoint, size: CGFloat, playing: Bool) {
        guard let img = Self.lyricsMascot else {
            drawSymbol("music.note", size: size, center: center, fallback: "♪")
            return
        }
        let now = Date()
        if playing {
            mascotPhase += now.timeIntervalSince(mascotLastTick) * 2 * .pi * 1.5
        }
        mascotLastTick = now
        let bob = sin(mascotPhase) * 1.5
        let rock = sin(mascotPhase * 0.5) * 0.05
        let rect = NSRect(x: center.x - size / 2, y: center.y - size / 2 + bob,
                          width: size, height: size)
        guard let ctx = NSGraphicsContext.current?.cgContext else {
            drawImageUpright(img, in: rect)
            return
        }
        ctx.saveGState()
        let pivot = CGPoint(x: center.x, y: center.y + bob)
        ctx.translateBy(x: pivot.x, y: pivot.y)
        ctx.rotate(by: rock)
        ctx.translateBy(x: -pivot.x, y: -pivot.y)
        drawImageUpright(img, in: rect)
        // Blink: briefly cover both eyes with the mascot's own white.
        let blinkPhase = now.timeIntervalSince1970.truncatingRemainder(dividingBy: 3.4)
        if blinkPhase < 0.12 {
            NSColor.white.setFill()
            for eye in [mascotEyeL, mascotEyeR] {
                let p = CGPoint(x: rect.minX + eye.x * size,
                                y: rect.minY + eye.y * size)
                let r = mascotEyeRadius * size
                NSBezierPath(roundedRect: NSRect(x: p.x - r * 1.5, y: p.y - r,
                                                width: r * 3, height: r * 2),
                             xRadius: r, yRadius: r).fill()
            }
        }
        ctx.restoreGState()
    }

    private func drawCenteredText(_ text: String, font: NSFont, color: NSColor, center: CGPoint) {
        let size = (text as NSString).size(withAttributes: [.font: font])
        drawText(text, font: font, color: color,
                 at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
    }

    private func drawPicker(startY: CGFloat) {
        let header = pinnedId == nil
            ? "Source: Auto (follow the active one)"
            : "Source: Pinned — click a source to unpin"
        drawText(header, font: NSFont.systemFont(ofSize: 11),
                 color: NSColor.white.withAlphaComponent(0.55),
                 at: NSPoint(x: 40, y: startY))
        var y = startY + 24
        let rowFont = NSFont.systemFont(ofSize: 12)
        for item in sessionsForPicker.prefix(4) {
            let mark = item.id == pinnedId ? "● " : "○ "
            let label = "\(mark)\(item.label) — \(item.title)"
            drawText(truncated(label, toWidth: 460, font: rowFont),
                     font: rowFont, color: .white, at: NSPoint(x: 40, y: y))
            y += 22
        }
    }

    // MARK: - Pomodoro

    /// Pomodoro timer section (640x180, like the reference screenshot):
    /// title + header, progress ring + stopwatch on the left, big
    /// countdown + reset + mode label on the right, mode pills below.
    /// The timer is wall-clock based (endDate), so it keeps counting
    /// while the card is closed and shows the right remaining time on
    /// reopen; AppDelegate's 1s refresh redraws it. The ring shows
    /// REMAINING fraction (full at the start, empty at the end) — that
    /// is why the reference screenshot's fresh 25:00 timer has a full
    /// red ring. Focus is red, short break is green. The play pill
    /// takes the mode color too.
    private enum PomodoroMode { case focus, shortBreak }
    private var pomodoroMode: PomodoroMode = .focus
    private var pomodoroIsRunning = false
    private var pomodoroEndDate: Date?
    private var pomodoroRemaining: TimeInterval = 25 * 60

    /// True when a pomodoro countdown is live (running, or paused
    /// mid-countdown). Fresh (full duration, never started) and
    /// finished (0 remaining) do not count — the pill reverts to
    /// music/zen then. AppDelegate uses this to keep the pill in
    /// compact (not zen) while a pomodoro runs without music.
    var isPomodoroActive: Bool {
        pomodoroIsRunning || (pomodoroRemaining > 0 && pomodoroRemaining < pomodoroDuration)
    }

    private var pomodoroDuration: TimeInterval {
        pomodoroMode == .focus ? 25 * 60 : 5 * 60
    }

    private var pomodoroColor: NSColor {
        pomodoroMode == .focus ? .systemRed : .systemGreen
    }

    /// Remaining seconds right now. While running it is wall-clock
    /// (endDate minus now); while paused it is the stored value. When
    /// the countdown reaches zero it flips to stopped here (the 1s
    /// refresh drives this; no dedicated timer is needed).
    private func pomodoroRemainingNow() -> TimeInterval {
        if pomodoroIsRunning, let end = pomodoroEndDate {
            let left = end.timeIntervalSinceNow
            if left <= 0 {
                pomodoroIsRunning = false
                pomodoroEndDate = nil
                pomodoroRemaining = 0
                return 0
            }
            return left
        }
        return pomodoroRemaining
    }

    private func pomodoroTimeString(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func togglePomodoro() {
        if pomodoroIsRunning {
            pomodoroRemaining = pomodoroRemainingNow()
            pomodoroEndDate = nil
            pomodoroIsRunning = false
        } else {
            if pomodoroRemaining <= 0 { pomodoroRemaining = pomodoroDuration }
            pomodoroEndDate = Date().addingTimeInterval(pomodoroRemaining)
            pomodoroIsRunning = true
        }
        needsDisplay = true
    }

    private func resetPomodoro() {
        pomodoroIsRunning = false
        pomodoroEndDate = nil
        pomodoroRemaining = pomodoroDuration
        needsDisplay = true
    }

    private func setPomodoroMode(_ mode: PomodoroMode) {
        guard mode != pomodoroMode else { return }
        pomodoroMode = mode
        pomodoroIsRunning = false
        pomodoroEndDate = nil
        pomodoroRemaining = pomodoroDuration
        needsDisplay = true
    }

    /// Hit rects for the pomodoro buttons, computed from the same
    /// layout drawPomodoro uses, so hit and drawn always agree.
    private func pomodoroButtonRects() -> (shortBreak: NSRect, play: NSRect, focus: NSRect, reset: NSRect) {
        let pillY: CGFloat = 130
        let pillH: CGFloat = 28
        let shortWidth = pomodoroModePillWidth(label: "Short Break")
        let focusWidth = pomodoroModePillWidth(label: "Focus Time")
        let shortBreak = NSRect(x: 220, y: pillY, width: shortWidth, height: pillH)
        let play = NSRect(x: shortBreak.maxX + 8, y: pillY, width: 56, height: pillH)
        let focus = NSRect(x: play.maxX + 8, y: pillY, width: focusWidth, height: pillH)
        let reset = NSRect(x: 362, y: 58, width: 32, height: 32)
        return (shortBreak, play, focus, reset)
    }

    private func pomodoroModePillWidth(label: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 14, weight: .medium)
        let textWidth = (label as NSString).size(withAttributes: [.font: font]).width
        return 12 + 16 + 6 + textWidth + 12
    }

    /// Progress ring: background circle (white 0.15) + remaining-
    /// fraction arc (color, clockwise from the top). Built
    /// point-by-point, not with NSBezierPath arcs, so the direction
    /// is correct in this flipped view regardless of angle
    /// conventions. Shared by the big pomodoro ring and the small
    /// closed-pill ring.
    private func drawProgressRing(center: CGPoint, radius: CGFloat, width: CGFloat,
                                  fraction: Double, color: NSColor) {
        NSColor.white.withAlphaComponent(0.15).setStroke()
        let bg = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                             width: radius * 2, height: radius * 2))
        bg.lineWidth = width
        bg.stroke()
        guard fraction > 0 else { return }
        let steps = max(2, Int(fraction * 72))
        let path = NSBezierPath()
        for i in 0...steps {
            let theta = -Double.pi / 2 + (Double(i) / Double(steps)) * fraction * 2 * Double.pi
            let pt = NSPoint(x: center.x + radius * CGFloat(cos(theta)),
                             y: center.y + radius * CGFloat(sin(theta)))
            if i == 0 { path.move(to: pt) } else { path.line(to: pt) }
        }
        color.setStroke()
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    private func drawPomodoro() {
        drawCardHeader(width: 640)
        drawText("Pomodoro", font: NSFont.boldSystemFont(ofSize: 20), color: .white, at: NSPoint(x: 28, y: 10))
        // Progress ring (left): background + remaining arc (shared
        // helper) + tinted interior + stopwatch.
        let ringCenter = CGPoint(x: 130, y: 100)
        let ringRadius: CGFloat = 42
        let ringWidth: CGFloat = 8
        let remaining = pomodoroRemainingNow()
        let fraction = pomodoroDuration > 0 ? max(0, min(1, remaining / pomodoroDuration)) : 0
        drawProgressRing(center: ringCenter, radius: ringRadius, width: ringWidth,
                         fraction: fraction, color: pomodoroColor)
        pomodoroColor.withAlphaComponent(0.15).setFill()
        NSBezierPath(ovalIn: NSRect(x: ringCenter.x - 33, y: ringCenter.y - 33, width: 66, height: 66)).fill()
        drawSymbol("stopwatch", size: 36, center: ringCenter, fallback: "◷")
        // Countdown (right) + reset + mode label.
        drawText(pomodoroTimeString(remaining), font: NSFont.boldSystemFont(ofSize: 44), color: .white,
                 at: NSPoint(x: 220, y: 48))
        let buttons = pomodoroButtonRects()
        NSColor.white.withAlphaComponent(0.12).setFill()
        NSBezierPath(ovalIn: buttons.reset).fill()
        drawSymbol("arrow.clockwise", size: 16,
                   center: CGPoint(x: buttons.reset.midX, y: buttons.reset.midY), fallback: "↻")
        drawText(pomodoroMode == .focus ? "Focus time" : "Short break",
                 font: NSFont.systemFont(ofSize: 16),
                 color: NSColor.white.withAlphaComponent(0.6), at: NSPoint(x: 220, y: 106))
        // Mode pills: Short Break, play/pause (mode color), Focus Time.
        // The active mode pill is brighter, so the mode reads at a glance.
        func modePill(_ rect: NSRect, icon: String, iconFallback: String, label: String, active: Bool) {
            (active ? NSColor.white.withAlphaComponent(0.22) : NSColor.white.withAlphaComponent(0.10)).setFill()
            NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
            drawSymbol(icon, size: 16, center: CGPoint(x: rect.minX + 20, y: rect.midY), fallback: iconFallback)
            drawText(label, font: NSFont.systemFont(ofSize: 14, weight: .medium),
                     color: active ? .white : NSColor.white.withAlphaComponent(0.75),
                     at: NSPoint(x: rect.minX + 34, y: rect.minY + 6))
        }
        modePill(buttons.shortBreak, icon: "cup.and.saucer", iconFallback: "●", label: "Short Break", active: pomodoroMode == .shortBreak)
        pomodoroColor.setFill()
        NSBezierPath(roundedRect: buttons.play, xRadius: buttons.play.height / 2, yRadius: buttons.play.height / 2).fill()
        drawSymbol(pomodoroIsRunning ? "pause.fill" : "play.fill", size: 16,
                   center: CGPoint(x: buttons.play.midX, y: buttons.play.midY),
                   fallback: pomodoroIsRunning ? "❚❚" : "▶")
        modePill(buttons.focus, icon: "target", iconFallback: "◎", label: "Focus Time", active: pomodoroMode == .focus)
    }

    // MARK: - Todo

    /// One task: persisted in UserDefaults (JSON) so it survives
    /// relaunch. No cloud, no account — a local list, like Nusa's
    /// todo. Shown incomplete-first (oldest first), up to 4 rows;
    /// completing a task reveals the next one in line.
    private struct TodoTask: Codable {
        var id: UUID
        var text: String
        var done: Bool
        var createdAt: Date
    }

    private var todoTasks: [TodoTask] = []
    private var todoTasksLoaded = false
    private let todoTasksDefaultsKey = "AuraTodoTasks"

    private func loadTodoTasksIfNeeded() {
        guard !todoTasksLoaded else { return }
        todoTasksLoaded = true
        guard let data = UserDefaults.standard.data(forKey: todoTasksDefaultsKey),
              let decoded = try? JSONDecoder().decode([TodoTask].self, from: data) else { return }
        todoTasks = decoded
    }

    private func saveTodoTasks() {
        guard let data = try? JSONEncoder().encode(todoTasks) else { return }
        UserDefaults.standard.set(data, forKey: todoTasksDefaultsKey)
    }

    private func todoSortedTasks() -> [TodoTask] {
        loadTodoTasksIfNeeded()
        return todoTasks.sorted { a, b in
            if a.done != b.done { return !a.done }
            return a.createdAt < b.createdAt
        }
    }

    /// Visible rows (same rects as drawn, so hit == drawn): the
    /// right column (x280-600), rows from y52, height 32, pitch 40,
    /// max 4. pillRect is the drawn pill (full width, ending at W-40
    /// so the right-edge dot column never overlaps it); rowRect is
    /// the toggle area (x280-568); deleteRect is the 24px delete
    /// square at x576-600.
    private func todoVisibleRows() -> [(task: TodoTask, pillRect: NSRect, rowRect: NSRect, deleteRect: NSRect)] {
        todoSortedTasks().prefix(4).enumerated().map { i, task in
            let y: CGFloat = 52 + CGFloat(i) * 40
            return (task: task,
                    pillRect: NSRect(x: 280, y: y, width: 320, height: 32),
                    rowRect: NSRect(x: 280, y: y, width: 288, height: 32),
                    deleteRect: NSRect(x: 576, y: y, width: 24, height: 32))
        }
    }

    /// The "+ Add task" pill (left column, y120-148). Measured
    /// from its text so hit == drawn, like the pomodoro pills.
    private func todoAddPillRect() -> NSRect {
        let font = NSFont.systemFont(ofSize: 14)
        let plusW = ("+" as NSString).size(withAttributes: [.font: font]).width
        let textW = ("Add task" as NSString).size(withAttributes: [.font: font]).width
        return NSRect(x: 28, y: 120, width: 12 + plusW + 6 + textW + 12, height: 28)
    }

    private func toggleTodoTask(id: UUID) {
        loadTodoTasksIfNeeded()
        guard let i = todoTasks.firstIndex(where: { $0.id == id }) else { return }
        todoTasks[i].done.toggle()
        saveTodoTasks()
        needsDisplay = true
    }

    private func deleteTodoTask(id: UUID) {
        loadTodoTasksIfNeeded()
        todoTasks.removeAll { $0.id == id }
        saveTodoTasks()
        needsDisplay = true
    }

    private func drawTodo() {
        drawCardHeader(width: 640)
        drawText("Todo", font: NSFont.boldSystemFont(ofSize: 20), color: .white, at: NSPoint(x: 28, y: 10))
        // Left column: progress + add.
        loadTodoTasksIfNeeded()
        let total = todoTasks.count
        let doneCount = todoTasks.filter { $0.done }.count
        if total > 0 {
            drawText("\(doneCount)/\(total)", font: NSFont.boldSystemFont(ofSize: 28), color: .white, at: NSPoint(x: 28, y: 52))
            drawText("done", font: NSFont.systemFont(ofSize: 12), color: NSColor.white.withAlphaComponent(0.6), at: NSPoint(x: 28, y: 88))
        } else {
            drawText("No tasks yet", font: NSFont.systemFont(ofSize: 14), color: NSColor.white.withAlphaComponent(0.6), at: NSPoint(x: 28, y: 60))
        }
        let addRect = todoAddPillRect()
        NSColor.white.withAlphaComponent(0.10).setFill()
        NSBezierPath(roundedRect: addRect, xRadius: 14, yRadius: 14).fill()
        let addFont = NSFont.systemFont(ofSize: 14)
        let plusW = ("+" as NSString).size(withAttributes: [.font: addFont]).width
        drawText("+", font: addFont, color: .white, at: NSPoint(x: addRect.minX + 12, y: addRect.minY + 5))
        drawText("Add task", font: addFont, color: .white, at: NSPoint(x: addRect.minX + 12 + plusW + 6, y: addRect.minY + 5))
        // While editing, the input row sits below the add pill
        // (y160-192): its own background plus the Enter/Esc hint.
        // The overflow line (y158) would collide with it, so it is
        // hidden until editing ends.
        if todoEditingField != nil {
            NSColor.white.withAlphaComponent(0.10).setFill()
            NSBezierPath(roundedRect: todoInputRect(), xRadius: 10, yRadius: 10).fill()
            drawText("Enter to add \u{00B7} Esc to cancel", font: NSFont.systemFont(ofSize: 11),
                     color: NSColor.white.withAlphaComponent(0.4), at: NSPoint(x: 28, y: 196))
        }
        // Overflow count under the add pill.
        let rows = todoVisibleRows()
        if todoEditingField == nil, total > rows.count {
            drawText("+\(total - rows.count) more", font: NSFont.systemFont(ofSize: 11),
                     color: NSColor.white.withAlphaComponent(0.4), at: NSPoint(x: 28, y: 158))
        }
        // Right column: task rows (subtle dark pills, green check
        // for done, strikethrough + dimmed done text).
        for row in rows {
            NSColor.white.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: row.pillRect, xRadius: 10, yRadius: 10).fill()
            let centerY = row.pillRect.midY
            let circleRect = NSRect(x: 292, y: centerY - 10, width: 20, height: 20)
            if row.task.done {
                NSColor.systemGreen.setFill()
                NSBezierPath(ovalIn: circleRect).fill()
                drawSymbol("checkmark", size: 12, center: CGPoint(x: circleRect.midX, y: centerY), fallback: "✓")
            } else {
                NSColor.white.withAlphaComponent(0.6).setStroke()
                let circle = NSBezierPath(ovalIn: circleRect)
                circle.lineWidth = 1.5
                circle.stroke()
            }
            let taskFont = NSFont.systemFont(ofSize: 14)
            let text = truncated(row.task.text, toWidth: 248, font: taskFont)
            if row.task.done {
                drawStrikethroughText(text, font: taskFont,
                                      color: NSColor.white.withAlphaComponent(0.5),
                                      at: NSPoint(x: 320, y: row.pillRect.minY + 7))
            } else {
                drawText(text, font: taskFont, color: .white,
                         at: NSPoint(x: 320, y: row.pillRect.minY + 7))
            }
            let xLabel = "×"
            let xFont = NSFont.systemFont(ofSize: 14)
            let xW = (xLabel as NSString).size(withAttributes: [.font: xFont]).width
            drawText(xLabel, font: xFont, color: NSColor.white.withAlphaComponent(0.4),
                     at: NSPoint(x: row.deleteRect.midX - xW / 2, y: centerY - 8))
        }
    }

    private func drawStrikethroughText(_ text: String, font: NSFont, color: NSColor, at point: NSPoint) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color,
            .strikethroughStyle: NSUnderlineStyle.single.rawValue, .strikethroughColor: color]
        NSAttributedString(string: text, attributes: attrs).draw(at: point)
    }

    // MARK: - Todo inline editing

    /// The live input field while adding a task, nil otherwise.
    /// AppDelegate reads isTodoEditing to hold the card open.
    private var todoEditingField: NSTextField?
    /// App that was frontmost when editing started (Aura itself
    /// excluded by the caller check in endTodoEditing): focus
    /// returns there after Enter/Escape, like the old modal did.
    private var todoEditingPreviousApp: NSRunningApplication?
    /// True while endTodoEditing is removing the field, so the
    /// resign it triggers does not re-enter endTodoEditing.
    private var todoEditingEnding = false
    var isTodoEditing: Bool { todoEditingField != nil }

    /// Input row: full-width below the add pill, y160-192, inside
    /// the 640x220 todo card with room for the hint at y196.
    private func todoInputRect() -> NSRect {
        NSRect(x: 28, y: 160, width: 584, height: 32)
    }

    /// Starts inline editing. The window must become key for the
    /// field to receive keystrokes, so allowKey is opened only
    /// for the editing session (see IslandWindow). The old modal
    /// existed because an in-card field once fought this window's
    /// focus system; the allowKey gate is what makes it work now.
    private func startTodoEditing() {
        guard state == .expanded, currentPage == .todo, todoEditingField == nil else { return }
        todoEditingPreviousApp = NSWorkspace.shared.frontmostApplication
        let field = NSTextField(frame: todoInputRect())
        field.delegate = self
        field.placeholderString = "New task..."
        field.font = NSFont.systemFont(ofSize: 14)
        field.textColor = .white
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        addSubview(field)
        todoEditingField = field
        if let win = window as? IslandWindow { win.allowKey = true }
        window?.makeKey()
        window?.makeFirstResponder(field)
        needsDisplay = true
    }

    /// Ends editing after Enter (submit) or Escape (cancel).
    /// After ending, hover is re-synced from the real cursor
    /// position: outside closes the card (normal rules resume),
    /// inside keeps it open. Focus returns to the previous app
    /// only when Aura is still the key window — if editing ended
    /// because focus was already lost to another app, restoring
    /// would yank the user back from the app they switched to.
    func endTodoEditing(submit: Bool) {
        guard let field = todoEditingField, !todoEditingEnding else { return }
        todoEditingEnding = true
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let wasKey = window?.isKeyWindow ?? false
        field.removeFromSuperview()
        todoEditingField = nil
        todoEditingEnding = false
        if submit, !text.isEmpty {
            loadTodoTasksIfNeeded()
            todoTasks.append(TodoTask(id: UUID(), text: text, done: false, createdAt: Date()))
            saveTodoTasks()
        }
        if let win = window as? IslandWindow { win.allowKey = false }
        if wasKey, let prev = todoEditingPreviousApp,
           prev.processIdentifier != ProcessInfo.processInfo.processIdentifier,
           !prev.isTerminated {
            prev.activate(options: [])
        }
        todoEditingPreviousApp = nil
        needsDisplay = true
        if let win = window {
            onHoverChanged?(win.frame.contains(NSEvent.mouseLocation))
        }
    }

    /// Silent discard for paths that already own the card state
    /// (page switch, close): no submit, no focus restore, no
    /// hover re-sync — the caller decides what happens next.
    func cancelTodoEditing() {
        guard let field = todoEditingField else { return }
        todoEditingEnding = true
        field.removeFromSuperview()
        todoEditingField = nil
        todoEditingEnding = false
        if let win = window as? IslandWindow { win.allowKey = false }
        todoEditingPreviousApp = nil
        needsDisplay = true
    }

    // MARK: - NSTextFieldDelegate (todo inline input)

    /// Return submits, Escape cancels. Empty Return is a no-op
    /// (stays in editing) rather than adding a blank task.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if let field = todoEditingField,
               !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                endTodoEditing(submit: true)
            }
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            endTodoEditing(submit: false)
            return true
        }
        return false
    }

    /// Focus lost for any other reason (window resigned key, app
    /// switch): discard the draft and let hover rules resume.
    /// Guarded by todoEditingEnding so our own removal does not
    /// re-enter endTodoEditing.
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field == todoEditingField, !todoEditingEnding else { return }
        endTodoEditing(submit: false)
    }

    /// After a modal closes, re-derive hover from the real mouse
    /// position: the mouse-exit that fired while the dialog was open
    /// was swallowed (see isShowingModal), so the tracking area will
    /// not re-fire it. Outside the window collapses the card (the
    /// normal leave rule, just deferred past the modal); inside just
    /// restores isHovering, and is a no-op on an open card.
    private func resyncHoverAfterModal() {
        guard let window else { return }
        onHoverChanged?(window.frame.contains(NSEvent.mouseLocation))
    }

    /// Run a card-modal picker/menu without collapsing the card.
    /// While it is open the cursor sits outside the island window,
    /// so the hover-exit collapse must be swallowed (the water
    /// settings dialog already relies on isShowingModal for this).
    /// Unlike resyncHoverAfterModal, no re-sync runs afterwards:
    /// after a pick the card stays open on purpose (the cursor is
    /// over the dismissed panel, i.e. outside the card, so a
    /// re-sync would collapse it at once), and the next real
    /// hover exit collapses it normally.
    private func presentCardModal<T>(_ body: () -> T) -> T {
        isShowingModal = true
        defer { isShowingModal = false }
        return body()
    }

    // MARK: - File tray (drag and drop + share)

    /// A file held in the tray: a reference, not a copy — the file
    /// stays where it is, the tray just remembers its path (like a
    /// shelf). Persisted in UserDefaults (key AuraTrayFiles), so the
    /// tray survives relaunch. If the original moves or deletes,
    /// the row goes stale (dimmed, share/drag disabled) until removed.
    struct TrayFile: Codable, Equatable {
        let id: UUID
        let path: String
        let name: String
        let isDirectory: Bool
        let size: Int64
        let addedAt: Date
        var url: URL { URL(fileURLWithPath: path) }
    }

    /// Share method chosen in the tray's share mode. AirDrop opens
    /// the system picker; LAN lists discovered Aura peers.
    private enum TrayShareMethod { case airDrop, lan }

    private var trayFiles: [TrayFile] = []
    private var trayFilesLoaded = false
    /// While a drag hovers with a valid file URL. The EXISTING tray
    /// pill is what bounces (never a new pill): hovering springs it
    /// slightly larger (1.03x), dropping pops it (1.12x) then springs
    /// it back to exact size. Read by AppDelegate.windowSize
    /// (headroom) — hence internal, not private.
    var trayDropHighlight = false {
        didSet {
            needsDisplay = true
            if oldValue != trayDropHighlight {
                // Slight expand while a file hovers (same pill, just
                // slightly larger); back to exact when it leaves.
                triggerTraySpring(to: trayDropHighlight ? 1.03 : 1.0)
                onTraySizeChanged?()
            }
        }
    }
    /// Bounce headroom: while a drag hovers or a bounce runs, the
    /// window is this much larger than the card so the bouncing
    /// card (up to ~1.12x) never clips; the margin is transparent.
    static let bounceHeadroomFactor: CGFloat = 1.15
    /// Called when the tray's size factors change (drop highlight
    /// flips, bounce settles) so AppDelegate re-applies window size.
    var onTraySizeChanged: (() -> Void)?
    /// Bubble bounce: a damped-cosine spring around a target,
    /// scale(t) = to + (from - to) * e^(-3t) * cos(4πt) — the
    /// existing pill pops and bounces like a bubble, then settles
    /// to its exact size. Hover springs to 1.03 (slight expand);
    /// drop pops to 1.12 then springs to 1.0.
    private var traySpringFrom: CGFloat = 1.0
    private var traySpringTo: CGFloat = 1.0
    private var traySpringStart: Date?
    private var traySpringTimer: Timer?
    private func traySpringScale(now: Date) -> CGFloat {
        guard let start = traySpringStart else { return traySpringTo }
        let t = now.timeIntervalSince(start)
        let decay = CGFloat(exp(-3 * t))
        let osc = CGFloat(cos(4 * Double.pi * t))
        return traySpringTo + (traySpringFrom - traySpringTo) * decay * osc
    }
    /// True while a bounce is running (window stays headroom-sized).
    var isTrayBouncing: Bool { traySpringTimer != nil }
    private func triggerTraySpring(to: CGFloat, from impulse: CGFloat? = nil) {
        let now = Date()
        traySpringFrom = impulse ?? traySpringScale(now: now)
        traySpringTo = to
        traySpringStart = now
        guard traySpringTimer == nil else { return }
        traySpringTimer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self, let start = self.traySpringStart else {
                self?.traySpringTimer?.invalidate()
                self?.traySpringTimer = nil
                return
            }
            self.needsDisplay = true
            let t = Date().timeIntervalSince(start)
            if CGFloat(exp(-3 * t)) * abs(self.traySpringFrom - self.traySpringTo) < 0.002 {
                self.traySpringTimer?.invalidate()
                self.traySpringTimer = nil
                self.onTraySizeChanged?()
            }
        }
        if let traySpringTimer { RunLoop.main.add(traySpringTimer, forMode: .common) }
    }
    /// Stop a running tray spring at once (used when the pill leaves
    /// expanded, e.g. closing right after a drop): without this the
    /// spring keeps oscillating through the 0.35s close animation and
    /// its transform fights the window animator. Cancelling also
    /// suppresses the bounce-settle onTraySizeChanged callback, so
    /// closing does not re-animate to the closed size a second time.
    func cancelTraySpring() {
        traySpringTimer?.invalidate()
        traySpringTimer = nil
        traySpringStart = nil
        traySpringFrom = 1.0
        traySpringTo = 1.0
        needsDisplay = true
    }
    /// The island's size without the drop bulge (single source of
    /// truth for AppDelegate.windowSize's base).
    func unbulgedSize(for state: IslandState) -> NSSize {
        if pillAlert != nil && state != .expanded {
            return NSSize(width: 360, height: 32)
        }
        switch state {
        case .expanded: return expandedSize
        case .zen: return state.size
        case .compact, .split: return closedSize
        }
    }
    /// Share mode: nil = list mode. Set when a row's share button is
    /// tapped; cleared on back/cancel, after AirDrop opens, or on drop.
    private var trayShareFile: TrayFile?
    /// Method chosen in share mode; nil = method chooser.
    private var trayShareMethod: TrayShareMethod?
    /// LAN peer tapped in share mode; non-nil = sending status view.
    private var traySharePeer: LANPeer?
    /// Discovered LAN peers (set by AppDelegate); redraws on change.
    var lanPeers: [LANPeer] = [] { didSet { needsDisplay = true } }
    /// LAN send status text + progress (set by AppDelegate during a
    /// send); redraws on change. Nil = no send in progress.
    var trayShareStatus: String? { didSet { needsDisplay = true } }
    var trayShareProgress: Double? { didSet { needsDisplay = true } }

    /// Callbacks to AppDelegate (set like onHoverChanged/onClicked).
    var onDragEnteredTray: (() -> Void)?
    var onTrayShareAirDrop: ((TrayFile) -> Void)?
    var onTrayShareLANPeer: ((TrayFile, LANPeer) -> Void)?
    var onTrayShareCancel: (() -> Void)?

    /// Pending drag-out: set on mouseDown on a grid tile (not its
    /// ×), so a press-drag starts a drag session and a plain press
    /// is a tap (share, on mouseUp). Cleared on drag start or mouseUp.
    private var trayPendingDrag: (file: TrayFile, point: NSPoint)?
    /// File the tray context menu was opened for (right-click).
    /// Set on right-click, cleared by the chosen action.
    private var trayMenuFile: TrayFile?
    /// Grid page (which page of tiles the shelf shows). 8 tiles per
    /// page (4x2); page count clamps, so delete/clear never leave
    /// it out of range.
    private var trayGridPage = 0
    /// True while a drag-out session is in flight (set on drag
    /// start, cleared when the session ends). AppDelegate skips
    /// hover-collapse while this is true.
    var isDraggingOut = false
    /// True while the pill is overlap-hidden to a tip strip: draw
    /// only the pill shape, no eyes/clock/content, so the strip is
    /// a clean marker instead of a slice of text.
    var isOverlapHidden = false
    /// Last drag-over point in view coords (for the "+ Copy" badge).
    /// Nil when no drag hovers.
    private var trayDragPoint: NSPoint? { didSet { needsDisplay = true } }

    /// Show the tray section (used when a drag enters the island).
    func showTray() {
        cardPage = .tray
        needsDisplay = true
    }

    private func loadTrayFilesIfNeeded() {
        guard !trayFilesLoaded else { return }
        trayFilesLoaded = true
        if let data = UserDefaults.standard.data(forKey: "AuraTrayFiles"),
           let decoded = try? JSONDecoder().decode([TrayFile].self, from: data) {
            trayFiles = decoded
        }
    }

    private func saveTrayFiles() {
        if let data = try? JSONEncoder().encode(trayFiles) {
            UserDefaults.standard.set(data, forKey: "AuraTrayFiles")
        }
    }

    /// Add dropped URLs to the tray (dedupe by path, directories
    /// allowed). Returns how many were added.
    @discardableResult
    private func addTrayFiles(_ urls: [URL]) -> Int {
        loadTrayFilesIfNeeded()
        var addedFiles: [TrayFile] = []
        for url in urls {
            let path = url.path
            guard !trayFiles.contains(where: { $0.path == path }) else { continue }
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            var size: Int64 = 0
            if exists, !isDir.boolValue {
                size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
            }
            let file = TrayFile(id: UUID(), path: path, name: url.lastPathComponent,
                                isDirectory: isDir.boolValue, size: size, addedAt: Date())
            trayFiles.append(file)
            addedFiles.append(file)
        }
        if !addedFiles.isEmpty {
            saveTrayFiles()
            // Drop bounces the existing pill (pop, then settle exact).
            triggerTraySpring(to: 1.0, from: 1.12)
            needsDisplay = true
        }
        return addedFiles.count
    }

    private func deleteTrayFile(id: UUID) {
        loadTrayFilesIfNeeded()
        trayFiles.removeAll { $0.id == id }
        saveTrayFiles()
        needsDisplay = true
    }

    private func trayFileExists(_ file: TrayFile) -> Bool {
        FileManager.default.fileExists(atPath: file.path)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024.0) }
        if bytes < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(bytes) / 1048576.0) }
        return String(format: "%.1f GB", Double(bytes) / 1073741824.0)
    }

    /// Back pill (top-right) in share mode.
    private func trayShareBackRect() -> NSRect {
        NSRect(x: 524, y: 10, width: 88, height: 28)
    }

    /// Method chooser rows in share mode (full-width pills).
    /// Open sits directly below Local Network, so a tray file can
    /// be opened from share mode without leaving it for the
    /// right-click menu.
    private func trayShareMethodRects() -> (airDrop: NSRect, lan: NSRect, open: NSRect) {
        (airDrop: NSRect(x: 28, y: 84, width: 572, height: 32),
         lan: NSRect(x: 28, y: 124, width: 572, height: 32),
         open: NSRect(x: 28, y: 164, width: 572, height: 32))
    }

    /// LAN peer rows in share mode (max 3).
    private func traySharePeerRects() -> [(peer: LANPeer, rect: NSRect)] {
        lanPeers.prefix(3).enumerated().map { i, peer in
            (peer: peer, rect: NSRect(x: 28, y: 84 + CGFloat(i) * 40, width: 572, height: 32))
        }
    }

    private func clearTrayShare() {
        trayShareFile = nil
        trayShareMethod = nil
        traySharePeer = nil
        trayShareStatus = nil
        trayShareProgress = nil
        needsDisplay = true
    }


    // MARK: - Remove BG section

    /// Remove-background section (Rimufu API backend, see
    /// RimufuRemoveBg.swift). Layout mirrors the tray card:
    /// 640x280, header + title, dots column on the right edge
    /// (content ends at x 600, clear of the dot hit column
    /// W-32..W-10). Left panel = drop/pick + original preview;
    /// right panel = the result alone, on a checkerboard (no
    /// before/after slider: the user removed it, the result
    /// panel is drag-out instead). Pressing the result arms a
    /// drag, like a tray tile; the result file is written once
    /// to Downloads/Aura and reused for later drags and Save.
    /// Rects follow the tray convention: base coords, used
    /// directly from mouseDown (at rest they equal view coords).
    private var removeBgOriginal: NSImage?
    private var removeBgResult: NSImage?
    private var removeBgResultData: Data?
    private var removeBgProcessing = false
    private var removeBgTask: URLSessionDataTask?
    private var removeBgPendingDragPoint: CGPoint?
    private var removeBgSavedURL: URL?
    private var removeBgDropHighlight = false { didSet { needsDisplay = true } }
    private var removeBgStatusText = "Drop an image, or click to pick one."
    private var removeBgStatusIsError = false
    private var removeBgModel: RemoveBgModel = .fast
    private var removeBgInputImage: NSImage?
    private var removeBgInputData: Data?
    private var removeBgInputName: String?

    /// Left panel: drop zone and pick target, also shows the
    /// original once one is loaded (clicking it re-picks).
    private func removeBgPickRect() -> NSRect {
        NSRect(x: 28, y: 48, width: 180, height: 180)
    }

    /// Right panel: the result alone. Ends at x 600 so it
    /// never overlaps the vertical dot column on the right edge.
    /// Also the drag source: pressing it arms a drag-out.
    private func removeBgResultRect() -> NSRect {
        NSRect(x: 224, y: 48, width: 376, height: 180)
    }

    /// Save pill, bottom-right of the card (only drawn/hit when a
    /// result exists). Solid white + black text, like the tray
    /// "+ Copy" badge, so it reads as tappable on the black card.
    private func removeBgSaveRect(saving: Bool = false) -> NSRect {
        let label = saving ? "Saving…" : "Save"
        let font = NSFont.systemFont(ofSize: 14, weight: .medium)
        let width = (label as NSString).size(withAttributes: [.font: font]).width + 24 + (saving ? 20 : 0)
        return NSRect(x: 600 - width, y: 236, width: width, height: 28)
    }

    /// Spinner timer + pill label. Called after the pill fill;
    /// the text is black on the solid white pill in both sections.
    private func startSaveSpinner() {
        guard saveSpinnerTimer == nil else { return }
        saveSpinnerTimer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.saveSpinnerPhase = (self.saveSpinnerPhase + 1) % 12
            self.needsDisplay = true
        }
        if let saveSpinnerTimer { RunLoop.main.add(saveSpinnerTimer, forMode: .common) }
    }

    private func stopSaveSpinner() {
        guard !removeBgSaving && convertSavingTool == nil else { return }
        saveSpinnerTimer?.invalidate()
        saveSpinnerTimer = nil
    }

    private func drawSavePillContent(in rect: NSRect, saving: Bool) {
        let font = NSFont.systemFont(ofSize: 14, weight: .medium)
        if saving {
            let path = NSBezierPath()
            path.appendArc(withCenter: CGPoint(x: rect.minX + 14, y: rect.midY), radius: 6,
                           startAngle: CGFloat(saveSpinnerPhase * 30),
                           endAngle: CGFloat(saveSpinnerPhase * 30 + 270),
                           clockwise: false)
            path.lineWidth = 2
            NSColor.black.setStroke()
            path.stroke()
            let label = "Saving…"
            let width = (label as NSString).size(withAttributes: [.font: font]).width
            drawText(label, font: font, color: .black,
                     at: NSPoint(x: rect.midX - width / 2 + 10, y: rect.minY + 5))
        } else {
            let width = ("Save" as NSString).size(withAttributes: [.font: font]).width
            drawText("Save", font: font, color: .black,
                     at: NSPoint(x: rect.midX - width / 2, y: rect.minY + 5))
        }
    }

    /// First-page thumbnail of PDF bytes, via CoreGraphics (no
    /// new framework: CGPDF lives in CoreGraphics, already
    /// available through AppKit). White background (a transparent
    /// one would read as a hole on the black card), capped at 2x
    /// so a huge page never allocates a giant bitmap. Nil when
    /// the bytes are not a readable PDF.
    private func pdfFirstPageImage(from data: Data, maxSize: NSSize) -> NSImage? {
        guard let provider = CGDataProvider(data: data as CFData),
              let doc = CGPDFDocument(provider),
              let page = doc.page(at: 1) else { return nil }
        let box = page.getBoxRect(.mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let scale = min(maxSize.width / box.width, maxSize.height / box.height, 2.0)
        let w = max(1, Int(box.width * scale))
        let h = max(1, Int(box.height * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let transform = page.getDrawingTransform(.mediaBox, rect: CGRect(x: 0, y: 0, width: w, height: h),
                                                 rotate: 0, preserveAspectRatio: true)
        ctx.concatenate(transform)
        ctx.drawPDFPage(page)
        guard let cgImage = ctx.makeImage() else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: w, height: h))
    }

    /// Aspect-fit rect for an image inside a rect, centered.
    private func removeBgFitRect(for image: NSImage, in rect: NSRect) -> NSRect {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return rect }
        let scale = min(rect.width / size.width, rect.height / size.height)
        let width = size.width * scale
        let height = size.height * scale
        return NSRect(x: rect.midX - width / 2, y: rect.midY - height / 2,
                      width: width, height: height)
    }

    /// Tray images usable for Remove BG: existing files, not
    /// directories, with an image extension (same set as the drop
    /// filter). A tray without images means no picker at all.
    private func removeBgTrayImages() -> [TrayFile] {
        loadTrayFilesIfNeeded()
        let imageExts: Set<String> = ["png", "jpg", "jpeg", "heic", "webp", "gif", "bmp", "tiff"]
        return trayFiles.filter {
            !$0.isDirectory
            && imageExts.contains(URL(fileURLWithPath: $0.path).pathExtension.lowercased())
            && trayFileExists($0)
        }
    }

    private func removeBgTrayPickerVisible() -> Bool {
        !removeBgTrayImages().isEmpty
    }

    /// Picker pill, bottom of the left panel (8pt margins). It
    /// sits inside the pick rect, so mouseDown checks it BEFORE
    /// the general left-panel pick.
    private func removeBgTrayPickerRect() -> NSRect {
        let left = removeBgPickRect()
        return NSRect(x: left.minX + 8, y: left.maxY - 36, width: left.width - 16, height: 28)
    }

    /// Image area inside the left panel: full inset when no
    /// picker, shrunk above the picker pill when one is shown, so
    /// the preview never slides under the pill.
    private func removeBgLeftImageRect() -> NSRect {
        let left = removeBgPickRect()
        if removeBgTrayPickerVisible() {
            return NSRect(x: left.minX + 8, y: left.minY + 8,
                          width: left.width - 16, height: left.height - 16 - 36)
        }
        return left.insetBy(dx: 8, dy: 8)
    }

    /// Popup menu of tray images, in tray order. Unlike the
    /// single-file tray tile menu, each item carries its own file
    /// in representedObject.
    private func showRemoveBgTrayMenu(at point: CGPoint) {
        let images = removeBgTrayImages()
        guard !images.isEmpty else {
            removeBgStatusText = "Tray has no images."
            removeBgStatusIsError = false
            needsDisplay = true
            return
        }
        let menu = NSMenu()
        let font = NSFont.systemFont(ofSize: 13)
        for file in images {
            let item = NSMenuItem(title: truncated(file.name, toWidth: 300, font: font),
                                  action: #selector(pickRemoveBgTrayMenuFile(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = file
            menu.addItem(item)
        }
        presentCardModal { menu.popUp(positioning: nil, at: point, in: self) }
    }

    @objc private func pickRemoveBgTrayMenuFile(_ sender: NSMenuItem) {
        guard let file = sender.representedObject as? TrayFile, trayFileExists(file) else {
            removeBgStatusText = "That tray file is missing."
            removeBgStatusIsError = true
            needsDisplay = true
            return
        }
        startRemoveBg(with: file.url)
    }

    private func drawRemoveBg() {
        drawCardHeader(width: 640, showWaveform: false)
        drawText("Remove BG", font: NSFont.boldSystemFont(ofSize: 20), color: .white,
                 at: NSPoint(x: 28, y: 10))
        let modelPill = removeBgModelPillRect()
        NSColor.white.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: modelPill, xRadius: 14, yRadius: 14).fill()
        NSColor.white.withAlphaComponent(0.3).setStroke()
        NSBezierPath(roundedRect: modelPill, xRadius: 14, yRadius: 14).stroke()
        let modelLabel = "Model: \(removeBgModel.displayName) \u{25be}"
        let modelFont = NSFont.systemFont(ofSize: 13, weight: .medium)
        let modelWidth = (modelLabel as NSString).size(withAttributes: [.font: modelFont]).width
        drawText(modelLabel, font: modelFont, color: .white,
                 at: NSPoint(x: modelPill.midX - modelWidth / 2, y: modelPill.minY + 5))
        // Left panel: dashed drop zone (tray drop-zone style).
        let left = removeBgPickRect()
        let leftPath = NSBezierPath(roundedRect: left, xRadius: 16, yRadius: 16)
        leftPath.setLineDash([8, 6], count: 2, phase: 0)
        leftPath.lineWidth = 1.5
        NSColor.white.withAlphaComponent(0.5).setStroke()
        leftPath.stroke()
        let leftImageArea = removeBgLeftImageRect()
        if let original = removeBgOriginal {
            let fit = removeBgFitRect(for: original, in: leftImageArea)
            drawImageUpright(original, in: fit)
        } else {
            let line1 = "Drop image here"
            let font1 = NSFont.systemFont(ofSize: 14)
            let w1 = (line1 as NSString).size(withAttributes: [.font: font1]).width
            drawText(line1, font: font1, color: NSColor.white.withAlphaComponent(0.8),
                     at: NSPoint(x: leftImageArea.midX - w1 / 2, y: leftImageArea.midY - 10))
            let line2 = "or click to pick"
            let font2 = NSFont.systemFont(ofSize: 12)
            let w2 = (line2 as NSString).size(withAttributes: [.font: font2]).width
            drawText(line2, font: font2, color: NSColor.white.withAlphaComponent(0.5),
                     at: NSPoint(x: leftImageArea.midX - w2 / 2, y: leftImageArea.midY + 10))
        }
        // From Tray picker pill, bottom of the left panel, only
        // when the tray actually holds a usable image — the pill
        // is never drawn dead.
        if removeBgTrayPickerVisible() {
            let picker = removeBgTrayPickerRect()
            NSColor.white.withAlphaComponent(0.15).setFill()
            NSBezierPath(roundedRect: picker, xRadius: 14, yRadius: 14).fill()
            NSColor.white.withAlphaComponent(0.3).setStroke()
            NSBezierPath(roundedRect: picker, xRadius: 14, yRadius: 14).stroke()
            let label = "From Tray \u{25be}"
            let pickerFont = NSFont.systemFont(ofSize: 13, weight: .medium)
            let pickerWidth = (label as NSString).size(withAttributes: [.font: pickerFont]).width
            drawText(label, font: pickerFont, color: .white,
                     at: NSPoint(x: picker.midX - pickerWidth / 2, y: picker.minY + 5))
        }
        // Right panel: result alone on a checkerboard, clipped
        // to a rounded rect so it never spills past the corners.
        let compare = removeBgResultRect()
        let comparePath = NSBezierPath(roundedRect: compare, xRadius: 12, yRadius: 12)
        NSGraphicsContext.saveGraphicsState()
        comparePath.addClip()
        let square: CGFloat = 12
        var row = 0
        var y = compare.minY
        while y < compare.maxY {
            var col = 0
            var x = compare.minX
            while x < compare.maxX {
                let light = (row + col) % 2 == 0
                NSColor.white.withAlphaComponent(light ? 0.12 : 0.04).setFill()
                NSRect(x: x, y: y, width: square, height: square).fill()
                col += 1
                x += square
            }
            row += 1
            y += square
        }
        if let result = removeBgResult {
            let fit = removeBgFitRect(for: result, in: compare.insetBy(dx: 8, dy: 8))
            drawImageUpright(result, in: fit)
        } else {
            let placeholder = "Result appears here"
            let font = NSFont.systemFont(ofSize: 13)
            let width = (placeholder as NSString).size(withAttributes: [.font: font]).width
            drawText(placeholder, font: font, color: NSColor.white.withAlphaComponent(0.5),
                     at: NSPoint(x: compare.midX - width / 2, y: compare.midY - 7))
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.3).setStroke()
        comparePath.lineWidth = 1
        comparePath.stroke()
        // Status row, bottom-left. Errors read red; everything else
        // is dim white, like the tray's dim labels.
        let statusFont = NSFont.systemFont(ofSize: 13)
        let statusColor = removeBgStatusIsError ? NSColor.systemRed : NSColor.white.withAlphaComponent(0.7)
        drawText(truncated(removeBgStatusText, toWidth: 400, font: statusFont),
                 font: statusFont, color: statusColor, at: NSPoint(x: 28, y: 244))
        // Save pill, only once a result exists. While a save
        // runs it shows the spinner instead of "Save".
        if removeBgResultData != nil, !removeBgProcessing {
            let save = removeBgSaveRect(saving: removeBgSaving)
            NSColor.white.setFill()
            NSBezierPath(roundedRect: save, xRadius: 14, yRadius: 14).fill()
            drawSavePillContent(in: save, saving: removeBgSaving)
        }
        // Drop highlight, on top of everything else in the section.
        if removeBgDropHighlight {
            let zone = NSRect(x: 28, y: 48, width: 572, height: 180)
            NSColor.white.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: zone, xRadius: 16, yRadius: 16).fill()
            let dashed = NSBezierPath(roundedRect: zone, xRadius: 16, yRadius: 16)
            dashed.setLineDash([8, 6], count: 2, phase: 0)
            dashed.lineWidth = 1.5
            NSColor.white.withAlphaComponent(0.8).setStroke()
            dashed.stroke()
            let label = "Release to remove background"
            let font = NSFont.systemFont(ofSize: 14)
            let width = (label as NSString).size(withAttributes: [.font: font]).width
            drawText(label, font: font, color: NSColor.white.withAlphaComponent(0.9),
                     at: NSPoint(x: zone.midX - width / 2, y: zone.midY - 7))
        }
    }

    private func pickRemoveBgImage() {
        guard !removeBgProcessing else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // allowedFileTypes is deprecated but avoids a
        // UniformTypeIdentifiers import; it still works on macOS 13.
        panel.allowedFileTypes = ["png", "jpg", "jpeg", "heic", "webp", "gif", "bmp", "tiff"]
        panel.message = "Choose an image to remove the background from"
        // runModal, not a sheet: the island window is a non-key
        // panel, so a sheet would have nowhere to attach, while
        // app-modal works regardless. Drag-and-drop onto the card
        // is the primary path if the panel ever fails to appear.
        guard presentCardModal({ panel.runModal() }) == .OK, let url = panel.url else { return }
        startRemoveBg(with: url)
    }

    /// Model pill, top-right of the Remove BG header (ends at
    /// x 600, clear of the dot column at x 608+; panels start
    /// at y 48, so the 28-tall pill at y 10 fits with room).
    /// Style is the translucent setting-pill style (like Convert's
    /// format pill), not a tool pill.
    private func removeBgModelPillRect() -> NSRect {
        let label = "Model: \(removeBgModel.displayName) \u{25be}"
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let width = (label as NSString).size(withAttributes: [.font: font]).width + 24
        return NSRect(x: 600 - width, y: 10, width: width, height: 28)
    }

    private func showRemoveBgModelMenu(at point: CGPoint) {
        let menu = NSMenu()
        for model in RemoveBgModel.allCases {
            let item = NSMenuItem(title: model.displayName,
                                  action: #selector(pickRemoveBgModel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = model.apiValue
            item.state = (model == removeBgModel) ? .on : .off
            menu.addItem(item)
        }
        presentCardModal { menu.popUp(positioning: nil, at: point, in: self) }
    }

    @objc private func pickRemoveBgModel(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String,
              let model = RemoveBgModel(rawValue: value) else { return }
        removeBgModel = model
        needsDisplay = true
        // Re-run with the stored input when one exists, so the
        // user can compare models without re-picking (same as
        // Convert's format change). Blocked while a run is in
        // flight — mouseDown already blocks the menu then.
        guard !removeBgProcessing,
              let image = removeBgInputImage,
              let data = removeBgInputData,
              let name = removeBgInputName else { return }
        startRemoveBgData(image: image, originalData: data, originalName: name)
    }

    private func startRemoveBg(with url: URL) {
        // A new image cancels the old run, so a stale result can
        // never overwrite the new one (see the Cancelled guard in
        // the completion below).
        removeBgTask?.cancel()
        removeBgTask = nil
        removeBgProcessing = true
        removeBgResult = nil
        removeBgResultData = nil
        removeBgSavedURL = nil
        removeBgStatusText = "Processing…"
        removeBgStatusIsError = false
        needsDisplay = true
        guard let image = NSImage(contentsOf: url) else {
            removeBgProcessing = false
            removeBgStatusText = "Could not read that image."
            removeBgStatusIsError = true
            needsDisplay = true
            return
        }
        removeBgOriginal = image
        needsDisplay = true
        guard let fileData = try? Data(contentsOf: url) else {
            removeBgProcessing = false
            removeBgStatusText = "Could not read that image."
            removeBgStatusIsError = true
            needsDisplay = true
            return
        }
        removeBgInputImage = image
        removeBgInputData = fileData
        removeBgInputName = url.lastPathComponent
        let prepared = RimufuRemoveBgClient.preparedUploadData(
            image: image, originalData: fileData, originalName: url.lastPathComponent)
        let task = RimufuRemoveBgClient.removeBackground(
            data: prepared.data, fileName: prepared.fileName, mimeType: prepared.mimeType, model: removeBgModel
        ) { [weak self] result in
            // URLSession calls back off the main thread; every UI
            // touch below must happen on main.
            DispatchQueue.main.async {
                guard let self else { return }
                self.removeBgTask = nil
                self.removeBgProcessing = false
                switch result {
                case .success(let pngData):
                    if let resultImage = NSImage(data: pngData) {
                        self.removeBgResult = resultImage
                        self.removeBgResultData = pngData
                        self.removeBgStatusText = "Done — drag the result out to use it."
                        self.removeBgStatusIsError = false
                    } else {
                        self.removeBgStatusText = "Server returned an image Aura could not read."
                        self.removeBgStatusIsError = true
                    }
                case .failure(let error):
                    // Cancelled means a newer image already reset
                    // the status; showing an error here would
                    // overwrite the new run's "Processing…".
                    if case .uploadFailed(let detail) = error, detail == "Cancelled." {
                        return
                    }
                    self.removeBgStatusText = error.message
                    self.removeBgStatusIsError = true
                }
                self.needsDisplay = true
            }
        }
        removeBgTask = task
    }

    /// Run Remove BG from already-loaded input (used by model
    /// changes, which re-run with the stored image instead of
    /// making the user re-pick it). Completion mirrors
    /// startRemoveBg(with:) — if that logic changes, update both.
    private func startRemoveBgData(image: NSImage, originalData: Data, originalName: String) {
        removeBgTask?.cancel()
        removeBgTask = nil
        removeBgProcessing = true
        removeBgResult = nil
        removeBgResultData = nil
        removeBgSavedURL = nil
        removeBgStatusText = "Processing…"
        removeBgStatusIsError = false
        needsDisplay = true
        let prepared = RimufuRemoveBgClient.preparedUploadData(
            image: image, originalData: originalData, originalName: originalName)
        let task = RimufuRemoveBgClient.removeBackground(
            data: prepared.data, fileName: prepared.fileName, mimeType: prepared.mimeType, model: removeBgModel
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.removeBgTask = nil
                self.removeBgProcessing = false
                switch result {
                case .success(let pngData):
                    if let resultImage = NSImage(data: pngData) {
                        self.removeBgResult = resultImage
                        self.removeBgResultData = pngData
                        self.removeBgStatusText = "Done — drag the result out to use it."
                        self.removeBgStatusIsError = false
                    } else {
                        self.removeBgStatusText = "Server returned an image Aura could not read."
                        self.removeBgStatusIsError = true
                    }
                case .failure(let error):
                    if case .uploadFailed(let detail) = error, detail == "Cancelled." {
                        return
                    }
                    self.removeBgStatusText = error.message
                    self.removeBgStatusIsError = true
                }
                self.needsDisplay = true
            }
        }
        removeBgTask = task
    }

    /// The result's file on disk, written once and reused: Save
    /// and drag-out share it, so dragging the same result three
    /// times does not create three numbered files, and Save after
    /// a drag does not duplicate it. Reset when a new image
    /// starts (see startRemoveBg), and re-written if the file was
    /// deleted externally.
    private func ensureRemoveBgFile() -> URL? {
        guard let data = removeBgResultData else { return nil }
        if let saved = removeBgSavedURL, FileManager.default.fileExists(atPath: saved.path) {
            return saved
        }
        guard let url = RimufuRemoveBgClient.uniqueDownloadURL(fileName: "Remove BG.png") else { return nil }
        do {
            try data.write(to: url, options: .atomic)
            removeBgSavedURL = url
            return url
        } catch {
            return nil
        }
    }

    private func saveRemoveBgResult() {
        // Already written (e.g. after a drag-out): instant, no
        // spinner — there is nothing to wait for.
        if let saved = removeBgSavedURL, FileManager.default.fileExists(atPath: saved.path) {
            let nameFont = NSFont.systemFont(ofSize: 13)
            removeBgStatusText = "Saved: \(truncated(saved.lastPathComponent, toWidth: 400, font: nameFont))"
            removeBgStatusIsError = false
            needsDisplay = true
            return
        }
        guard !removeBgSaving, let data = removeBgResultData,
              let url = RimufuRemoveBgClient.uniqueDownloadURL(fileName: "Remove BG.png") else {
            if !removeBgSaving {
                removeBgStatusText = "Could not save the result."
                removeBgStatusIsError = true
                needsDisplay = true
            }
            return
        }
        removeBgSaving = true
        startSaveSpinner()
        needsDisplay = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ok = (try? data.write(to: url, options: .atomic)) != nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.removeBgSaving = false
                self.stopSaveSpinner()
                if ok {
                    self.removeBgSavedURL = url
                    let nameFont = NSFont.systemFont(ofSize: 13)
                    self.removeBgStatusText = "Saved: \(self.truncated(url.lastPathComponent, toWidth: 400, font: nameFont))"
                    self.removeBgStatusIsError = false
                } else {
                    self.removeBgStatusText = "Could not save the result."
                    self.removeBgStatusIsError = true
                }
                self.needsDisplay = true
            }
        }
    }


    // MARK: - Convert section (Fase 1: single-file tools)

    /// Convert section (Rimufu API backend, see RimufuConvert.swift).
    /// One section with tool pills on top (pomodoro-pill pattern),
    /// not one section per tool — otherwise the dot column would
    /// grow to 11-12 sections. Layout mirrors Remove BG: 640x280,
    /// header + title, dots column on the right edge (content ends
    /// at x 600). Title at y 10, tool pills at y 36 (28 tall),
    /// panels at y 72 (156 tall), status at y 244, Save pill at
    /// y 236 (shared position with Remove BG's Save pill).
    /// Per-tool state is preserved when switching pills, so a
    /// result is not lost by an accidental pill tap. Merge PDF
    /// keeps its file list apart (mergeFiles below): one
    /// ConvertState per single-file tool, plus the merge list
    /// whose result/status ride in convertStates[.mergePDF].
    /// Rects follow the tray convention: base coords, used
    /// directly from mouseDown (at rest they equal view coords).
    private enum ConvertTool: CaseIterable {
        case photo, mergePDF, pdfToWord, compressPDF, pdfToMD

        var displayName: String {
            switch self {
            case .photo: return "Photo"
            case .mergePDF: return "Merge PDF"
            case .pdfToWord: return "PDF to Word"
            case .compressPDF: return "Compress PDF"
            case .pdfToMD: return "PDF to MD"
            }
        }

        var defaultStatus: String {
            switch self {
            case .photo: return "Drop an image, or click to pick one."
            case .mergePDF: return "Add at least 2 PDFs, then press Merge."
            default: return "Drop a PDF, or click to pick one."
            }
        }
    }

    private struct ConvertState {
        var inputName: String?
        var inputData: Data?
        var inputImage: NSImage?
        var inputSize: Int = 0
        var resultData: Data?
        var resultImage: NSImage?
        /// First-page thumbnail of a PDF result (merged /
        /// compressed), rendered once at completion so drawing
        /// never re-renders the page. Nil for non-PDF results.
        var resultPDFPreview: NSImage?
        var resultFileName: String?
        var savedURL: URL?
        var processing: Bool = false
        var statusText: String
        var statusIsError: Bool = false

        init(tool: ConvertTool) {
            statusText = tool.defaultStatus
        }
    }

    private var convertStates: [ConvertTool: ConvertState] = [:]
    private var convertActiveTool: ConvertTool = .photo
    private var convertPhotoFormat: ConvertFormat = .webp
    private var convertTask: URLSessionDataTask?
    private var convertActiveTaskTool: ConvertTool?
    private var convertPendingDrag: (tool: ConvertTool, point: CGPoint)?

    /// Save in flight: the Save pill shows a spinning "Saving…"
    /// state while the file write runs off the main thread, so a
    /// big result never looks dead. The spinner timer is shared;
    /// it stops when neither save runs. Convert tracks the tool
    /// so a save for one tool never spins another tool's pill.
    private var removeBgSaving = false
    private var convertSavingTool: ConvertTool?
    private var saveSpinnerPhase = 0
    private var saveSpinnerTimer: Timer?
    private var convertDropHighlight = false { didSet { needsDisplay = true } }

    /// Merge PDF's file list, in merge order: (file name, bytes).
    /// The result/status ride in convertStates[.mergePDF] like
    /// any other tool, so Save, drag-out, and the status row need
    /// no merge branch - only this list lives apart.
    private var mergeFiles: [(name: String, data: Data)] = []

    /// Merge drag reorder: pressing a list row arms a drag (the
    /// item, the press point, and the name order at press time).
    /// Moving past 3px activates it and the list shuffles live
    /// under the cursor; releasing without a drag keeps the old
    /// tap behavior (open the picker). A reorder invalidates a
    /// previous result only if the final order actually changed.
    private var mergeDragItem: (name: String, data: Data)?
    private var mergeDragIndex: Int?
    private var mergeDragPoint: CGPoint?
    private var mergeDragActive = false
    private var mergeDragStartOrder: [String] = []
    /// Cursor position during an active merge reorder drag, in
    /// view coords: the zoomed drag chip is drawn centered on it.
    private var mergeDragCursor: CGPoint?

    private func convertState(for tool: ConvertTool) -> ConvertState {
        convertStates[tool] ?? ConvertState(tool: tool)
    }

    private func setConvertState(_ state: ConvertState, for tool: ConvertTool) {
        convertStates[tool] = state
    }

    /// Whether a dropped/picked URL fits a tool: images for photo
    /// (same set as the Remove BG drop filter), PDFs for the PDF
    /// tools. The server re-validates (400 for a non-image / non-
    /// PDF), so this is a UI filter, not the security boundary.
    private func convertAccepts(url: URL, for tool: ConvertTool) -> Bool {
        let ext = url.pathExtension.lowercased()
        if tool == .photo {
            return ["png", "jpg", "jpeg", "heic", "webp", "gif", "bmp", "tiff"].contains(ext)
        }
        return ext == "pdf"
    }

    /// Left panel: drop zone and pick target (the From Tray pill
    /// sits inside it, see convertFromTrayPillRect).
    private func convertLeftRect() -> NSRect {
        // Merge PDF keeps a longer queue, so its file panel is
        // wider than the result panel; every other tool keeps the
        // original 180/376 split. All hit tests, content rects,
        // and the From Tray pill go through these two functions,
        // so nothing else needs to change.
        if convertActiveTool == .mergePDF {
            return NSRect(x: 28, y: 72, width: 300, height: 156)
        }
        return NSRect(x: 28, y: 72, width: 180, height: 156)
    }

    /// Right panel: the result. Ends at x 600 so it never
    /// overlaps the vertical dot column on the right edge. Also
    /// the drag source: pressing it arms a drag-out.
    private func convertRightRect() -> NSRect {
        if convertActiveTool == .mergePDF {
            return NSRect(x: 344, y: 72, width: 256, height: 156)
        }
        return NSRect(x: 224, y: 72, width: 376, height: 156)
    }

    /// Tool row metrics, self-fitting: the row must end at or
    /// before x 600 (the right panel's edge, clear of the dot
    /// column). Starting from the standard 14pt / 24pt padding,
    /// shrink the font, then the padding, until the tool pills
    /// fit. The Format pill used to ride this row and overflow
    /// it; it now lives in the bottom row (see
    /// convertFormatPillRect), so the fit covers tools only.
    /// Font metrics cannot be checked from Linux, so the fit is
    /// computed here instead of assumed.
    private func convertToolRowMetrics() -> (rects: [(tool: ConvertTool, rect: NSRect)], font: NSFont) {
        var fontSize: CGFloat = 14
        var pad: CGFloat = 24
        while true {
            let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
            var x: CGFloat = 28
            var rects: [(tool: ConvertTool, rect: NSRect)] = []
            for tool in ConvertTool.allCases {
                let width = (tool.displayName as NSString).size(withAttributes: [.font: font]).width + pad
                rects.append((tool: tool, rect: NSRect(x: x, y: 36, width: width, height: 28)))
                x += width + 8
            }
            if (rects.last?.rect.maxX ?? 28) <= 600 || (fontSize <= 11 && pad <= 16) {
                return (rects, font)
            }
            if fontSize > 11 {
                fontSize -= 0.5
            } else {
                pad -= 2
            }
        }
    }

    /// Format pill, bottom row of the Convert card (moved down
    /// from the tool row, which it used to overflow): fixed x 316
    /// so it never collides with the status text (truncated to
    /// 280 wide while Photo is active, ending at x 308) or the
    /// Save pill (x 536+). Same translucent setting-pill style.
    private func convertFormatPillRect() -> NSRect {
        let label = "Format: \(convertPhotoFormat.displayName) \u{25be}"
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let width = (label as NSString).size(withAttributes: [.font: font]).width + 24
        return NSRect(x: 316, y: 236, width: width, height: 28)
    }

    /// Content area inside the left panel: shrunk above the
    /// From Tray footer pill only when that pill is actually
    /// drawn (tray has a usable file for the active tool);
    /// otherwise the full inset is used.
    private func convertLeftContentRect() -> NSRect {
        let left = convertLeftRect()
        if convertTrayFiles(for: convertActiveTool).isEmpty {
            return left.insetBy(dx: 8, dy: 8)
        }
        return NSRect(x: left.minX + 8, y: left.minY + 8,
                      width: left.width - 16, height: left.height - 16 - 36)
    }

    private func drawConvert() {
        drawCardHeader(width: 640, showWaveform: false)
        drawText("Convert", font: NSFont.boldSystemFont(ofSize: 20), color: .white,
                 at: NSPoint(x: 28, y: 10))
        // Tool pills: active = solid white + black text (Save
        // pill style), inactive = translucent + stroke (From Tray
        // pill style).
        let row = convertToolRowMetrics()
        for (tool, rect) in row.rects {
            let active = (tool == convertActiveTool)
            if active {
                NSColor.white.setFill()
            } else {
                NSColor.white.withAlphaComponent(0.15).setFill()
            }
            NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14).fill()
            if !active {
                NSColor.white.withAlphaComponent(0.3).setStroke()
                NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14).stroke()
            }
            let font = row.font
            let width = (tool.displayName as NSString).size(withAttributes: [.font: font]).width
            drawText(tool.displayName, font: font, color: active ? .black : .white,
                     at: NSPoint(x: rect.midX - width / 2, y: rect.minY + 5))
        }
        if convertActiveTool == .photo {
            let format = convertFormatPillRect()
            NSColor.white.withAlphaComponent(0.15).setFill()
            NSBezierPath(roundedRect: format, xRadius: 14, yRadius: 14).fill()
            NSColor.white.withAlphaComponent(0.3).setStroke()
            NSBezierPath(roundedRect: format, xRadius: 14, yRadius: 14).stroke()
            let label = "Format: \(convertPhotoFormat.displayName) \u{25be}"
            let formatFont = NSFont.systemFont(ofSize: 13, weight: .medium)
            let formatWidth = (label as NSString).size(withAttributes: [.font: formatFont]).width
            drawText(label, font: formatFont, color: .white,
                     at: NSPoint(x: format.midX - formatWidth / 2, y: format.minY + 5))
        }
        let state = convertState(for: convertActiveTool)
        // Left panel: dashed drop zone (tray drop-zone style).
        let left = convertLeftRect()
        let leftPath = NSBezierPath(roundedRect: left, xRadius: 16, yRadius: 16)
        leftPath.setLineDash([8, 6], count: 2, phase: 0)
        leftPath.lineWidth = 1.5
        NSColor.white.withAlphaComponent(0.5).setStroke()
        leftPath.stroke()
        let content = convertLeftContentRect()
        if convertActiveTool == .mergePDF {
            drawMergeFileList(in: content)
        } else if convertActiveTool == .photo {
            if let image = state.inputImage {
                let fit = removeBgFitRect(for: image, in: content)
                drawImageUpright(image, in: fit)
            } else {
                let line1 = "Drop image here"
                let font1 = NSFont.systemFont(ofSize: 14)
                let w1 = (line1 as NSString).size(withAttributes: [.font: font1]).width
                drawText(line1, font: font1, color: NSColor.white.withAlphaComponent(0.8),
                         at: NSPoint(x: content.midX - w1 / 2, y: content.midY - 10))
                let line2 = "or click to pick"
                let font2 = NSFont.systemFont(ofSize: 12)
                let w2 = (line2 as NSString).size(withAttributes: [.font: font2]).width
                drawText(line2, font: font2, color: NSColor.white.withAlphaComponent(0.5),
                         at: NSPoint(x: content.midX - w2 / 2, y: content.midY + 10))
            }
        } else {
            if let name = state.inputName {
                let nameFont = NSFont.systemFont(ofSize: 13)
                let nameText = truncated(name, toWidth: content.width, font: nameFont)
                let nameWidth = (nameText as NSString).size(withAttributes: [.font: nameFont]).width
                drawText(nameText, font: nameFont, color: NSColor.white.withAlphaComponent(0.9),
                         at: NSPoint(x: content.midX - nameWidth / 2, y: content.midY - 10))
                let sizeText = formatBytes(Int64(state.inputSize))
                let sizeFont = NSFont.systemFont(ofSize: 12)
                let sizeWidth = (sizeText as NSString).size(withAttributes: [.font: sizeFont]).width
                drawText(sizeText, font: sizeFont, color: NSColor.white.withAlphaComponent(0.5),
                         at: NSPoint(x: content.midX - sizeWidth / 2, y: content.midY + 10))
            } else {
                let line1 = "Drop PDF here"
                let font1 = NSFont.systemFont(ofSize: 14)
                let w1 = (line1 as NSString).size(withAttributes: [.font: font1]).width
                drawText(line1, font: font1, color: NSColor.white.withAlphaComponent(0.8),
                         at: NSPoint(x: content.midX - w1 / 2, y: content.midY - 10))
                let line2 = "or click to pick"
                let font2 = NSFont.systemFont(ofSize: 12)
                let w2 = (line2 as NSString).size(withAttributes: [.font: font2]).width
                drawText(line2, font: font2, color: NSColor.white.withAlphaComponent(0.5),
                         at: NSPoint(x: content.midX - w2 / 2, y: content.midY + 10))
            }
        }
        if !convertTrayFiles(for: convertActiveTool).isEmpty {
            let tray = convertFromTrayPillRect()
            NSColor.white.withAlphaComponent(0.15).setFill()
            NSBezierPath(roundedRect: tray, xRadius: 14, yRadius: 14).fill()
            NSColor.white.withAlphaComponent(0.3).setStroke()
            NSBezierPath(roundedRect: tray, xRadius: 14, yRadius: 14).stroke()
            let label = "From Tray \u{25be}"
            let trayFont = NSFont.systemFont(ofSize: 13, weight: .medium)
            let trayWidth = (label as NSString).size(withAttributes: [.font: trayFont]).width
            drawText(label, font: trayFont, color: .white,
                     at: NSPoint(x: tray.midX - trayWidth / 2, y: tray.minY + 5))
        }
        // Right panel: result. Photo gets a checkerboard (image
        // result, like Remove BG); document tools get plain info
        // text, no checkerboard.
        let right = convertRightRect()
        let rightPath = NSBezierPath(roundedRect: right, xRadius: 12, yRadius: 12)
        if convertActiveTool == .photo {
            NSGraphicsContext.saveGraphicsState()
            rightPath.addClip()
            let square: CGFloat = 12
            var row = 0
            var y = right.minY
            while y < right.maxY {
                var col = 0
                var x = right.minX
                while x < right.maxX {
                    let light = (row + col) % 2 == 0
                    NSColor.white.withAlphaComponent(light ? 0.12 : 0.04).setFill()
                    NSRect(x: x, y: y, width: square, height: square).fill()
                    col += 1
                    x += square
                }
                row += 1
                y += square
            }
            if let resultImage = state.resultImage {
                let fit = removeBgFitRect(for: resultImage, in: right.insetBy(dx: 8, dy: 8))
                drawImageUpright(resultImage, in: fit)
            } else if let resultData = state.resultData, let resultName = state.resultFileName {
                // Bytes are valid (the client checked the format
                // magic) but this Mac cannot decode them for
                // preview — AVIF is the known case. The file itself
                // is fine: drag and Save still work, only the
                // preview is missing, so this is info, not error.
                let nameFont = NSFont.systemFont(ofSize: 13)
                let nameText = truncated(resultName, toWidth: right.width - 16, font: nameFont)
                let nameWidth = (nameText as NSString).size(withAttributes: [.font: nameFont]).width
                drawText(nameText, font: nameFont, color: NSColor.white.withAlphaComponent(0.9),
                         at: NSPoint(x: right.midX - nameWidth / 2, y: right.midY - 20))
                let sizeText = formatBytes(Int64(resultData.count))
                let sizeFont = NSFont.systemFont(ofSize: 12)
                let sizeWidth = (sizeText as NSString).size(withAttributes: [.font: sizeFont]).width
                drawText(sizeText, font: sizeFont, color: NSColor.white.withAlphaComponent(0.5),
                         at: NSPoint(x: right.midX - sizeWidth / 2, y: right.midY))
                let note = "Preview not available on this Mac."
                let noteFont = NSFont.systemFont(ofSize: 12)
                let noteWidth = (note as NSString).size(withAttributes: [.font: noteFont]).width
                drawText(note, font: noteFont, color: NSColor.white.withAlphaComponent(0.5),
                         at: NSPoint(x: right.midX - noteWidth / 2, y: right.midY + 20))
            } else {
                let placeholder = "Result appears here"
                let font = NSFont.systemFont(ofSize: 13)
                let width = (placeholder as NSString).size(withAttributes: [.font: font]).width
                drawText(placeholder, font: font, color: NSColor.white.withAlphaComponent(0.5),
                         at: NSPoint(x: right.midX - width / 2, y: right.midY - 7))
            }
            NSGraphicsContext.restoreGraphicsState()
        } else if convertActiveTool == .pdfToMD, let resultData = state.resultData {
            let text = String(data: resultData, encoding: .utf8) ?? ""
            let lines = text.components(separatedBy: "\n")
            let font = NSFont.systemFont(ofSize: 12)
            let innerWidth = right.width - 16
            var y = right.minY + 12
            for line in lines.prefix(6) {
                let shown = truncated(line, toWidth: innerWidth, font: font)
                drawText(shown, font: font, color: NSColor.white.withAlphaComponent(0.8),
                         at: NSPoint(x: right.minX + 8, y: y))
                y += 16
            }
            if lines.count > 6 {
                drawText("\u{2026}", font: font, color: NSColor.white.withAlphaComponent(0.5),
                         at: NSPoint(x: right.minX + 8, y: y))
            }
        } else if convertActiveTool == .mergePDF, let resultData = state.resultData,
                  let resultName = state.resultFileName, let preview = state.resultPDFPreview {
            // Merge result in the narrowed panel: thumbnail
            // centered, name + size + hint stacked below it
            // (the side-by-side layout would crush the text at
            // this width).
            let box = NSRect(x: right.minX + 8, y: right.minY + 8,
                             width: right.width - 16, height: 84)
            let fit = removeBgFitRect(for: preview, in: box)
            drawImageUpright(preview, in: fit)
            var ty = box.maxY + 8
            let mergeNameFont = NSFont.systemFont(ofSize: 13)
            let mergeNameText = truncated(resultName, toWidth: right.width - 16, font: mergeNameFont)
            let mergeNameWidth = (mergeNameText as NSString).size(withAttributes: [.font: mergeNameFont]).width
            drawText(mergeNameText, font: mergeNameFont, color: NSColor.white.withAlphaComponent(0.9),
                     at: NSPoint(x: right.midX - mergeNameWidth / 2, y: ty))
            ty += 18
            let mergeSizeText = formatBytes(Int64(resultData.count))
            let mergeSizeFont = NSFont.systemFont(ofSize: 12)
            let mergeSizeWidth = (mergeSizeText as NSString).size(withAttributes: [.font: mergeSizeFont]).width
            drawText(mergeSizeText, font: mergeSizeFont, color: NSColor.white.withAlphaComponent(0.5),
                     at: NSPoint(x: right.midX - mergeSizeWidth / 2, y: ty))
            ty += 18
            let mergeHint = "Drag the result out or Save it."
            let mergeHintFont = NSFont.systemFont(ofSize: 12)
            let mergeHintWidth = (mergeHint as NSString).size(withAttributes: [.font: mergeHintFont]).width
            drawText(mergeHint, font: mergeHintFont, color: NSColor.white.withAlphaComponent(0.5),
                     at: NSPoint(x: right.midX - mergeHintWidth / 2, y: ty))
        } else if let resultData = state.resultData, let resultName = state.resultFileName {
            if let preview = state.resultPDFPreview {
                // PDF result (merged / compressed): first-page
                // thumbnail on the left, name + size + hint
                // stacked on the right — the file itself, not
                // just its name.
                let fit = removeBgFitRect(for: preview, in: NSRect(x: right.minX + 8, y: right.minY + 8, width: 120, height: 140))
                drawImageUpright(preview, in: fit)
                let detailX = fit.maxX + 12
                let detailWidth = right.maxX - 8 - detailX
                let nameFont = NSFont.systemFont(ofSize: 13)
                let nameText = truncated(resultName, toWidth: detailWidth, font: nameFont)
                drawText(nameText, font: nameFont, color: NSColor.white.withAlphaComponent(0.9),
                         at: NSPoint(x: detailX, y: right.midY - 20))
                let sizeText = formatBytes(Int64(resultData.count))
                let sizeFont = NSFont.systemFont(ofSize: 12)
                drawText(sizeText, font: sizeFont, color: NSColor.white.withAlphaComponent(0.5),
                         at: NSPoint(x: detailX, y: right.midY))
                let hint = "Drag the result out or Save it."
                let hintFont = NSFont.systemFont(ofSize: 12)
                drawText(hint, font: hintFont, color: NSColor.white.withAlphaComponent(0.5),
                         at: NSPoint(x: detailX, y: right.midY + 20))
            } else {
                // Non-PDF result (Word): the file's icon, large,
                // above its name + size + hint.
                // Copy before resizing: the workspace icon is
                // shared, and mutating its size would leak into
                // every other use of that file-type icon.
                let icon = (NSWorkspace.shared.icon(forFileType: (resultName as NSString).pathExtension).copy() as? NSImage)
                    ?? NSWorkspace.shared.icon(forFileType: (resultName as NSString).pathExtension)
                icon.size = NSSize(width: 48, height: 48)
                icon.draw(in: NSRect(x: right.midX - 24, y: right.midY - 52, width: 48, height: 48),
                          from: .zero, operation: .sourceOver, fraction: 1.0)
                let nameFont = NSFont.systemFont(ofSize: 13)
                let nameText = truncated(resultName, toWidth: right.width - 16, font: nameFont)
                let nameWidth = (nameText as NSString).size(withAttributes: [.font: nameFont]).width
                drawText(nameText, font: nameFont, color: NSColor.white.withAlphaComponent(0.9),
                         at: NSPoint(x: right.midX - nameWidth / 2, y: right.midY + 8))
                let sizeText = formatBytes(Int64(resultData.count))
                let sizeFont = NSFont.systemFont(ofSize: 12)
                let sizeWidth = (sizeText as NSString).size(withAttributes: [.font: sizeFont]).width
                drawText(sizeText, font: sizeFont, color: NSColor.white.withAlphaComponent(0.5),
                         at: NSPoint(x: right.midX - sizeWidth / 2, y: right.midY + 28))
                let hint = "Drag the result out or Save it."
                let hintFont = NSFont.systemFont(ofSize: 12)
                let hintWidth = (hint as NSString).size(withAttributes: [.font: hintFont]).width
                drawText(hint, font: hintFont, color: NSColor.white.withAlphaComponent(0.5),
                         at: NSPoint(x: right.midX - hintWidth / 2, y: right.midY + 48))
            }
        } else {
            let placeholder = "Result appears here"
            let font = NSFont.systemFont(ofSize: 13)
            let width = (placeholder as NSString).size(withAttributes: [.font: font]).width
            drawText(placeholder, font: font, color: NSColor.white.withAlphaComponent(0.5),
                     at: NSPoint(x: right.midX - width / 2, y: right.midY - 7))
        }
        NSColor.white.withAlphaComponent(0.3).setStroke()
        rightPath.lineWidth = 1
        rightPath.stroke()
        // Status row, bottom-left (same coordinates as Remove BG).
        let statusFont = NSFont.systemFont(ofSize: 13)
        let statusColor = state.statusIsError ? NSColor.systemRed : NSColor.white.withAlphaComponent(0.7)
        // While Photo is active the status is truncated to 280
        // so it ends at x 308, clear of the bottom-row format
        // pill starting at x 316.
        drawText(truncated(state.statusText, toWidth: convertActiveTool == .photo ? 280 : 400, font: statusFont),
                 font: statusFont, color: statusColor, at: NSPoint(x: 28, y: 244))
        // Merge button, same spot as Save (Save replaces it
        // once a result exists): solid when 2+ files are ready,
        // translucent when fewer - tapping it short of 2 files
        // only sets the hint status, it never calls the server.
        if convertActiveTool == .mergePDF, state.resultData == nil, !state.processing {
            let merge = removeBgSaveRect()
            let ready = mergeFiles.count >= 2
            if ready {
                NSColor.white.setFill()
            } else {
                NSColor.white.withAlphaComponent(0.15).setFill()
            }
            NSBezierPath(roundedRect: merge, xRadius: 14, yRadius: 14).fill()
            if !ready {
                NSColor.white.withAlphaComponent(0.3).setStroke()
                NSBezierPath(roundedRect: merge, xRadius: 14, yRadius: 14).stroke()
            }
            let mergeFont = NSFont.systemFont(ofSize: 14, weight: .medium)
            let mergeWidth = ("Merge" as NSString).size(withAttributes: [.font: mergeFont]).width
            drawText("Merge", font: mergeFont, color: ready ? .black : .white,
                     at: NSPoint(x: merge.midX - mergeWidth / 2, y: merge.minY + 5))
        }
        // Save pill, only once a result exists (shared position
        // with Remove BG's Save pill). While a save runs it
        // shows the spinner instead of "Save".
        if state.resultData != nil, !state.processing {
            let save = removeBgSaveRect(saving: convertSavingTool == convertActiveTool)
            NSColor.white.setFill()
            NSBezierPath(roundedRect: save, xRadius: 14, yRadius: 14).fill()
            drawSavePillContent(in: save, saving: convertSavingTool == convertActiveTool)
        }
        // Drop highlight, on top of everything else in the section.
        if convertDropHighlight {
            let zone = NSRect(x: 28, y: 72, width: 572, height: 156)
            NSColor.white.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: zone, xRadius: 16, yRadius: 16).fill()
            let dashed = NSBezierPath(roundedRect: zone, xRadius: 16, yRadius: 16)
            dashed.setLineDash([8, 6], count: 2, phase: 0)
            dashed.lineWidth = 1.5
            NSColor.white.withAlphaComponent(0.8).setStroke()
            dashed.stroke()
            let label = convertActiveTool == .mergePDF ? "Release to add PDFs" : "Release to convert"
            let font = NSFont.systemFont(ofSize: 14)
            let width = (label as NSString).size(withAttributes: [.font: font]).width
            drawText(label, font: font, color: NSColor.white.withAlphaComponent(0.9),
                     at: NSPoint(x: zone.midX - width / 2, y: zone.midY - 7))
        }
    }

    private func convertFromTrayPillRect() -> NSRect {
        let left = convertLeftRect()
        return NSRect(x: left.minX + 8, y: left.maxY - 36, width: left.width - 16, height: 28)
    }

    /// Tray files usable for a tool (same filter as the drop
    /// filter, plus the file still existing on disk). Single-file
    /// tools take one; merge appends from the same list via its
    /// own menu (showMergeTrayMenu) instead of replacing.
    private func convertTrayFiles(for tool: ConvertTool) -> [TrayFile] {
        trayFiles.filter { file in
            !file.isDirectory && trayFileExists(file) && convertAccepts(url: file.url, for: tool)
        }
    }

    private func showConvertFromTrayMenu(at point: CGPoint) {
        let files = convertTrayFiles(for: convertActiveTool)
        guard !files.isEmpty else { return }
        let menu = NSMenu()
        for file in files {
            let nameFont = NSFont.systemFont(ofSize: 13)
            let item = NSMenuItem(title: truncated(file.name, toWidth: 300, font: nameFont),
                                  action: #selector(pickConvertFromTrayMenuFile(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = file
            menu.addItem(item)
        }
        presentCardModal { menu.popUp(positioning: nil, at: point, in: self) }
    }

    @objc private func pickConvertFromTrayMenuFile(_ sender: NSMenuItem) {
        guard let file = sender.representedObject as? TrayFile else { return }
        startConvert(with: file.url, tool: convertActiveTool)
    }

    private func pickConvertFile() {
        let tool = convertActiveTool
        guard !convertState(for: tool).processing else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // allowedFileTypes is deprecated but avoids a
        // UniformTypeIdentifiers import; it still works on macOS 13.
        if tool == .photo {
            panel.allowedFileTypes = ["png", "jpg", "jpeg", "heic", "webp", "gif", "bmp", "tiff"]
            panel.message = "Choose an image to convert"
        } else {
            panel.allowedFileTypes = ["pdf"]
            panel.message = "Choose a PDF"
        }
        // runModal, not a sheet: the island window is a non-key
        // panel, so a sheet would have nowhere to attach (same
        // reasoning as Remove BG's picker).
        guard presentCardModal({ panel.runModal() }) == .OK, let url = panel.url else { return }
        startConvert(with: url, tool: tool)
    }

    private func convertResultFileName(for tool: ConvertTool, inputName: String, format: ConvertFormat) -> String {
        let base = (inputName as NSString).deletingPathExtension
        switch tool {
        case .photo: return base + "." + format.fileExtension
        case .pdfToWord: return base + ".docx"
        case .compressPDF: return base + " compressed.pdf"
        case .pdfToMD: return base + ".md"
        case .mergePDF: return "merged_document.pdf"
        }
    }

    private func startConvert(with url: URL, tool: ConvertTool) {
        guard let fileData = try? Data(contentsOf: url) else {
            var failed = convertState(for: tool)
            failed.processing = false
            failed.statusText = "Could not read that file."
            failed.statusIsError = true
            setConvertState(failed, for: tool)
            needsDisplay = true
            return
        }
        var inputImage: NSImage?
        if tool == .photo {
            guard let image = NSImage(contentsOf: url) else {
                var failed = convertState(for: tool)
                failed.processing = false
                failed.statusText = "Could not read that image."
                failed.statusIsError = true
                setConvertState(failed, for: tool)
                needsDisplay = true
                return
            }
            inputImage = image
        }
        startConvertData(fileData, inputName: url.lastPathComponent, tool: tool, inputImage: inputImage)
    }

    /// Shared run start, used by pick/drop and by format changes
    /// (which re-run with the stored input, no re-pick needed).
    /// Cancelling a previous run resets that tool's state
    /// synchronously first, so its cancelled completion — which
    /// returns early — can never overwrite the new run's status.
    private func startConvertData(_ fileData: Data, inputName: String, tool: ConvertTool, inputImage: NSImage?) {
        // Merge never comes through here (it uses startMerge,
        // which owns the same single-task machinery).
        guard tool != .mergePDF else { return }
        if let prevTool = convertActiveTaskTool, convertTask != nil {
            var prev = convertState(for: prevTool)
            if prev.processing {
                prev.processing = false
                prev.statusText = "Cancelled."
                prev.statusIsError = false
                setConvertState(prev, for: prevTool)
            }
            convertTask?.cancel()
            convertTask = nil
            convertActiveTaskTool = nil
        }
        let photoFormat = convertPhotoFormat
        var state = convertState(for: tool)
        state.processing = true
        state.resultData = nil
        state.resultImage = nil
        state.resultPDFPreview = nil
        state.resultFileName = nil
        state.savedURL = nil
        state.statusText = "Processing…"
        state.statusIsError = false
        state.inputName = inputName
        state.inputData = fileData
        state.inputSize = fileData.count
        state.inputImage = inputImage
        setConvertState(state, for: tool)
        needsDisplay = true
        let completion: (Result<Data, RimufuConvertError>) -> Void = { [weak self] result in
            // URLSession calls back off the main thread; every UI
            // touch below must happen on main.
            DispatchQueue.main.async {
                guard let self else { return }
                if self.convertActiveTaskTool == tool {
                    self.convertTask = nil
                    self.convertActiveTaskTool = nil
                }
                switch result {
                case .success(let data):
                    var done = self.convertState(for: tool)
                    done.processing = false
                    done.resultData = data
                    done.resultFileName = self.convertResultFileName(for: tool, inputName: inputName, format: photoFormat)
                    if tool == .compressPDF {
                        done.resultPDFPreview = self.pdfFirstPageImage(from: data, maxSize: NSSize(width: 360, height: 140))
                    }
                    if tool == .photo {
                        // May stay nil for AVIF: the bytes are valid
                        // (the client checked the magic), this Mac
                        // just cannot decode them for preview. Draw
                        // handles that as info, not error.
                        done.resultImage = NSImage(data: data)
                    }
                    done.statusText = "Done — drag the result out to use it."
                    done.statusIsError = false
                    self.setConvertState(done, for: tool)
                case .failure(let error):
                    // Cancelled means a newer run already reset the
                    // status; showing an error here would overwrite
                    // the new run's "Processing…".
                    if case .uploadFailed(let detail) = error, detail == "Cancelled." {
                        return
                    }
                    var failed = self.convertState(for: tool)
                    failed.processing = false
                    failed.statusText = error.message
                    failed.statusIsError = true
                    self.setConvertState(failed, for: tool)
                }
                self.needsDisplay = true
            }
        }
        let task: URLSessionDataTask?
        switch tool {
        case .photo:
            task = RimufuConvertClient.convertImage(data: fileData, fileName: inputName,
                                                     mimeType: RimufuRemoveBgClient.mimeType(for: inputName),
                                                     format: photoFormat, completion: completion)
        case .pdfToWord:
            task = RimufuConvertClient.pdfToWord(data: fileData, fileName: inputName, completion: completion)
        case .compressPDF:
            task = RimufuConvertClient.compressPDF(data: fileData, fileName: inputName, completion: completion)
        case .pdfToMD:
            task = RimufuConvertClient.pdfToMarkdown(data: fileData, fileName: inputName, completion: completion)
        case .mergePDF:
            // Unreachable (guarded above); kept for exhaustiveness.
            task = nil
        }
        convertTask = task
        convertActiveTaskTool = tool
    }

    /// Format menu for the photo tool (bottom-row pill).
    /// The current format is checkmarked. Picking a new format
    /// re-runs with the stored input when one exists, so the user
    /// can compare AVIF vs WebP without re-picking.
    private func showConvertFormatMenu(at point: CGPoint) {
        let menu = NSMenu()
        for format in ConvertFormat.allCases {
            let item = NSMenuItem(title: format.displayName,
                                  action: #selector(pickConvertFormat(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = format.formValue
            item.state = (format == convertPhotoFormat) ? .on : .off
            menu.addItem(item)
        }
        presentCardModal { menu.popUp(positioning: nil, at: point, in: self) }
    }

    @objc private func pickConvertFormat(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String,
              let format = ConvertFormat(rawValue: value) else { return }
        convertPhotoFormat = format
        needsDisplay = true
        let state = convertState(for: .photo)
        guard !state.processing, let inputData = state.inputData, let inputName = state.inputName else { return }
        startConvertData(inputData, inputName: inputName, tool: .photo, inputImage: state.inputImage)
    }

    /// The result's file on disk, written once and reused (same
    /// pattern as Remove BG's ensure, but per Convert tool).
    private func ensureConvertFile(for tool: ConvertTool) -> URL? {
        var state = convertState(for: tool)
        guard let data = state.resultData, let fileName = state.resultFileName else { return nil }
        if let saved = state.savedURL, FileManager.default.fileExists(atPath: saved.path) {
            return saved
        }
        guard let url = RimufuRemoveBgClient.uniqueDownloadURL(fileName: fileName) else { return nil }
        do {
            try data.write(to: url, options: .atomic)
            state.savedURL = url
            setConvertState(state, for: tool)
            return url
        } catch {
            return nil
        }
    }

    /// Rows of the merge list, for drawing and for hit-testing
    /// the per-row remove control. Rows live in the left panel's
    /// content rect (which already shrinks above the From Tray
    /// footer pill when one is drawn), 18pt tall. When the list
    /// is longer than the panel, the last visible row becomes
    /// an overflow line with no remove control.
    /// Rows of the merge list (file rows only: the overflow
    /// line is not a row and never drags). Shared by drawing,
    /// the remove control, and reorder hit-testing, so the three
    /// can never disagree about row geometry.
    private func mergeFileRowRects() -> [(index: Int, rect: NSRect)] {
        let content = convertLeftContentRect()
        let maxRows = max(1, Int(content.height / 18))
        let shown = min(mergeFiles.count, maxRows)
        let overflow = mergeFiles.count > maxRows
        let rows = overflow ? shown - 1 : shown
        return (0..<rows).map { i in
            (index: i, rect: NSRect(x: content.minX, y: content.minY + CGFloat(i) * 18,
                                    width: content.width, height: 18))
        }
    }

    private func mergeFileRemoveRects() -> [(index: Int, rect: NSRect)] {
        mergeFileRowRects().map { (index: $0.index,
                                    rect: NSRect(x: $0.rect.maxX - 20, y: $0.rect.minY,
                                                 width: 20, height: 18)) }
    }

    private func drawMergeFileList(in content: NSRect) {
        if mergeFiles.isEmpty {
            let line1 = "Drop PDFs here"
            let font1 = NSFont.systemFont(ofSize: 14)
            let w1 = (line1 as NSString).size(withAttributes: [.font: font1]).width
            drawText(line1, font: font1, color: NSColor.white.withAlphaComponent(0.8),
                     at: NSPoint(x: content.midX - w1 / 2, y: content.midY - 10))
            let line2 = "or click to pick"
            let font2 = NSFont.systemFont(ofSize: 12)
            let w2 = (line2 as NSString).size(withAttributes: [.font: font2]).width
            drawText(line2, font: font2, color: NSColor.white.withAlphaComponent(0.5),
                     at: NSPoint(x: content.midX - w2 / 2, y: content.midY + 10))
            return
        }
        let maxRows = max(1, Int(content.height / 18))
        let overflow = mergeFiles.count > maxRows
        let shown = min(mergeFiles.count, maxRows)
        let nameFont = NSFont.systemFont(ofSize: 13)
        for i in 0..<shown {
            let y = content.minY + CGFloat(i) * 18
            if overflow, i == shown - 1 {
                let more = "... +\(mergeFiles.count - (shown - 1)) more"
                drawText(more, font: nameFont, color: NSColor.white.withAlphaComponent(0.5),
                         at: NSPoint(x: content.minX, y: y + 2))
                continue
            }
            // The dragged row lifts out of the list (drawn as a
            // zoomed chip under the cursor below); its slot keeps
            // only the highlight so the landing spot stays visible.
            let isDraggedRow = mergeDragActive && mergeDragIndex == i
            if isDraggedRow {
                NSColor.white.withAlphaComponent(0.12).setFill()
                NSRect(x: content.minX, y: y, width: content.width, height: 18).fill()
            } else {
            // Drag grip (music-queue style): three lines at the
            // row's left edge; the row drags to reorder.
            NSColor.white.withAlphaComponent(0.4).setFill()
            for gy in [y + 4, y + 8, y + 12] {
                NSRect(x: content.minX, y: gy, width: 8, height: 1.5).fill()
            }
            let name = truncated(mergeFiles[i].name, toWidth: content.width - 38, font: nameFont)
            drawText(name, font: nameFont, color: NSColor.white.withAlphaComponent(0.9),
                     at: NSPoint(x: content.minX + 14, y: y + 2))
            // Remove control, drawn as two strokes (not a glyph):
            // a 10pt cross at the row's right edge, inside the
            // 20pt hit rect mergeFileRemoveRects returns.
            let cross = NSRect(x: content.maxX - 14, y: y + 4, width: 10, height: 10)
            NSColor.white.withAlphaComponent(0.5).setStroke()
            let crossPath = NSBezierPath()
            crossPath.lineWidth = 1.5
            crossPath.move(to: NSPoint(x: cross.minX, y: cross.minY))
            crossPath.line(to: NSPoint(x: cross.maxX, y: cross.maxY))
            crossPath.move(to: NSPoint(x: cross.maxX, y: cross.minY))
            crossPath.line(to: NSPoint(x: cross.minX, y: cross.maxY))
            crossPath.stroke()
            }
        }
        // Floating drag chip: the dragged file follows the cursor,
        // zoomed 1.18x with a soft shadow, so the drag reads as
        // lifting the file out of the queue.
        if mergeDragActive, let cursor = mergeDragCursor,
           let di = mergeDragIndex, di < mergeFiles.count {
            let file = mergeFiles[di]
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 4), blur: 10,
                          color: NSColor.black.withAlphaComponent(0.45).cgColor)
            ctx.translateBy(x: cursor.x, y: cursor.y)
            ctx.scaleBy(x: 1.18, y: 1.18)
            ctx.translateBy(x: -content.midX, y: -(content.minY + 9))
            let chip = NSRect(x: content.minX, y: content.minY,
                              width: content.width, height: 18)
            NSColor.white.withAlphaComponent(0.32).setFill()
            NSBezierPath(roundedRect: chip, xRadius: 9, yRadius: 9).fill()
            NSColor.white.withAlphaComponent(0.5).setStroke()
            NSBezierPath(roundedRect: chip, xRadius: 9, yRadius: 9).stroke()
            NSColor.white.withAlphaComponent(0.5).setFill()
            for gy in [chip.minY + 4, chip.minY + 8, chip.minY + 12] {
                NSRect(x: chip.minX + 6, y: gy, width: 8, height: 1.5).fill()
            }
            let chipName = truncated(file.name, toWidth: content.width - 44, font: nameFont)
            drawText(chipName, font: nameFont, color: .white,
                     at: NSPoint(x: chip.minX + 20, y: chip.minY + 2))
            ctx.restoreGState()
        }
    }

    /// Append files to the merge list (picker, drop, or From
    /// Tray). Any list change invalidates a previous result:
    /// the merged file no longer matches the list.
    private func addMergeFiles(_ urls: [URL]) {
        guard !convertState(for: .mergePDF).processing else { return }
        var added = 0
        for url in urls where convertAccepts(url: url, for: .mergePDF) {
            guard let data = try? Data(contentsOf: url) else { continue }
            mergeFiles.append((name: url.lastPathComponent, data: data))
            added += 1
        }
        guard added > 0 else { return }
        var state = convertState(for: .mergePDF)
        state.resultData = nil
        state.resultImage = nil
        state.resultPDFPreview = nil
        state.resultFileName = nil
        state.savedURL = nil
        state.statusIsError = false
        state.statusText = mergeFiles.count == 1
            ? "1 PDF - add at least 1 more, then press Merge."
            : "\(mergeFiles.count) PDFs ready - press Merge."
        setConvertState(state, for: .mergePDF)
        needsDisplay = true
    }

    private func removeMergeFile(at index: Int) {
        guard !convertState(for: .mergePDF).processing else { return }
        guard mergeFiles.indices.contains(index) else { return }
        mergeFiles.remove(at: index)
        var state = convertState(for: .mergePDF)
        state.resultData = nil
        state.resultImage = nil
        state.resultPDFPreview = nil
        state.resultFileName = nil
        state.savedURL = nil
        state.statusIsError = false
        if mergeFiles.isEmpty {
            state.statusText = ConvertTool.mergePDF.defaultStatus
        } else if mergeFiles.count == 1 {
            state.statusText = "1 PDF - add at least 1 more, then press Merge."
        } else {
            state.statusText = "\(mergeFiles.count) PDFs ready - press Merge."
        }
        setConvertState(state, for: .mergePDF)
        needsDisplay = true
    }

    private func pickMergeFiles() {
        guard !convertState(for: .mergePDF).processing else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedFileTypes = ["pdf"]
        panel.message = "Choose PDFs to merge"
        // runModal, not a sheet: same non-key window reasoning
        // as pickConvertFile.
        guard presentCardModal({ panel.runModal() }) == .OK, !panel.urls.isEmpty else { return }
        addMergeFiles(panel.urls)
    }

    private func showMergeTrayMenu(at point: CGPoint) {
        let files = convertTrayFiles(for: .mergePDF)
        guard !files.isEmpty else { return }
        let menu = NSMenu()
        for file in files {
            let nameFont = NSFont.systemFont(ofSize: 13)
            let item = NSMenuItem(title: truncated(file.name, toWidth: 300, font: nameFont),
                                  action: #selector(pickMergeFromTrayMenuFile(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = file
            menu.addItem(item)
        }
        presentCardModal { menu.popUp(positioning: nil, at: point, in: self) }
    }

    @objc private func pickMergeFromTrayMenuFile(_ sender: NSMenuItem) {
        guard let file = sender.representedObject as? TrayFile else { return }
        addMergeFiles([file.url])
    }

    /// Run the merge. The files snapshot is taken up front:
    /// adds/removes are ignored while a run is in flight, so
    /// the list cannot change under the upload.
    private func startMerge() {
        let tool = ConvertTool.mergePDF
        if convertState(for: tool).processing { return }
        guard mergeFiles.count >= 2 else {
            var hint = convertState(for: tool)
            hint.statusText = "Add at least 2 PDFs to merge."
            hint.statusIsError = false
            setConvertState(hint, for: tool)
            needsDisplay = true
            return
        }
        if let prevTool = convertActiveTaskTool, convertTask != nil {
            var prev = convertState(for: prevTool)
            if prev.processing {
                prev.processing = false
                prev.statusText = "Cancelled."
                prev.statusIsError = false
                setConvertState(prev, for: prevTool)
            }
            convertTask?.cancel()
            convertTask = nil
            convertActiveTaskTool = nil
        }
        let files = mergeFiles
        var state = convertState(for: tool)
        state.processing = true
        state.resultData = nil
        state.resultImage = nil
        state.resultPDFPreview = nil
        state.resultFileName = nil
        state.savedURL = nil
        state.statusText = "Merging..."
        state.statusIsError = false
        setConvertState(state, for: tool)
        needsDisplay = true
        let completion: (Result<Data, RimufuConvertError>) -> Void = { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.convertActiveTaskTool == tool {
                    self.convertTask = nil
                    self.convertActiveTaskTool = nil
                }
                switch result {
                case .success(let data):
                    var done = self.convertState(for: tool)
                    done.processing = false
                    done.resultData = data
                    done.resultFileName = "merged_document.pdf"
                    done.resultPDFPreview = self.pdfFirstPageImage(from: data, maxSize: NSSize(width: 360, height: 140))
                    done.statusText = "Done - drag the result out to use it."
                    done.statusIsError = false
                    self.setConvertState(done, for: tool)
                case .failure(let error):
                    if case .uploadFailed(let detail) = error, detail == "Cancelled." {
                        return
                    }
                    var failed = self.convertState(for: tool)
                    failed.processing = false
                    failed.statusText = error.message
                    failed.statusIsError = true
                    self.setConvertState(failed, for: tool)
                }
                self.needsDisplay = true
            }
        }
        convertTask = RimufuConvertClient.mergePDFs(files: files.map { (data: $0.data, fileName: $0.name) }, completion: completion)
        convertActiveTaskTool = tool
    }

    private func saveConvertResult() {
        let tool = convertActiveTool
        var state = convertState(for: tool)
        // Already written (e.g. after a drag-out): instant, no
        // spinner — there is nothing to wait for.
        if let saved = state.savedURL, FileManager.default.fileExists(atPath: saved.path) {
            let nameFont = NSFont.systemFont(ofSize: 13)
            state.statusText = "Saved: \(truncated(saved.lastPathComponent, toWidth: 400, font: nameFont))"
            state.statusIsError = false
            setConvertState(state, for: tool)
            needsDisplay = true
            return
        }
        guard convertSavingTool == nil, let data = state.resultData, let fileName = state.resultFileName,
              let url = RimufuRemoveBgClient.uniqueDownloadURL(fileName: fileName) else {
            if convertSavingTool == nil {
                state.statusText = "Could not save the result."
                state.statusIsError = true
                setConvertState(state, for: tool)
                needsDisplay = true
            }
            return
        }
        convertSavingTool = tool
        startSaveSpinner()
        needsDisplay = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ok = (try? data.write(to: url, options: .atomic)) != nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.convertSavingTool = nil
                self.stopSaveSpinner()
                var done = self.convertState(for: tool)
                if ok {
                    done.savedURL = url
                    let nameFont = NSFont.systemFont(ofSize: 13)
                    done.statusText = "Saved: \(self.truncated(url.lastPathComponent, toWidth: 400, font: nameFont))"
                    done.statusIsError = false
                } else {
                    done.statusText = "Could not save the result."
                    done.statusIsError = true
                }
                self.setConvertState(done, for: tool)
                self.needsDisplay = true
            }
        }
    }

    private func drawTray() {
        // Drop zone replaces the content while a drag hovers (the
        // Shelf reference: dashed area + "Release to add", title and
        // dots stay). Share mode is already cleared on drag-enter.
        if trayDropHighlight {
            drawTrayDropZone()
            return
        }
        if trayShareFile != nil {
            // Share mode draws its own top (title + back pill, no
            // card header — the header waveform would collide with
            // the back pill at the top-right).
            drawTrayShare()
        } else {
            drawCardHeader(width: 640)
            drawText("Tray", font: NSFont.boldSystemFont(ofSize: 20), color: .white, at: NSPoint(x: 28, y: 10))
            drawTrayGrid()
        }
    }

    /// Tiles per grid page (4 columns x 2 rows).
    private let trayGridColumns = 4
    private let trayGridRows = 2
    private var trayTilesPerPage: Int { trayGridColumns * trayGridRows }

    private func trayGridPageCount() -> Int {
        loadTrayFilesIfNeeded()
        return max(1, (trayFiles.count + trayTilesPerPage - 1) / trayTilesPerPage)
    }

    /// Files on the current grid page (clamped page).
    private func trayGridPageFiles() -> [TrayFile] {
        loadTrayFilesIfNeeded()
        let page = min(trayGridPage, trayGridPageCount() - 1)
        let start = page * trayTilesPerPage
        return Array(trayFiles.dropFirst(start).prefix(trayTilesPerPage))
    }

    private func moveGridPage(by delta: Int) {
        let count = trayGridPageCount()
        guard count > 1 else { return }
        trayGridPage = (trayGridPage + delta + count) % count
        needsDisplay = true
    }

    /// Clear-all (the Shelf "Clear" / DynamicNotch "All"): removes
    /// references only, never the files themselves.
    private func clearTray() {
        loadTrayFilesIfNeeded()
        trayFiles.removeAll()
        trayGridPage = 0
        saveTrayFiles()
        needsDisplay = true
    }

    /// "Clear" pill right after the "Tray" title (like Shelf's
    /// title + Clear). Only drawn/hit when the tray is non-empty.
    private func trayClearPillRect() -> NSRect {
        let titleFont = NSFont.boldSystemFont(ofSize: 20)
        let titleW = ("Tray" as NSString).size(withAttributes: [.font: titleFont]).width
        let clearFont = NSFont.systemFont(ofSize: 14)
        let clearW = ("Clear" as NSString).size(withAttributes: [.font: clearFont]).width
        return NSRect(x: 28 + titleW + 12, y: 10, width: 12 + clearW + 12, height: 28)
    }

    /// Draws the Clear pill (no-op when empty). Shared by the
    /// grid and the drop zone so hit == drawn in both.
    private func drawTrayClearPill() {
        guard !trayFiles.isEmpty else { return }
        let clear = trayClearPillRect()
        NSColor.white.withAlphaComponent(0.10).setFill()
        NSBezierPath(roundedRect: clear, xRadius: 14, yRadius: 14).fill()
        let clearFont = NSFont.systemFont(ofSize: 14)
        let clearW = ("Clear" as NSString).size(withAttributes: [.font: clearFont]).width
        drawText("Clear", font: clearFont, color: .white,
                 at: NSPoint(x: clear.midX - clearW / 2, y: clear.minY + 5))
    }

    /// Tiles on the current grid page: rect + delete (×) rect +
    /// existence. Tile 136x100, gap 12, grid x30..610, y44..256.
    private func trayGridTileRects() -> [(file: TrayFile, rect: NSRect, deleteRect: NSRect, exists: Bool)] {
        trayGridPageFiles().enumerated().map { i, file in
            let col = i % trayGridColumns
            let row = i / trayGridColumns
            let rect = NSRect(x: 30 + CGFloat(col) * (136 + 12),
                              y: 44 + CGFloat(row) * (100 + 12),
                              width: 136, height: 100)
            return (file: file, rect: rect,
                    deleteRect: NSRect(x: rect.maxX - 24, y: rect.minY, width: 24, height: 24),
                    exists: trayFileExists(file))
        }
    }

    /// Arrow hit areas (44px, centered on the 36px circles at the
    /// grid's vertical center, y150).
    private func trayGridArrowRects() -> (left: NSRect, right: NSRect) {
        (left: NSRect(x: 26, y: 128, width: 44, height: 44),
         right: NSRect(x: 570, y: 128, width: 44, height: 44))
    }

    /// Page dot hit slots (18px pitch, 16 tall, y260..276).
    /// Empty when there is only one page (no dots drawn).
    private func trayGridPageDotRects() -> [NSRect] {
        let count = trayGridPageCount()
        guard count > 1 else { return [] }
        let startX = (640 - CGFloat(count * 18)) / 2
        return (0..<count).map { i in NSRect(x: startX + CGFloat(i * 18), y: 260, width: 18, height: 16) }
    }

    /// Page dots (bottom center, like Shelf): active = dash, rest =
    /// dots. Hidden when there is only one page.
    private func drawTrayPageDots() {
        let count = trayGridPageCount()
        guard count > 1 else { return }
        let page = min(trayGridPage, count - 1)
        for (i, slot) in trayGridPageDotRects().enumerated() {
            if i == page {
                NSColor.white.setFill()
                NSBezierPath(roundedRect: NSRect(x: slot.midX - 6, y: 265, width: 12, height: 6), xRadius: 3, yRadius: 3).fill()
            } else {
                NSColor.white.withAlphaComponent(0.4).setFill()
                NSBezierPath(ovalIn: NSRect(x: slot.midX - 3, y: 265, width: 6, height: 6)).fill()
            }
        }
    }

    /// Draw one grid tile (background + icon + name + size + ×).
    /// The caller wraps this in a scale transform for popping tiles.
    private func drawTrayTile(file: TrayFile, rect: NSRect, deleteRect: NSRect, exists: Bool) {
        NSColor.white.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
        let alpha: CGFloat = exists ? 1.0 : 0.4
        let symbol = file.isDirectory ? "folder.fill" : "doc.fill"
        drawSymbol(symbol, size: 36, center: CGPoint(x: rect.midX, y: rect.minY + 28), fallback: file.isDirectory ? "F" : "D",
                   color: NSColor.white.withAlphaComponent(alpha))
        let nameFont = NSFont.systemFont(ofSize: 13)
        let name = exists ? file.name : file.name + " (missing)"
        let nameText = truncated(name, toWidth: rect.width - 16, font: nameFont)
        let nameW = (nameText as NSString).size(withAttributes: [.font: nameFont]).width
        drawText(nameText, font: nameFont, color: NSColor.white.withAlphaComponent(alpha),
                 at: NSPoint(x: rect.midX - nameW / 2, y: rect.minY + 62))
        let sizeFont = NSFont.systemFont(ofSize: 11)
        let sizeText = file.isDirectory ? "Folder" : formatBytes(file.size)
        let sizeW = (sizeText as NSString).size(withAttributes: [.font: sizeFont]).width
        drawText(sizeText, font: sizeFont, color: NSColor.white.withAlphaComponent(0.6),
                 at: NSPoint(x: rect.midX - sizeW / 2, y: rect.minY + 82))
        let xLabel = "×"
        let xFont = NSFont.systemFont(ofSize: 14)
        let xW = (xLabel as NSString).size(withAttributes: [.font: xFont]).width
        drawText(xLabel, font: xFont, color: NSColor.white.withAlphaComponent(0.4),
                 at: NSPoint(x: deleteRect.midX - xW / 2, y: deleteRect.midY - 8))
    }


    /// Grid list view (DynamicNotch-style): tiles 4x2 per page,
    /// arrows + page dots when there is another page, Clear.
    /// Tap a tile = share (on mouseUp); press-drag a tile = drag-out.
    private func drawTrayGrid() {
        loadTrayFilesIfNeeded()
        drawTrayClearPill()
        let tiles = trayGridTileRects()
        if tiles.isEmpty {
            // Empty state: dashed drop-target box + file icon (the
            // tray is a drop target even when idle, not just mid-drag).
            let zone = NSRect(x: 28, y: 44, width: 584, height: 212)
            let dashed = NSBezierPath(roundedRect: zone, xRadius: 20, yRadius: 20)
            dashed.setLineDash([8, 6], count: 2, phase: 0)
            dashed.lineWidth = 1.5
            NSColor.white.withAlphaComponent(0.5).setStroke()
            dashed.stroke()
            drawSymbol("doc.fill", size: 48, center: CGPoint(x: 320, y: 165), fallback: "D",
                       color: NSColor.white.withAlphaComponent(0.6))
            let emptyFont = NSFont.systemFont(ofSize: 14)
            let emptyText = "Drag files here"
            let emptyW = (emptyText as NSString).size(withAttributes: [.font: emptyFont]).width
            drawText(emptyText, font: emptyFont, color: NSColor.white.withAlphaComponent(0.6),
                     at: NSPoint(x: 320 - emptyW / 2, y: 115))
            return
        }
        // Arrows (only when there is another page).
        if trayGridPageCount() > 1 {
            let arrows = trayGridArrowRects()
            for center in [CGPoint(x: arrows.left.midX, y: arrows.left.midY),
                           CGPoint(x: arrows.right.midX, y: arrows.right.midY)] {
                NSColor.white.withAlphaComponent(0.15).setFill()
                NSBezierPath(ovalIn: NSRect(x: center.x - 18, y: center.y - 18, width: 36, height: 36)).fill()
            }
            drawSymbol("chevron.left", size: 16, center: CGPoint(x: arrows.left.midX, y: arrows.left.midY), fallback: "<")
            drawSymbol("chevron.right", size: 16, center: CGPoint(x: arrows.right.midX, y: arrows.right.midY), fallback: ">")
        }
        // Tiles (Nusa-style: items appear together, no pop).
        for tile in tiles {
            drawTrayTile(file: tile.file, rect: tile.rect, deleteRect: tile.deleteRect, exists: tile.exists)
        }
        drawTrayPageDots()
    }

    /// Drop zone while a drag hovers (Shelf's drag state): dashed
    /// area + "Release to add" + "+ Copy" badge at the cursor.
    /// Title, Clear, and dots stay; the file content is replaced.
    private func drawTrayDropZone() {
        drawCardHeader(width: 640)
        drawText("Tray", font: NSFont.boldSystemFont(ofSize: 20), color: .white, at: NSPoint(x: 28, y: 10))
        drawTrayClearPill()
        let zone = NSRect(x: 28, y: 44, width: 584, height: 212)
        // Cursor light (replaces the tray gradient): a radial glow
        // centred on the drag cursor, clipped to the drop zone, so it
        // follows the cursor as draggingUpdated refreshes trayDragPoint.
        // Drop-zone drawing lives in base coords (the draw() spring
        // transform maps them to window coords), so a drag point in
        // window coords is converted back to base coords while a
        // spring runs; at rest the two are identical.
        if let point = trayDragPoint, let ctx = NSGraphicsContext.current?.cgContext {
            let glowPoint = basePoint(from: point)
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: zone, cornerWidth: 20, cornerHeight: 20, transform: nil))
            ctx.clip()
            let glowColors = [NSColor.white.withAlphaComponent(0.25).cgColor,
                              NSColor.white.withAlphaComponent(0.0).cgColor] as CFArray
            if let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: glowColors, locations: [0, 1]) {
                ctx.drawRadialGradient(glow, startCenter: glowPoint, startRadius: 0,
                                       endCenter: glowPoint, endRadius: 160, options: [])
            }
            ctx.restoreGState()
        }
        let dashed = NSBezierPath(roundedRect: zone, xRadius: 20, yRadius: 20)
        dashed.setLineDash([8, 6], count: 2, phase: 0)
        dashed.lineWidth = 1.5
        NSColor.white.withAlphaComponent(0.5).setStroke()
        dashed.stroke()
        let label = "Release to add"
        let labelFont = NSFont.systemFont(ofSize: 14)
        let labelW = (label as NSString).size(withAttributes: [.font: labelFont]).width
        drawText(label, font: labelFont, color: NSColor.white.withAlphaComponent(0.7),
                 at: NSPoint(x: zone.midX - labelW / 2, y: zone.midY - 7))
        drawTrayPageDots()
        // "+ Copy" badge below-right of the cursor (clamped to the card).
        if let point = trayDragPoint {
            // Badge is drawn in base coords: use the converted cursor
            // point and clamp to the base card, not the headroom window,
            // or the badge (like the dots) drifts right during a drag.
            let base = basePoint(from: point)
            let badgeFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
            let badgeW = ("+ Copy" as NSString).size(withAttributes: [.font: badgeFont]).width + 16
            let badgeX = min(base.x + 14, drawingWidth - badgeW - 8)
            let badgeY = min(base.y + 6, drawingHeight - 22 - 8)
            let badge = NSRect(x: badgeX, y: badgeY, width: badgeW, height: 22)
            NSColor.white.setFill()
            NSBezierPath(roundedRect: badge, xRadius: 11, yRadius: 11).fill()
            drawText("+ Copy", font: badgeFont, color: .black,
                     at: NSPoint(x: badge.minX + 8, y: badge.minY + 5))
        }
    }

    private func drawTrayShare() {
        guard let file = trayShareFile else { return }
        drawText("Share", font: NSFont.boldSystemFont(ofSize: 20), color: .white, at: NSPoint(x: 28, y: 10))
        // Back pill (top-right).
        let back = trayShareBackRect()
        NSColor.white.withAlphaComponent(0.10).setFill()
        NSBezierPath(roundedRect: back, xRadius: 14, yRadius: 14).fill()
        let backFont = NSFont.systemFont(ofSize: 14)
        let backW = ("Cancel" as NSString).size(withAttributes: [.font: backFont]).width
        drawText("Cancel", font: backFont, color: .white,
                 at: NSPoint(x: back.midX - backW / 2, y: back.minY + 5))
        // Shared file row (32-tall row at minY 44: icon center 60,
        // name baseline 51, like todo's rows).
        drawSymbol(file.isDirectory ? "folder.fill" : "doc.fill", size: 20,
                   center: CGPoint(x: 40, y: 60), fallback: file.isDirectory ? "F" : "D")
        let nameFont = NSFont.systemFont(ofSize: 14)
        drawText(truncated(file.name, toWidth: 540, font: nameFont),
                 font: nameFont, color: .white, at: NSPoint(x: 56, y: 51))
        if let peer = traySharePeer {
            // Sending status view.
            drawText("To \(peer.name)", font: NSFont.systemFont(ofSize: 14),
                     color: NSColor.white.withAlphaComponent(0.6), at: NSPoint(x: 28, y: 96))
            drawText(trayShareStatus ?? "Sending...", font: NSFont.systemFont(ofSize: 14),
                     color: .white, at: NSPoint(x: 28, y: 120))
            if let progress = trayShareProgress {
                let track = NSRect(x: 28, y: 152, width: 572, height: 8)
                NSColor.white.withAlphaComponent(0.15).setFill()
                NSBezierPath(roundedRect: track, xRadius: 4, yRadius: 4).fill()
                let fillW = max(0, min(1, progress)) * track.width
                if fillW > 0 {
                    NSColor.white.setFill()
                    NSBezierPath(roundedRect: NSRect(x: 28, y: 152, width: fillW, height: 8),
                                 xRadius: min(4, fillW / 2), yRadius: 4).fill()
                }
            }
        } else if trayShareMethod == .lan {
            // Peer list (the recipient picker).
            let peers = traySharePeerRects()
            if peers.isEmpty {
                drawText("Looking for Aura devices...", font: NSFont.systemFont(ofSize: 14),
                         color: NSColor.white.withAlphaComponent(0.6), at: NSPoint(x: 28, y: 84))
                drawText("Other devices must run Aura on the same network.",
                         font: NSFont.systemFont(ofSize: 12),
                         color: NSColor.white.withAlphaComponent(0.4), at: NSPoint(x: 28, y: 108))
            } else {
                for row in peers {
                    NSColor.white.withAlphaComponent(0.08).setFill()
                    NSBezierPath(roundedRect: row.rect, xRadius: 10, yRadius: 10).fill()
                    drawSymbol("person.fill", size: 20, center: CGPoint(x: 40, y: row.rect.midY), fallback: "O")
                    let peerFont = NSFont.systemFont(ofSize: 14)
                    drawText(truncated(row.peer.name, toWidth: 500, font: peerFont),
                             font: peerFont, color: .white, at: NSPoint(x: 56, y: row.rect.minY + 7))
                }
                if lanPeers.count > 3 {
                    drawText("+\(lanPeers.count - 3) more devices", font: NSFont.systemFont(ofSize: 11),
                             color: NSColor.white.withAlphaComponent(0.4), at: NSPoint(x: 28, y: 204))
                }
            }
        } else {
            // Method chooser.
            let methods = trayShareMethodRects()
            NSColor.white.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: methods.airDrop, xRadius: 10, yRadius: 10).fill()
            NSBezierPath(roundedRect: methods.lan, xRadius: 10, yRadius: 10).fill()
            NSBezierPath(roundedRect: methods.open, xRadius: 10, yRadius: 10).fill()
            drawSymbol("paperplane.fill", size: 20, center: CGPoint(x: 40, y: methods.airDrop.midY), fallback: "A")
            drawSymbol("network", size: 20, center: CGPoint(x: 40, y: methods.lan.midY), fallback: "N")
            drawSymbol("arrow.up.forward", size: 20, center: CGPoint(x: 40, y: methods.open.midY), fallback: "O")
            let methodFont = NSFont.systemFont(ofSize: 14)
            drawText("AirDrop", font: methodFont, color: .white, at: NSPoint(x: 56, y: methods.airDrop.minY + 7))
            drawText("Local Network", font: methodFont, color: .white, at: NSPoint(x: 56, y: methods.lan.minY + 7))
            drawText("Open", font: methodFont, color: .white, at: NSPoint(x: 56, y: methods.open.minY + 7))
            drawText("AirDrop: nearby Apple devices. Local Network: fellow Aura users.",
                     font: NSFont.systemFont(ofSize: 12),
                     color: NSColor.white.withAlphaComponent(0.4), at: NSPoint(x: 28, y: 204))
        }
    }

    // MARK: - Water reminder

    /// Water intake tracker, modelled on Nusa's Water Reminder:
    /// today's intake vs a daily goal (default 1.5 L), a progress
    /// bar, a notification toggle, Drink (logs one glass) and
    /// Settings (goal, glass size, reminder interval), plus an
    /// hourly bar chart for today. Today only (no day navigation
    /// — the date arrows were removed on user request). Intake +
    /// settings persist
    /// in UserDefaults (key AuraWaterData) and reset per day. The
    /// reminder itself is a wall-clock timer (started from cardPage
    /// didSet, never from draw) that fires one system notification
    /// when due; it resets on Drink and on an interval change.
    /// Notifications are skipped when run as a raw binary (no
    /// bundle identifier — calling it there crashed the app); the
    /// section still works as a tracker there, and notifications
    /// work from the packaged Aura.app.
    private struct WaterDay: Codable { var hourly: [Int: Int] = [:] }
    private struct WaterStore: Codable {
        var goalMl: Int = 1500
        var glassMl: Int = 250
        var intervalMinutes: Int = 60
        var notificationsEnabled: Bool = true
        var days: [String: WaterDay] = [:]
    }

    private static let waterDayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private static let waterDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "EEE d MMM yyyy"
        return f
    }()

    private var waterStore = WaterStore()
    private var waterStoreLoaded = false
    private var waterEndDate: Date?

    private func loadWaterStoreIfNeeded() {
        guard !waterStoreLoaded else { return }
        waterStoreLoaded = true
        if let data = UserDefaults.standard.data(forKey: "AuraWaterData"),
           let decoded = try? JSONDecoder().decode(WaterStore.self, from: data) {
            waterStore = decoded
        }
    }

    private func saveWaterStore() {
        if let data = try? JSONEncoder().encode(waterStore) {
            UserDefaults.standard.set(data, forKey: "AuraWaterData")
        }
    }

    private func waterDayKey(_ date: Date) -> String {
        Self.waterDayKeyFormatter.string(from: date)
    }

    private var waterTodayKey: String { waterDayKey(Date()) }
    private func waterTotal(forKey key: String) -> Int {
        waterStore.days[key]?.hourly.values.reduce(0, +) ?? 0
    }
    private func waterHourly(forKey key: String) -> [Int: Int] {
        waterStore.days[key]?.hourly ?? [:]
    }

    /// Starts the reminder timer on first navigation to the
    /// section (called from cardPage didSet, i.e. event handling
    /// — never from draw, so the notification authorization prompt
    /// never appears mid-draw/mid-animation).
    private func ensureWaterStarted() {
        loadWaterStoreIfNeeded()
        guard waterEndDate == nil else { return }
        waterEndDate = Date().addingTimeInterval(TimeInterval(waterStore.intervalMinutes * 60))
        scheduleWaterNotification()
    }

    private func resetWaterTimer() {
        loadWaterStoreIfNeeded()
        waterEndDate = Date().addingTimeInterval(TimeInterval(waterStore.intervalMinutes * 60))
        scheduleWaterNotification()
    }

    private var waterAuthRequested = false
    private var waterAuthGranted = false

    /// Logs one glass to today. Also resets the reminder.
    private func drinkWater() {
        loadWaterStoreIfNeeded()
        let key = waterDayKey(Date())
        let hour = Calendar.current.component(.hour, from: Date())
        var day = waterStore.days[key] ?? WaterDay()
        day.hourly[hour, default: 0] += waterStore.glassMl
        waterStore.days[key] = day
        saveWaterStore()
        resetWaterTimer()
        needsDisplay = true
    }

    private func toggleWaterNotifications() {
        loadWaterStoreIfNeeded()
        waterStore.notificationsEnabled.toggle()
        saveWaterStore()
        if waterStore.notificationsEnabled {
            let keepSchedule = waterEndDate.map { $0 > Date() } ?? false
            if !keepSchedule {
                waterEndDate = Date().addingTimeInterval(TimeInterval(waterStore.intervalMinutes * 60))
            }
            scheduleWaterNotification()
        } else if Bundle.main.bundleIdentifier != nil {
            // Guarded like schedule: the notification system cannot
            // register a raw binary (no bundle), and calling it there
            // crashed the app on toggle OFF. On a raw binary there is
            // never anything pending (schedule is guarded too), so
            // skipping the cancel is a no-op there.
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["water-reminder"])
        }
        needsDisplay = true
    }

    private func showWaterSettingsAlert() {
        loadWaterStoreIfNeeded()
        let alert = NSAlert()
        alert.messageText = "Water Settings"
        alert.informativeText = "Change the daily goal, glass size, and reminder interval."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 90))
        func row(_ label: String, value: String, y: CGFloat) -> NSTextField {
            let labelField = NSTextField(labelWithString: label)
            labelField.frame = NSRect(x: 0, y: y, width: 150, height: 22)
            accessory.addSubview(labelField)
            let field = NSTextField(frame: NSRect(x: 158, y: y, width: 80, height: 22))
            field.stringValue = value
            accessory.addSubview(field)
            return field
        }
        let goalField = row("Daily goal (ml)", value: "\(waterStore.goalMl)", y: 68)
        let glassField = row("Glass (ml)", value: "\(waterStore.glassMl)", y: 38)
        let intervalField = row("Interval (min)", value: "\(waterStore.intervalMinutes)", y: 8)
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = goalField
        isShowingModal = true
        let response = alert.runModal()
        isShowingModal = false
        resyncHoverAfterModal()
        guard response == .alertFirstButtonReturn else { return }
        let oldInterval = waterStore.intervalMinutes
        if let v = Int(goalField.stringValue.trimmingCharacters(in: .whitespaces)), v > 0 {
            waterStore.goalMl = v
        }
        if let v = Int(glassField.stringValue.trimmingCharacters(in: .whitespaces)), v > 0 {
            waterStore.glassMl = v
        }
        if let v = Int(intervalField.stringValue.trimmingCharacters(in: .whitespaces)), v > 0 {
            waterStore.intervalMinutes = v
        }
        saveWaterStore()
        if waterStore.intervalMinutes != oldInterval {
            resetWaterTimer()
        }
        needsDisplay = true
    }

    private func formatLiters(_ ml: Int) -> String {
        if ml % 1000 == 0 { return "\(ml / 1000)" }
        if ml % 100 == 0 { return String(format: "%.1f", Double(ml) / 1000.0) }
        return String(format: "%.2f", Double(ml) / 1000.0)
    }

    private func scheduleWaterNotification() {
        // Notifications need a bundled app (bundle identifier).
        // Running the raw .build/release binary has none, and the
        // notification system cannot register it — calling it there
        // crashed the app on first scroll to water. Skip silently
        // there (the section still works as a timer); notifications
        // work from the packaged Aura.app.
        guard Bundle.main.bundleIdentifier != nil else { return }
        loadWaterStoreIfNeeded()
        guard waterStore.notificationsEnabled else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["water-reminder"])
        guard let end = waterEndDate else { return }
        guard max(0, end.timeIntervalSinceNow) > 0 else { return }
        if waterAuthGranted {
            addWaterNotification(center: center)
        } else if !waterAuthRequested {
            waterAuthRequested = true
            center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
                guard let self else { return }
                self.waterAuthGranted = granted
                guard granted else { return }
                self.addWaterNotification(center: center)
            }
        }
        // If requested but not granted (denied, or the prompt is
        // still showing), do nothing — the grant completion above
        // schedules it once granted.
    }

    private func addWaterNotification(center: UNUserNotificationCenter) {
        guard let end = waterEndDate else { return }
        let remaining = max(0, end.timeIntervalSinceNow)
        guard remaining > 0 else { return }
        let content = UNMutableNotificationContent()
        content.title = "Time to drink"
        content.body = "Drink water now."
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: remaining, repeats: false)
        center.add(UNNotificationRequest(identifier: "water-reminder", content: content, trigger: trigger))
    }

    /// Hit rects (same as drawn): toggle (top-right of the left
    /// column), Drink + Settings pills (bottom row, left column).
    private func waterButtonRects() -> (toggle: NSRect, drink: NSRect, settings: NSRect) {
        let font = NSFont.systemFont(ofSize: 14, weight: .medium)
        func pillWidth(_ label: String) -> CGFloat {
            let w = (label as NSString).size(withAttributes: [.font: font]).width
            return 12 + 14 + 6 + w + 12
        }
        let toggle = NSRect(x: 284, y: 54, width: 56, height: 32)
        let drink = NSRect(x: 48, y: 132, width: pillWidth("Drink"), height: 28)
        let settings = NSRect(x: drink.maxX + 8, y: 132, width: pillWidth("Settings"), height: 28)
        return (toggle, drink, settings)
    }

    private func drawWaterHeader() {
        // Title: "Water" white + "Reminder" blue, 20pt bold, left.
        let titleFont = NSFont.boldSystemFont(ofSize: 20)
        drawText("Water", font: titleFont, color: .white, at: NSPoint(x: 48, y: 10))
        let waterW = ("Water " as NSString).size(withAttributes: [.font: titleFont]).width
        drawText("Reminder", font: titleFont, color: .systemBlue, at: NSPoint(x: 48 + waterW, y: 10))
        let titleEnd = 48 + waterW + ("Reminder" as NSString).size(withAttributes: [.font: titleFont]).width
        // Status ring: green while reminders are on, dim when off.
        let ringCenter = CGPoint(x: titleEnd + 20, y: 22)
        (waterStore.notificationsEnabled ? NSColor.systemGreen : NSColor.white.withAlphaComponent(0.3)).setStroke()
        let ringPath = NSBezierPath(ovalIn: NSRect(x: ringCenter.x - 8, y: ringCenter.y - 8, width: 16, height: 16))
        ringPath.lineWidth = 2
        ringPath.stroke()
        // Date (viewed day) + time (now, the clock), 13pt.
        let dateFont = NSFont.systemFont(ofSize: 13, weight: .medium)
        let timeFont = NSFont.systemFont(ofSize: 13, weight: .bold)
        let dateStr = Self.waterDateFormatter.string(from: Date())
        let timeStr = Self.clockFormatter.string(from: Date())
        let dateX = ringCenter.x + 20
        drawText(dateStr, font: dateFont, color: .white, at: NSPoint(x: dateX, y: 14))
        let dateW = (dateStr as NSString).size(withAttributes: [.font: dateFont]).width
        drawText(timeStr, font: timeFont, color: .white, at: NSPoint(x: dateX + dateW + 6, y: 14))
        drawWaveform(in: NSRect(x: 640 - 68, y: 14, width: 48, height: 16))
    }

    private func drawWaterChart() {
        // Right column: hourly bars for the viewed day (bars
        // x390-592, baseline y150, top y50), y labels on the left,
        // x labels 00/06/12/18 below. Scale is at least 400 ml (like
        // the reference) so bars never clip.
        let hourly = waterHourly(forKey: waterTodayKey)
        let maxHour = hourly.values.max() ?? 0
        let scale = max(400, maxHour)
        let barsLeft: CGFloat = 390
        let barsWidth: CGFloat = 202
        let baseline: CGFloat = 150
        let chartHeight: CGFloat = 100
        let slotW = barsWidth / 24
        // Y labels (right-aligned at x385) + dotted gridlines.
        let yFont = NSFont.systemFont(ofSize: 10, weight: .medium)
        let yColor = NSColor.white.withAlphaComponent(0.5)
        func yLabel(_ text: String, y: CGFloat) {
            let w = (text as NSString).size(withAttributes: [.font: yFont]).width
            drawText(text, font: yFont, color: yColor, at: NSPoint(x: 385 - w, y: y - 5))
        }
        yLabel("\(scale)", y: baseline - chartHeight)
        yLabel("\(scale / 2)", y: baseline - chartHeight / 2)
        yLabel("0 ml", y: baseline)
        for gy in [baseline - chartHeight, baseline - chartHeight / 2] {
            let grid = NSBezierPath()
            grid.move(to: NSPoint(x: barsLeft, y: gy))
            grid.line(to: NSPoint(x: barsLeft + barsWidth, y: gy))
            grid.setLineDash([1, 3], count: 2, phase: 0)
            NSColor.white.withAlphaComponent(0.15).setStroke()
            grid.stroke()
        }
        NSColor.white.withAlphaComponent(0.25).setStroke()
        let axis = NSBezierPath()
        axis.move(to: NSPoint(x: barsLeft, y: baseline))
        axis.line(to: NSPoint(x: barsLeft + barsWidth, y: baseline))
        axis.stroke()
        // Bars (vertical gradient, light base -> dark tip).
        let lightBlue = NSColor(red: 0.5, green: 0.8, blue: 1.0, alpha: 1.0)
        for (hour, ml) in hourly where ml > 0 {
            let slotX = barsLeft + CGFloat(hour) * slotW
            let barW: CGFloat = 6
            let barX = slotX + (slotW - barW) / 2
            let height = CGFloat(ml) / CGFloat(scale) * chartHeight
            let barRect = NSRect(x: barX, y: baseline - height, width: barW, height: height)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: barRect, xRadius: min(3, height / 2), yRadius: min(3, height / 2)).addClip()
            NSGradient(starting: lightBlue, ending: NSColor.systemBlue)?.draw(in: barRect, angle: 90)
            NSGraphicsContext.restoreGraphicsState()
        }
        // X labels (centered on their hour slots).
        let xFont = NSFont.systemFont(ofSize: 10, weight: .medium)
        for hour in [0, 6, 12, 18] {
            let label = String(format: "%02d", hour)
            let w = (label as NSString).size(withAttributes: [.font: xFont]).width
            let cx = barsLeft + (CGFloat(hour) + 0.5) * slotW
            drawText(label, font: xFont, color: yColor, at: NSPoint(x: cx - w / 2, y: 155))
        }
    }

    private func drawWater() {
        loadWaterStoreIfNeeded()
        drawWaterHeader()
        let total = waterTotal(forKey: waterTodayKey)
        let goal = waterStore.goalMl
        // Big number + goal (left column, x48).
        let totalFont = NSFont.boldSystemFont(ofSize: 44)
        let totalStr = formatLiters(total)
        drawText(totalStr, font: totalFont, color: .white, at: NSPoint(x: 48, y: 48))
        let totalW = (totalStr as NSString).size(withAttributes: [.font: totalFont]).width
        drawText("/ \(formatLiters(goal)) L", font: NSFont.systemFont(ofSize: 18, weight: .medium),
                 color: NSColor.white.withAlphaComponent(0.5), at: NSPoint(x: 48 + totalW + 8, y: 61))
        // Day label + percent + goal reached (y100).
        let dayLabel = "Today"
        let percent = goal > 0 ? Int((Double(total) / Double(goal) * 100).rounded()) : 0
        let labelFont = NSFont.systemFont(ofSize: 14, weight: .medium)
        let percentFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
        var lx: CGFloat = 48
        func segment(_ text: String, font: NSFont, color: NSColor) {
            drawText(text, font: font, color: color, at: NSPoint(x: lx, y: 100))
            lx += (text as NSString).size(withAttributes: [.font: font]).width
        }
        segment(dayLabel, font: labelFont, color: NSColor.white.withAlphaComponent(0.6))
        segment(" · ", font: labelFont, color: NSColor.white.withAlphaComponent(0.6))
        segment("\(percent)%", font: percentFont, color: .systemBlue)
        if percent >= 100 {
            segment(" · Goal reached", font: labelFont, color: NSColor.white.withAlphaComponent(0.6))
        }
        // Progress bar (x48-340, y118, h8): track + gradient fill.
        let trackRect = NSRect(x: 48, y: 118, width: 292, height: 8)
        NSColor.white.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: trackRect, xRadius: 4, yRadius: 4).fill()
        let fraction = goal > 0 ? min(1, Double(total) / Double(goal)) : 0
        if fraction > 0 {
            let fillW = 292 * fraction
            let fillRect = NSRect(x: 48, y: 118, width: fillW, height: 8)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: fillRect, xRadius: min(4, fillW / 2), yRadius: 4).addClip()
            NSGradient(starting: NSColor(red: 0.5, green: 0.8, blue: 1.0, alpha: 1.0),
                       ending: NSColor.systemBlue)?.draw(in: fillRect, angle: 0)
            NSGraphicsContext.restoreGraphicsState()
        }
        // Toggle (top-right of the left column).
        let buttons = waterButtonRects()
        let on = waterStore.notificationsEnabled
        (on ? NSColor.systemBlue : NSColor.white.withAlphaComponent(0.20)).setFill()
        NSBezierPath(roundedRect: buttons.toggle, xRadius: 16, yRadius: 16).fill()
        let knobX = on ? buttons.toggle.maxX - 4 - 24 : buttons.toggle.minX + 4
        let knobRect = NSRect(x: knobX, y: buttons.toggle.minY + 4, width: 24, height: 24)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knobRect).fill()
        drawSymbol("bell.fill", size: 13, center: CGPoint(x: knobRect.midX, y: knobRect.midY),
                   fallback: "●", color: on ? .systemBlue : NSColor.white.withAlphaComponent(0.5))
        // Drink (blue) + Settings (dark) pills, with icons.
        func iconPill(_ rect: NSRect, _ symbol: String, _ label: String, fill: NSColor,
                      iconColor: NSColor, textColor: NSColor) {
            fill.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14).fill()
            let font = NSFont.systemFont(ofSize: 14, weight: .medium)
            drawSymbol(symbol, size: 14, center: CGPoint(x: rect.minX + 12 + 7, y: rect.midY),
                       fallback: "●", color: iconColor)
            drawText(label, font: font, color: textColor,
                     at: NSPoint(x: rect.minX + 12 + 14 + 6, y: rect.minY + 5))
        }
        iconPill(buttons.drink, "drop.fill", "Drink", fill: .systemBlue,
                 iconColor: .white, textColor: .white)
        iconPill(buttons.settings, "slider.horizontal.3", "Settings",
                 fill: NSColor.white.withAlphaComponent(0.10),
                 iconColor: NSColor.white.withAlphaComponent(0.75),
                 textColor: NSColor.white.withAlphaComponent(0.75))
        // Chart (right column).
        drawWaterChart()
    }
}
