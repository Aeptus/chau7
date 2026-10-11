//! Text shown by the tab bar, the idle tabs popover and the hover card:
//! durations, sizes, CPU, relative ages and middle truncation.

/// `LastCommandInfo.durationString`: "340ms", "1.2s", "3m 5s", "1h 2m".
pub fn command_duration(seconds: f64) -> String {
    let d = seconds.max(0.0);
    if d < 1.0 {
        format!("{:.0}ms", d * 1000.0)
    } else if d < 60.0 {
        format!("{d:.1}s")
    } else if d < 3600.0 {
        format!("{}m {}s", d as u64 / 60, d as u64 % 60)
    } else {
        format!("{}h {}m", d as u64 / 3600, (d as u64 % 3600) / 60)
    }
}

/// `LastCommandInfo.badgeText`: "..." while running, else "✓ 1.2s" or "✗ 2.0s".
pub fn command_badge(exit_code: Option<i32>, seconds: f64) -> String {
    match exit_code {
        None => "...".to_string(),
        Some(code) => format!(
            "{} {}",
            if code == 0 { "✓" } else { "✗" },
            command_duration(seconds)
        ),
    }
}

/// Idle duration in the idle tabs popover (`idleDuration(for:)`): "12m", "1h 5m".
pub fn idle_duration(seconds: f64) -> String {
    let s = seconds.max(0.0) as u64;
    if s < 3600 {
        format!("{}m", s / 60)
    } else {
        format!("{}h {}m", s / 3600, (s % 3600) / 60)
    }
}

/// `ProcessResourceInfo.formattedCPU`: "12.3%".
pub fn format_cpu(percent: f64) -> String {
    format!("{percent:.1}%")
}

/// `ProcessResourceInfo.formattedRSS`: "512.0 MB", "1.5 GB".
pub fn format_rss(bytes: u64) -> String {
    let mb = bytes as f64 / (1024.0 * 1024.0);
    if mb >= 1024.0 {
        format!("{:.1} GB", mb / 1024.0)
    } else {
        format!("{mb:.1} MB")
    }
}

/// Hover card token counts (`formatTokens`): "950", "12K", "1.2M".
pub fn format_tokens(count: u64) -> String {
    if count >= 1_000_000 {
        format!("{:.1}M", count as f64 / 1_000_000.0)
    } else if count >= 1000 {
        format!("{:.0}K", count as f64 / 1000.0)
    } else {
        count.to_string()
    }
}

/// Hover card footer age, like `RelativeDateTimeFormatter` with the
/// abbreviated style: "now", "42 sec ago", "5 min ago", "2 hr ago", "3 days ago".
pub fn relative_age(seconds: f64) -> String {
    let s = seconds.max(0.0) as u64;
    if s == 0 {
        "now".to_string()
    } else if s < 60 {
        format!("{s} sec ago")
    } else if s < 3600 {
        format!("{} min ago", s / 60)
    } else if s < 86_400 {
        format!("{} hr ago", s / 3600)
    } else {
        let days = s / 86_400;
        format!("{days} {} ago", if days == 1 { "day" } else { "days" })
    }
}

/// Local time of day, short style ("14:05"), for bookmark rows.
pub fn short_time(time: std::time::SystemTime) -> String {
    chrono::DateTime::<chrono::Local>::from(time)
        .format("%H:%M")
        .to_string()
}

/// Shorten `text` to at most `max_chars` characters by replacing its middle
/// with "…" (SwiftUI `.truncationMode(.middle)`).
pub fn truncate_middle(text: &str, max_chars: usize) -> String {
    let chars: Vec<char> = text.chars().collect();
    if chars.len() <= max_chars || max_chars < 2 {
        return text.to_string();
    }
    let keep = max_chars - 1;
    let head = keep.div_ceil(2);
    let tail = keep - head;
    let mut out: String = chars[..head].iter().collect();
    out.push('…');
    out.extend(&chars[chars.len() - tail..]);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn durations_follow_last_command_info() {
        assert_eq!(command_duration(0.34), "340ms");
        assert_eq!(command_duration(1.25), "1.2s");
        assert_eq!(command_duration(185.0), "3m 5s");
        assert_eq!(command_duration(3720.0), "1h 2m");
        assert_eq!(command_badge(None, 3.0), "...");
        assert_eq!(command_badge(Some(0), 1.0), "✓ 1.0s");
        assert_eq!(command_badge(Some(2), 0.5), "✗ 500ms");
    }

    #[test]
    fn idle_durations() {
        assert_eq!(idle_duration(720.0), "12m");
        assert_eq!(idle_duration(3900.0), "1h 5m");
    }

    #[test]
    fn sizes_and_cpu() {
        assert_eq!(format_cpu(12.345), "12.3%");
        assert_eq!(format_rss(512 * 1024 * 1024), "512.0 MB");
        assert_eq!(format_rss(3 * 512 * 1024 * 1024), "1.5 GB");
        assert_eq!(format_tokens(950), "950");
        assert_eq!(format_tokens(12_300), "12K");
        assert_eq!(format_tokens(1_250_000), "1.2M");
    }

    #[test]
    fn relative_ages() {
        assert_eq!(relative_age(0.2), "now");
        assert_eq!(relative_age(42.0), "42 sec ago");
        assert_eq!(relative_age(300.0), "5 min ago");
        assert_eq!(relative_age(7300.0), "2 hr ago");
        assert_eq!(relative_age(86_400.0), "1 day ago");
    }

    #[test]
    fn middle_truncation() {
        assert_eq!(truncate_middle("short", 10), "short");
        assert_eq!(truncate_middle("abcdefghij", 5), "ab…ij");
        assert_eq!(truncate_middle("abcdefghij", 6), "abc…ij");
    }
}
