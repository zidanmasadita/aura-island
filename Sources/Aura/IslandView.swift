import AppKit

/// Draws the island in Nusa's visual language: solid black card, white
/// type, green battery ring, live-looking waveform, album art, and
/// expanded music/lyrics pages modelled on Nusa's music card.
///
/// Layouts (flipped coordinates, y grows downward):
/// - zen (140x32): the idle face — two white eyes.
/// - compact: the closed notch, boxy with a concave bezel sweep
///   (12pt tuck) — plain music 140x32 (same as idle, ring + clock +
///   waveform), lyrics mode 360x32 (note icon + lyric line).
/// - expanded, wide and short (never tall): music is the dense Nusa
///   music card (640x180: header, artwork, title/artist, progress,
///   controls, chevron, dots); opening lyrics only widens the card
///   (700x180, same height) and compresses the music part, putting
///   the lyrics panel on the right, like Nusa; sources is the picker
///   on the 640x220 footprint. The bubble toggles
///   music/lyrics, the chevron advances a page, and the dots jump
///   pages.
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
            // page, so reopening never lands on a stale lyrics/sources page.
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
    var lyricCurrent: String? {
        didSet {
            // Spotify-style rise: when the sung line changes while the
            // lyrics page is visible, the stack rises smoothly into
            // place instead of jumping. Only on a real change
            // (refreshLyricLine sets all three every tick, usually to
            // the same values) and only when the page is visible —
            // otherwise the offset just stays at rest.
            if oldValue != lyricCurrent, state == .expanded, currentPage == .lyrics {
                startLyricSlide()
            }
        }
    }
    var lyricNext: String?

    // MARK: - Lyrics rise animation (Spotify-style)

    /// Extra Y offset for the lyrics block while it rises into place.
    /// 0 at rest; set to about one line height when the sung line
    /// changes, then eased back to 0 at 60fps. Only the text block
    /// moves — the divider stays fixed.
    private var lyricSlideOffset: CGFloat = 0
    private var lyricSlideFrom: CGFloat = 0
    private var lyricSlideStart: Date = Date()
    private var lyricSlideTimer: Timer?
    private let lyricSlideDuration: TimeInterval = 0.45
    private let lyricSlideDistance: CGFloat = 26

    private func startLyricSlide() {
        // Restarting mid-flight keeps the current offset instead of
        // jumping back to full distance (fast lyrics would stutter).
        lyricSlideFrom = lyricSlideTimer == nil ? lyricSlideDistance : lyricSlideOffset
        lyricSlideStart = Date()
        lyricSlideTimer?.invalidate()
        lyricSlideTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.stepLyricSlide(timer: timer)
        }
    }

    private func stepLyricSlide(timer: Timer) {
        let p = min(1.0, Date().timeIntervalSince(lyricSlideStart) / lyricSlideDuration)
        let e = 1.0 - pow(1.0 - p, 3.0) // easeOutCubic, like the window animator
        lyricSlideOffset = lyricSlideFrom * (1.0 - e)
        if p >= 1.0 {
            lyricSlideOffset = 0
            timer.invalidate()
            lyricSlideTimer = nil
        }
        needsDisplay = true
    }
    var sessionsForPicker: [DisplaySession] = []
    var pinnedId: String?
    var batteryPercent: Double?
    var batteryCharging: Bool = false

    /// The expanded card's current page. View-internal display state;
    /// the chevron, dots, and bubble icon switch it, nothing else reads it.
    private var cardPage: CardPage = .music {
        didSet {
            if state == .expanded { onExpandedSizeChanged?(expandedSize) }
            needsDisplay = true
        }
    }

    /// Window size for the expanded card, per page. The music card is
    /// the dense 640x180 card (shorter but packed: header, 56px cover,
    /// progress, controls, dots); lyrics only widens it to 700x180 —
    /// the height does not change, so switching pages never moves
    /// the music part vertically; sources stays 640x220.
    var expandedSize: NSSize {
        switch currentPage {
        case .music: return NSSize(width: 640, height: 180)
        case .lyrics: return NSSize(width: 700, height: 180)
        case .sources: return NSSize(width: 640, height: 220)
        }
    }

    /// Size of the closed (compact/split) pill: the plain music pill
    /// is 160x32 — a bit wider than the idle pill (140x32) so the
    /// ring + clock + waveform are not crammed; the lyrics-mode
    /// pill stays wider (360x32) so the lyric line still fits.
    /// AppDelegate uses this instead of the fixed state size for
    /// compact/split.
    var closedSize: NSSize {
        lyricsMode ? NSSize(width: 360, height: 32) : NSSize(width: 160, height: 32)
    }

    private enum CardPage { case music, lyrics, sources }

    /// Pages the dots offer: music + lyrics always, sources only when
    /// there is more than one session to choose from.
    private var availablePages: [CardPage] {
        sessionsForPicker.count > 1 ? [.music, .lyrics, .sources] : [.music, .lyrics]
    }

    private var currentPage: CardPage {
        availablePages.contains(cardPage) ? cardPage : .music
    }

    /// Rects for the interactive elements of the expanded card.
    /// The bubble toggles music/lyrics; the chevron advances a page.
    /// The bubble sits further right than the card edge so it does not
    /// hug the corner. Both pages share the dense row (controls at
    /// y140, bubble y126); the chevron sits at the card's middle
    /// (y76) — only the music page has one.
    private var musicBubbleRect: NSRect { NSRect(x: 42, y: 126, width: 28, height: 28) }
    private var chevronRect: NSRect { NSRect(x: 590, y: 76, width: 28, height: 28) }

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

    /// Visual rects of the page dots (active = wide dash, rest = dots).
    private func dotRects() -> [NSRect] {
        let pages = availablePages
        let active = pages.firstIndex(of: currentPage) ?? 0
        var total: CGFloat = 0
        for i in pages.indices { total += (i == active ? 16 : 6) + 12 }
        total -= 12
        var x = (bounds.width - total) / 2
        var rects: [NSRect] = []
        for i in pages.indices {
            let w: CGFloat = i == active ? 16 : 6
            rects.append(NSRect(x: x, y: dotsY, width: w, height: 6))
            x += w + 12
        }
        return rects
    }

    /// Dots sit above the bottom edge and follow the window height:
    /// 20pt on the 180-tall music/lyrics cards (tighter bottom
    /// margin), 36pt on the 220-tall sources page.
    private var dotsY: CGFloat { bounds.height - (currentPage == .sources ? 36 : 20) }

    private func dotIndex(at point: CGPoint) -> Int? {
        guard point.y >= dotsY - 6 && point.y <= dotsY + 12 else { return nil }
        for (i, rect) in dotRects().enumerated() {
            if point.x >= rect.minX - 3 && point.x <= rect.maxX + 3 { return i }
        }
        return nil
    }

    var onHoverChanged: ((Bool) -> Void)?
    var onClicked: (() -> Void)?
    var onSessionPicked: ((String) -> Void)?
    var onUnpin: (() -> Void)?
    var onPlayPause: (() -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    /// Fired when the expanded card's page changes, so the window can
    /// resize to the page (music/sources 640, lyrics 700 wide).
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
            let pages = availablePages
            if index < pages.count {
                cardPage = pages[index]
                needsDisplay = true
            }
            return
        }
        switch currentPage {
        case .music:
            // Speech bubble opens lyrics (the card extends horizontally).
            if musicBubbleRect.contains(point) {
                cardPage = .lyrics
                needsDisplay = true
                return
            }
            if chevronRect.contains(point) {
                advancePage()
                return
            }
            if let hit = controlHit(at: point, centers: [268, 320, 372], yMin: 130, yMax: 150) {
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
            // No chevron here: the widened lyrics panel occupies the
            // music card's right edge where the chevron lives.
            // Controls are the music card's own row, recentered on the
            // compressed music part (see drawMusicCard).
            if let hit = controlHit(at: point, centers: [118, 170, 222], yMin: 130, yMax: 150) {
                performControl(hit)
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
        // the controls and picker rows responded, the rest did nothing.
        onClicked?()
    }

    private func performControl(_ hit: Int) {
        switch hit {
        case 0: onPrevious?()
        case 1: onPlayPause?()
        default: onNext?()
        }
    }

    /// Chevron: advance one page in dot order (music -> lyrics ->
    /// sources when available -> back to music).
    private func advancePage() {
        let pages = availablePages
        guard let i = pages.firstIndex(of: currentPage) else { return }
        cardPage = pages[(i + 1) % pages.count]
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
        // out for the full width (cover, header waveform, chevron)
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
        guard let session else {
            drawCentered("Tidak ada media yang diputar",
                         font: NSFont.systemFont(ofSize: 13),
                         color: NSColor.white.withAlphaComponent(0.7),
                         y: bounds.height / 2 - 8)
            return
        }
        switch currentPage {
        case .music:
            drawMusicCard(session)
            drawPageDots()
        case .lyrics:
            // 700x180: same height as the music card, only wider.
            // The music part compresses (title and progress narrower,
            // see drawMusicCard) and the lyrics panel takes the right
            // portion inside the same card, like Nusa. No header here:
            // the lyrics page shows no clock or waveform.
            drawMusicCard(session, lyricsOpen: true)
            drawLyricsPanel()
            drawPageDots()
        case .sources:
            drawCardHeader()
            drawPicker(startY: 64)
            drawPageDots()
        }
    }

    /// Header for the card pages, like Nusa's music card: green dot
    /// + date/time, waveform top-right. Used on the music and sources
    /// pages (640 wide); the lyrics page has no header at all — no
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
    /// big title/artist, full-width progress, controls, and a chevron
    /// that advances a page. The dense 640x180 card — 56px artwork,
    /// tighter gaps — shorter but packed, shared by the music page
    /// and the lyrics page's music part (same vertical positions, so
    /// switching pages never moves it). The lyrics page reuses it
    /// with lyricsOpen: like Nusa, opening lyrics compresses the
    /// music part into 340px (title/artist 212, progress bar 172,
    /// controls centered on 170) and the lyrics panel takes the right
    /// portion of the slightly wider 700-wide card — and the header
    /// (clock + waveform) is omitted there. The chevron
    /// (which would sit inside the panel) is omitted too.
    private func drawMusicCard(_ session: DisplaySession, lyricsOpen: Bool = false) {
        // No header on the lyrics page: no clock, no waveform.
        if !lyricsOpen {
            drawCardHeader(width: 640)
        }
        // Dense vertical layout, shared by both pages: cover 36,
        // progress 104, controls 140. Only the horizontal compression
        // differs (lyrics page: 340-wide music part).
        drawArtwork(artworkThumb(for: session), in: NSRect(x: 28, y: 36, width: 56, height: 56), cornerRadius: 12)
        let textWidth: CGFloat = lyricsOpen ? 212 : 460
        let titleFont = NSFont.boldSystemFont(ofSize: 25)
        drawText(truncated(session.title, toWidth: textWidth, font: titleFont),
                 font: titleFont, color: .white, at: NSPoint(x: 108, y: 36))
        let artistFont = NSFont.systemFont(ofSize: 16)
        drawText(truncated(session.artist, toWidth: textWidth, font: artistFont),
                 font: artistFont, color: NSColor.white.withAlphaComponent(0.65),
                 at: NSPoint(x: 108, y: 68))
        if lyricsOpen {
            drawProgress(session, elapsedX: 28, barX: 88, barWidth: 172, rightX: 320,
                         y: 104, font: NSFont.systemFont(ofSize: 12), barHeight: 4)
        } else {
            drawProgress(session, elapsedX: 28, barX: 88, barWidth: 452, rightX: 612,
                         y: 104, font: NSFont.systemFont(ofSize: 12), barHeight: 4)
        }
        drawSymbol("ellipsis.bubble.fill", size: 20, center: CGPoint(x: 56, y: 140), fallback: "···")
        let controls: [CGFloat] = lyricsOpen ? [118, 170, 222] : [268, 320, 372]
        drawSymbol("backward.fill", size: 20, center: CGPoint(x: controls[0], y: 140), fallback: "‹")
        drawSymbol(session.isPlaying ? "pause.fill" : "play.fill", size: 20,
                   center: CGPoint(x: controls[1], y: 140), fallback: session.isPlaying ? "❚❚" : "▶")
        drawSymbol("forward.fill", size: 20, center: CGPoint(x: controls[2], y: 140), fallback: "›")
        if !lyricsOpen {
            drawSymbol("chevron.right", size: 20, center: CGPoint(x: 604, y: 90), fallback: "›")
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
    /// column on the right of the compressed music part (x 352..688,
    /// 336 wide), inside the slightly extended 700-wide card. The
    /// divider sits beside the song title: the title ends at most at
    /// 320 (108 + 212), and the divider is at 340.
    /// A long lyric line wraps onto a second line instead of being
    /// cut off with "…", so no lyric is ever truncated mid-line.
    private func drawLyricsPanel() {
        // Divider between the compressed music part (left) and the panel.
        // 28..158: it stops 2pt above the dots (y160) so it never
        // crosses them.
        NSColor.white.withAlphaComponent(0.12).setFill()
        NSRect(x: 340, y: 28, width: 1, height: 130).fill()
        // Lyrics column: dim previous, bold current, dim next,
        // stacked as a block centered in the panel (28..158).
        let x: CGFloat = 352
        let width: CGFloat = 336
        struct Entry { let lines: [String]; let font: NSFont; let color: NSColor }
        var entries: [Entry] = []
        if let prev = lyricPrev {
            let font = NSFont.systemFont(ofSize: 16)
            entries.append(Entry(lines: wrappedLines(prev, font: font, width: width, maxLines: 2),
                                 font: font, color: NSColor.white.withAlphaComponent(0.35)))
        }
        if let current = lyricCurrent {
            let font = NSFont.boldSystemFont(ofSize: 21)
            entries.append(Entry(lines: wrappedLines(current, font: font, width: width, maxLines: 2),
                                 font: font, color: .white))
        }
        if let next = lyricNext {
            let font = NSFont.systemFont(ofSize: 16)
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
        func lineHeight(_ font: NSFont) -> CGFloat {
            ceil(font.ascender - font.descender + font.leading)
        }
        let textHeight = entries.reduce(0) { $0 + CGFloat($1.lines.count) * lineHeight($1.font) }
        let gapCount = max(0, entries.count - 1)
        let gap: CGFloat = gapCount > 0 ? min(10, max(0, (130 - textHeight) / CGFloat(gapCount))) : 0
        // The block rises into place while a slide runs (see
        // lyricSlideOffset): it starts one line low and eases up to
        // this centered position, Spotify-style.
        var y = 28 + (130 - (textHeight + gap * CGFloat(gapCount))) / 2 + lyricSlideOffset
        for entry in entries {
            for line in entry.lines {
                drawText(line, font: entry.font, color: entry.color, at: NSPoint(x: x, y: y))
                y += lineHeight(entry.font)
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
            if availablePages[i] == currentPage {
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
    private func drawSymbol(_ name: String, size: CGFloat, center: CGPoint, fallback: String) {
        let key = "\(name)-\(Int(size))"
        let rect = NSRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
        if let cached = Self.symbolCache[key] {
            cached.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
            return
        }
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
            drawCenteredText(fallback, font: NSFont.systemFont(ofSize: size), color: .white, center: center)
            return
        }
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        base.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero,
                  operation: .sourceOver, fraction: 1.0)
        NSColor.white.set()
        // Tint: source-in keeps the SOURCE color (white) masked by the
        // symbol's alpha. destination-in would keep the DESTINATION
        // color — the symbol rasterizes black — which is why the
        // buttons rendered black-on-black and looked dim instead of
        // white. (The cached image is per-launch, so a fresh build
        // picks the white version up.)
        NSRect(x: 0, y: 0, width: size, height: size).fill(using: .sourceIn)
        img.unlockFocus()
        Self.symbolCache[key] = img
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
                 at: NSPoint(x: 20, y: startY))
        var y = startY + 24
        let rowFont = NSFont.systemFont(ofSize: 12)
        for item in sessionsForPicker.prefix(4) {
            let mark = item.id == pinnedId ? "● " : "○ "
            let label = "\(mark)\(item.label) — \(item.title)"
            drawText(truncated(label, toWidth: 480, font: rowFont),
                     font: rowFont, color: .white, at: NSPoint(x: 20, y: y))
            y += 22
        }
    }
}
