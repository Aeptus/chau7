import Foundation

public enum DateFormatters {
    /// Shared ISO8601 formatter with fractional seconds.
    public static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Shared ISO8601 formatter without fractional seconds, for parsing
    /// timestamps produced by writers that omit them.
    public static let iso8601NoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Formats current date as ISO8601 string.
    public static func nowISO8601() -> String {
        iso8601.string(from: Date())
    }

    /// Parses an ISO8601 string with or without fractional seconds.
    public static func parseISO8601(_ string: String) -> Date? {
        iso8601.date(from: string) ?? iso8601NoFractional.date(from: string)
    }
}
