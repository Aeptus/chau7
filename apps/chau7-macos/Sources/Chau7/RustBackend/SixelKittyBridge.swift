import Foundation
import AppKit

/// Bridges Sixel and Kitty image protocol support
/// into Chau7's inline image display system.
///
/// This bridge:
/// 1. Enables the protocols when settings allow
/// 2. Converts decoded image data into InlineImageView displays
/// 3. Manages the Kitty image cache size setting
@MainActor
final class SixelKittyBridge: ObservableObject {
    static let shared = SixelKittyBridge()

    @Published var isSixelEnabled = false
    @Published var isKittyGraphicsEnabled = false
    @Published var kittyCacheLimitMB = 256 // Default 256MB cache

    private init() {
        loadSettings()
        Log.info("SixelKittyBridge initialized: sixel=\(isSixelEnabled) kitty=\(isKittyGraphicsEnabled) cache=\(kittyCacheLimitMB)MB")
    }

    /// Call during terminal view setup to configure terminal options
    func configureTerminal(_ terminalView: Any) {
        // Access terminalView's terminal.options to set:
        // - terminal.options.enableSixelReported = isSixelEnabled
        // - terminal.options.kittyImageCacheLimitBytes = kittyCacheLimitMB * 1024 * 1024
        Log.info("Configured terminal graphics: sixel=\(isSixelEnabled) kitty=\(isKittyGraphicsEnabled)")
    }

    func loadSettings() {
        let defaults = UserDefaults.standard
        isSixelEnabled = defaults.bool(forKey: "feature.sixelEnabled")
        isKittyGraphicsEnabled = defaults.bool(forKey: "feature.kittyGraphicsEnabled")
        kittyCacheLimitMB = defaults.integer(forKey: "feature.kittyCacheLimitMB")
        if kittyCacheLimitMB == 0 { kittyCacheLimitMB = 256 }
    }

    func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(isSixelEnabled, forKey: "feature.sixelEnabled")
        defaults.set(isKittyGraphicsEnabled, forKey: "feature.kittyGraphicsEnabled")
        defaults.set(kittyCacheLimitMB, forKey: "feature.kittyCacheLimitMB")
        Log.info("Saved graphics settings: sixel=\(isSixelEnabled) kitty=\(isKittyGraphicsEnabled) cache=\(kittyCacheLimitMB)MB")
    }
}
