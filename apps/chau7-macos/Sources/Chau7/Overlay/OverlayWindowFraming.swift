import AppKit
import Foundation

/// Pure-function helpers for keeping overlay windows on-screen.
///
/// Bug #92 ("input line clipped at bottom of screen") was caused by the
/// overlay window extending below `NSScreen.visibleFrame.minY` (under the
/// dock or off-screen). The terminal grid renders all rows correctly, but
/// macOS clips the bottom slice of the window to the screen-visible region,
/// chopping the bottom row's lower half. The fix is to clamp window frames
/// to the containing screen's `visibleFrame` on resize, drag, and screen-
/// configuration change.
///
/// The clamp is exposed as a static pure function so it can be unit-tested
/// without standing up an `NSWindow`.
enum OverlayWindowFraming {
    /// Clamps `proposed` so it fits entirely within `visibleFrame`.
    ///
    /// Strategy:
    ///   1. Cap size at `visibleFrame.size` so the window cannot be larger
    ///      than the screen's usable area.
    ///   2. Shift origin so no edge extends past the corresponding
    ///      `visibleFrame` edge. The shift never grows the rect — it only
    ///      slides it back into bounds.
    ///
    /// This is idempotent: calling it twice produces the same result as
    /// calling it once.
    static func clampedFrame(proposed: NSRect, in visibleFrame: NSRect) -> NSRect {
        var rect = proposed
        rect.size.width = min(rect.size.width, visibleFrame.width)
        rect.size.height = min(rect.size.height, visibleFrame.height)
        if rect.maxX > visibleFrame.maxX {
            rect.origin.x = visibleFrame.maxX - rect.size.width
        }
        if rect.origin.x < visibleFrame.minX {
            rect.origin.x = visibleFrame.minX
        }
        if rect.maxY > visibleFrame.maxY {
            rect.origin.y = visibleFrame.maxY - rect.size.height
        }
        if rect.origin.y < visibleFrame.minY {
            rect.origin.y = visibleFrame.minY
        }
        return rect
    }
}
