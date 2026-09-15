import Foundation

enum RegionalNumberFormat: String, CaseIterable, Identifiable {
    case french = "fr"
    case european = "eu"
    case unitedStates = "us"

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .french:
            return "French"
        case .european:
            return "European"
        case .unitedStates:
            return "US"
        }
    }

    var example: String {
        switch self {
        case .french:
            return "1 234,56"
        case .european:
            return "1.234,56"
        case .unitedStates:
            return "1,234.56"
        }
    }

    var locale: Locale {
        switch self {
        case .french:
            return Locale(identifier: "fr_FR")
        case .european:
            return Locale(identifier: "de_DE")
        case .unitedStates:
            return Locale(identifier: "en_US")
        }
    }
}
