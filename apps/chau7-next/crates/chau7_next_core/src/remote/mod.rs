//! Remote control wire formats shared with the iOS app and the Go relay client.
//!
//! Ports the Remote* files and `FrameParser.swift` of
//! `apps/chau7-macos/Sources/Chau7Core`. Byte layouts, endianness, flag bits and
//! JSON keys must stay identical to the Swift side.

pub mod activity_state;
pub mod agent_state;
pub mod frame;
pub mod frame_parser;
pub mod grid_cache;
pub mod grid_delivery;
pub mod grid_snapshot;
pub mod interactive_prompt;
pub mod models;
pub mod output_buffering;
pub mod protection;
pub mod relay_credentials;
pub mod tab_registry;
pub mod viewer;
pub mod viewer_protocol;

/// Seconds between the Unix epoch and Apple's reference date (2001-01-01 UTC).
const APPLE_REFERENCE_OFFSET_SECS: f64 = 978_307_200.0;

/// serde adapter matching Swift's default `Date` Codable strategy
/// (`deferredToDate`): a JSON number of seconds since 2001-01-01 UTC.
///
/// The Swift remote code uses a bare `JSONEncoder()`/`JSONDecoder()`, so this is
/// what the iOS app expects on the wire (not ISO 8601, despite the spec).
pub(crate) mod apple_date {
    use super::APPLE_REFERENCE_OFFSET_SECS;
    use chrono::{DateTime, TimeZone, Utc};
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn to_reference_seconds(date: &DateTime<Utc>) -> f64 {
        date.timestamp() as f64 + f64::from(date.timestamp_subsec_nanos()) / 1e9
            - APPLE_REFERENCE_OFFSET_SECS
    }

    pub fn from_reference_seconds(secs: f64) -> Option<DateTime<Utc>> {
        let unix = secs + APPLE_REFERENCE_OFFSET_SECS;
        if !unix.is_finite() {
            return None;
        }
        let whole = unix.floor();
        let nanos = ((unix - whole) * 1e9).round() as u32;
        let (whole, nanos) = if nanos >= 1_000_000_000 {
            (whole as i64 + 1, 0)
        } else {
            (whole as i64, nanos)
        };
        Utc.timestamp_opt(whole, nanos).single()
    }

    pub fn serialize<S: Serializer>(date: &DateTime<Utc>, s: S) -> Result<S::Ok, S::Error> {
        let secs = to_reference_seconds(date);
        // Swift prints whole numbers without a fractional part.
        if secs.fract() == 0.0 && secs.abs() < 9.0e15 {
            s.serialize_i64(secs as i64)
        } else {
            s.serialize_f64(secs)
        }
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<DateTime<Utc>, D::Error> {
        let secs = f64::deserialize(d)?;
        from_reference_seconds(secs).ok_or_else(|| serde::de::Error::custom("date out of range"))
    }

    pub mod option {
        use super::*;

        pub fn serialize<S: Serializer>(
            date: &Option<DateTime<Utc>>,
            s: S,
        ) -> Result<S::Ok, S::Error> {
            match date {
                Some(d) => super::serialize(d, s),
                None => s.serialize_none(),
            }
        }

        pub fn deserialize<'de, D: Deserializer<'de>>(
            d: D,
        ) -> Result<Option<DateTime<Utc>>, D::Error> {
            match Option::<f64>::deserialize(d)? {
                Some(secs) => from_reference_seconds(secs)
                    .map(Some)
                    .ok_or_else(|| serde::de::Error::custom("date out of range")),
                None => Ok(None),
            }
        }
    }
}
