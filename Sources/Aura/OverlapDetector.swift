import AppKit

/// Detects whether the closed pill covers another app's content.
///
/// This follows Nusa's idea, adapted to macOS (re-implemented from
/// the RE findings, no Nusa code):
/// - Nusa only looks at the FOREGROUND window (WinEventHook on
///   foreground change + move/size end), ignoring its own window,
///   invisible/minimized windows, and system windows
///   (taskbar/desktop classes). Aura does the same: only the
///   frontmost app's windows count, not any background window.
/// - Nusa then checks whether that window overlaps the notch area.
///   Aura does the same against the pill's normal frame, with a
///   25% area threshold so a window merely grazing the pill's edge
///   does not trigger a hide.
///
/// Two macOS-specific traps, both fixed here:
/// - CGWindowList bounds use Quartz coordinates (origin at the
///   TOP-left of the main display, y growing down), while
///   NSScreen/NSWindow frames use AppKit coordinates (origin at
///   the BOTTOM-left, y growing up). Intersecting them directly
///   never matches for a top-of-screen window — the previous
///   version's bug, and why the pill never hid. Bounds are
///   converted: appKitY = mainScreenHeight - quartzY - height.
/// - Nusa additionally samples the actual pixels under the notch
///   (BitBlt from the screen DC) and only hides when the pixels
///   vary — i.e. real content, not a uniform background. Aura does
///   NOT copy that step: on modern macOS it would need Screen
///   Recording permission, which Aura does not ask for. Frame
///   overlap is the trade-off: a window whose top area happens to
///   be blank still hides the pill.
enum OverlapDetector {
    struct Result {
        let covered: Bool
        let ownerName: String
        let windowFrame: NSRect?
    }

    static func check(pillFrame: NSRect) -> Result {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else {
            return Result(covered: false, ownerName: "", windowFrame: nil)
        }
        let frontPID = frontmost.processIdentifier
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard frontPID != ownPID else {
            return Result(covered: false, ownerName: frontmost.localizedName ?? "", windowFrame: nil)
        }
        guard let mainHeight = NSScreen.main?.frame.height,
              let list = CGWindowListCopyWindowInfo(
                  [.optionOnScreenOnly, .excludeDesktopElements],
                  kCGNullWindowID
              ) as? [[String: Any]] else {
            return Result(covered: false, ownerName: frontmost.localizedName ?? "", windowFrame: nil)
        }
        let ownerName = frontmost.localizedName ?? ""
        let pillArea = pillFrame.width * pillFrame.height
        guard pillArea > 0 else {
            return Result(covered: false, ownerName: ownerName, windowFrame: nil)
        }
        for win in list {
            // Foreground app only, like Nusa's GetForegroundWindow.
            guard let pid = (win[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid == frontPID else {
                continue
            }
            if let layer = (win[kCGWindowLayer as String] as? NSNumber)?.intValue, layer != 0 {
                continue
            }
            if let alpha = win[kCGWindowAlpha as String] as? Double, alpha <= 0 {
                continue
            }
            guard let boundsDict = win[kCGWindowBounds as String] as? [String: Any],
                  let x = (boundsDict["X"] as? NSNumber)?.doubleValue,
                  let yQ = (boundsDict["Y"] as? NSNumber)?.doubleValue,
                  let w = (boundsDict["Width"] as? NSNumber)?.doubleValue,
                  let h = (boundsDict["Height"] as? NSNumber)?.doubleValue else {
                continue
            }
            // Quartz (top-left origin) -> AppKit (bottom-left origin).
            let bounds = NSRect(x: x, y: mainHeight - yQ - h, width: w, height: h)
            let inter = pillFrame.intersection(bounds)
            if !inter.isNull, inter.width * inter.height > pillArea * 0.25 {
                return Result(covered: true, ownerName: ownerName, windowFrame: bounds)
            }
        }
        return Result(covered: false, ownerName: ownerName, windowFrame: nil)
    }
}
