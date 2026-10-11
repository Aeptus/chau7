//! Gregorian local-day boundaries matching Foundation Calendar's day arithmetic.
//! Chrono's checked_sub_days rejects folds and gaps, whereas Calendar resolves
//! them. These conversions run only in the existing background analytics load.
use chrono::{DateTime, Days, LocalResult, NaiveDateTime, Offset, TimeDelta, TimeZone, Utc};

// Real-world timezone changes include entire skipped days. Bound the rare gap
// search to two days on either side rather than walking historical transitions.
const GAP_SEARCH_HOURS: i64 = 48;

fn adjacent_offset<Tz: TimeZone>(zone: &Tz, local: NaiveDateTime, direction: i64) -> Option<i32> {
    for hour in 1..=GAP_SEARCH_HOURS {
        let candidate = local.checked_add_signed(TimeDelta::hours(hour * direction))?;
        let resolved = zone.from_local_datetime(&candidate);
        let date = if direction < 0 {
            resolved.latest()
        } else {
            resolved.earliest()
        };
        if let Some(date) = date {
            return Some(date.offset().fix().local_minus_utc());
        }
    }
    None
}

pub(super) fn subtract_days<Tz: TimeZone>(now: DateTime<Tz>, days: u64) -> Option<DateTime<Utc>> {
    let zone = now.timezone();
    let local = now.naive_local().checked_sub_days(Days::new(days))?;
    match zone.from_local_datetime(&local) {
        LocalResult::Single(date) => Some(date.with_timezone(&Utc)),
        LocalResult::Ambiguous(first, second) => {
            // Calendar preserves the source offset when the destination repeats.
            let source = now.offset().fix();
            let date = if second.offset().fix() == source {
                second
            } else {
                first
            };
            Some(date.with_timezone(&Utc))
        }
        LocalResult::None => {
            let before = adjacent_offset(&zone, local, -1)?;
            let after = adjacent_offset(&zone, local, 1)?;
            let gap = after.checked_sub(before)?;
            if gap <= 0 {
                return None;
            }
            // A DST gap advances through the gap preserving minutes/seconds.
            // Calendar subtracting into a skipped civil day instead resolves
            // backward (e.g. Samoa's missing 2011-12-30).
            let offset = if gap >= 86_400 { after } else { before };
            Some(
                local
                    .checked_sub_signed(TimeDelta::seconds(offset.into()))?
                    .and_utc(),
            )
        }
    }
}

pub(super) fn start_of_day<Tz: TimeZone>(now: DateTime<Tz>) -> Option<DateTime<Utc>> {
    let zone = now.timezone();
    let midnight = now.date_naive().and_hms_opt(0, 0, 0)?;
    if let Some(date) = zone.from_local_datetime(&midnight).earliest() {
        return Some(date.with_timezone(&Utc));
    }
    // Midnight itself can be skipped. Find the first existing local second,
    // including historical transitions with non-hour offsets, without a scan
    // of every second or assumptions about the length of a day.
    let mut upper = None;
    for hour in 1..=GAP_SEARCH_HOURS {
        let candidate = midnight.checked_add_signed(TimeDelta::hours(hour))?;
        if zone.from_local_datetime(&candidate).earliest().is_some() {
            upper = Some(hour * 3600);
            break;
        }
    }
    let mut upper = upper?;
    let mut lower = 0;
    while upper - lower > 1 {
        let middle = lower + (upper - lower) / 2;
        let candidate = midnight.checked_add_signed(TimeDelta::seconds(middle))?;
        if zone.from_local_datetime(&candidate).earliest().is_some() {
            upper = middle;
        } else {
            lower = middle;
        }
    }
    zone.from_local_datetime(&midnight.checked_add_signed(TimeDelta::seconds(upper))?)
        .earliest()
        .map(|date| date.with_timezone(&Utc))
}

#[cfg(test)]
mod tests {
    use super::super::AnalyticsRange;
    use super::*;
    use chrono::{FixedOffset, NaiveDate};

    // Exact IANA transition boundaries, represented without global TZ changes
    // or a new dependency. Only the one transition under test is needed.
    #[derive(Clone, Copy, Debug)]
    struct Zone {
        transition: NaiveDateTime,
        before: i32,
        after: i32,
    }
    #[derive(Clone, Copy, Debug)]
    struct ZoneOffset {
        zone: Zone,
        fixed: FixedOffset,
    }
    impl Offset for ZoneOffset {
        fn fix(&self) -> FixedOffset {
            self.fixed
        }
    }
    impl Zone {
        fn offset(self, seconds: i32) -> ZoneOffset {
            ZoneOffset {
                zone: self,
                fixed: FixedOffset::east_opt(seconds).unwrap(),
            }
        }
        fn new(transition: &str, before: i32, after: i32) -> Self {
            Self {
                transition: utc(transition).naive_utc(),
                before,
                after,
            }
        }
    }
    impl TimeZone for Zone {
        type Offset = ZoneOffset;
        fn from_offset(offset: &Self::Offset) -> Self {
            offset.zone
        }
        fn offset_from_local_date(&self, date: &NaiveDate) -> LocalResult<Self::Offset> {
            self.offset_from_local_datetime(&date.and_hms_opt(0, 0, 0).unwrap())
        }
        fn offset_from_local_datetime(&self, local: &NaiveDateTime) -> LocalResult<Self::Offset> {
            let before = local
                .checked_sub_signed(TimeDelta::seconds(self.before.into()))
                .is_some_and(|at| at < self.transition);
            let after = local
                .checked_sub_signed(TimeDelta::seconds(self.after.into()))
                .is_some_and(|at| at >= self.transition);
            match (before, after) {
                (true, true) => {
                    LocalResult::Ambiguous(self.offset(self.before), self.offset(self.after))
                }
                (true, false) => LocalResult::Single(self.offset(self.before)),
                (false, true) => LocalResult::Single(self.offset(self.after)),
                (false, false) => LocalResult::None,
            }
        }
        fn offset_from_utc_date(&self, date: &NaiveDate) -> Self::Offset {
            self.offset_from_utc_datetime(&date.and_hms_opt(0, 0, 0).unwrap())
        }
        fn offset_from_utc_datetime(&self, utc: &NaiveDateTime) -> Self::Offset {
            self.offset(if *utc < self.transition {
                self.before
            } else {
                self.after
            })
        }
    }
    fn utc(text: &str) -> DateTime<Utc> {
        DateTime::parse_from_rfc3339(text)
            .unwrap()
            .with_timezone(&Utc)
    }
    #[test]
    fn paris_fold_preserves_source_offset_like_foundation() {
        let zone = Zone::new("2026-10-25T01:00:00Z", 7200, 3600);
        let now = utc("2026-11-01T01:30:00Z").with_timezone(&zone);
        assert!(now.checked_sub_days(Days::new(7)).is_none());
        assert_eq!(AnalyticsRange::Week.after(now), subtract_days(now, 7));
        assert_eq!(subtract_days(now, 7), Some(utc("2026-10-25T01:30:00Z")));
    }
    #[test]
    fn paris_gap_preserves_minutes_like_foundation() {
        let zone = Zone::new("2026-03-29T01:00:00Z", 3600, 7200);
        let now = utc("2026-04-05T00:30:00Z").with_timezone(&zone);
        assert!(now.checked_sub_days(Days::new(7)).is_none());
        assert_eq!(AnalyticsRange::Week.after(now), subtract_days(now, 7));
        assert_eq!(subtract_days(now, 7), Some(utc("2026-03-29T01:30:00Z")));
    }
    #[test]
    fn santiago_today_starts_after_skipped_midnight_like_foundation() {
        let zone = Zone::new("2026-09-06T04:00:00Z", -14400, -10800);
        let now = utc("2026-09-06T15:00:00Z").with_timezone(&zone);
        assert_eq!(start_of_day(now), Some(utc("2026-09-06T04:00:00Z")));
        assert_eq!(AnalyticsRange::Today.after(now), start_of_day(now));
        assert_eq!(subtract_days(now, 1), Some(utc("2026-09-05T16:00:00Z")));
    }
    #[test]
    fn apia_skipped_day_subtraction_resolves_backward_like_foundation() {
        let zone = Zone::new("2011-12-30T10:00:00Z", -36000, 50400);
        let now = utc("2012-01-05T22:00:00Z").with_timezone(&zone);
        assert_eq!(subtract_days(now, 7), Some(utc("2011-12-29T22:00:00Z")));
        assert_eq!(start_of_day(now), Some(utc("2012-01-05T10:00:00Z")));
    }
    #[test]
    fn today_uses_first_instant_of_repeated_midnight() {
        let zone = Zone::new("2026-10-25T00:00:00Z", 3600, 0);
        let now = utc("2026-10-25T12:00:00Z").with_timezone(&zone);
        assert_eq!(start_of_day(now), Some(utc("2026-10-24T23:00:00Z")));
    }
    #[test]
    fn midnight_gap_supports_non_hour_transition() {
        let zone = Zone::new("2026-01-01T00:00:00Z", 0, 1800);
        let now = utc("2026-01-01T12:00:00Z").with_timezone(&zone);
        assert_eq!(start_of_day(now), Some(utc("2026-01-01T00:00:00Z")));
    }
    #[test]
    fn ordinary_boundaries_and_out_of_range_days_remain_explicit() {
        let now = utc("2026-10-11T12:34:56Z").with_timezone(&FixedOffset::east_opt(7200).unwrap());
        assert_eq!(subtract_days(now, 7), Some(utc("2026-10-04T12:34:56Z")));
        assert_eq!(start_of_day(now), Some(utc("2026-10-10T22:00:00Z")));
        assert_eq!(subtract_days(now, u64::MAX), None);
    }
}
