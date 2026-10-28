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
/// - Nusa then checks whether that window overlaps the notch area,
///   and samples the pixels underneath, hiding only when they vary.
///   Aura does the same: frame overlap (25% threshold) is only the
///   first gate; the pixel test below is the second.
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
        /// Varied-pixel count under the pill, when a capture was
        /// available; nil when capture failed (usually Screen
        /// Recording permission missing).
        let variedPixels: Int?
    }

    /// Nusa-style pixel test, adapted to macOS: capture ONLY the
    /// foreground window (by window ID, so Aura's own pill is never
    /// in the image) over the pill rect, then count pixels whose
    /// colour differs from their left neighbour by >= 14 in any
    /// channel — the same < 0xE flatness test Nusa's BitBlt loop
    /// uses. A solid colour, a blank header, or a smooth gradient
    /// has almost no such pixels; text, icons, and tab edges have
    /// many. Hide only when varied >= 20 (Nusa used 12 over a
    /// similar strip; 20 gives a little noise margin).
    /// Returns nil when no capture is available at all.
    static func variedPixelCount(pillFrame: NSRect, windowID: CGWindowID, mainHeight: CGFloat) -> Int? {
        // AppKit (bottom-left origin) -> Quartz (top-left origin).
        let quartzRect = CGRect(x: pillFrame.minX,
                                y: mainHeight - pillFrame.maxY,
                                width: pillFrame.width,
                                height: pillFrame.height)
        guard let image = CGImage(windowListFromArrayScreenBounds: quartzRect, windowArray: [windowID], imageOption: .bestResolution) else {
            return nil
        }
        // NSBitmapImageRep is the reliable AppKit route to raw pixels
        // (CGDataProvider bridging varies by SDK); bitmapData may be
        // nil for planar formats, in which case there is no sample.
        let rep = NSBitmapImageRep(cgImage: image)
        guard let ptr = rep.bitmapData else {
            return nil
        }
        let width = rep.pixelsWide
        let height = rep.pixelsHigh
        let bytesPerRow = rep.bytesPerRow
        let bytesPerPixel = rep.bitsPerPixel / 8
        guard bytesPerPixel >= 3, width > 1, height > 0 else { return nil }
        var varied = 0
        for y in 0..<height {
            let row = ptr + y * bytesPerRow
            for x in 1..<width {
                let off = x * bytesPerPixel
                let prev = off - bytesPerPixel
                // Ignore fully transparent pixels (window does not
                // actually cover that point, e.g. rounded corners).
                if bytesPerPixel >= 4, row[off + 3] == 0 { continue }
                var maxDiff = 0
                for c in 0..<3 {
                    let d = abs(Int(row[off + c]) - Int(row[prev + c]))
                    if d > maxDiff { maxDiff = d }
                }
                if maxDiff >= 14 { varied += 1 }
            }
        }
        return varied
    }

    static func check(pillFrame: NSRect) -> Result {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else {
            return Result(covered: false, ownerName: "", windowFrame: nil, variedPixels: nil)
        }
        let frontPID = frontmost.processIdentifier
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard frontPID != ownPID else {
            return Result(covered: false, ownerName: frontmost.localizedName ?? "", windowFrame: nil, variedPixels: nil)
        }
        guard let mainHeight = NSScreen.main?.frame.height,
              let list = CGWindowListCopyWindowInfo(
                  [.optionOnScreenOnly, .excludeDesktopElements],
                  kCGNullWindowID
              ) as? [[String: Any]] else {
            return Result(covered: false, ownerName: frontmost.localizedName ?? "", windowFrame: nil, variedPixels: nil)
        }
        let ownerName = frontmost.localizedName ?? ""
        let pillArea = pillFrame.width * pillFrame.height
        guard pillArea > 0 else {
            return Result(covered: false, ownerName: ownerName, windowFrame: nil, variedPixels: nil)
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
                // Frame overlap alone is not enough: a blank dark
                // header or solid background also overlaps, but it
                // is not content. Only hide when the pixels under
                // the pill actually vary (Nusa's test).
                guard let windowID = (win[kCGWindowNumber as String] as? NSNumber)?.uint32Value else {
                    return Result(covered: true, ownerName: ownerName, windowFrame: bounds, variedPixels: nil)
                }
                let varied = variedPixelCount(pillFrame: pillFrame, windowID: windowID, mainHeight: mainHeight)
                if let varied {
                    return Result(covered: varied >= 20, ownerName: ownerName, windowFrame: bounds, variedPixels: varied)
                }
                // No capture (Screen Recording permission missing):
                // do NOT hide, and let the log say why, instead of
                // silently falling back to frame-only hiding.
                return Result(covered: false, ownerName: ownerName, windowFrame: bounds, variedPixels: nil)
            }
        }
        return Result(covered: false, ownerName: ownerName, windowFrame: nil, variedPixels: nil)
    }
}
