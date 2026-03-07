import Foundation
import AppKit

/// Imports profiles from Terminal.app and iTerm2 into Chau7.
/// Reads Terminal.app preferences from ~/Library/Preferences/com.apple.Terminal.plist
/// Reads iTerm2 preferences from ~/Library/Preferences/com.googlecode.iterm2.plist
@MainActor
final class TerminalMigrationWizard: ObservableObject {
    @Published var detectedProfiles: [ImportableProfile] = []
    @Published var importStatus: ImportStatus = .idle
    @Published var importErrors: [String] = []

    enum ImportStatus {
        case idle, scanning, importing, complete, failed
    }

    init() {
        Log.info("TerminalMigrationWizard initialized")
    }

    // MARK: - Detection

    func scanForProfiles() {
        importStatus = .scanning
        detectedProfiles = []

        // Scan Terminal.app
        detectedProfiles.append(contentsOf: scanTerminalApp())

        // Scan iTerm2
        detectedProfiles.append(contentsOf: scanITerm2())

        importStatus = detectedProfiles.isEmpty ? .failed : .idle
        Log.info("TerminalMigrationWizard: found \(detectedProfiles.count) profiles")
    }

    // MARK: - Terminal.app Import

    private func scanTerminalApp() -> [ImportableProfile] {
        let plistPath = NSHomeDirectory() + "/Library/Preferences/com.apple.Terminal.plist"
        guard let plist = NSDictionary(contentsOfFile: plistPath) as? [String: Any] else {
            Log.info("TerminalMigrationWizard: no Terminal.app plist found")
            return []
        }

        guard let profiles = plist["Window Settings"] as? [String: [String: Any]] else {
            return []
        }

        return profiles.compactMap { name, settings -> ImportableProfile? in
            var profile = ImportableProfile(name: name, source: .terminalApp)

            // Font
            if let fontData = settings["Font"] as? Data,
               let font = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSFont.self, from: fontData) {
                profile.fontFamily = font.familyName ?? "Menlo"
                profile.fontSize = Int(font.pointSize)
            }

            // Colors
            if let bgData = settings["BackgroundColor"] as? Data,
               let bg = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: bgData) {
                profile.backgroundColor = bg.hexString
            }
            if let fgData = settings["TextColor"] as? Data,
               let fg = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: fgData) {
                profile.foregroundColor = fg.hexString
            }

            // Cursor
            if let cursorType = settings["CursorType"] as? Int {
                switch cursorType {
                case 0: profile.cursorStyle = "block"
                case 1: profile.cursorStyle = "underline"
                case 2: profile.cursorStyle = "bar"
                default: break
                }
            }

            // Window size
            if let cols = settings["columnCount"] as? Int { profile.columns = cols }
            if let rows = settings["rowCount"] as? Int { profile.rows = rows }

            // Shell
            if let shell = settings["CommandString"] as? String { profile.shell = shell }

            Log.info("TerminalMigrationWizard: found Terminal.app profile '\(name)'")
            return profile
        }
    }

    // MARK: - iTerm2 Import

    private func scanITerm2() -> [ImportableProfile] {
        let plistPath = NSHomeDirectory() + "/Library/Preferences/com.googlecode.iterm2.plist"
        guard let plist = NSDictionary(contentsOfFile: plistPath) as? [String: Any],
              let bookmarks = plist["New Bookmarks"] as? [[String: Any]] else {
            Log.info("TerminalMigrationWizard: no iTerm2 plist found")
            return []
        }

        return bookmarks.compactMap { settings -> ImportableProfile? in
            guard let name = settings["Name"] as? String else { return nil }
            var profile = ImportableProfile(name: name, source: .iterm2)

            // Font
            if let fontName = settings["Normal Font"] as? String {
                // iTerm2 stores font as "FontName Size"
                let parts = fontName.split(separator: " ")
                if parts.count >= 2 {
                    profile.fontFamily = parts.dropLast().joined(separator: " ")
                    profile.fontSize = Int(parts.last ?? "13") ?? 13
                }
            }

            // Colors (iTerm2 uses component dictionaries)
            if let bg = settings["Background Color"] as? [String: Any] {
                profile.backgroundColor = colorFromiTermDict(bg)
            }
            if let fg = settings["Foreground Color"] as? [String: Any] {
                profile.foregroundColor = colorFromiTermDict(fg)
            }

            // Shell
            if let cmd = settings["Command"] as? String { profile.shell = cmd }
            if let dir = settings["Working Directory"] as? String { profile.directory = dir }

            Log.info("TerminalMigrationWizard: found iTerm2 profile '\(name)'")
            return profile
        }
    }

    private func colorFromiTermDict(_ dict: [String: Any]) -> String? {
        guard let r = dict["Red Component"] as? Double,
              let g = dict["Green Component"] as? Double,
              let b = dict["Blue Component"] as? Double else { return nil }
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }

    // MARK: - Import

    func importProfile(_ profile: ImportableProfile) {
        importStatus = .importing

        let settings = FeatureSettings.shared

        // Save original settings
        let originalFont = settings.fontFamily
        let originalSize = settings.fontSize
        let originalCursor = settings.cursorStyle

        // Apply profile values temporarily for createProfile snapshot
        if let font = profile.fontFamily { settings.fontFamily = font }
        if let size = profile.fontSize { settings.fontSize = size }
        if let cursor = profile.cursorStyle { settings.cursorStyle = cursor }

        _ = settings.createProfile(name: "Imported: \(profile.name)")

        // Restore original settings
        settings.fontFamily = originalFont
        settings.fontSize = originalSize
        settings.cursorStyle = originalCursor

        importStatus = .complete
        Log.info("TerminalMigrationWizard: imported '\(profile.name)' from \(profile.source.displayName)")
    }

    func importProfiles(_ profiles: [ImportableProfile]) {
        importStatus = .importing
        importErrors = []

        let settings = FeatureSettings.shared

        // Save original settings so we can restore after import
        let originalFont = settings.fontFamily
        let originalSize = settings.fontSize
        let originalCursor = settings.cursorStyle

        for profile in profiles {
            // Apply profile values temporarily for createProfile snapshot
            if let font = profile.fontFamily { settings.fontFamily = font }
            if let size = profile.fontSize { settings.fontSize = size }
            if let cursor = profile.cursorStyle { settings.cursorStyle = cursor }

            _ = settings.createProfile(name: "Imported: \(profile.name)")
            Log.info("TerminalMigrationWizard: imported '\(profile.name)' from \(profile.source.displayName)")

            // Reset to original before next iteration
            settings.fontFamily = originalFont
            settings.fontSize = originalSize
            settings.cursorStyle = originalCursor
        }

        importStatus = .complete
        Log.info("TerminalMigrationWizard: batch import complete (\(profiles.count) profiles)")
    }
}

// MARK: - Supporting Types

struct ImportableProfile: Identifiable {
    let id = UUID()
    let name: String
    let source: ProfileSource
    var fontFamily: String?
    var fontSize: Int?
    var backgroundColor: String?
    var foregroundColor: String?
    var cursorStyle: String?
    var columns: Int?
    var rows: Int?
    var shell: String?
    var directory: String?

    var summary: String {
        var parts: [String] = [source.displayName]
        if let font = fontFamily { parts.append(font) }
        if let size = fontSize { parts.append("\(size)pt") }
        return parts.joined(separator: " · ")
    }
}

enum ProfileSource: String {
    case terminalApp = "terminal"
    case iterm2

    var displayName: String {
        switch self {
        case .terminalApp: return "Terminal.app"
        case .iterm2: return "iTerm2"
        }
    }

    var icon: String {
        switch self {
        case .terminalApp: return "terminal"
        case .iterm2: return "rectangle.split.3x1"
        }
    }
}

extension NSColor {
    var hexString: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "#000000" }
        return String(
            format: "#%02X%02X%02X",
            Int(rgb.redComponent * 255),
            Int(rgb.greenComponent * 255),
            Int(rgb.blueComponent * 255)
        )
    }
}
