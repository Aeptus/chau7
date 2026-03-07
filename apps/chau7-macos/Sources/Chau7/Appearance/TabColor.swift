import SwiftUI

enum TabColor: String, CaseIterable, Identifiable {
    case blue
    case teal
    case green
    case yellow
    case orange
    case pink
    case purple
    case gray

    var id: String {
        rawValue
    }

    var color: Color {
        switch self {
        case .blue:
            return Color(red: 0.25, green: 0.55, blue: 0.95)
        case .teal:
            return Color(red: 0.20, green: 0.70, blue: 0.70)
        case .green:
            return Color(red: 0.25, green: 0.75, blue: 0.40)
        case .yellow:
            return Color(red: 0.95, green: 0.80, blue: 0.25)
        case .orange:
            return Color(red: 0.95, green: 0.55, blue: 0.25)
        case .pink:
            return Color(red: 0.95, green: 0.45, blue: 0.70)
        case .purple:
            return Color(red: 0.65, green: 0.45, blue: 0.90)
        case .gray:
            return Color(red: 0.70, green: 0.70, blue: 0.72)
        }
    }
}
