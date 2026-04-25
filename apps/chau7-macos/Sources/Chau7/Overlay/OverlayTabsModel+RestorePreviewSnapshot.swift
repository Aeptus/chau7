import AppKit
import Foundation

/// Bitmap snapshot helpers used by the restore-preview pipeline on
/// `OverlayTabsModel`. Five concerns:
///
///   - `snapshotSurface(for:)` — walks an NSView hierarchy to find the
///     `UnifiedTerminalContainerView` / `RustTerminalContainerView` /
///     `RustTerminalView` that owns the live pixels for a tab. Returns
///     the input view if no terminal-specific container is found.
///
///   - `isSnapshotSurfaceReady(_:)` — checks whether the resolved
///     surface has a non-hidden Rust terminal view. We only want to
///     capture pixels when the renderer has produced something visible.
///
///   - `captureSnapshotImage(from:allowForcedTerminalSync:)` — produces
///     an `NSImage` either from the Rust terminal's retained-frame fast
///     path or, as a fallback, by calling `cacheDisplay(in:to:)` on the
///     snapshot view's bitmap representation. The Rust path is a couple
///     of orders of magnitude faster on a hot tab.
///
///   - `pngData(from:)` / `restorePreviewImage(from:)` — round-trips
///     `NSImage` ↔ PNG `Data` so the snapshot can be persisted into
///     `SavedTerminalPaneState.previewSnapshotPNGData` and decoded
///     back on next launch.
///
/// Pure statics; no instance state. Extracted from the main
/// `OverlayTabsModel.swift` so the bitmap-capture concern lives next to
/// its sibling tab-switch optimization helpers, not interleaved with
/// tab-state serialization.
extension OverlayTabsModel {

    private static func snapshotSurface(for view: NSView) -> NSView {
        if let unified = view as? UnifiedTerminalContainerView {
            return unified
        }
        if let container = view as? RustTerminalContainerView {
            return container
        }
        if let container = view.superview as? RustTerminalContainerView {
            return container
        }
        if let unified = view.superview as? UnifiedTerminalContainerView {
            return unified
        }
        if let unified = view.superview?.superview as? UnifiedTerminalContainerView {
            return unified
        }
        return view
    }

    private static func isSnapshotSurfaceReady(_ view: NSView) -> Bool {
        if let unified = view as? UnifiedTerminalContainerView {
            return !(unified.rustTerminalView?.isHidden ?? true)
        }
        if let container = view as? RustTerminalContainerView {
            guard let terminalView = container.terminalView else { return false }
            return !terminalView.isHidden
        }
        return !view.isHidden
    }

    static func captureSnapshotImage(from view: NSView, allowForcedTerminalSync: Bool = false) -> NSImage? {
        if let rustView = view as? RustTerminalView {
            return rustView.makeRetainedFrameImage(allowForcedSync: allowForcedTerminalSync)
        }
        if let unified = view as? UnifiedTerminalContainerView,
           let rustView = unified.rustTerminalView {
            return rustView.makeRetainedFrameImage(allowForcedSync: allowForcedTerminalSync)
        }
        if let container = view as? RustTerminalContainerView,
           let rustView = container.terminalView {
            return rustView.makeRetainedFrameImage(allowForcedSync: allowForcedTerminalSync)
        }
        let snapshotView = snapshotSurface(for: view)
        guard isSnapshotSurfaceReady(snapshotView) else {
            return nil
        }
        snapshotView.layoutSubtreeIfNeeded()
        guard snapshotView.bounds.width > 0,
              snapshotView.bounds.height > 0,
              let bitmapRep = snapshotView.bitmapImageRepForCachingDisplay(in: snapshotView.bounds) else {
            return nil
        }
        snapshotView.cacheDisplay(in: snapshotView.bounds, to: bitmapRep)

        let image = NSImage(size: snapshotView.bounds.size)
        image.addRepresentation(bitmapRep)
        return image
    }

    static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }

    static func restorePreviewImage(from pngData: Data?) -> NSImage? {
        guard let pngData else { return nil }
        return NSImage(data: pngData)
    }
}
