import SwiftUI

/// In-app privacy page for issue reporting.
///
/// GDPR-compliant sub-processor disclosure with data categories,
/// retention, legal basis, and data subject rights.
/// Maintains Chau7's honest-but-cheeky tone throughout.
struct IssueReportingPrivacyView: View {
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    // MARK: Header

                    Text(L("privacy.issueReporting.title", "Who sees what"))
                        .font(.system(size: 16, weight: .semibold))

                    Text(L(
                        "privacy.issueReporting.intro",
                        "Your bug report touches exactly two third-party services on its way to us. No trackers, no analytics platforms, no \"partners.\" Here's the full list — you're looking at it."
                    ))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                    // MARK: Data Categories

                    dataSection

                    Divider()

                    // MARK: Sub-processors

                    subProcessorSection

                    Divider()

                    // MARK: Your control

                    controlSection

                    Divider()

                    // MARK: Legal basis & retention

                    legalSection

                    Divider()

                    // MARK: Your rights

                    rightsSection
                }
                .padding(24)
            }

            Divider()

            HStack {
                Spacer()
                Button(L("privacy.close", "Close")) {
                    onClose()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 560, height: 680)
    }

    // MARK: - Data Categories

    private var dataSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("privacy.data.header", "What data is sent"))
                .font(.system(size: 13, weight: .medium))

            Text(L(
                "privacy.data.intro",
                "Two tiers. The first is always included (it's genuinely boring). The second is entirely up to you."
            ))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            dataCategoryBox(
                title: L("privacy.data.always.title", "Always included"),
                icon: "checkmark.circle",
                color: .green,
                rows: [
                    ("App version", "e.g. \"Chau7 0.9.3\""),
                    ("macOS version", "e.g. \"15.4\""),
                    ("Tab count", "Just the number, no tab names"),
                    ("Your description", "Whatever you typed in the text box"),
                    ("Timestamp", "When the report was generated")
                ]
            )

            dataCategoryBox(
                title: L("privacy.data.optIn.title", "Opt-in only (all off by default)"),
                icon: "hand.raised.circle",
                color: .orange,
                rows: [
                    ("Feature settings", "Which toggles are on/off — no personal data"),
                    ("Application logs", "Last 50 log lines — may contain file paths, commands"),
                    ("Recent events", "Last 20 app events — tool calls, notifications"),
                    ("Tab metadata", "Tab title, working directory, active app, git branch"),
                    ("Terminal history", "Last 50 lines of terminal output from one tab"),
                    ("AI session info", "Agent state, project name, recent tool usage"),
                    ("Contact info", "Your name and/or GitHub handle — only if you provide them")
                ]
            )
        }
    }

    // MARK: - Sub-processors

    private var subProcessorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("privacy.subprocessors.header", "Sub-processors"))
                .font(.system(size: 13, weight: .medium))

            Text(L(
                "privacy.subprocessors.intro",
                "The complete list. If we ever add another one, this page updates with the app."
            ))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            subProcessorCard(
                name: "Cloudflare, Inc.",
                role: L("privacy.sp.cloudflare.role", "Request relay and rate limiting"),
                location: "United States (global edge network)",
                dataProcessed: L(
                    "privacy.sp.cloudflare.data",
                    "IP address, HTTP headers, request timestamp. Your report body passes through but is not stored."
                ),
                retention: L(
                    "privacy.sp.cloudflare.retention",
                    "Request metadata: per Cloudflare's standard log retention (up to 72h). Report body: not retained."
                ),
                humanNote: L(
                    "privacy.sp.cloudflare.note",
                    "Think mail carrier, not filing cabinet."
                ),
                policyURL: "https://www.cloudflare.com/privacypolicy/",
                dpaURL: "https://www.cloudflare.com/cloudflare-customer-dpa/"
            )

            subProcessorCard(
                name: "GitHub, Inc. (Microsoft)",
                role: L("privacy.sp.github.role", "Issue storage"),
                location: "United States",
                dataProcessed: L(
                    "privacy.sp.github.data",
                    "Full report content: description, environment info, and any opt-in diagnostics. Stored as a private GitHub issue."
                ),
                retention: L(
                    "privacy.sp.github.retention",
                    "Retained until the issue is resolved and deleted by the dev team, or upon deletion request."
                ),
                humanNote: L(
                    "privacy.sp.github.note",
                    "Private repo, dev team eyes only. What you saw in the preview is what they see."
                ),
                policyURL: "https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement",
                dpaURL: "https://github.com/customer-terms/github-data-protection-agreement"
            )
        }
    }

    // MARK: - Your Control

    private var controlSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("privacy.control.header", "You're in charge"))
                .font(.system(size: 13, weight: .medium))

            bulletPoint(L(
                "privacy.control.default",
                "Default report: your words + app version + macOS version + tab count. That's it. We don't even know your username unless you tell us."
            ))
            bulletPoint(L(
                "privacy.control.optIn",
                "Every diagnostic toggle is off by default. You flip it, you see what it adds in the live preview. No surprises, no fine print."
            ))
            bulletPoint(L(
                "privacy.control.saveLocal",
                "Not sure? Hit \"Save Locally\" instead. Review the file, redact anything you want, then come back."
            ))
            bulletPoint(L(
                "privacy.control.paths",
                "We automatically replace your home directory with ~ in file paths. Your /Users/cool-hacker-name stays between you and your Mac."
            ))
        }
    }

    // MARK: - Legal Basis & Retention

    private var legalSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("privacy.legal.header", "Legal basis & retention"))
                .font(.system(size: 13, weight: .medium))

            labeledRow(
                label: L("privacy.legal.basis.label", "Legal basis"),
                value: L(
                    "privacy.legal.basis.value",
                    "Legitimate interest (Art. 6(1)(f) GDPR) — you initiated the report to get a bug fixed, and we process it to do exactly that. For optional diagnostics, your explicit action of toggling them on serves as consent."
                )
            )

            labeledRow(
                label: L("privacy.legal.retention.label", "Retention"),
                value: L(
                    "privacy.legal.retention.value",
                    "Reports are kept for the lifetime of the issue. Once resolved, issues are periodically cleaned up. You can request deletion at any time (see below)."
                )
            )

            labeledRow(
                label: L("privacy.legal.transfers.label", "International transfers"),
                value: L(
                    "privacy.legal.transfers.value",
                    "Both sub-processors are US-based. Transfers are covered under their respective DPAs and the EU-US Data Privacy Framework."
                )
            )
        }
    }

    // MARK: - Your Rights

    private var rightsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("privacy.rights.header", "Your rights"))
                .font(.system(size: 13, weight: .medium))

            Text(L(
                "privacy.rights.intro",
                "Under GDPR and similar regulations, you can:"
            ))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            bulletPoint(L(
                "privacy.rights.access",
                "Request a copy of any data we hold about you."
            ))
            bulletPoint(L(
                "privacy.rights.rectification",
                "Ask us to correct inaccurate information in a report."
            ))
            bulletPoint(L(
                "privacy.rights.erasure",
                "Ask us to delete your report — we'll remove the GitHub issue."
            ))
            bulletPoint(L(
                "privacy.rights.restriction",
                "Ask us to stop processing your data while a concern is being resolved."
            ))
            bulletPoint(L(
                "privacy.rights.portability",
                "Request your data in a portable format (it's already markdown, so that's easy)."
            ))

            Text(L(
                "privacy.rights.contact",
                "To exercise any of these rights, open an issue at github.com/anthropics/chau7 or email the address listed on that repository."
            ))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
        }
    }

    // MARK: - Components

    private func dataCategoryBox(
        title: String,
        icon: String,
        color: Color,
        rows: [(String, String)]
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(color)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }

            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 0) {
                    Text(row.0)
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 130, alignment: .leading)
                    Text(row.1)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func subProcessorCard(
        name: String,
        role: String,
        location: String,
        dataProcessed: String,
        retention: String,
        humanNote: String,
        policyURL: String,
        dpaURL: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(name)
                .font(.system(size: 13, weight: .semibold))

            labeledRow(label: L("privacy.sp.role", "Role"), value: role)
            labeledRow(label: L("privacy.sp.location", "Location"), value: location)
            labeledRow(label: L("privacy.sp.data", "Data processed"), value: dataProcessed)
            labeledRow(label: L("privacy.sp.retention", "Retention"), value: retention)

            Text(humanNote)
                .font(.system(size: 10, weight: .medium))
                .italic()
                .foregroundStyle(.tertiary)

            HStack(spacing: 16) {
                if let url = URL(string: policyURL) {
                    Link(destination: url) {
                        linkLabel(L("privacy.viewPolicy", "Privacy Policy"))
                    }
                }
                if let url = URL(string: dpaURL) {
                    Link(destination: url) {
                        linkLabel(L("privacy.viewDPA", "DPA"))
                    }
                }
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func linkLabel(_ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.up.right.square")
                .font(.system(size: 10))
            Text(text)
                .font(.system(size: 10))
        }
        .foregroundStyle(.blue)
    }

    private func labeledRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func bulletPoint(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\u{2022}")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
