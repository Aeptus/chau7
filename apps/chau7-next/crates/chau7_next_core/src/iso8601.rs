//! ISO 8601 timestamps with fractional seconds, plus the serde helpers that
//! reproduce how Swift's `Codable` writes `Date`, `UUID` and `Data`.
//!
//! Ports `apps/chau7-macos/Sources/Chau7Core/DateFormatters.swift`
//! (`DateFormatters.iso8601` and `nowISO8601()`). Other modules use
//! [`now_iso8601`] for log and event timestamps.
//!
//! The Swift formatter uses `[.withInternetDateTime, .withFractionalSeconds]`:
//! it writes `2025-01-14T12:30:45.123Z` (milliseconds, UTC) and only parses
//! strings that have both a fractional part and a time zone.

use chrono::{DateTime, SecondsFormat, Utc};
use regex::Regex;
use std::sync::OnceLock;

fn pattern() -> &'static Regex {
    static PATTERN: OnceLock<Regex> = OnceLock::new();
    PATTERN.get_or_init(|| {
        Regex::new(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+(?:Z|[+-]\d{2}:\d{2})$")
            .expect("valid ISO 8601 pattern")
    })
}

/// Format a date like Swift's shared formatter: UTC, milliseconds, `Z`.
pub fn format_iso8601(date: DateTime<Utc>) -> String {
    date.to_rfc3339_opts(SecondsFormat::Millis, true)
}

/// Parse a string the way Swift's shared formatter does. Returns `None` when
/// the fractional seconds or the time zone are missing, or the text is not a
/// valid date.
pub fn parse_iso8601(text: &str) -> Option<DateTime<Utc>> {
    if !pattern().is_match(text) {
        return None;
    }
    DateTime::parse_from_rfc3339(text)
        .ok()
        .map(|d| d.with_timezone(&Utc))
}

/// The current time as an ISO 8601 string with fractional seconds
/// (`DateFormatters.nowISO8601()`).
pub fn now_iso8601() -> String {
    format_iso8601(Utc::now())
}

/// Seconds between two dates as a float (`Date.timeIntervalSince`).
pub fn seconds_between(later: DateTime<Utc>, earlier: DateTime<Utc>) -> f64 {
    let delta = later - earlier;
    match delta.num_nanoseconds() {
        Some(ns) => ns as f64 / 1e9,
        None => delta.num_milliseconds() as f64 / 1e3,
    }
}

/// Add fractional seconds to a date (`Date.addingTimeInterval`).
pub fn adding_seconds(date: DateTime<Utc>, seconds: f64) -> DateTime<Utc> {
    date + chrono::Duration::nanoseconds((seconds * 1e9).round() as i64)
}

/// Unix seconds of Swift's reference date (2001-01-01T00:00:00Z).
const REFERENCE_DATE_UNIX: i64 = 978_307_200;

/// `Date` as Swift's default `JSONEncoder` writes it: a number of seconds
/// since 2001-01-01T00:00:00Z. Use with `#[serde(with = "...::reference_date")]`.
pub mod reference_date {
    use super::*;
    use serde::{Deserialize, Deserializer, Serialize, Serializer};

    pub fn to_seconds(date: DateTime<Utc>) -> f64 {
        (date.timestamp() - REFERENCE_DATE_UNIX) as f64
            + f64::from(date.timestamp_subsec_nanos()) / 1e9
    }

    pub fn from_seconds(seconds: f64) -> Option<DateTime<Utc>> {
        if !seconds.is_finite() {
            return None;
        }
        let whole = seconds.floor();
        let nanos = (((seconds - whole) * 1e9).round() as u32).min(999_999_999);
        DateTime::from_timestamp(whole as i64 + REFERENCE_DATE_UNIX, nanos)
    }

    pub fn serialize<S: Serializer>(date: &DateTime<Utc>, s: S) -> Result<S::Ok, S::Error> {
        to_seconds(*date).serialize(s)
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<DateTime<Utc>, D::Error> {
        let seconds = f64::deserialize(d)?;
        from_seconds(seconds).ok_or_else(|| serde::de::Error::custom("date out of range"))
    }
}

/// Optional [`reference_date`]; pair with
/// `skip_serializing_if = "Option::is_none"` (Swift omits nil optionals).
pub mod reference_date_opt {
    use super::*;
    use serde::{Deserialize, Deserializer, Serialize, Serializer};

    pub fn serialize<S: Serializer>(date: &Option<DateTime<Utc>>, s: S) -> Result<S::Ok, S::Error> {
        date.map(reference_date::to_seconds).serialize(s)
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Option<DateTime<Utc>>, D::Error> {
        match Option::<f64>::deserialize(d)? {
            None => Ok(None),
            Some(seconds) => reference_date::from_seconds(seconds)
                .map(Some)
                .ok_or_else(|| serde::de::Error::custom("date out of range")),
        }
    }
}

/// `Date` as `JSONEncoder.dateEncodingStrategy = .iso8601` writes it:
/// `2023-11-14T22:13:20Z`, whole seconds, no fraction.
pub mod iso8601_seconds {
    use super::*;
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(date: &DateTime<Utc>, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&date.to_rfc3339_opts(SecondsFormat::Secs, true))
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<DateTime<Utc>, D::Error> {
        let text = String::deserialize(d)?;
        let plain = Regex::new(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:Z|[+-]\d{2}:\d{2})$")
            .map_err(serde::de::Error::custom)?;
        if !plain.is_match(&text) {
            return Err(serde::de::Error::custom("invalid ISO 8601 date"));
        }
        DateTime::parse_from_rfc3339(&text)
            .map(|d| d.with_timezone(&Utc))
            .map_err(serde::de::Error::custom)
    }
}

/// `UUID` as Swift writes it: uppercase hyphenated. Reading accepts both cases.
pub mod uuid_upper {
    use serde::{Deserialize, Deserializer, Serializer};
    use uuid::Uuid;

    pub fn serialize<S: Serializer>(id: &Uuid, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&id.hyphenated().to_string().to_uppercase())
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Uuid, D::Error> {
        let text = String::deserialize(d)?;
        Uuid::parse_str(&text).map_err(serde::de::Error::custom)
    }
}

/// `Data` as Swift's default coder writes it: a standard base64 string.
pub mod data_base64 {
    use base64::Engine;
    use base64::engine::general_purpose::STANDARD;
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(bytes: &[u8], s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&STANDARD.encode(bytes))
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Vec<u8>, D::Error> {
        let text = String::deserialize(d)?;
        STANDARD.decode(text).map_err(serde::de::Error::custom)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn unix(seconds: f64) -> DateTime<Utc> {
        adding_seconds(Utc.timestamp_opt(0, 0).unwrap(), seconds)
    }

    #[test]
    fn iso8601_formatter_parses_date_with_fractional_seconds() {
        assert!(parse_iso8601("2025-01-14T12:30:45.123Z").is_some());
    }

    #[test]
    fn iso8601_formatter_formats_date_with_fractional_seconds() {
        let formatted = format_iso8601(unix(1_736_856_000.0));
        assert!(formatted.contains("2025-01-14"));
        assert!(formatted.contains('T'));
        assert!(formatted.ends_with('Z'));
        assert!(formatted.contains('.'));
        assert_eq!(formatted, "2025-01-14T12:00:00.000Z");
    }

    #[test]
    fn iso8601_formatter_round_trip() {
        let original = unix(1_736_856_000.456);
        let formatted = format_iso8601(original);
        let parsed = parse_iso8601(&formatted).expect("parses");
        assert!(seconds_between(parsed, original).abs() < 0.01);
    }

    #[test]
    fn iso8601_formatter_rejects_invalid_string() {
        assert!(parse_iso8601("not a date").is_none());
    }

    #[test]
    fn iso8601_formatter_rejects_date_without_timezone() {
        assert!(parse_iso8601("2025-01-14T12:00:00").is_none());
    }

    #[test]
    fn now_iso8601_returns_valid_iso8601_string() {
        let result = now_iso8601();
        assert!(parse_iso8601(&result).is_some());
    }

    #[test]
    fn now_iso8601_is_recent() {
        let date = parse_iso8601(&now_iso8601()).unwrap();
        assert!(seconds_between(Utc::now(), date).abs() < 2.0);
    }

    #[test]
    fn now_iso8601_contains_expected_format() {
        let result = now_iso8601();
        assert!(result.contains('T'));
        assert!(result.ends_with('Z'));
        assert!(result.contains('.'));
    }

    #[test]
    fn iso8601_formatter_is_singleton() {
        // The compiled pattern is shared, like Swift's shared formatter.
        assert!(std::ptr::eq(pattern(), pattern()));
    }

    // Branches without a Swift test.

    #[test]
    fn rejects_fractionless_input_and_accepts_offsets() {
        assert!(parse_iso8601("2025-01-14T12:00:00Z").is_none());
        let a = parse_iso8601("2025-01-14T13:00:00.5+01:00").unwrap();
        let b = parse_iso8601("2025-01-14T12:00:00.500Z").unwrap();
        assert_eq!(a, b);
    }

    #[test]
    fn reference_date_matches_swift_default_coding() {
        // 2001-01-01T00:00:00Z is 0 in Swift's default Date encoding.
        let reference = Utc.timestamp_opt(REFERENCE_DATE_UNIX, 0).unwrap();
        assert_eq!(reference_date::to_seconds(reference), 0.0);
        let date = Utc.timestamp_opt(1_700_000_000, 0).unwrap();
        assert_eq!(reference_date::to_seconds(date), 721_692_800.0);
        assert_eq!(reference_date::from_seconds(721_692_800.0), Some(date));
        assert_eq!(
            reference_date::from_seconds(-0.5).unwrap(),
            Utc.timestamp_opt(REFERENCE_DATE_UNIX - 1, 500_000_000)
                .unwrap()
        );
    }
}
