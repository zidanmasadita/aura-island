import AppKit

/// Borderless floating window, Nusa-style: top-center, always on top,
/// transparent, never steals focus.
final class IslandWindow: NSWindow {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .stationary]
        isMovableByWindowBackground = false
        // Mouse events stay enabled even in zen: hover is what expands
        // the island, so the window must keep receiving tracking events.
        ignoresMouseEvents = false
    }

    /// Position the window centered horizontally, just below the menu bar.
    func placeAtTopCenter() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let w = frame.width
        let h = frame.height
        let x = visible.midX - w / 2
        let y = visible.maxY - h - 8
        setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
    }
}

/// Drives frame interpolation with an ease-out cubic curve, timer based
/// (same philosophy as Nusa: timers step the animation, no keyframes).
final class IslandAnimator {
    private weak var window: IslandWindow?
    private var timer: Timer?
    private var from: NSRect = .zero
    private var to: NSRect = .zero
    private var start: Date = Date()
    private let duration: TimeInterval = 0.35

    init(window: IslandWindow) {
        self.window = window
    }

    func animate(to size: NSSize) {
        guard let window else { return }
        timer?.invalidate()
        from = window.frame
        let x = window.frame.midX - size.width / 2
        let y: CGFloat
        if let screen = NSScreen.main {
            y = screen.visibleFrame.maxY - size.height - 8
        } else {
            y = window.frame.minY
        }
        to = NSRect(x: x, y: y, width: size.width, height: size.height)
        start = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] t in
            self?.step(timer: t)
        }
    }

    private func step(timer: Timer) {
        guard let window else {
            timer.invalidate()
            return
        }
        let elapsed = Date().timeIntervalSince(start)
        let p = min(1.0, elapsed / duration)
        // easeOutCubic
        let e = 1.0 - pow(1.0 - p, 3.0)
        let x = from.origin.x + (to.origin.x - from.origin.x) * e
        let y = from.origin.y + (to.origin.y - from.origin.y) * e
        let w = from.width + (to.width - from.width) * e
        let h = from.height + (to.height - from.height) * e
        window.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
        if p >= 1.0 {
            timer.invalidate()
            self.timer = nil
        }
    }
}
