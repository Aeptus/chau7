//! Line timestamps (`Terminal/Session/LineTimestampTracker.swift`): when each
//! output line arrived, shown next to the line as a relative time ("now",
//! "5s", "3m", "2h", then the date with the user's format).
//!
//! Swift counts newlines in the raw output; Chau7 Next records the absolute
//! line (scrollback size plus cursor row) each time output arrives, which
//! gives the same stamps without parsing the byte stream.

use std::collections::BTreeMap;

use chrono::{DateTime, Local};

/// Timestamps by absolute line, at most `max_entries` (oldest dropped first).
#[derive(Debug, Clone)]
pub struct LineTimestamps {
    stamps: BTreeMap<i64, DateTime<Local>>,
    last_line: Option<i64>,
    max_entries: usize,
}

impl Default for LineTimestamps {
    fn default() -> Self {
        Self::new(10_000)
    }
}

impl LineTimestamps {
    pub fn new(max_entries: usize) -> Self {
        Self {
            stamps: BTreeMap::new(),
            last_line: None,
            max_entries,
        }
    }

    /// Output arrived and the cursor is now on absolute line `line`: every
    /// line since the last call gets `now`, and so does the cursor line
    /// (partial lines are refreshed, as Swift does for output without a newline).
    pub fn record(&mut self, line: i64, now: DateTime<Local>) {
        let from = self.last_line.map(|l| l + 1).unwrap_or(line).min(line);
        for l in from..line {
            self.stamps.entry(l).or_insert(now);
        }
        self.stamps.insert(line, now);
        self.last_line = Some(line);
        while self.stamps.len() > self.max_entries {
            self.stamps.pop_first();
        }
    }

    /// `removed` lines left the top of the scrollback: renumber.
    pub fn shift(&mut self, removed: i64) {
        if removed == 0 {
            return;
        }
        self.stamps = std::mem::take(&mut self.stamps)
            .into_iter()
            .filter_map(|(l, t)| (l - removed >= 0).then_some((l - removed, t)))
            .collect();
        self.last_line = self.last_line.map(|l| (l - removed).max(0));
    }

    /// Clear Scrollback or reset.
    pub fn clear(&mut self) {
        self.stamps.clear();
        self.last_line = None;
    }

    pub fn get(&self, line: i64) -> Option<DateTime<Local>> {
        self.stamps.get(&line).copied()
    }

    pub fn len(&self) -> usize {
        self.stamps.len()
    }

    pub fn is_empty(&self) -> bool {
        self.stamps.is_empty()
    }
}

/// `relativeTimestamp(forRow:)`.
pub fn relative(date: DateTime<Local>, now: DateTime<Local>, format: &str) -> String {
    let secs = (now - date).num_milliseconds() as f64 / 1000.0;
    if secs < 1.0 {
        "now".into()
    } else if secs < 60.0 {
        format!("{}s", secs as i64)
    } else if secs < 3600.0 {
        format!("{}m", (secs / 60.0) as i64)
    } else if secs < 86400.0 {
        format!("{}h", (secs / 3600.0) as i64)
    } else {
        date.format(&to_chrono_format(format)).to_string()
    }
}

/// Width in characters of the timestamp gutter: the longest label
/// [`relative`] can give ("now", "59m", or a date in `format`).
pub fn gutter_chars(format: &str) -> usize {
    use chrono::TimeZone;
    // A date with two-digit fields everywhere, so the width is the widest.
    let sample = Local
        .with_ymd_and_hms(2026, 12, 28, 23, 59, 59)
        .single()
        .unwrap_or_else(Local::now);
    let date = sample.format(&to_chrono_format(format)).to_string();
    date.chars().count().max(3)
}

/// Convert a Unicode date pattern (`DateFormatter.dateFormat`, e.g.
/// `yyyy-MM-dd HH:mm:ss`) to a chrono format string. Quoted text ('at') is
/// kept literally; unknown letters are kept as is.
pub fn to_chrono_format(pattern: &str) -> String {
    let chars: Vec<char> = pattern.chars().collect();
    let mut out = String::new();
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        if c == '\'' {
            // Quoted literal; '' is a single quote.
            i += 1;
            while i < chars.len() {
                if chars[i] == '\'' {
                    if chars.get(i + 1) == Some(&'\'') {
                        out.push('\'');
                        i += 2;
                        continue;
                    }
                    break;
                }
                push_literal(&mut out, chars[i]);
                i += 1;
            }
            i += 1;
            continue;
        }
        if !c.is_ascii_alphabetic() {
            push_literal(&mut out, c);
            i += 1;
            continue;
        }
        let mut n = 1;
        while i + n < chars.len() && chars[i + n] == c {
            n += 1;
        }
        let spec = match (c, n) {
            ('y', 2) => "%y",
            ('y', _) => "%Y",
            ('M', 1) => "%-m",
            ('M', 2) => "%m",
            ('M', 3) => "%b",
            ('M', _) => "%B",
            ('d', 1) => "%-d",
            ('d', _) => "%d",
            ('H', 1) => "%-H",
            ('H', _) => "%H",
            ('h', 1) => "%-I",
            ('h', _) => "%I",
            ('m', 1) => "%-M",
            ('m', _) => "%M",
            ('s', 1) => "%-S",
            ('s', _) => "%S",
            ('S', _) => "%3f",
            ('a', _) => "%p",
            ('E', 1..=3) => "%a",
            ('E', _) => "%A",
            ('Z', _) | ('x', _) | ('X', _) => "%z",
            ('z', _) => "%Z",
            _ => "",
        };
        if spec.is_empty() {
            for _ in 0..n {
                push_literal(&mut out, c);
            }
        } else {
            out.push_str(spec);
        }
        i += n;
    }
    out
}

fn push_literal(out: &mut String, c: char) {
    if c == '%' {
        out.push_str("%%");
    } else {
        out.push(c);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    #[test]
    fn gutter_fits_the_longest_label() {
        assert_eq!(gutter_chars("HH:mm:ss"), 8);
        assert_eq!(gutter_chars("yyyy-MM-dd HH:mm"), 16);
        // "now" and "59m" need 3 even with a tiny format.
        assert_eq!(gutter_chars("H"), 3);
    }

    fn at(secs: i64) -> DateTime<Local> {
        Local.timestamp_opt(1_700_000_000 + secs, 0).unwrap()
    }

    #[test]
    fn records_every_new_line() {
        let mut t = LineTimestamps::default();
        t.record(3, at(0));
        t.record(6, at(5));
        assert_eq!(t.get(3), Some(at(0)));
        assert_eq!(t.get(4), Some(at(5)));
        assert_eq!(t.get(6), Some(at(5)));
        assert_eq!(t.get(7), None);
        // Partial line refreshed.
        t.record(6, at(9));
        assert_eq!(t.get(6), Some(at(9)));
        assert_eq!(t.get(5), Some(at(5)));
    }

    #[test]
    fn prunes_and_shifts() {
        let mut t = LineTimestamps::new(3);
        t.record(0, at(0));
        t.record(4, at(1));
        assert_eq!(t.len(), 3);
        assert_eq!(t.get(1), None);
        t.shift(3);
        assert_eq!(t.get(1), Some(at(1)));
        assert_eq!(t.get(0), Some(at(1)));
        t.clear();
        assert!(t.is_empty());
    }

    #[test]
    fn relative_times_match_swift() {
        let now = at(100_000);
        assert_eq!(relative(at(100_000), now, "HH:mm:ss"), "now");
        assert_eq!(relative(at(99_990), now, "HH:mm:ss"), "10s");
        assert_eq!(relative(at(99_700), now, "HH:mm:ss"), "5m");
        assert_eq!(relative(at(92_800), now, "HH:mm:ss"), "2h");
        let old = at(0);
        assert_eq!(
            relative(old, now, "yyyy-MM-dd"),
            old.format("%Y-%m-%d").to_string()
        );
    }

    #[test]
    fn converts_date_patterns() {
        assert_eq!(to_chrono_format("HH:mm:ss"), "%H:%M:%S");
        assert_eq!(to_chrono_format("yyyy-MM-dd HH:mm"), "%Y-%m-%d %H:%M");
        assert_eq!(to_chrono_format("h:mm a"), "%-I:%M %p");
        assert_eq!(to_chrono_format("EEE d MMM 'at' HH'h'"), "%a %-d %b at %Hh");
        assert_eq!(to_chrono_format("HH:mm:ss.SSS 100%"), "%H:%M:%S.%3f 100%%");
    }
}
