import AppKit

enum AppIcon {
    /// Loads the app icon from bundle or Resources folder.
    /// Returns nil if not found.
    static func loadFromFile() -> NSImage? {
        // Try bundle first (for .app builds)
        if let url = Bundle.main.url(forResource: "AppDockIcon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }

        // For debug builds, look relative to executable location
        // .build/debug/Chau7 -> ../../Resources/AppDockIcon.png
        let executableURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let debugResourcesURL = executableURL
            .deletingLastPathComponent()  // .build/debug
            .deletingLastPathComponent()  // .build
            .deletingLastPathComponent()  // project root
            .appendingPathComponent("Resources/AppDockIcon.png")

        if FileManager.default.fileExists(atPath: debugResourcesURL.path),
           let image = NSImage(contentsOf: debugResourcesURL) {
            return image
        }

        return nil
    }

    /// Generates a fallback icon programmatically.
    static func generateFallback() -> NSImage {
        let size = NSSize(width: 256, height: 256)
        let image = NSImage(size: size)

        image.lockFocus()
        defer { image.unlockFocus() }

        let rect = NSRect(origin: .zero, size: size)
        NSColor(calibratedWhite: 0.06, alpha: 1.0).setFill()
        rect.fill()

        let insetRect = rect.insetBy(dx: 24, dy: 24)
        let background = NSBezierPath(roundedRect: insetRect, xRadius: 48, yRadius: 48)
        NSColor(calibratedRed: 0.10, green: 0.54, blue: 0.62, alpha: 1.0).setFill()
        background.fill()

        let bellRect = NSRect(x: 72, y: 86, width: 112, height: 104)
        let bellPath = NSBezierPath(roundedRect: bellRect, xRadius: 28, yRadius: 28)
        NSColor.white.setFill()
        bellPath.fill()

        let clapperRect = NSRect(x: 112, y: 60, width: 32, height: 32)
        let clapperPath = NSBezierPath(ovalIn: clapperRect)
        NSColor.white.setFill()
        clapperPath.fill()

        let baseRect = NSRect(x: 96, y: 72, width: 64, height: 12)
        let basePath = NSBezierPath(roundedRect: baseRect, xRadius: 6, yRadius: 6)
        NSColor.white.setFill()
        basePath.fill()

        return image
    }

    /// Loads icon from file or generates fallback.
    static func load() -> NSImage {
        loadFromFile() ?? generateFallback()
    }

    /// Applies the app icon to the dock.
    static func apply() {
        let image = load()
        NSApplication.shared.applicationIconImage = image
        if loadFromFile() != nil {
            Log.info("Loaded dock icon from file.")
        }
    }
}
