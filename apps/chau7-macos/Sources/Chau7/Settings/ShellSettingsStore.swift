import Chau7Core
import Foundation

/// Owns the shell configuration domain: shell selection, custom shell path,
/// startup command, and LS_COLORS injection.
///
/// Extracted from `FeatureSettings` (which forwards) following the
/// store-behind-facade pattern of the other settings domains.
@Observable
final class ShellSettingsStore {

    enum Keys {
        static let shellType = "terminal.shellType"
        static let customShellPath = "terminal.customShellPath"
        static let startupCommand = "terminal.startupCommand"
        static let lsColorsEnabled = "terminal.lsColorsEnabled"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var shellType: ShellType {
        didSet { defaults.set(shellType.rawValue, forKey: Keys.shellType) }
    }

    var customShellPath: String {
        didSet { defaults.set(customShellPath, forKey: Keys.customShellPath) }
    }

    var startupCommand: String {
        didSet { defaults.set(startupCommand, forKey: Keys.startupCommand) }
    }

    var isLsColorsEnabled: Bool {
        didSet { defaults.set(isLsColorsEnabled, forKey: Keys.lsColorsEnabled) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let shellRaw = defaults.string(forKey: Keys.shellType),
           let shell = ShellType(rawValue: shellRaw) {
            self.shellType = shell
        } else {
            self.shellType = .system
        }
        self.customShellPath = defaults.string(forKey: Keys.customShellPath) ?? ""
        self.startupCommand = defaults.string(forKey: Keys.startupCommand) ?? ""
        self.isLsColorsEnabled = defaults.object(forKey: Keys.lsColorsEnabled) as? Bool ?? true
    }

    /// Reset by deriving from the loader (single source of defaults).
    func resetToDefaults() {
        for key in [Keys.shellType, Keys.customShellPath, Keys.startupCommand, Keys.lsColorsEnabled] {
            defaults.removeObject(forKey: key)
        }
        let fresh = ShellSettingsStore(defaults: defaults)
        shellType = fresh.shellType
        customShellPath = fresh.customShellPath
        startupCommand = fresh.startupCommand
        isLsColorsEnabled = fresh.isLsColorsEnabled
    }
}
