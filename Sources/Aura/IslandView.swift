import AppKit

/// Draws the island in Nusa's visual language: solid black card, white
/// type, green battery ring, live-looking waveform, album art, and
/// expanded music/lyrics pages modelled on Nusa's music card.
///
/// Layouts (flipped coordinates, y grows downward):
/// - zen (140x32): the idle face — two white eyes.
/// - compact: the closed notch — 320x32, both for plain playback
///   (battery ring, clock, waveform, tight) and in lyrics mode
///   (note icon + lyric line).
/// - expanded, wide and short (never tall): music is the normal Nusa
///   music card (640x220: header, artwork, title/artist, progress,
///   controls, chevron, dots); opening lyrics keeps the same 640x220
///   card but compresses the music part and puts the lyrics panel on
///   the right, like Nusa; sources is the picker on the music card's
///   footprint (640x220). The bubble toggles music/lyrics, the
///   chevron advances a page, and the dots jump pages.
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
    var lyricCurrent: String?
    var lyricNext: String?
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

    /// Window size for the expanded card, per page. All pages share
    /// the 640x220 card — like Nusa, opening lyrics does NOT widen
    /// the card; the music part compresses and the lyrics panel takes
    /// the right portion inside the same width.
    var expandedSize: NSSize {
        switch currentPage {
        case .music: return NSSize(width: 640, height: 220)
        case .lyrics: return NSSize(width: 640, height: 220)
        case .sources: return NSSize(width: 640, height: 220)
        }
    }

    /// Size of the closed (compact/split) pill: half height (320x32),
    /// both for plain playback and in lyrics mode (the note icon +
    /// lyric line fit in 32). AppDelegate uses this instead of the
    /// fixed state size for compact/split.
    var closedSize: NSSize {
        NSSize(width: 320, height: 32)
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
    /// hug the corner.
    private var musicBubbleRect: NSRect { NSRect(x: 42, y: 150, width: 28, height: 28) }
    private var chevronRect: NSRect { NSRect(x: 590, y: 96, width: 28, height: 28) }

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

    /// Dots sit 36pt above the bottom edge, so they follow the window
    /// height (all card pages are 220 tall now).
    private var dotsY: CGFloat { bounds.height - 36 }

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
    /// resize to the page. All pages share the 640 card, so this only
    /// fires on a genuine size change; AppDelegate ignores it unless expanded.
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
            if let hit = controlHit(at: point, centers: [268, 320, 372], yMin: 154, yMax: 174) {
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
            if let hit = controlHit(at: point, centers: [118, 170, 222], yMin: 154, yMax: 174) {
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
        let path = notchPath(
            rect: rect,
            tuck: 12,
            // Full cards keep the 28pt bottom rounding from the Nusa
            // reference; short pills (compact, music strip) are fully
            // rounded like the closed pill.
            bottomRadius: state == .expanded && rect.height > 100 ? 28 : rect.height / 2
        )
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
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
        drawBatteryRing(center: CGPoint(x: 28, y: midY), radius: 10)
        drawCentered(
            Self.clockFormatter.string(from: Date()),
            font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            color: .white, y: midY - 9)
        let waveHeight: CGFloat = bounds.height <= 40 ? 14 : 20
        drawWaveform(in: NSRect(x: 250, y: midY - waveHeight / 2, width: 42, height: waveHeight))
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
            // Same 640-wide card — opening lyrics does not widen it.
            // The music part compresses (title and progress narrower,
            // see drawMusicCard) and the lyrics panel takes the right
            // portion inside the same card, like Nusa.
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
    /// + date/time, waveform top-right. `width` is the region the
    /// header belongs to: 640 on the music/sources pages, 340 on the
    /// lyrics page (where the music part compresses for the panel). No
    /// battery ring here — the reference card has none; the ring
    /// lives in the closed state.
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

    /// Music card (640x220), modelled on Nusa's music card: header,
    /// artwork, big title/artist, full-width progress, controls, and
    /// a chevron that advances a page. Compressed vertically — smaller
    /// artwork, tighter gaps — so the card does not reach far down.
    /// This is the normal active card; the lyrics page reuses it on
    /// its left side, except when lyricsOpen: like Nusa, opening
    /// lyrics compresses the music part into 340px (title/artist 212,
    /// progress bar 172, header centered on 340, controls centered on
    /// 170) and the lyrics panel takes the right portion inside the
    /// same 640-wide card — the card does not grow. The chevron
    /// (which would sit inside the panel) is omitted.
    private func drawMusicCard(_ session: DisplaySession, lyricsOpen: Bool = false) {
        drawCardHeader(width: lyricsOpen ? 340 : 640)
        drawArtwork(artworkThumb(for: session), in: NSRect(x: 28, y: 44, width: 64, height: 64), cornerRadius: 12)
        let textWidth: CGFloat = lyricsOpen ? 212 : 460
        let titleFont = NSFont.boldSystemFont(ofSize: 25)
        drawText(truncated(session.title, toWidth: textWidth, font: titleFont),
                 font: titleFont, color: .white, at: NSPoint(x: 108, y: 44))
        let artistFont = NSFont.systemFont(ofSize: 16)
        drawText(truncated(session.artist, toWidth: textWidth, font: artistFont),
                 font: artistFont, color: NSColor.white.withAlphaComponent(0.65),
                 at: NSPoint(x: 108, y: 80))
        if lyricsOpen {
            drawProgress(session, elapsedX: 28, barX: 88, barWidth: 172, rightX: 320,
                         y: 126, font: NSFont.systemFont(ofSize: 12), barHeight: 4)
        } else {
            drawProgress(session, elapsedX: 28, barX: 88, barWidth: 452, rightX: 612,
                         y: 126, font: NSFont.systemFont(ofSize: 12), barHeight: 4)
        }
        drawSymbol("ellipsis.bubble.fill", size: 20, center: CGPoint(x: 56, y: 164), fallback: "···")
        let controls = lyricsOpen ? [118, 170, 222] : [268, 320, 372]
        drawSymbol("backward.fill", size: 20, center: CGPoint(x: controls[0], y: 164), fallback: "‹")
        drawSymbol(session.isPlaying ? "pause.fill" : "play.fill", size: 20,
                   center: CGPoint(x: controls[1], y: 164), fallback: session.isPlaying ? "❚❚" : "▶")
        drawSymbol("forward.fill", size: 20, center: CGPoint(x: controls[2], y: 164), fallback: "›")
        if !lyricsOpen {
            drawSymbol("chevron.right", size: 20, center: CGPoint(x: 604, y: 110), fallback: "›")
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
    /// column on the right of the compressed music part (x 352..628,
    /// 276 wide), inside the same 640-wide card. The divider sits
    /// beside the song title: the title ends at most at 320
    /// (108 + 212), and the divider is at 340.
    private func drawLyricsPanel() {
        // Divider between the compressed music part (left) and the panel.
        NSColor.white.withAlphaComponent(0.12).setFill()
        NSRect(x: 340, y: 44, width: 1, height: 132).fill()
        // Lyrics column: dim previous, bold current, dim next,
        // vertically centered in the panel.
        let x: CGFloat = 352
        let width: CGFloat = 276
        if let prev = lyricPrev {
            let font = NSFont.systemFont(ofSize: 16)
            drawText(truncated(prev, toWidth: width, font: font),
                     font: font, color: NSColor.white.withAlphaComponent(0.35),
                     at: NSPoint(x: x, y: 67))
        }
        if let current = lyricCurrent {
            let font = NSFont.boldSystemFont(ofSize: 21)
            drawText(truncated(current, toWidth: width, font: font),
                     font: font, color: .white, at: NSPoint(x: x, y: 97))
        } else {
            drawText("Lirik tidak tersedia",
                     font: NSFont.systemFont(ofSize: 14),
                     color: NSColor.white.withAlphaComponent(0.4),
                     at: NSPoint(x: x, y: 97))
        }
        if let next = lyricNext {
            let font = NSFont.systemFont(ofSize: 16)
            drawText(truncated(next, toWidth: width, font: font),
                     font: font, color: NSColor.white.withAlphaComponent(0.45),
                     at: NSPoint(x: x, y: 134))
        }
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
