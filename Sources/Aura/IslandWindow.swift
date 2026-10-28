import AppKit

/// Borderless floating window, Nusa-style: top-center, always on top,
/// transparent, never steals focus.
final class IslandWindow: NSWindow {
    /// Gate for becoming key. The island normally never steals
    /// focus (borderless, non-key), but an inline text field can
    /// only receive keystrokes in a key window. IslandView sets
    /// this true only while the todo input is active, and false
    /// again when editing ends, so ordinary hover/click never
    /// makes Aura the key app.
    var allowKey = false
    override var canBecomeKey: Bool { allowKey }

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

    /// Top Y for a window of this height on this screen. Notchless:
    /// flush against the menu bar, as before (visibleFrame.maxY, +1
    /// tuck so no hairline gap can show). Notched: flush against the
    /// top of the physical screen, so the pill merges with the
    /// hardware notch instead of floating as a second pill below it.
    static func topY(forHeight h: CGFloat, on screen: NSScreen) -> CGFloat {
        if HardwareNotch.forMainScreen().hasNotch {
            return screen.frame.maxY - h
        }
        return screen.visibleFrame.maxY - h + 1
    }

    /// Position the window centered horizontally, flush against the menu
    /// bar so the card reads as a notch, not a floating pill.
    func placeAtTopCenter() {
        guard let screen = NSScreen.main else { return }
        let w = frame.width
        let h = frame.height
        let notch = HardwareNotch.forMainScreen()
        let x = notch.hasNotch ? screen.frame.midX - w / 2 : screen.visibleFrame.midX - w / 2
        let y = Self.topY(forHeight: h, on: screen)
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

    /// Animates to a size at the normal top Y, or to yOverride
    /// when given — the overlap-hide path uses it to slide the pill
    /// up so only its tip remains visible, without changing size.
    /// Stops any running animation so a direct setFrame is not
    /// overwritten by a stale animation step.
    func cancel() {
        timer?.invalidate()
        timer = nil
    }

    func animate(to size: NSSize, yOverride: CGFloat? = nil) {
        guard let window else { return }
        timer?.invalidate()
        from = window.frame
        let x = window.frame.midX - size.width / 2
        let y: CGFloat
        if let yOverride {
            y = yOverride
        } else if let screen = NSScreen.main {
            y = IslandWindow.topY(forHeight: size.height, on: screen)
        } else {
            y = window.frame.minY
        }
        to = NSRect(x: x, y: y, width: size.width, height: size.height)
        start = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] t in
            self?.step(timer: t)
        }
        // .common, like the alert timer: a scheduledTimer only fires
        // in the default mode, so during an NSAlert modal the resize
        // animation froze mid-flight (window stuck between sizes).
        // Common modes keep it running through modals and tracking.
        if let timer { RunLoop.main.add(timer, forMode: .common) }
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
