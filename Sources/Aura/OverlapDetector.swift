import AppKit
import ApplicationServices

/// Detects whether the closed pill covers another app's content.
///
/// This follows Nusa's idea, adapted to macOS (re-implemented from
/// the RE findings, no Nusa code):
/// - Nusa only looks at the FOREGROUND window (WinEventHook on
///   foreground change + move/size end), ignoring its own window,
///   invisible/minimized windows, and system windows
///   (taskbar/desktop classes). Aura does the same: only the
///   frontmost app's windows count, not any background window.
/// - Nusa then checks whether that window overlaps the notch area,
///   and samples the pixels underneath, hiding only when they vary.
///   Aura does NOT copy the pixel step: on macOS that needs Screen
///   Recording permission, which the user explicitly rejected.
///   Instead, Aura asks the system what UI element is actually
///   under the pill, via the Accessibility API
///   (AXUIElementCopyElementAtPosition). That reads UI structure
///   only — no screen capture, no pixels — and it is the native
///   macOS way to answer "what is underneath this point".
///
/// Two macOS-specific traps, both fixed here:
/// - CGWindowList bounds use Quartz coordinates (origin at the
///   TOP-left of the main display, y growing down), while
///   NSScreen/NSWindow frames use AppKit coordinates (origin at
///   the BOTTOM-left, y growing up). Bounds are converted:
///   appKitY = mainScreenHeight - quartzY - height.
/// - Accessibility coordinates also use the Quartz (top-left)
///   origin, so sample points are converted the same way.
///
/// Decision, after the frame gate (a foreground window covering
/// >25% of the pill):
/// - Sample 5 points across the pill's width at its centre height.
/// - If any point lands on a specific UI element — a tab button,
///   a toolbar button, text, a link, an image, a cell, and so on
///   — that is content, and the pill hides.
/// - If every point lands only on the window itself (role
///   AXWindow), on the application, or on nothing (desktop, empty
///   window background), that is NOT content, and the pill stays.
/// - If Accessibility permission is not granted, the API returns
///   nothing usable: the pill does NOT hide, and the log says the
///   permission is missing, instead of silently guessing.
enum OverlapDetector {
    struct Result {
        let covered: Bool
        let ownerName: String
        let windowFrame: NSRect?
        /// Role/title of the first content element found under the
        /// pill, when one was found; nil otherwise.
        let elementRole: String?
        let elementTitle: String?
        /// False when Accessibility permission is missing.
        let axTrusted: Bool
    }

    /// The element at one Quartz point, or nil when there is none
    /// or it cannot be read.
    private static func elementAt(quartzPoint: CGPoint) -> (role: String, title: String)? {
        let systemWide = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(
            systemWide, Float(quartzPoint.x), Float(quartzPoint.y), &element)
        guard err == .success, let element else { return nil }
        var roleValue: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
        let role = roleValue as? String ?? ""
        var titleValue: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleValue)
        var title = titleValue as? String ?? ""
        if title.isEmpty {
            var descValue: AnyObject?
            AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &descValue)
            title = descValue as? String ?? ""
        }
        return (role: role, title: title)
    }

    /// True when any sampled point under the pill lands on a
    /// specific UI element rather than just the window itself.
    static func contentUnderPill(pillFrame: NSRect, mainHeight: CGFloat) -> (found: Bool, role: String?, title: String?, trusted: Bool) {
        guard AXIsProcessTrusted() else {
            return (found: false, role: nil, title: nil, trusted: false)
        }
        let centerYAppKit = pillFrame.midY
        let centerYQuartz = mainHeight - centerYAppKit
        for fraction in [0.1, 0.3, 0.5, 0.7, 0.9] {
            let x = pillFrame.minX + pillFrame.width * fraction
            let point = CGPoint(x: x, y: centerYQuartz)
            guard let el = elementAt(quartzPoint: point) else { continue }
            // The window itself, the application, and the system-wide
            // element are background, not content.
            if el.role == "AXWindow" || el.role == "AXApplication" || el.role.isEmpty {
                continue
            }
            return (found: true, role: el.role, title: el.title, trusted: true)
        }
        return (found: false, role: nil, title: nil, trusted: true)
    }

    static func check(pillFrame: NSRect) -> Result {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else {
            return Result(covered: false, ownerName: "", windowFrame: nil, elementRole: nil, elementTitle: nil, axTrusted: AXIsProcessTrusted())
        }
        let frontPID = frontmost.processIdentifier
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard frontPID != ownPID else {
            return Result(covered: false, ownerName: frontmost.localizedName ?? "", windowFrame: nil, elementRole: nil, elementTitle: nil, axTrusted: AXIsProcessTrusted())
        }
        guard let mainHeight = NSScreen.main?.frame.height,
              let list = CGWindowListCopyWindowInfo(
                  [.optionOnScreenOnly, .excludeDesktopElements],
                  kCGNullWindowID
              ) as? [[String: Any]] else {
            return Result(covered: false, ownerName: frontmost.localizedName ?? "", windowFrame: nil, elementRole: nil, elementTitle: nil, axTrusted: AXIsProcessTrusted())
        }
        let ownerName = frontmost.localizedName ?? ""
        let pillArea = pillFrame.width * pillFrame.height
        guard pillArea > 0 else {
            return Result(covered: false, ownerName: ownerName, windowFrame: nil, elementRole: nil, elementTitle: nil, axTrusted: AXIsProcessTrusted())
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
                // Frame overlap is only the first gate. The second
                // gate is what is actually under the pill.
                let ax = contentUnderPill(pillFrame: pillFrame, mainHeight: mainHeight)
                return Result(covered: ax.found, ownerName: ownerName, windowFrame: bounds,
                              elementRole: ax.role, elementTitle: ax.title, axTrusted: ax.trusted)
            }
        }
        return Result(covered: false, ownerName: ownerName, windowFrame: nil, elementRole: nil, elementTitle: nil, axTrusted: AXIsProcessTrusted())
    }
}
