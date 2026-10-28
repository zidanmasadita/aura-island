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
        /// Roles of elements whose frames intersect the pill,
        /// whether whitelisted or not — for the log, so a miss
        /// can be diagnosed from what the app actually exposes.
        let intersectingRoles: [String]
    }

    /// Roles that are actual things under the pill: a browser tab
    /// (Chrome exposes tabs as radio buttons / tab groups), a
    /// search button or field, text, a link, an image, a table
    /// cell, a menu item. Everything else — scroll areas, web
    /// areas, groups, toolbars, split groups, windows — is a
    /// container or background, and must NOT hide the pill on
    /// its own.
    static let contentRoles: Set<String> = [
        "AXButton", "AXRadioButton", "AXCheckBox", "AXPopUpButton",
        "AXMenuButton", "AXStaticText", "AXTextField", "AXTextArea",
        "AXLink", "AXImage", "AXCell", "AXRow", "AXMenuItem",
        "AXSlider", "AXComboBox", "AXDisclosureTriangle",
        "AXTabGroup",
    ]

    private static func axString(_ element: AXUIElement, _ attribute: CFString) -> String {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return "" }
        return value as? String ?? ""
    }

    private static func axFrame(_ element: AXUIElement, primaryHeight: CGFloat) -> NSRect? {
        var posValue: AnyObject?
        var sizeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let posAX = posValue as? AXValue, let sizeAX = sizeValue as? AXValue else {
            return nil
        }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posAX, .cgPoint, &point),
              AXValueGetValue(sizeAX, .cgSize, &size) else {
            return nil
        }
        // AX positions are Quartz (top-left origin, relative to
        // the primary display) -> AppKit (bottom-left origin).
        return NSRect(x: point.x, y: primaryHeight - point.y - size.height,
                      width: size.width, height: size.height)
    }

    /// Searches one app's accessibility tree for a whitelisted
    /// content element whose frame intersects the pill. System-wide
    /// hit-testing (AXUIElementCopyElementAtPosition) cannot work
    /// here: Aura's own pill is the topmost window at those points,
    /// so hit-testing returns Aura itself, never the app underneath.
    /// Querying the underlying app's tree directly avoids that.
    /// Traversal is pruned by frame: a subtree whose frame does
    /// not intersect the pill cannot contain an intersecting child,
    /// so large trees (a web page below the tab bar) are never
    /// walked. A node budget guards against pathological trees.
    static func contentUnderPill(pillFrame: NSRect, windowPID: Int32) -> (found: Bool, role: String?, title: String?, trusted: Bool, intersectingRoles: [String]) {
        guard AXIsProcessTrusted() else {
            return (found: false, role: nil, title: nil, trusted: false, intersectingRoles: [])
        }
        let primaryHeight = primaryHeight
        let appElement = AXUIElementCreateApplication(windowPID)
        var windowsValue: AnyObject?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement] else {
            return (found: false, role: nil, title: nil, trusted: true, intersectingRoles: [])
        }
        var intersectingRoles = Set<String>()
        var visited = 0
        func visit(_ element: AXUIElement, depth: Int) -> (role: String, title: String)? {
            if visited > 3000 || depth > 16 { return nil }
            visited += 1
            let role = axString(element, kAXRoleAttribute as CFString)
            if let frame = axFrame(element, primaryHeight: primaryHeight) {
                if frame.intersection(pillFrame).isNull {
                    return nil
                }
                if !role.isEmpty { intersectingRoles.insert(role) }
                if contentRoles.contains(role) {
                    return (role: role, title: axString(element, kAXTitleAttribute as CFString))
                }
            }
            var childrenValue: AnyObject?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
                  let children = childrenValue as? [AXUIElement] else {
                return nil
            }
            for child in children {
                if let found = visit(child, depth: depth + 1) { return found }
            }
            return nil
        }
        for window in windows {
            if let found = visit(window, depth: 0) {
                return (found: true, role: found.role, title: found.title, trusted: true,
                        intersectingRoles: Array(intersectingRoles).sorted())
            }
        }
        return (found: false, role: nil, title: nil, trusted: true,
                intersectingRoles: Array(intersectingRoles).sorted())
    }

    static func check(pillFrame: NSRect) -> Result {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let mainHeight = primaryHeight
        guard mainHeight > 0,
              let list = CGWindowListCopyWindowInfo(
                  [.optionOnScreenOnly, .excludeDesktopElements],
                  kCGNullWindowID
              ) as? [[String: Any]] else {
            return Result(covered: false, ownerName: "", windowFrame: nil, elementRole: nil, elementTitle: nil, axTrusted: AXIsProcessTrusted(), intersectingRoles: [])
        }
        let pillArea = pillFrame.width * pillFrame.height
        guard pillArea > 0 else {
            return Result(covered: false, ownerName: "", windowFrame: nil, elementRole: nil, elementTitle: nil, axTrusted: AXIsProcessTrusted(), intersectingRoles: [])
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
                let ax = contentUnderPill(pillFrame: pillFrame, windowPID: pid)
                return Result(covered: ax.found, ownerName: ownerName, windowFrame: bounds,
                              elementRole: ax.role, elementTitle: ax.title, axTrusted: ax.trusted,
                              intersectingRoles: ax.intersectingRoles)
            }
        }
        return Result(covered: false, ownerName: "", windowFrame: nil, elementRole: nil, elementTitle: nil, axTrusted: AXIsProcessTrusted(), intersectingRoles: [])
    }
}
