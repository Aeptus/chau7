//! Date encodings used by the Swift `Codable` types ported in this crate.
//!
//! Foundation's `JSONEncoder` writes a `Date` in one of two ways, depending on
//! the encoder's strategy:
//!
//! - default (`swift_reference`): seconds since 2001-01-01 00:00:00 UTC as a
//!   JSON number (used by the iOS client and the remote frames);
//! - `.iso8601` (`iso8601`): `2026-04-01T09:00:00Z`, whole seconds, no
//!   fractional part (used by the telemetry query service).
//!
//! Both are exposed as `#[serde(with = "...")]` modules, with `_opt` variants
//! for optional fields. The decoders are lenient: the ISO 8601 decoder accepts
//! any RFC 3339 string, with or without fractional seconds.

use chrono::{DateTime, TimeZone, Utc};

/// Unix timestamp of the Foundation reference date (2001-01-01T00:00:00Z).
const REFERENCE_DATE_UNIX: i64 = 978_307_200;

/// Parse an ISO 8601 timestamp the way the Swift parsers do: fractional
/// seconds first, then the basic form. Returns `None` for empty or invalid
/// input.
pub fn parse_iso8601(value: Option<&str>) -> Option<DateTime<Utc>> {
    let value = value?;
    if value.is_empty() {
        return None;
    }
    DateTime::parse_from_rfc3339(value)
        .ok()
        .map(|d| d.with_timezone(&Utc))
}

/// Format like `ISO8601DateFormatter` with `.withInternetDateTime` and
/// `.withFractionalSeconds` (always three fractional digits).
pub fn format_iso8601_fractional(date: &DateTime<Utc>) -> String {
    date.format("%Y-%m-%dT%H:%M:%S%.3fZ").to_string()
}

fn format_iso8601_whole(date: &DateTime<Utc>) -> String {
    date.format("%Y-%m-%dT%H:%M:%SZ").to_string()
}

/// Seconds since the Foundation reference date, as `Date.timeIntervalSinceReferenceDate`.
pub fn to_reference_seconds(date: &DateTime<Utc>) -> f64 {
    (date.timestamp() - REFERENCE_DATE_UNIX) as f64 + f64::from(date.timestamp_subsec_nanos()) / 1e9
}

/// Inverse of [`to_reference_seconds`].
pub fn from_reference_seconds(seconds: f64) -> Option<DateTime<Utc>> {
    if !seconds.is_finite() {
        return None;
    }
    let whole = seconds.floor();
    let nanos = ((seconds - whole) * 1e9).round() as i64;
    let (whole, nanos) = if nanos >= 1_000_000_000 {
        (whole as i64 + 1, 0)
    } else {
        (whole as i64, nanos)
    };
    Utc.timestamp_opt(whole + REFERENCE_DATE_UNIX, nanos as u32)
        .single()
}

/// `#[serde(with = "...")]` module for Foundation's default `Date` encoding.
pub mod swift_reference {
    use super::*;
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(date: &DateTime<Utc>, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_f64(to_reference_seconds(date))
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<DateTime<Utc>, D::Error> {
        let seconds = f64::deserialize(d)?;
        from_reference_seconds(seconds).ok_or_else(|| serde::de::Error::custom("date out of range"))
    }
}

/// Optional variant of [`swift_reference`].
pub mod swift_reference_opt {
    use super::*;
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(date: &Option<DateTime<Utc>>, s: S) -> Result<S::Ok, S::Error> {
        match date {
            Some(d) => s.serialize_f64(to_reference_seconds(d)),
            None => s.serialize_none(),
        }
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Option<DateTime<Utc>>, D::Error> {
        match Option::<f64>::deserialize(d)? {
            Some(seconds) => from_reference_seconds(seconds)
                .map(Some)
                .ok_or_else(|| serde::de::Error::custom("date out of range")),
            None => Ok(None),
        }
    }
}

/// `#[serde(with = "...")]` module for `JSONEncoder.dateEncodingStrategy = .iso8601`.
pub mod iso8601 {
    use super::*;
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(date: &DateTime<Utc>, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&format_iso8601_whole(date))
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<DateTime<Utc>, D::Error> {
        let text = String::deserialize(d)?;
        parse_iso8601(Some(&text)).ok_or_else(|| serde::de::Error::custom("invalid ISO 8601 date"))
    }
}

/// Optional variant of [`iso8601`].
pub mod iso8601_opt {
    use super::*;
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(date: &Option<DateTime<Utc>>, s: S) -> Result<S::Ok, S::Error> {
        match date {
            Some(d) => s.serialize_str(&format_iso8601_whole(d)),
            None => s.serialize_none(),
        }
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Option<DateTime<Utc>>, D::Error> {
        match Option::<String>::deserialize(d)? {
            Some(text) => parse_iso8601(Some(&text))
                .map(Some)
                .ok_or_else(|| serde::de::Error::custom("invalid ISO 8601 date")),
            None => Ok(None),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reference_seconds_round_trip() {
        let date = from_reference_seconds(794_770_102.125).unwrap();
        assert_eq!(to_reference_seconds(&date), 794_770_102.125);
    }

    #[test]
    fn parse_iso8601_accepts_fractional_and_basic() {
        let a = parse_iso8601(Some("2026-04-01T09:00:00.000Z")).unwrap();
        let b = parse_iso8601(Some("2026-04-01T09:00:00Z")).unwrap();
        assert_eq!(a, b);
        assert!(parse_iso8601(Some("")).is_none());
        assert!(parse_iso8601(None).is_none());
        assert!(parse_iso8601(Some("nope")).is_none());
    }

    #[test]
    fn fractional_format_has_three_digits() {
        let d = parse_iso8601(Some("2026-04-01T09:00:00.5Z")).unwrap();
        assert_eq!(format_iso8601_fractional(&d), "2026-04-01T09:00:00.500Z");
    }
}
