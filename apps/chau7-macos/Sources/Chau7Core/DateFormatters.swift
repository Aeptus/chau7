import Foundation

public enum DateFormatters {
    /// Shared ISO8601 formatter with fractional seconds.
    ///
    /// `nonisolated(unsafe)` is a statement, not a suppression: `ISO8601DateFormatter`
    /// is a `Formatter`, and the Foundation formatters are documented as safe for
    /// concurrent *use* on Apple platforms (only configuration after publication is
    /// unsafe). These two are configured inside the initializer and never mutated
    /// again, so every later `string(from:)` / `date(from:)` is a read.
    ///
    /// The annotation is required because `Formatter` does not conform to `Sendable`,
    /// so under `StrictConcurrency` — which the pre-push gate compiles with
    /// `-warnings-as-errors` — a shared global of this type is a hard error. The
    /// alternative, a lock around every format call, would add contention to what is
    /// currently a lock-free read on hot transcript-parsing paths.
    public nonisolated(unsafe) static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Shared ISO8601 formatter without fractional seconds, for parsing
    /// timestamps produced by writers that omit them.
    ///
    /// See the note on `iso8601` for why this is safe to share.
    public nonisolated(unsafe) static let iso8601NoFractional: ISO8601DateFormatter = {
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
