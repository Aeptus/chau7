import Foundation

/// Manages minimal mode, which hides non-essential UI chrome to maximize
/// terminal real estate. When enabled, hides:
/// - Tab bar (when single tab)
/// - Title bar accessories
/// - Status bar / overlay widgets
/// - Sidebar (if open)
/// Can be toggled via keyboard shortcut (Cmd+Shift+M) or menu item.
@MainActor
@Observable
final class MinimalMode {
    static let shared = MinimalMode()

    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "feature.minimalMode")
            Log.info("Minimal mode: \(isEnabled ? "enabled" : "disabled")")
            NotificationCenter.default.post(name: .minimalModeChanged, object: nil)
        }
    }

    /// Which elements are hidden in minimal mode
    var hideTabBar: Bool {
        didSet { UserDefaults.standard.set(hideTabBar, forKey: "minimal.hideTabBar") }
    }

    var hideTitleBar: Bool {
        didSet { UserDefaults.standard.set(hideTitleBar, forKey: "minimal.hideTitleBar") }
    }

    var hideStatusBar: Bool {
        didSet { UserDefaults.standard.set(hideStatusBar, forKey: "minimal.hideStatusBar") }
    }

    var hideSidebar: Bool {
        didSet { UserDefaults.standard.set(hideSidebar, forKey: "minimal.hideSidebar") }
    }

    private init() {
        let defaults = UserDefaults.standard
        self.isEnabled = defaults.bool(forKey: "feature.minimalMode")
        self.hideTabBar = defaults.object(forKey: "minimal.hideTabBar") as? Bool ?? true
        self.hideTitleBar = defaults.object(forKey: "minimal.hideTitleBar") as? Bool ?? true
        self.hideStatusBar = defaults.object(forKey: "minimal.hideStatusBar") as? Bool ?? true
        self.hideSidebar = defaults.object(forKey: "minimal.hideSidebar") as? Bool ?? true
    }

    func toggle() {
        isEnabled.toggle()
    }
}

extension Notification.Name {
    static let minimalModeChanged = Notification.Name("com.chau7.minimalModeChanged")
}
