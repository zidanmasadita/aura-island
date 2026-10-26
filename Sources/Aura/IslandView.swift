import AppKit

/// Draws the island in Nusa's visual language: solid black card, white
/// type, green battery ring, live-looking waveform, album art, and a
/// split lyrics column in the expanded card.
///
/// Layouts (flipped coordinates, y grows downward):
/// - zen (140x32): the idle face — two white eyes.
/// - compact (380x64): the closed notch — battery ring, clock, waveform.
/// - expanded (520x360): header (battery, date+time, waveform), media row
///   (artwork, title/artist, lyrics column), progress + times, controls,
///   then the session picker ("pilih active").
final class IslandView: NSView {
    var state: IslandState = .zen {
        didSet { needsDisplay = true }
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

    var onHoverChanged: ((Bool) -> Void)?
    var onClicked: (() -> Void)?
    var onSessionPicked: ((String) -> Void)?
    var onUnpin: (() -> Void)?
    var onPlayPause: (() -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?

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
        // Controls row: y 160...196.
        if point.y >= 160 && point.y <= 196 {
            let cx = bounds.width / 2
            if point.x >= cx - 70 && point.x < cx - 20 {
                onPrevious?()
            } else if point.x >= cx - 20 && point.x <= cx + 20 {
                onPlayPause?()
            } else if point.x > cx + 20 && point.x <= cx + 70 {
                onNext?()
            }
            return
        }
        // Picker rows start at y 240, row height 26, max 4 rows.
        if point.y >= 240 {
            let index = Int((point.y - 240) / 26)
            if index >= 0 && index < min(sessionsForPicker.count, 4) {
                let picked = sessionsForPicker[index]
                if picked.id == pinnedId {
                    onUnpin?()
                } else {
                    onSessionPicked?(picked.id)
                }
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = bounds
        let radius: CGFloat = state == .expanded ? 28 : rect.height / 2
        let pill = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSColor.black.withAlphaComponent(0.98).setFill()
        pill.fill()
        if state == .expanded {
            // Subtle blue glow at the bottom, like Nusa's expanded card.
            NSGraphicsContext.saveGraphicsState()
            pill.setClip()
            let glow = NSGradient(
                starting: NSColor.systemBlue.withAlphaComponent(0.35),
                ending: NSColor.systemBlue.withAlphaComponent(0.0)
            )
            glow?.draw(
                in: NSRect(x: 0, y: rect.height * 0.55, width: rect.width, height: rect.height * 0.45),
                angle: 90
            )
            NSGraphicsContext.restoreGraphicsState()
        }
        NSColor.white.withAlphaComponent(0.15).setStroke()
        pill.lineWidth = 0.5
        pill.stroke()

        switch state {
        case .zen:
            drawEyes()
        case .compact, .split:
            drawClosed()
        case .expanded:
            drawExpanded()
        }
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

    private func drawArtwork(_ image: NSImage?, in rect: NSRect) {
        let clip = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
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
        // Header: battery ring, date + time, waveform.
        drawBatteryRing(center: CGPoint(x: 34, y: 27), radius: 9)
        drawCentered(
            Self.headerDateFormatter.string(from: Date()),
            font: NSFont.systemFont(ofSize: 13, weight: .medium),
            color: .white, y: 18)
        drawWaveform(in: NSRect(x: 452, y: 18, width: 48, height: 18))

        guard let session else {
            drawCentered("Tidak ada media yang diputar",
                         font: NSFont.systemFont(ofSize: 13),
                         color: NSColor.white.withAlphaComponent(0.7), y: 60)
            drawPicker(startY: 104)
            return
        }

        // Media row: artwork + title/artist on the left, lyrics on the right.
        drawArtwork(session.artwork, in: NSRect(x: 20, y: 56, width: 72, height: 72))
        let titleFont = NSFont.boldSystemFont(ofSize: 17)
        drawText(truncated(session.title, toWidth: 184, font: titleFont),
                 font: titleFont, color: .white, at: NSPoint(x: 104, y: 58))
        let artistFont = NSFont.systemFont(ofSize: 13)
        drawText(truncated(session.artist, toWidth: 184, font: artistFont),
                 font: artistFont, color: NSColor.white.withAlphaComponent(0.65),
                 at: NSPoint(x: 104, y: 82))
        drawLyricsColumn()

        // Progress: elapsed, bar, remaining.
        let timeFont = NSFont.systemFont(ofSize: 12)
        drawText(formatTime(session.position), font: timeFont, color: .white,
                 at: NSPoint(x: 20, y: 142))
        if session.duration > 0 {
            drawRightAligned("-\(formatTime(session.duration - session.position))",
                             font: timeFont, color: .white, rightX: 500, y: 142)
            let barX: CGFloat = 64
            let barW: CGFloat = 388
            let bg = NSBezierPath(roundedRect: NSRect(x: barX, y: 147, width: barW, height: 4),
                                  xRadius: 2, yRadius: 2)
            NSColor.white.withAlphaComponent(0.25).setFill()
            bg.fill()
            let filled = min(1.0, session.position / session.duration)
            let fg = NSBezierPath(roundedRect: NSRect(x: barX, y: 147, width: barW * CGFloat(filled), height: 4),
                                  xRadius: 2, yRadius: 2)
            NSColor.white.setFill()
            fg.fill()
        }

        // Controls.
        let playGlyph = session.isPlaying ? "❚❚" : "▶"
        drawCentered("‹   \(playGlyph)   ›",
                     font: NSFont.systemFont(ofSize: 20), color: .white, y: 168)

        // Divider + session picker.
        NSColor.white.withAlphaComponent(0.12).setFill()
        NSRect(x: 20, y: 206, width: 480, height: 1).fill()
        drawPicker(startY: 216)
    }

    private func drawLyricsColumn() {
        let x: CGFloat = 300
        let width: CGFloat = 200
        if let prev = lyricPrev {
            let font = NSFont.systemFont(ofSize: 13)
            drawText(truncated(prev, toWidth: width, font: font),
                     font: font, color: NSColor.white.withAlphaComponent(0.35),
                     at: NSPoint(x: x, y: 58))
        }
        if let current = lyricCurrent {
            let font = NSFont.boldSystemFont(ofSize: 15)
            drawText(truncated(current, toWidth: width, font: font),
                     font: font, color: .white, at: NSPoint(x: x, y: 80))
        } else {
            drawText("Lirik tidak tersedia",
                     font: NSFont.systemFont(ofSize: 13),
                     color: NSColor.white.withAlphaComponent(0.4),
                     at: NSPoint(x: x, y: 80))
        }
        if let next = lyricNext {
            let font = NSFont.systemFont(ofSize: 13)
            drawText(truncated(next, toWidth: width, font: font),
                     font: font, color: NSColor.white.withAlphaComponent(0.35),
                     at: NSPoint(x: x, y: 104))
        }
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
