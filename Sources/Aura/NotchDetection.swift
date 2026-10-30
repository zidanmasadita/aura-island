import AppKit

/// Hardware-notch geometry for the screen Aura lives on, from public
/// AppKit APIs only (the same signals DynamicNotch reads, implemented
/// here from scratch — no DynamicNotch code).
///
/// - `hasNotch` is true when the screen reports a top safe-area inset
///   or a measurable gap between its two auxiliary top areas.
/// - `width`/`height` come from the auxiliary top areas (macOS 12+):
///   the notch is whatever is left between the left and right menu-bar
///   areas. On a notchless screen both are 0.
/// - Detection follows the pill's target display (the pinned display,
///   or the active monitor), so a notchless external monitor still
///   gets the floating pill, and a notched built-in gets the merged
///   layout. It is re-read on every call, so a screen change is
///   picked up the next time the window is placed or resized.
/// - Debug preview on a notchless Mac: `defaults write
///   com.aura.island AuraForceNotch -bool true` then relaunch. The
///   fallback size (200x32, a typical 14-inch MacBook Pro notch,
///   estimate) is only used when the hardware reports no notch.
struct HardwareNotch {
    let hasNotch: Bool
    let width: CGFloat
    let height: CGFloat

    static func forPillScreen() -> HardwareNotch {
        guard let screen = IslandWindow.targetScreen() else {
            return HardwareNotch(hasNotch: false, width: 0, height: 0)
        }
        return forScreen(screen)
    }

    static func forScreen(_ screen: NSScreen) -> HardwareNotch {
        if let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let width = screen.frame.width - (left.width + right.width)
            if width > 0 {
                return HardwareNotch(hasNotch: true, width: width, height: left.height)
            }
        }
        if screen.safeAreaInsets.top > 0 {
            return HardwareNotch(hasNotch: true, width: 0, height: screen.safeAreaInsets.top)
        }
        if UserDefaults.standard.bool(forKey: "AuraForceNotch") {
            return HardwareNotch(hasNotch: true, width: 200, height: 32)
        }
        return HardwareNotch(hasNotch: false, width: 0, height: 0)
    }
}
