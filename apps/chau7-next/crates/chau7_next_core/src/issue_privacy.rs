//! The "Who sees what" page of issue reporting (`IssueReportingPrivacyView`):
//! what a report contains, which third parties handle it, and the reader's
//! rights. Plain data, shown by the Report an Issue window.

/// A line of the data tables: name and what it holds.
pub type DataRow = (&'static str, &'static str);

pub const TITLE: &str = "Who sees what";
pub const INTRO: &str = "Your bug report touches exactly two third-party services on its way to us. No trackers, no analytics platforms, no \"partners.\" Here's the full list, you're looking at it.";

pub const DATA_HEADER: &str = "What data is sent";
pub const DATA_INTRO: &str = "Two tiers. The first is always included (it's genuinely boring). The second is entirely up to you.";

pub const ALWAYS_TITLE: &str = "Always included";
pub const ALWAYS_ROWS: [DataRow; 5] = [
    ("App version", "e.g. \"Chau7 0.9.3\""),
    ("macOS version", "e.g. \"15.4\""),
    ("Tab count", "Just the number, no tab names"),
    ("Your description", "Whatever you typed in the text box"),
    ("Timestamp", "When the report was generated"),
];

pub const OPT_IN_TITLE: &str = "Opt-in only (all off by default)";
pub const OPT_IN_ROWS: [DataRow; 7] = [
    (
        "Feature settings",
        "Which toggles are on/off, no personal data",
    ),
    (
        "Application logs",
        "Last 50 log lines, may contain file paths, commands",
    ),
    (
        "Recent events",
        "Last 20 app events, tool calls, notifications",
    ),
    (
        "Tab metadata",
        "Tab title, working directory, active app, git branch",
    ),
    (
        "Terminal history",
        "Last 50 lines of terminal output from one tab",
    ),
    (
        "AI session info",
        "Agent state, project name, recent tool usage",
    ),
    (
        "Contact info",
        "Your name and/or GitHub handle, only if you provide them",
    ),
];

/// A third party that handles reports.
pub struct SubProcessor {
    pub name: &'static str,
    pub role: &'static str,
    pub location: &'static str,
    pub data: &'static str,
    pub retention: &'static str,
    pub note: &'static str,
    pub policy_url: &'static str,
    pub dpa_url: &'static str,
}

pub const SUBPROCESSORS_HEADER: &str = "Sub-processors";
pub const SUBPROCESSORS_INTRO: &str =
    "The complete list. If we ever add another one, this page updates with the app.";

pub const SUBPROCESSORS: [SubProcessor; 2] = [
    SubProcessor {
        name: "Cloudflare, Inc.",
        role: "Request relay and rate limiting",
        location: "United States (global edge network)",
        data: "IP address, HTTP headers, request timestamp. Your report body passes through but is not stored.",
        retention: "Request metadata: per Cloudflare's standard log retention (up to 72h). Report body: not retained.",
        note: "Think mail carrier, not filing cabinet.",
        policy_url: "https://www.cloudflare.com/privacypolicy/",
        dpa_url: "https://www.cloudflare.com/cloudflare-customer-dpa/",
    },
    SubProcessor {
        name: "GitHub, Inc. (Microsoft)",
        role: "Issue storage",
        location: "United States",
        data: "Full report content: description, environment info, and any opt-in diagnostics. Stored as a private GitHub issue.",
        retention: "Retained until the issue is resolved and deleted by the dev team, or upon deletion request.",
        note: "Private repo, dev team eyes only. What you saw in the preview is what they see.",
        policy_url: "https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement",
        dpa_url: "https://github.com/customer-terms/github-data-protection-agreement",
    },
];

pub const CONTROL_HEADER: &str = "You're in charge";
pub const CONTROL_POINTS: [&str; 4] = [
    "Default report: your words + app version + macOS version + tab count. That's it. We don't even know your username unless you tell us.",
    "Every diagnostic toggle is off by default. You flip it, you see what it adds in the live preview. No surprises, no fine print.",
    "Not sure? Hit \"Save Locally\" instead. Review the file, redact anything you want, then come back.",
    "We automatically replace your home directory with ~ in file paths. Your /Users/cool-hacker-name stays between you and your Mac.",
];

pub const LEGAL_HEADER: &str = "Legal basis & retention";
/// (label, text)
pub const LEGAL_ROWS: [DataRow; 3] = [
    (
        "Legal basis",
        "Legitimate interest (Art. 6(1)(f) GDPR). You initiated the report to get a bug fixed, and we process it to do exactly that. For optional diagnostics, your explicit action of toggling them on serves as consent.",
    ),
    (
        "Retention",
        "Reports are kept for the lifetime of the issue. Once resolved, issues are periodically cleaned up. You can request deletion at any time (see below).",
    ),
    (
        "International transfers",
        "Both sub-processors are US-based. Transfers are covered under their respective DPAs and the EU-US Data Privacy Framework.",
    ),
];

pub const RIGHTS_HEADER: &str = "Your rights";
pub const RIGHTS_INTRO: &str = "Under GDPR and similar regulations, you can:";
pub const RIGHTS_POINTS: [&str; 5] = [
    "Request a copy of any data we hold about you.",
    "Ask us to correct inaccurate information in a report.",
    "Ask us to delete your report. We'll remove the GitHub issue.",
    "Ask us to stop processing your data while a concern is being resolved.",
    "Request your data in a portable format (it's already markdown, so that's easy).",
];
pub const RIGHTS_CONTACT: &str = "To exercise any of these rights, open an issue at github.com/anthropics/chau7 or email the address listed on that repository.";

#[cfg(test)]
mod tests {
    use super::*;

    fn all_text() -> String {
        let mut text = vec![TITLE, INTRO, DATA_HEADER, DATA_INTRO, RIGHTS_CONTACT];
        for (a, b) in ALWAYS_ROWS.iter().chain(&OPT_IN_ROWS).chain(&LEGAL_ROWS) {
            text.extend([*a, *b]);
        }
        for sp in &SUBPROCESSORS {
            text.extend([
                sp.name,
                sp.role,
                sp.location,
                sp.data,
                sp.retention,
                sp.note,
            ]);
        }
        text.extend(CONTROL_POINTS);
        text.extend(RIGHTS_POINTS);
        text.join("\n")
    }

    #[test]
    fn lists_have_the_swift_sizes() {
        assert_eq!(ALWAYS_ROWS.len(), 5);
        assert_eq!(OPT_IN_ROWS.len(), 7);
        assert_eq!(SUBPROCESSORS.len(), 2);
        assert_eq!(CONTROL_POINTS.len(), 4);
        assert_eq!(RIGHTS_POINTS.len(), 5);
    }

    #[test]
    fn links_are_https() {
        for sp in &SUBPROCESSORS {
            assert!(sp.policy_url.starts_with("https://"));
            assert!(sp.dpa_url.starts_with("https://"));
        }
    }

    #[test]
    fn no_long_dashes() {
        assert!(!all_text().contains('\u{2014}'));
    }
}
