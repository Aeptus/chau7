import Foundation
import SwiftUI

// MARK: - Supported Languages

enum AppLanguage: String, CaseIterable, Identifiable, Codable {
    case system = "system"
    case english = "en"
    case french = "fr"
    case arabic = "ar"      // RTL language
    case hebrew = "he"      // RTL language

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
        case .arabic:
            return "العربية"
        case .hebrew:
            return "עברית"
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
        case .arabic:
            return Locale(identifier: "ar")
        case .hebrew:
            return Locale(identifier: "he")
        }
    }

    /// Returns true for right-to-left languages
    var isRTL: Bool {
        switch self {
        case .arabic, .hebrew:
            return true
        case .system:
            return Locale.current.language.characterDirection == .rightToLeft
        default:
            return false
        }
    }

    /// Returns the text direction for this language
    var layoutDirection: LayoutDirection {
        isRTL ? .rightToLeft : .leftToRight
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

// MARK: - RTL Support

extension LocalizationManager {
    /// Current layout direction based on selected language
    var layoutDirection: LayoutDirection {
        currentLanguage.layoutDirection
    }

    /// Whether the current language is RTL
    var isRTL: Bool {
        currentLanguage.isRTL
    }
}

/// View modifier that applies correct layout direction based on current language
struct LocalizedLayoutModifier: ViewModifier {
    @ObservedObject private var localization = LocalizationManager.shared

    func body(content: Content) -> some View {
        content
            .environment(\.layoutDirection, localization.layoutDirection)
    }
}

extension View {
    /// Applies correct layout direction for the current language (LTR or RTL)
    func localizedLayout() -> some View {
        modifier(LocalizedLayoutModifier())
    }

    /// Flips the view horizontally for RTL languages
    func flipForRTL() -> some View {
        scaleEffect(x: LocalizationManager.shared.isRTL ? -1 : 1, y: 1)
    }
}

// MARK: - Localized Formatters

/// Provides locale-aware formatters that respect the current language setting.
enum LocalizedFormatters {

    // MARK: - Date Formatters

    /// Short date format localized to current language (e.g., "1/12/24" or "12/1/24")
    static var shortDate: DateFormatter {
        let f = DateFormatter()
        f.locale = LocalizationManager.shared.currentLanguage.locale
        f.dateStyle = .short
        f.timeStyle = .none
        return f
    }

    /// Medium date format localized (e.g., "Jan 12, 2024" or "12 janv. 2024")
    static var mediumDate: DateFormatter {
        let f = DateFormatter()
        f.locale = LocalizationManager.shared.currentLanguage.locale
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }

    /// Long date format localized (e.g., "January 12, 2024")
    static var longDate: DateFormatter {
        let f = DateFormatter()
        f.locale = LocalizationManager.shared.currentLanguage.locale
        f.dateStyle = .long
        f.timeStyle = .none
        return f
    }

    /// Short time format localized (e.g., "3:45 PM" or "15:45")
    static var shortTime: DateFormatter {
        let f = DateFormatter()
        f.locale = LocalizationManager.shared.currentLanguage.locale
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }

    /// Medium time format localized (e.g., "3:45:30 PM")
    static var mediumTime: DateFormatter {
        let f = DateFormatter()
        f.locale = LocalizationManager.shared.currentLanguage.locale
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }

    /// Date and time format localized
    static var dateTime: DateFormatter {
        let f = DateFormatter()
        f.locale = LocalizationManager.shared.currentLanguage.locale
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }

    /// Relative date formatter (e.g., "yesterday", "2 days ago")
    static var relative: RelativeDateTimeFormatter {
        let f = RelativeDateTimeFormatter()
        f.locale = LocalizationManager.shared.currentLanguage.locale
        f.unitsStyle = .abbreviated
        return f
    }

    // MARK: - Number Formatters

    /// Decimal number formatter localized (respects decimal separator)
    static var decimal: NumberFormatter {
        let f = NumberFormatter()
        f.locale = LocalizationManager.shared.currentLanguage.locale
        f.numberStyle = .decimal
        return f
    }

    /// Percentage formatter localized
    static var percent: NumberFormatter {
        let f = NumberFormatter()
        f.locale = LocalizationManager.shared.currentLanguage.locale
        f.numberStyle = .percent
        f.maximumFractionDigits = 1
        return f
    }

    /// File size formatter (e.g., "1.5 MB", "2 Ko")
    static var fileSize: ByteCountFormatter {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }

    /// Integer formatter with grouping (e.g., "1,234" or "1 234")
    static var integer: NumberFormatter {
        let f = NumberFormatter()
        f.locale = LocalizationManager.shared.currentLanguage.locale
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }

    // MARK: - Convenience Methods

    /// Formats a date using the short date format for current locale
    static func formatShortDate(_ date: Date) -> String {
        shortDate.string(from: date)
    }

    /// Formats a date using the medium date format for current locale
    static func formatMediumDate(_ date: Date) -> String {
        mediumDate.string(from: date)
    }

    /// Formats a time using the short time format for current locale
    static func formatShortTime(_ date: Date) -> String {
        shortTime.string(from: date)
    }

    /// Formats a date and time for current locale
    static func formatDateTime(_ date: Date) -> String {
        dateTime.string(from: date)
    }

    /// Formats a relative date (e.g., "2 hours ago")
    static func formatRelative(_ date: Date) -> String {
        relative.localizedString(for: date, relativeTo: Date())
    }

    /// Formats a number with locale-appropriate decimal separator
    static func formatDecimal(_ number: Double) -> String {
        decimal.string(from: NSNumber(value: number)) ?? String(number)
    }

    /// Formats a number as a percentage
    static func formatPercent(_ value: Double) -> String {
        percent.string(from: NSNumber(value: value)) ?? "\(Int(value * 100))%"
    }

    /// Formats bytes as human-readable file size
    static func formatFileSize(_ bytes: Int64) -> String {
        fileSize.string(fromByteCount: bytes)
    }

    /// Formats an integer with locale-appropriate grouping
    static func formatInteger(_ number: Int) -> String {
        integer.string(from: NSNumber(value: number)) ?? String(number)
    }
}
