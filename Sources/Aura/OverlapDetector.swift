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
/// Decision, after the frame gate (a window covering >25% of
/// the pill — any window on the pill's screen, not just the
/// frontmost app's, because the pill can sit on monitor 1 while
/// the active app is on monitor 2):
/// - Sample 5 points across the pill's width at its centre height.
/// - Hide ONLY when a point lands on a specific element: a tab
///   button, a search button/field, text, a link, an image, a
///   cell, and so on (whitelist below). Containers do NOT count:
///   AXScrollArea, AXWebArea, AXGroup, AXToolbar, AXWindow, and
///   the like are just the area the content sits in — counting
///   them made the pill hide over blank web pages and empty
///   windows, which is the bug the user reported.
/// - If Accessibility permission is not granted, the API returns
///   nothing usable: the pill does NOT hide, and the log says the
///   permission is missing, instead of silently guessing.
///
/// Multi-monitor trap: NSScreen.main follows the key window, so
/// it changes when the user activates an app on another monitor.
/// Using it for coordinate conversion shifted every rect by the
/// height difference between monitors, and the pill on monitor 1
/// could never hide while monitor 2 was active. Conversion now
/// uses the PRIMARY display (frame origin (0,0)), which never
/// moves, and the pill frame itself comes from the pill window's
/// own screen (see AppDelegate).
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

    /// Height of the primary display (frame origin (0,0)) in
    /// AppKit points. Quartz coordinates are relative to the
    /// primary display's top-left, so this — not NSScreen.main,
    /// which follows the key window across monitors — is the
    /// correct flip constant for every screen.
    static var primaryHeight: CGFloat {
        NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height ?? 0
    }

    /// Roles that are actual things under the pill: a browser tab
    /// (Chrome exposes tabs as radio buttons), a search button or
    /// field, text, a link, an image, a table cell, a menu item.
    /// Everything else — scroll areas, web areas, groups, toolbars,
    /// split groups, windows — is a container or background, and
    /// must NOT hide the pill on its own.
    static let contentRoles: Set<String> = [
        "AXButton", "AXRadioButton", "AXCheckBox", "AXPopUpButton",
        "AXMenuButton", "AXStaticText", "AXTextField", "AXTextArea",
        "AXLink", "AXImage", "AXCell", "AXRow", "AXMenuItem",
        "AXSlider", "AXComboBox", "AXDisclosureTriangle",
    ]

    /// True when any sampled point under the pill lands on a
    /// whitelisted content element.
    static func contentUnderPill(pillFrame: NSRect) -> (found: Bool, role: String?, title: String?, trusted: Bool) {
        guard AXIsProcessTrusted() else {
            return (found: false, role: nil, title: nil, trusted: false)
        }
        let centerYQuartz = primaryHeight - pillFrame.midY
        for fraction in [0.1, 0.3, 0.5, 0.7, 0.9] {
            let x = pillFrame.minX + pillFrame.width * fraction
            let point = CGPoint(x: x, y: centerYQuartz)
            guard let el = elementAt(quartzPoint: point) else { continue }
            if contentRoles.contains(el.role) {
                return (found: true, role: el.role, title: el.title, trusted: true)
            }
        }
        return (found: false, role: nil, title: nil, trusted: true)
    }

    static func check(pillFrame: NSRect) -> Result {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let mainHeight = primaryHeight
        guard mainHeight > 0,
              let list = CGWindowListCopyWindowInfo(
                  [.optionOnScreenOnly, .excludeDesktopElements],
                  kCGNullWindowID
              ) as? [[String: Any]] else {
            return Result(covered: false, ownerName: "", windowFrame: nil, elementRole: nil, elementTitle: nil, axTrusted: AXIsProcessTrusted())
        }
        let pillArea = pillFrame.width * pillFrame.height
        guard pillArea > 0 else {
            return Result(covered: false, ownerName: "", windowFrame: nil, elementRole: nil, elementTitle: nil, axTrusted: AXIsProcessTrusted())
        }
        for win in list {
            // Any window on the pill's screen, not just the
            // frontmost app's: the pill on monitor 1 must still
            // hide when a monitor-1 window covers it, even while
            // the active app lives on monitor 2. The AX sample
            // below is what actually identifies the element under
            // the pill, regardless of which app is frontmost.
            guard let pid = (win[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != ownPID else {
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
            // Quartz (top-left origin, relative to the primary
            // display) -> AppKit (bottom-left origin).
            let bounds = NSRect(x: x, y: mainHeight - yQ - h, width: w, height: h)
            let inter = pillFrame.intersection(bounds)
            if !inter.isNull, inter.width * inter.height > pillArea * 0.25 {
                // Frame overlap is only the first gate. The second
                // gate is what is actually under the pill.
                let ownerName = (win[kCGWindowOwnerName as String] as? String) ?? ""
                let ax = contentUnderPill(pillFrame: pillFrame)
                return Result(covered: ax.found, ownerName: ownerName, windowFrame: bounds,
                              elementRole: ax.role, elementTitle: ax.title, axTrusted: ax.trusted)
            }
        }
        return Result(covered: false, ownerName: "", windowFrame: nil, elementRole: nil, elementTitle: nil, axTrusted: AXIsProcessTrusted())
    }
}
