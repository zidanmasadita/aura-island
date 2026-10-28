import AppKit

/// Detects whether the closed pill covers another app's content,
/// by window frame — not by pixels (no screenshot, no Accessibility
/// permission needed for frames).
///
/// CGWindowListCopyWindowInfo returns on-screen windows with their
/// owner PID, layer, alpha, and bounds (on-screen only is already enforced by the list option). A window
/// counts when it is: not Aura's own, layer 0 (normal app windows —
/// menu bar, Dock, and desktop elements are other layers and are
/// also excluded by .excludeDesktopElements), on-screen, and
/// non-transparent. The pill counts as covering content when such
/// a window intersects more than 25% of the pill's area, so a
/// window merely grazing the pill's edge does not trigger a hide.
enum OverlapDetector {
    static func coversContent(pillFrame: NSRect) -> Bool {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return false }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let pillArea = pillFrame.width * pillFrame.height
        guard pillArea > 0 else { return false }
        for win in list {
            if let pid = win[kCGWindowOwnerPID as String] as? Int32, pid == ownPID {
                continue
            }
            if let layer = win[kCGWindowLayer as String] as? Int, layer != 0 {
                continue
            }
            if let alpha = win[kCGWindowAlpha as String] as? Double, alpha <= 0 {
                continue
            }
            guard let boundsDict = win[kCGWindowBounds as String] as? [String: Any],
                  let x = (boundsDict["X"] as? NSNumber)?.doubleValue,
                  let y = (boundsDict["Y"] as? NSNumber)?.doubleValue,
                  let w = (boundsDict["Width"] as? NSNumber)?.doubleValue,
                  let h = (boundsDict["Height"] as? NSNumber)?.doubleValue else {
                continue
            }
            let bounds = NSRect(x: x, y: y, width: w, height: h)
            let inter = pillFrame.intersection(bounds)
            if !inter.isNull, inter.width * inter.height > pillArea * 0.25 {
                return true
            }
        }
        return false
    }
}
