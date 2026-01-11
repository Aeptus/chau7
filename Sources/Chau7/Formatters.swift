import Foundation

// MARK: - Shared Formatters (Code Optimization)
// Consolidates DateFormatter instances to avoid repeated initialization

enum Formatters {
    /// Short time format (e.g., "3:45 PM")
    static let shortTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()
}
