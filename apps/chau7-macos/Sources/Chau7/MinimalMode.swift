import Foundation

/// Manages minimal mode, which hides non-essential UI chrome to maximize
/// terminal real estate. When enabled, hides:
/// - Tab bar (when single tab)
/// - Title bar accessories
/// - Status bar / overlay widgets
/// - Sidebar (if open)
/// Can be toggled via keyboard shortcut (Cmd+Shift+M) or menu item.
@MainActor
final class MinimalMode: ObservableObject {
    static let shared = MinimalMode()

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "feature.minimalMode")
            Log.info("Minimal mode: \(isEnabled ? "enabled" : "disabled")")
            NotificationCenter.default.post(name: .minimalModeChanged, object: nil)
        }
    }

    /// Which elements are hidden in minimal mode
    @Published var hideTabBar: Bool {
        didSet { UserDefaults.standard.set(hideTabBar, forKey: "minimal.hideTabBar") }
    }
    @Published var hideTitleBar: Bool {
        didSet { UserDefaults.standard.set(hideTitleBar, forKey: "minimal.hideTitleBar") }
    }
    @Published var hideStatusBar: Bool {
        didSet { UserDefaults.standard.set(hideStatusBar, forKey: "minimal.hideStatusBar") }
    }
    @Published var hideSidebar: Bool {
        didSet { UserDefaults.standard.set(hideSidebar, forKey: "minimal.hideSidebar") }
    }

    private init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.bool(forKey: "feature.minimalMode")
        hideTabBar = defaults.object(forKey: "minimal.hideTabBar") as? Bool ?? true
        hideTitleBar = defaults.object(forKey: "minimal.hideTitleBar") as? Bool ?? true
        hideStatusBar = defaults.object(forKey: "minimal.hideStatusBar") as? Bool ?? true
        hideSidebar = defaults.object(forKey: "minimal.hideSidebar") as? Bool ?? true
    }

    func toggle() {
        isEnabled.toggle()
    }
}

extension Notification.Name {
    static let minimalModeChanged = Notification.Name("com.chau7.minimalModeChanged")
}
