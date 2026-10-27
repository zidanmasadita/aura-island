import AppKit
import UserNotifications

/// Draws the island in Nusa's visual language: solid black card, white
/// type, green battery ring, live-looking waveform, album art, and
/// expanded music/lyrics pages modelled on Nusa's music card.
///
/// Layouts (flipped coordinates, y grows downward):
/// - zen (140x32): the idle face — two white eyes.
/// - compact: the closed notch, boxy with a concave bezel sweep
///   (12pt tuck) — plain music 160x32 (ring + clock + waveform),
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
///   lyric line — never clock, battery ring, or waveform — until the
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
final class IslandView: NSView {
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
            // Leaving the expanded card always returns to the music
            // page, so reopening never lands on a stale lyrics/pomodoro/todo/water/sources page.
            if state != .expanded { cardPage = .music }
            needsDisplay = true
        }
    }
    /// True when the card was last closed from the lyrics page: the
    /// inactive pill then shows lyrics, not clock/battery/waveform.
    private var lyricsMode = false
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

    /// The expanded card's current page. View-internal display state;
    /// the dots, three-finger swipe, and bubble icon switch it, nothing else reads it.
    private var cardPage: CardPage = .music {
        didSet {
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
    /// Water Reminder).
    var expandedSize: NSSize {
        switch currentPage {
        case .music: return NSSize(width: 520, height: 180)
        case .lyrics: return NSSize(width: 700, height: 180)
        case .pomodoro: return NSSize(width: 640, height: 180)
        case .todo: return NSSize(width: 640, height: 220)
        case .water: return NSSize(width: 640, height: 180)
        case .sources: return NSSize(width: 640, height: 220)
        }
    }

    /// Size of the closed (compact/split) pill: the plain music pill
    /// is 160x32 — a bit wider than the idle pill (140x32) so the
    /// ring + clock + waveform are not crammed; the lyrics-mode
    /// pill stays wider (360x32) so the lyric line still fits.
    /// A live pomodoro takes the 160x32 pill (same size as plain
    /// music, so starting/stopping it never resizes the pill).
    /// AppDelegate uses this instead of the fixed state size for
    /// compact/split.
    var closedSize: NSSize {
        if isPomodoroActive { return NSSize(width: 160, height: 32) }
        return lyricsMode ? NSSize(width: 360, height: 32) : NSSize(width: 160, height: 32)
    }

    private enum CardPage { case music, lyrics, pomodoro, todo, water, sources }

    /// Sections the dots and three-finger swipe offer: music +
    /// pomodoro + todo + water always, sources only when there is more than
    /// one session to choose from. Lyrics is NOT a section — it is a
    /// panel of the music section (via the bubble), so swipe and dots
    /// never land on it; that was the old chevron's mistake (it
    /// jumped to lyrics).
    private var availableSections: [CardPage] {
        sessionsForPicker.count > 1 ? [.music, .pomodoro, .todo, .water, .sources] : [.music, .pomodoro, .todo, .water]
    }

    /// The page actually drawn (lyrics included). Sources falls back
    /// to music when it stops being available (sessions drop to one).
    private var currentPage: CardPage {
        (cardPage == .sources && sessionsForPicker.count <= 1) ? .music : cardPage
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

    // MARK: - Realtime position

    /// Anchor for client-side position interpolation: the last sensor
    /// reading (track, reported position, wall time, playing state).
    /// The displayed position advances from this anchor by wall clock
    /// until the next reading re-anchors it.
    private var positionAnchor: (key: String, reported: Double, at: Date, playing: Bool)?
    private var lastReportedPosition: Double?

    /// Position to display right now. While playing it advances by wall
    /// clock from the anchor, so the bar moves even when the sensor's
    /// elapsed value is a frozen snapshot; while paused it sits at the
    /// anchored position. Re-anchoring happens on track change, a
    /// play/pause flip, a sensor jump (seek), or when the sensor runs
    /// ahead of the display — never when the sensor merely sits behind
    /// it, because a stale sensor must not drag the bar backwards.
    var livePosition: Double {
        guard let s = session else { return 0 }
        guard let a = positionAnchor, a.key == "\(s.title)|\(s.artist)" else { return s.position }
        if !s.isPlaying { return a.reported }
        let p = a.reported + Date().timeIntervalSince(a.at)
        if s.duration > 0 { return min(max(0, p), s.duration) }
        return max(0, p)
    }

    private func updatePositionAnchor() {
        guard let s = session else {
            positionAnchor = nil
            lastReportedPosition = nil
            return
        }
        let key = "\(s.title)|\(s.artist)"
        let reported = s.position
        // Interpolated position BEFORE this reading, from the old anchor.
        let live = livePosition
        let jumped = lastReportedPosition.map { abs(reported - $0) > 2.0 } ?? true
        let sensorAhead = (reported - live) > 2.0
        if positionAnchor == nil || positionAnchor!.key != key || positionAnchor!.playing != s.isPlaying
            || jumped || sensorAhead {
            positionAnchor = (key: key, reported: reported, at: Date(), playing: s.isPlaying)
        }
        lastReportedPosition = reported
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
        let x = bounds.width - 24
        return pages.indices.map { i in
            let y = top + CGFloat(i) * 18
            return i == active
                ? NSRect(x: x, y: y + 1, width: 6, height: 16)
                : NSRect(x: x, y: y + 6, width: 6, height: 6)
        }
    }

    /// Top of the vertical dot column, centered on the card height.
    private var dotColumnTop: CGFloat {
        (bounds.height - CGFloat(availableSections.count) * 18) / 2
    }

    private func dotIndex(at point: CGPoint) -> Int? {
        guard point.x >= bounds.width - 32 && point.x <= bounds.width - 10 else { return nil }
        let top = dotColumnTop
        guard point.y >= top && point.y <= top + CGFloat(availableSections.count) * 18 else { return nil }
        let index = Int((point.y - top) / 18)
        return (index >= 0 && index < availableSections.count) ? index : nil
    }

    var onHoverChanged: ((Bool) -> Void)?
    var onClicked: (() -> Void)?
    var onSessionPicked: ((String) -> Void)?
    var onUnpin: (() -> Void)?
    var onPlayPause: (() -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    /// Fired when the expanded card's page changes, so the window can
    /// resize to the page (music 520, pomodoro/todo/sources 640, lyrics 700 wide).
    /// AppDelegate ignores it unless expanded.
    var onExpandedSizeChanged: ((NSSize) -> Void)?

    override var isFlipped: Bool { true }

    private var trackingArea: NSTrackingArea?
    private var waveTimer: Timer?
    private var wavePhase: Double = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
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
            options: [.mouseEnteredAndExited, .activeAlways],
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
        onHoverChanged?(false)
    }

    override func mouseDown(with event: NSEvent) {
        guard state == .expanded else {
            onClicked?()
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
            if musicBubbleRect.contains(point) {
                cardPage = .lyrics
                needsDisplay = true
                return
            }
            if let hit = controlHit(at: point, centers: [208, 260, 312], yMin: 130, yMax: 150) {
                performControl(hit)
                return
            }
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
                showAddTaskAlert()
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
        }
        // Any other click on the expanded card collapses it. Without this
        // fallthrough there was no way to close the card by clicking: only
        // the controls, picker rows, pomodoro buttons, and todo rows responded, the
        // rest did nothing.
        onClicked?()
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
    /// pomodoro -> todo -> water -> sources when available -> back to music),
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
        let path = notchPath(
            rect: rect,
            tuck: 12,
            // Full cards keep the 28pt bottom rounding from the Nusa
            // reference; short pills (compact, music strip) are fully
            // rounded like the closed pill.
            bottomRadius: state == .expanded && rect.height > 100 ? 28 : rect.height / 2
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
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.98).cgColor)
        ctx.fillPath()
        // Pill tint: when album artwork is present, the background is a
        // gradient from the cover's dominant color (darkened so white
        // text stays readable) down to black. Without artwork, plain black.
        if state != .zen, let topColor = gradientTopColor() {
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            let colors = [topColor.cgColor, NSColor.black.cgColor] as CFArray
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                ctx.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: 0, y: rect.minY),
                    end: CGPoint(x: 0, y: rect.maxY),
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

        switch state {
        case .zen:
            drawEyes()
        case .compact, .split:
            drawClosed()
        case .expanded:
            drawExpanded()
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

    /// Two white eyes, the idle face from Nusa's "Istirahat" state.
    private func drawEyes() {
        NSColor.white.setFill()
        for x in [51.0, 78.0] {
            let eye = NSBezierPath(ovalIn: NSRect(x: x, y: 9, width: 11, height: 14))
            eye.fill()
        }
    }

    /// Battery ring: dim track + green arc for the charge level.
    private func drawBatteryRing(center: CGPoint, radius: CGFloat) {
        guard let percent = batteryPercent else { return }
        let frame = NSRect(x: center.x - radius, y: center.y - radius,
                           width: radius * 2, height: radius * 2)
        let track = NSBezierPath(ovalIn: frame)
        NSColor.white.withAlphaComponent(0.25).setStroke()
        track.lineWidth = 2.5
        track.stroke()
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius,
                      startAngle: 90, endAngle: 90 - 360 * CGFloat(percent),
                      clockwise: true)
        NSColor.systemGreen.setStroke()
        arc.lineWidth = 2.5
        arc.stroke()
    }

    private var cachedDominantKey: String?
    private var cachedDominantColor: NSColor?

    /// Darkened dominant cover color for the background gradient, or nil
    /// when there is no artwork (plain black pill). Cached per track so
    /// the 10x/second waveform redraw never re-samples the image.
    private func gradientTopColor() -> NSColor? {
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
        // Lyrics mode (card was closed from the lyrics page): note icon
        // + current lyric line, the line centered on the pill — never
        // clock, battery ring, or waveform. Without a synced line, the
        // song title stands in.
        if lyricsMode, let session {
            drawSymbol("music.note", size: 20, center: CGPoint(x: 28, y: midY), fallback: "♪")
            let line = lyricCurrent ?? session.title
            let font = NSFont.systemFont(ofSize: 13, weight: .medium)
            drawCentered(truncated(line, toWidth: 236, font: font),
                         font: font, color: .white, y: midY - 8)
            return
        }
        // The plain music pill is 160 wide: ring + clock + waveform,
        // tightened to fit — smaller ring left, clock centered,
        // narrower waveform at the right edge. All three stay
        // inside the 12pt tuck (sides at 12 and width-12).
        // Padding: the ring sits 10pt inside the left edge and the
        // waveform ends 10pt before the right edge, so the contents
        // never hug the pill's border (at any width, including
        // mid-collapse-animation frames).
        drawBatteryRing(center: CGPoint(x: 30, y: midY), radius: 8)
        drawCentered(Self.clockFormatter.string(from: Date()),
                     font: NSFont.systemFont(ofSize: 15, weight: .semibold),
                     color: .white, y: midY - 9)
        let waveHeight: CGFloat = bounds.height <= 40 ? 14 : 20
        drawWaveform(in: NSRect(x: bounds.width - 50, y: midY - waveHeight / 2, width: 28, height: waveHeight))
    }

    // MARK: - Expanded card

    private func drawExpanded() {
        // Pomodoro, todo, and water work without music (their own
        // timer, list, and reminder), so they bypass the no-media
        // guard every other page sits behind.
        if currentPage == .pomodoro {
            drawPomodoro()
        } else if currentPage == .todo {
            drawTodo()
        } else if currentPage == .water {
            drawWater()
        } else {
            guard let session else {
                drawCentered("Tidak ada media yang diputar",
                             font: NSFont.systemFont(ofSize: 13),
                             color: NSColor.white.withAlphaComponent(0.7),
                             y: bounds.height / 2 - 8)
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
            case .pomodoro, .todo, .water:
                break // handled above
            }
        }
        drawPageDots()
    }

    /// Header for the card pages, like Nusa's music card: green dot
    /// + date/time, waveform top-right. Used on the music, pomodoro, and sources
    /// pages; the lyrics page has no header at all — no
    /// clock, no waveform. No battery ring here — the reference card
    /// has none; the ring lives in the closed state.
    private func drawCardHeader(width: CGFloat = 640) {
        let dateStr = Self.headerDateFormatter.string(from: Date())
        let dateFont = NSFont.systemFont(ofSize: 13, weight: .medium)
        let dateWidth = (dateStr as NSString).size(withAttributes: [.font: dateFont]).width
        let groupWidth = dateWidth + 16
        let groupX = (width - groupWidth) / 2
        NSColor.systemGreen.setFill()
        NSBezierPath(ovalIn: NSRect(x: groupX, y: 17, width: 8, height: 8)).fill()
        drawText(dateStr, font: dateFont, color: .white, at: NSPoint(x: groupX + 16, y: 14))
        drawWaveform(in: NSRect(x: width - 68, y: 14, width: 48, height: 16))
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
    private func drawMusicCard(_ session: DisplaySession, lyricsOpen: Bool = false) {
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
        drawSymbol("ellipsis.bubble.fill", size: 20, center: CGPoint(x: 56, y: 140), fallback: "···")
        let controls: [CGFloat] = lyricsOpen ? [118, 170, 222] : [208, 260, 312]
        drawSymbol("backward.fill", size: 20, center: CGPoint(x: controls[0], y: 140), fallback: "‹")
        drawSymbol(session.isPlaying ? "pause.fill" : "play.fill", size: 20,
                   center: CGPoint(x: controls[1], y: 140), fallback: session.isPlaying ? "❚❚" : "▶")
        drawSymbol("forward.fill", size: 20, center: CGPoint(x: controls[2], y: 140), fallback: "›")
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
                    // Scale about the line block's own center, so the
                    // block grows/shrinks in place while it travels;
                    // wrapped lines were fixed at roll start, so the
                    // scale never reflows text.
                    ctx.saveGState()
                    ctx.translateBy(x: x + width / 2, y: centerY)
                    ctx.scaleBy(x: scale, y: scale)
                    ctx.translateBy(x: -(x + width / 2), y: -centerY)
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
            drawText("Lirik tidak tersedia",
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
        let pos = livePosition
        drawText(formatTime(pos), font: font, color: .white,
                 at: NSPoint(x: elapsedX, y: y))
        guard session.duration > 0 else { return }
        drawRightAligned("-\(formatTime(session.duration - pos))",
                         font: font, color: .white, rightX: rightX, y: y)
        let bg = NSBezierPath(roundedRect: NSRect(x: barX, y: y + 6, width: barWidth, height: barHeight),
                              xRadius: barHeight / 2, yRadius: barHeight / 2)
        NSColor.white.withAlphaComponent(0.25).setFill()
        bg.fill()
        let filled = min(1.0, pos / session.duration)
        let fg = NSBezierPath(roundedRect: NSRect(x: barX, y: y + 6, width: barWidth * CGFloat(filled), height: barHeight),
                              xRadius: barHeight / 2, yRadius: barHeight / 2)
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
    private func drawSymbol(_ name: String, size: CGFloat, center: CGPoint, fallback: String, color: NSColor = .white) {
        let key = "\(name)-\(Int(size))"
        let rect = NSRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
        if color == .white, let cached = Self.symbolCache[key] {
            cached.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
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
        img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
    }

    private func drawCenteredText(_ text: String, font: NSFont, color: NSColor, center: CGPoint) {
        let size = (text as NSString).size(withAttributes: [.font: font])
        drawText(text, font: font, color: color,
                 at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
    }

    private func drawPicker(startY: CGFloat) {
        let header = pinnedId == nil
            ? "Sumber: Auto (ikuti yang aktif)"
            : "Sumber: Pin aktif — klik sumber untuk lepas"
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

    /// The "+ Tambah tugas" pill (left column, y120-148). Measured
    /// from its text so hit == drawn, like the pomodoro pills.
    private func todoAddPillRect() -> NSRect {
        let font = NSFont.systemFont(ofSize: 14)
        let plusW = ("+" as NSString).size(withAttributes: [.font: font]).width
        let textW = ("Tambah tugas" as NSString).size(withAttributes: [.font: font]).width
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
            drawText("selesai", font: NSFont.systemFont(ofSize: 12), color: NSColor.white.withAlphaComponent(0.6), at: NSPoint(x: 28, y: 88))
        } else {
            drawText("Belum ada tugas", font: NSFont.systemFont(ofSize: 14), color: NSColor.white.withAlphaComponent(0.6), at: NSPoint(x: 28, y: 60))
        }
        let addRect = todoAddPillRect()
        NSColor.white.withAlphaComponent(0.10).setFill()
        NSBezierPath(roundedRect: addRect, xRadius: 14, yRadius: 14).fill()
        let addFont = NSFont.systemFont(ofSize: 14)
        let plusW = ("+" as NSString).size(withAttributes: [.font: addFont]).width
        drawText("+", font: addFont, color: .white, at: NSPoint(x: addRect.minX + 12, y: addRect.minY + 5))
        drawText("Tambah tugas", font: addFont, color: .white, at: NSPoint(x: addRect.minX + 12 + plusW + 6, y: addRect.minY + 5))
        // Overflow count under the add pill.
        let rows = todoVisibleRows()
        if total > rows.count {
            drawText("＋\(total - rows.count) lainnya", font: NSFont.systemFont(ofSize: 11),
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

    /// Add a task via a modal alert (not an in-card text field: the
    /// in-card field fought the borderless notch window's focus
    /// system and froze the pill when pressed. The alert runs in
    /// its own key window, so typing always works).
    private func showAddTaskAlert() {
        let alert = NSAlert()
        alert.messageText = "Tugas baru"
        alert.informativeText = "Tulis tugas yang ingin ditambahkan."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "Tugas baru..."
        alert.accessoryView = field
        alert.addButton(withTitle: "Tambah")
        alert.addButton(withTitle: "Batal")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        loadTodoTasksIfNeeded()
        todoTasks.append(TodoTask(id: UUID(), text: text, done: false, createdAt: Date()))
        saveTodoTasks()
        needsDisplay = true
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
        alert.messageText = "Pengaturan Minum"
        alert.informativeText = "Ubah goal harian, ukuran gelas, dan interval pengingat."
        alert.addButton(withTitle: "Simpan")
        alert.addButton(withTitle: "Batal")
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
        let goalField = row("Goal harian (ml)", value: "\(waterStore.goalMl)", y: 68)
        let glassField = row("Gelas (ml)", value: "\(waterStore.glassMl)", y: 38)
        let intervalField = row("Interval (menit)", value: "\(waterStore.intervalMinutes)", y: 8)
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = goalField
        guard alert.runModal() == .alertFirstButtonReturn else { return }
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
        content.title = "Waktunya minum"
        content.body = "Minum air sekarang."
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
