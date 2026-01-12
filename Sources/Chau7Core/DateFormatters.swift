import Foundation

public enum DateFormatters {
    /// Shared ISO8601 formatter with fractional seconds.
    public static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Formats current date as ISO8601 string.
    public static func nowISO8601() -> String {
        iso8601.string(from: Date())
    }
}
