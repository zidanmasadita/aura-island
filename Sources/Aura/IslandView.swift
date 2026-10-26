import AppKit

/// Draws the island pill/card with CoreGraphics + AppKit text.
/// Flipped coordinates (y grows downward) to keep layout math simple.
final class IslandView: NSView {
    var state: IslandState = .zen {
        didSet { needsDisplay = true }
    }
    var session: DisplaySession?
    var lyricLine: String?
    var sessionsForPicker: [DisplaySession] = []
    var pinnedId: String?

    var onHoverChanged: ((Bool) -> Void)?
    var onClicked: (() -> Void)?
    var onSessionPicked: ((String) -> Void)?
    var onUnpin: (() -> Void)?
    var onPlayPause: (() -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?

    override var isFlipped: Bool { true }

    private var trackingArea: NSTrackingArea?

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
        // Controls row: y 110...140.
        if point.y >= 110 && point.y <= 140 {
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
        // Picker rows start at y 184, row height 28.
        if point.y >= 184 {
            let index = Int((point.y - 184) / 28)
            if index >= 0 && index < sessionsForPicker.count {
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
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = bounds
        let radius = rect.height / 2
        let pill = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSColor.black.withAlphaComponent(0.92).setFill()
        pill.fill()
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.15).cgColor)
        context.setLineWidth(0.5)
        pill.stroke()

        switch state {
        case .zen:
            if session?.isPlaying == true {
                let dot = NSBezierPath(ovalIn: NSRect(
                    x: rect.midX - 3, y: rect.midY - 3, width: 6, height: 6))
                NSColor.white.setFill()
                dot.fill()
            }
        case .compact, .split:
            drawCompact()
        case .expanded:
            drawExpanded()
        }
    }

    // MARK: - Layouts

    private func drawCentered(_ text: String, fontSize: CGFloat, bold: Bool, y: CGFloat, color: NSColor = .white) {
        let font = bold
            ? NSFont.boldSystemFont(ofSize: fontSize)
            : NSFont.systemFont(ofSize: fontSize)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()
        let x = (bounds.width - size.width) / 2
        str.draw(at: NSPoint(x: x, y: y))
    }

    private func drawCompact() {
        guard let session else { return }
        drawCentered(session.title, fontSize: 14, bold: true, y: 10)
        drawCentered(session.artist, fontSize: 12, bold: false, y: 32,
                     color: NSColor.white.withAlphaComponent(0.7))
        if session.duration > 0 {
            let barX: CGFloat = 24
            let barW = bounds.width - 48
            let bg = NSBezierPath(roundedRect: NSRect(x: barX, y: 52, width: barW, height: 4),
                                  xRadius: 2, yRadius: 2)
            NSColor.white.withAlphaComponent(0.25).setFill()
            bg.fill()
            let filled = min(1.0, session.position / session.duration)
            let fg = NSBezierPath(roundedRect: NSRect(x: barX, y: 52, width: barW * CGFloat(filled), height: 4),
                                  xRadius: 2, yRadius: 2)
            NSColor.white.setFill()
            fg.fill()
        }
    }

    private func drawExpanded() {
        guard let session else {
            drawCentered("Tidak ada media yang diputar", fontSize: 13, bold: false, y: 20,
                         color: NSColor.white.withAlphaComponent(0.7))
            drawPickerHeaderAndRows(startY: 60)
            return
        }
        drawCentered(session.title, fontSize: 15, bold: true, y: 14)
        drawCentered(session.artist, fontSize: 13, bold: false, y: 38,
                     color: NSColor.white.withAlphaComponent(0.7))
        let lyric = lyricLine ?? "Lirik tidak tersedia"
        drawCentered(lyric, fontSize: 14, bold: false, y: 64,
                     color: NSColor.white.withAlphaComponent(0.9))
        if session.duration > 0 {
            let barX: CGFloat = 24
            let barW = bounds.width - 48
            let bg = NSBezierPath(roundedRect: NSRect(x: barX, y: 96, width: barW, height: 4),
                                  xRadius: 2, yRadius: 2)
            NSColor.white.withAlphaComponent(0.25).setFill()
            bg.fill()
            let filled = min(1.0, session.position / session.duration)
            let fg = NSBezierPath(roundedRect: NSRect(x: barX, y: 96, width: barW * CGFloat(filled), height: 4),
                                  xRadius: 2, yRadius: 2)
            NSColor.white.setFill()
            fg.fill()
        }
        let playGlyph = session.isPlaying ? "❚❚" : "▶"
        drawCentered("‹   \(playGlyph)   ›", fontSize: 18, bold: false, y: 112)
        drawPickerHeaderAndRows(startY: 160)
    }

    private func drawPickerHeaderAndRows(startY: CGFloat) {
        let header = pinnedId == nil
            ? "Sumber: Auto (ikuti yang aktif)"
            : "Sumber: Pin aktif — klik sumber untuk lepas"
        let headerAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.white.withAlphaComponent(0.6),
        ]
        NSAttributedString(string: header, attributes: headerAttrs)
            .draw(at: NSPoint(x: 20, y: startY))
        var y = startY + 24
        for item in sessionsForPicker {
            let mark = item.id == pinnedId ? "● " : "○ "
            let label = "\(mark)\(item.label) — \(item.title)"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.white,
            ]
            NSAttributedString(string: label, attributes: attrs)
                .draw(at: NSPoint(x: 20, y: y))
            y += 28
        }
    }
}
