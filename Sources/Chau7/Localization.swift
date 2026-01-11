import Foundation
import SwiftUI

// MARK: - Supported Languages

enum AppLanguage: String, CaseIterable, Identifiable, Codable {
    case system = "system"
    case english = "en"
    case french = "fr"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system:
            // Use our L() function for consistency with custom bundle
            return L("language.system", "System Default")
        case .english:
            return "English"
        case .french:
            return "Français"
        }
    }

    var locale: Locale {
        switch self {
        case .system:
            return .current
        case .english:
            return Locale(identifier: "en")
        case .french:
            return Locale(identifier: "fr")
        }
    }

    /// Returns the bundle for this language, or nil for system default
    var bundle: Bundle? {
        guard self != .system else { return nil }
        guard let path = Bundle.main.path(forResource: rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return nil
        }
        return bundle
    }
}

// MARK: - Localization Manager

final class LocalizationManager: ObservableObject {
    static let shared = LocalizationManager()

    @Published var currentLanguage: AppLanguage {
        didSet {
            UserDefaults.standard.set(currentLanguage.rawValue, forKey: "appLanguage")
            updateBundle()
            NotificationCenter.default.post(name: .languageDidChange, object: nil)
        }
    }

    private(set) var bundle: Bundle

    private init() {
        let savedLanguage = UserDefaults.standard.string(forKey: "appLanguage") ?? "system"
        self.currentLanguage = AppLanguage(rawValue: savedLanguage) ?? .system
        self.bundle = Bundle.main
        updateBundle()
    }

    private func updateBundle() {
        if let languageBundle = currentLanguage.bundle {
            bundle = languageBundle
        } else {
            // System default - use preferred language
            let preferredLanguage = Bundle.main.preferredLocalizations.first ?? "en"
            if let path = Bundle.main.path(forResource: preferredLanguage, ofType: "lproj"),
               let preferredBundle = Bundle(path: path) {
                bundle = preferredBundle
            } else {
                bundle = Bundle.main
            }
        }
    }

    func localizedString(_ key: String, defaultValue: String = "") -> String {
        let value = bundle.localizedString(forKey: key, value: nil, table: nil)
        if value == key && !defaultValue.isEmpty {
            return defaultValue
        }
        return value
    }
}

// MARK: - Notification

extension Notification.Name {
    static let languageDidChange = Notification.Name("languageDidChange")
}

// MARK: - Localized String Helper

/// Convenience function for localized strings
func L(_ key: String, _ defaultValue: String = "") -> String {
    LocalizationManager.shared.localizedString(key, defaultValue: defaultValue)
}

/// Convenience function for localized strings with arguments
func L(_ key: String, _ defaultValue: String = "", _ args: CVarArg...) -> String {
    let format = LocalizationManager.shared.localizedString(key, defaultValue: defaultValue)
    return String(format: format, arguments: args)
}

// MARK: - SwiftUI Text Extension

extension Text {
    /// Creates a localized Text view
    init(localized key: String, defaultValue: String = "") {
        self.init(L(key, defaultValue))
    }
}

// MARK: - String Extension for Localization

extension String {
    /// Returns the localized version of this string
    var localized: String {
        L(self, self)
    }

    /// Returns the localized version with format arguments
    func localized(_ args: CVarArg...) -> String {
        let format = L(self, self)
        return String(format: format, arguments: args)
    }
}
