import AppKit

/// Draws the island in Nusa's visual language: solid black card, white
/// type, green battery ring, live-looking waveform, album art, and
/// expanded music/lyrics pages modelled on Nusa's music card.
///
/// Layouts (flipped coordinates, y grows downward):
/// - zen (140x32): the idle face — two white eyes.
/// - compact (380x64): the closed notch — battery ring, clock, waveform.
/// - expanded: size follows the page — music is a slim strip (460x112:
///   artwork, title/artist, current lyric line, thin progress, controls),
///   lyrics is the full card (520x360: header, mini player, lyrics
///   column, dots), sources is a shorter card (520x260: session picker).
///   The bubble (or the lyric line) opens lyrics, the dots jump pages,
///   and the lyrics page's bubble goes back to music.
final class IslandView: NSView {
    var state: IslandState = .zen {
        didSet {
            // Leaving the expanded card always returns to the music
            // page, so reopening never lands on a stale lyrics/sources page.
            if state != .expanded { cardPage = .music }
            needsDisplay = true
        }
    }
    var session: DisplaySession? {
        didSet { needsDisplay = true }
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

    /// Window size for the expanded card, per page: the music strip is
    /// a slim bar (the "small pill" while lyrics are closed), lyrics and
    /// sources are the full card.
    var expandedSize: NSSize {
        switch currentPage {
        case .music: return NSSize(width: 460, height: 112)
        case .lyrics: return NSSize(width: 520, height: 360)
        case .sources: return NSSize(width: 520, height: 260)
        }
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
    /// The music strip's bubble opens lyrics; the lyric line itself is
    /// also tappable for the same. The lyrics page's bubble goes back.
    private var stripBubbleRect: NSRect { NSRect(x: 310, y: 42, width: 28, height: 28) }
    private var stripLyricRect: NSRect { NSRect(x: 100, y: 66, width: 200, height: 16) }
    private var lyricsBubbleRect: NSRect { NSRect(x: 14, y: 176, width: 28, height: 28) }

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
    /// height (lyrics card 360, sources card 260).
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
    /// resize to the page: the music strip is small, lyrics/sources are
    /// the full card. AppDelegate ignores it unless expanded.
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
        // Page dots (lyrics/sources pages only — the music strip has none).
        if currentPage != .music, let index = dotIndex(at: point) {
            let pages = availablePages
            if index < pages.count {
                cardPage = pages[index]
                needsDisplay = true
            }
            return
        }
        switch currentPage {
        case .music:
            // Speech bubble, or the lyric line itself: lyrics page
            // (the card grows to the full lyrics view).
            if stripBubbleRect.contains(point) || stripLyricRect.contains(point) {
                cardPage = .lyrics
                needsDisplay = true
                return
            }
            // Controls row (right side of the strip).
            if let hit = controlHit(at: point, centers: [362, 400, 438], yMin: 38, yMax: 74, halfWidth: 18) {
                switch hit {
                case 0: onPrevious?()
                case 1: onPlayPause?()
                default: onNext?()
                }
                return
            }
        case .lyrics:
            // Speech bubble toggles back to the music page.
            if lyricsBubbleRect.contains(point) {
                cardPage = .music
                needsDisplay = true
                return
            }
            // Controls row (left column).
            if let hit = controlHit(at: point, centers: [83, 127, 171], yMin: 176, yMax: 204) {
                switch hit {
                case 0: onPrevious?()
                case 1: onPlayPause?()
                default: onNext?()
                }
                return
            }
        case .sources:
            // Picker rows: header at y 80, rows from y 104, height 26, max 4.
            if point.y >= 104 {
                let index = Int((point.y - 104) / 26)
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
            bottomRadius: state == .expanded ? 28 : rect.height / 2
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
            image.draw(in: rect, from: src, operation: .sourceOver, fraction: 1.0)
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
        drawBatteryRing(center: CGPoint(x: 30, y: 32), radius: 10)
        drawCentered(
            Self.clockFormatter.string(from: Date()),
            font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            color: .white, y: 24)
        drawWaveform(in: NSRect(x: 318, y: 22, width: 42, height: 20))
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
            // The music strip has no header and no dots — just the song.
            drawMusicStrip(session)
        case .lyrics, .sources:
            drawCardHeader()
            if currentPage == .lyrics {
                drawLyricsPage(session)
            } else {
                drawPicker(startY: 80)
            }
            drawPageDots()
        }
    }

    /// Header for the full card pages, like Nusa's music card: green dot
    /// + date/time centered, waveform top-right. No battery ring here —
    /// the reference card has none; the ring lives in the closed state.
    private func drawCardHeader() {
        let dateStr = Self.headerDateFormatter.string(from: Date())
        let dateFont = NSFont.systemFont(ofSize: 13, weight: .medium)
        let dateWidth = (dateStr as NSString).size(withAttributes: [.font: dateFont]).width
        let groupWidth = dateWidth + 16
        let groupX = (bounds.width - groupWidth) / 2
        NSColor.systemGreen.setFill()
        NSBezierPath(ovalIn: NSRect(x: groupX, y: 21, width: 8, height: 8)).fill()
        drawText(dateStr, font: dateFont, color: .white, at: NSPoint(x: groupX + 16, y: 18))
        drawWaveform(in: NSRect(x: 452, y: 18, width: 48, height: 18))
    }

    /// Music strip (460x112): the "small pill" while lyrics are closed —
    /// artwork, title/artist, the current lyric line, a thin progress
    /// bar, and controls. The bubble (or the lyric line) opens lyrics.
    private func drawMusicStrip(_ session: DisplaySession) {
        drawArtwork(session.artwork, in: NSRect(x: 16, y: 20, width: 72, height: 72), cornerRadius: 12)
        let titleFont = NSFont.boldSystemFont(ofSize: 16)
        drawText(truncated(session.title, toWidth: 200, font: titleFont),
                 font: titleFont, color: .white, at: NSPoint(x: 100, y: 24))
        let artistFont = NSFont.systemFont(ofSize: 12)
        drawText(truncated(session.artist, toWidth: 200, font: artistFont),
                 font: artistFont, color: NSColor.white.withAlphaComponent(0.65),
                 at: NSPoint(x: 100, y: 48))
        if let line = lyricCurrent {
            let lyricFont = NSFont.systemFont(ofSize: 12)
            drawText(truncated(line, toWidth: 200, font: lyricFont),
                     font: lyricFont, color: NSColor.white.withAlphaComponent(0.55),
                     at: NSPoint(x: 100, y: 68))
        }
        // Thin progress bar along the bottom of the strip.
        if session.duration > 0 {
            let bg = NSBezierPath(roundedRect: NSRect(x: 16, y: 102, width: 428, height: 3),
                                  xRadius: 1.5, yRadius: 1.5)
            NSColor.white.withAlphaComponent(0.25).setFill()
            bg.fill()
            let filled = min(1.0, session.position / session.duration)
            let fg = NSBezierPath(roundedRect: NSRect(x: 16, y: 102, width: 428 * CGFloat(filled), height: 3),
                                  xRadius: 1.5, yRadius: 1.5)
            NSColor.white.setFill()
            fg.fill()
        }
        // Controls (right side).
        drawSymbol("ellipsis.bubble.fill", size: 20, center: CGPoint(x: 324, y: 56), fallback: "···")
        drawSymbol("backward.fill", size: 20, center: CGPoint(x: 362, y: 56), fallback: "‹")
        drawSymbol(session.isPlaying ? "pause.fill" : "play.fill", size: 20,
                   center: CGPoint(x: 400, y: 56), fallback: session.isPlaying ? "❚❚" : "▶")
        drawSymbol("forward.fill", size: 20, center: CGPoint(x: 438, y: 56), fallback: "›")
    }

    /// Lyrics page, modelled on Nusa's lyrics card: mini player on the
    /// left, lyrics column on the right, divider between them.
    private func drawLyricsPage(_ session: DisplaySession) {
        drawArtwork(session.artwork, in: NSRect(x: 20, y: 56, width: 76, height: 76), cornerRadius: 12)
        let titleFont = NSFont.boldSystemFont(ofSize: 19)
        drawText(truncated(session.title, toWidth: 127, font: titleFont),
                 font: titleFont, color: .white, at: NSPoint(x: 108, y: 60))
        let artistFont = NSFont.systemFont(ofSize: 13)
        drawText(truncated(session.artist, toWidth: 127, font: artistFont),
                 font: artistFont, color: NSColor.white.withAlphaComponent(0.65),
                 at: NSPoint(x: 108, y: 86))
        drawProgress(session, elapsedX: 20, barX: 64, barWidth: 108, rightX: 235,
                     y: 150, font: NSFont.systemFont(ofSize: 12), barHeight: 4)
        drawSymbol("ellipsis.bubble.fill", size: 20, center: CGPoint(x: 28, y: 190), fallback: "···")
        drawSymbol("backward.fill", size: 20, center: CGPoint(x: 83, y: 190), fallback: "‹")
        drawSymbol(session.isPlaying ? "pause.fill" : "play.fill", size: 20,
                   center: CGPoint(x: 127, y: 190), fallback: session.isPlaying ? "❚❚" : "▶")
        drawSymbol("forward.fill", size: 20, center: CGPoint(x: 171, y: 190), fallback: "›")
        // Divider.
        NSColor.white.withAlphaComponent(0.12).setFill()
        NSRect(x: 250, y: 56, width: 1, height: 184).fill()
        // Lyrics column: dim previous, bold current, dim next.
        let x: CGFloat = 266
        let width: CGFloat = 234
        if let prev = lyricPrev {
            let font = NSFont.systemFont(ofSize: 16)
            drawText(truncated(prev, toWidth: width, font: font),
                     font: font, color: NSColor.white.withAlphaComponent(0.35),
                     at: NSPoint(x: x, y: 70))
        }
        if let current = lyricCurrent {
            let font = NSFont.boldSystemFont(ofSize: 21)
            drawText(truncated(current, toWidth: width, font: font),
                     font: font, color: .white, at: NSPoint(x: x, y: 100))
        } else {
            drawText("Lirik tidak tersedia",
                     font: NSFont.systemFont(ofSize: 14),
                     color: NSColor.white.withAlphaComponent(0.4),
                     at: NSPoint(x: x, y: 100))
        }
        if let next = lyricNext {
            let font = NSFont.systemFont(ofSize: 16)
            drawText(truncated(next, toWidth: width, font: font),
                     font: font, color: NSColor.white.withAlphaComponent(0.45),
                     at: NSPoint(x: x, y: 135))
        }
    }

    private func drawProgress(_ session: DisplaySession, elapsedX: CGFloat, barX: CGFloat,
                              barWidth: CGFloat, rightX: CGFloat, y: CGFloat,
                              font: NSFont, barHeight: CGFloat) {
        drawText(formatTime(session.position), font: font, color: .white,
                 at: NSPoint(x: elapsedX, y: y))
        guard session.duration > 0 else { return }
        drawRightAligned("-\(formatTime(session.duration - session.position))",
                         font: font, color: .white, rightX: rightX, y: y)
        let bg = NSBezierPath(roundedRect: NSRect(x: barX, y: y + 6, width: barWidth, height: barHeight),
                              xRadius: barHeight / 2, yRadius: barHeight / 2)
        NSColor.white.withAlphaComponent(0.25).setFill()
        bg.fill()
        let filled = min(1.0, session.position / session.duration)
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
        NSRect(x: 0, y: 0, width: size, height: size).fill(using: .destinationIn)
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
            y += 26
        }
    }
}
