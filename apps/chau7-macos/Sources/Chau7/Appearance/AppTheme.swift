import Foundation

enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .system:
            return L("theme.system", "System")
        case .light:
            return L("theme.light", "Light")
        case .dark:
            return L("theme.dark", "Dark")
        }
    }
}
