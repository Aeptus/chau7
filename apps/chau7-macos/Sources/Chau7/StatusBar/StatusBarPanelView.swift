import AppKit
import SwiftUI

// MARK: - Status Bar Panel View

@MainActor
struct StatusBarPanelView: View {
    @Bindable var viewModel: CommandCenterViewModel
    @State private var isRecentActivityExpanded = false

    private var model: AppModel {
        viewModel.model
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HeroZoneView(
                status: viewModel.heroStatus,
                onResumeMonitoring: { setMonitoring(true) },
                onOpenMonitoringSettings: { viewModel.openMonitoringSettings() }
            )

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    actionListSection
                    pinnedSnippetsSection
                    recentActivityDisclosure
                }
                .padding(12)
            }
            .frame(maxHeight: 360)

            Divider()

            footerSection
        }
        .frame(width: 380)
    }

    // MARK: - Action List

    private var actionListSection: some View {
        let sessions = viewModel.actionSessions
        return Group {
            if !sessions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(
                        title: L("statusBar.actionList", "Action list"),
                        systemImage: "list.bullet"
                    )

                    ForEach(sessions) { session in
                        ActionSessionRow(session: session, onTap: {
                            viewModel.focusSession(session)
                        })
                    }
                }
            }
        }
    }

    // MARK: - Pinned Snippets

    private var pinnedSnippetsSection: some View {
        let pinnedSnippets = SnippetManager.shared.entries.filter { $0.snippet.isPinned }.prefix(5)
        return Group {
            if !pinnedSnippets.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(
                        title: L("statusBar.pinnedSnippets", "Pinned snippets"),
                        systemImage: "pin",
                        actionTitle: L("statusBar.pinnedSnippets.settings", "Snippet settings"),
                        actionSystemImage: "gearshape",
                        onAction: {
                            viewModel.openPinnedSnippetSettings()
                        }
                    )

                    ForEach(Array(pinnedSnippets)) { entry in
                        PinnedSnippetRow(
                            entry: entry,
                            isCopied: viewModel.copiedSnippetID == entry.id,
                            onInsert: {
                                viewModel.executeSnippet(entry)
                            }
                        )
                    }
                }
            }
        }
    }

    // MARK: - Recent Activity

    private var recentActivityDisclosure: some View {
        let timeline = viewModel.unifiedTimeline()
        return Group {
            if !timeline.isEmpty {
                DisclosureGroup(isExpanded: $isRecentActivityExpanded) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(timeline) { entry in
                            TimelineRow(entry: entry)
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    SectionHeader(
                        title: L("statusBar.recentActivity", "Recent activity"),
                        systemImage: "clock"
                    )
                }
            }
        }
    }

    private func setMonitoring(_ isMonitoring: Bool) {
        model.isMonitoring = isMonitoring
        model.applyMonitoringState()
        NotificationCenter.default.post(name: .monitoringStateChanged, object: nil)
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack(spacing: 10) {
            Button {
                viewModel.openDefaultSettings()
            } label: {
                Label(L("statusBar.settings", "Settings"), systemImage: "gearshape")
            }
            .controlSize(.small)

            Button {
                viewModel.showQuitConfirmation = true
            } label: {
                Label(L("statusBar.quit.short", "Quit"), systemImage: "power")
            }
            .controlSize(.small)
            .popover(isPresented: $viewModel.showQuitConfirmation) {
                VStack(spacing: 10) {
                    Text(L("statusBar.quit.confirm", "Quit Chau7?"))
                        .font(StatusBarPanelStyle.Fonts.confirmationTitle)
                    HStack(spacing: 8) {
                        Button(L("action.cancel", "Cancel")) {
                            viewModel.showQuitConfirmation = false
                        }
                        .controlSize(.small)
                        Button(L("statusBar.quit", "Quit"), role: .destructive) {
                            NSApplication.shared.terminate(nil)
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .tint(StatusBarPanelStyle.Colors.destructive)
                    }
                }
                .padding(12)
            }

            Spacer()

            Text("v\(bundleVersion)")
                .font(StatusBarPanelStyle.Fonts.version)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(StatusBarPanelStyle.Colors.windowBackground)
    }

    private var bundleVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}

// MARK: - Hero Zone

@MainActor
private struct HeroZoneView: View {
    let status: CommandCenterHeroStatus
    let onResumeMonitoring: () -> Void
    let onOpenMonitoringSettings: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon)
                .font(StatusBarPanelStyle.Fonts.heroIcon)
                .foregroundStyle(color)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(status.title)
                    .font(StatusBarPanelStyle.Fonts.heroTitle)
                    .lineLimit(1)
                Text(status.detail)
                    .font(StatusBarPanelStyle.Fonts.heroDetail)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if status.tone == .monitoringPaused {
                HStack(spacing: 6) {
                    Button {
                        onResumeMonitoring()
                    } label: {
                        Label(L("statusBar.resumeMonitoring", "Resume"), systemImage: "play.fill")
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)

                    Button {
                        onOpenMonitoringSettings()
                    } label: {
                        Label(L("statusBar.monitoringSettings", "Monitoring"), systemImage: "bell.badge")
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .background(backgroundColor)
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch status.tone {
        case .approvalRequired:
            return "hand.raised.fill"
        case .waitingForInput:
            return "keyboard.fill"
        case .monitoringPaused:
            return "pause.circle.fill"
        case .running:
            return "gearshape.2.fill"
        case .quiet:
            return "checkmark.circle.fill"
        }
    }

    private var color: Color {
        switch status.tone {
        case .approvalRequired:
            return StatusBarPanelStyle.Colors.approval
        case .waitingForInput:
            return StatusBarPanelStyle.Colors.waiting
        case .monitoringPaused:
            return StatusBarPanelStyle.Colors.paused
        case .running:
            return StatusBarPanelStyle.Colors.running
        case .quiet:
            return StatusBarPanelStyle.Colors.quiet
        }
    }

    private var backgroundColor: Color {
        switch status.tone {
        case .approvalRequired, .waitingForInput:
            return color.opacity(0.12)
        case .monitoringPaused:
            return StatusBarPanelStyle.Colors.controlBackground
        case .running, .quiet:
            return StatusBarPanelStyle.Colors.windowBackground
        }
    }
}

// MARK: - Section Header

private struct SectionHeader: View {
    let title: String
    let systemImage: String
    let actionTitle: String?
    let actionSystemImage: String?
    let onAction: (() -> Void)?

    init(
        title: String,
        systemImage: String,
        actionTitle: String? = nil,
        actionSystemImage: String? = nil,
        onAction: (() -> Void)? = nil
    ) {
        self.title = title
        self.systemImage = systemImage
        self.actionTitle = actionTitle
        self.actionSystemImage = actionSystemImage
        self.onAction = onAction
    }

    var body: some View {
        HStack {
            Label(title, systemImage: systemImage)
                .font(StatusBarPanelStyle.Fonts.sectionHeader)
                .foregroundStyle(.secondary)

            Spacer()

            if let actionTitle, let actionSystemImage, let onAction {
                Button(action: onAction) {
                    Image(systemName: actionSystemImage)
                        .font(StatusBarPanelStyle.Fonts.sectionActionIcon)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(actionTitle)
                .accessibilityLabel(actionTitle)
            }
        }
    }
}

// MARK: - Action Session Row

private struct ActionSessionRow: View {
    let session: CommandCenterSessionSummary
    let onTap: () -> Void

    private var presentation: CommandCenterSessionPresentation {
        CommandCenterSessionPresentation.presentation(for: session.state)
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: presentation.symbolName)
                    .font(StatusBarPanelStyle.Fonts.rowIcon)
                    .foregroundStyle(statusColor)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .font(StatusBarPanelStyle.Fonts.rowTitle)
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        Text(presentation.description)
                            .font(StatusBarPanelStyle.Fonts.rowDetail)
                        if showAppName {
                            Text(session.appName)
                                .font(StatusBarPanelStyle.Fonts.rowMetadata)
                                .foregroundStyle(.tertiary)
                        }
                        if let contextLabel = session.contextLabel {
                            Text("· \(contextLabel)")
                                .font(StatusBarPanelStyle.Fonts.rowMetadata)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundStyle(stateColor)
                }
                .layoutPriority(1)

                Spacer()

                Text(timeAgo(session.lastActivity))
                    .font(StatusBarPanelStyle.Fonts.rowDetail)
                    .foregroundStyle(.tertiary)

                Image(systemName: "chevron.right")
                    .font(StatusBarPanelStyle.Fonts.rowMetadata)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(
                    presentation.needsAttention
                        ? StatusBarPanelStyle.Colors.attentionBackground
                        : StatusBarPanelStyle.Colors.rowHitTargetBackground
                )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            L(
                "a11y.status.session",
                "%@, %@, %@",
                session.title,
                presentation.description,
                timeAgo(session.lastActivity)
            )
        )
        .accessibilityHint(L("a11y.status.session.hint", "Focus this session"))
    }

    private var showAppName: Bool {
        session.appName.caseInsensitiveCompare(session.title) != .orderedSame
    }

    private var statusColor: Color {
        switch presentation.tone {
        case .running:
            return StatusBarPanelStyle.Colors.sessionRunning
        case .approvalRequired:
            return StatusBarPanelStyle.Colors.approval
        case .waitingInput:
            return StatusBarPanelStyle.Colors.input
        case .stuck:
            return StatusBarPanelStyle.Colors.stuck
        }
    }

    private var stateColor: Color {
        switch presentation.tone {
        case .approvalRequired:
            return StatusBarPanelStyle.Colors.approval
        case .waitingInput:
            return StatusBarPanelStyle.Colors.input
        case .stuck:
            return StatusBarPanelStyle.Colors.stuck
        case .running:
            return .secondary
        }
    }

    private func timeAgo(_ date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60 { return L("time.now", "now") }
        if seconds < 3600 {
            let minutes = seconds / 60
            if minutes == 1 {
                return L("time.minute.ago", "1 minute ago")
            }
            return String(format: L("time.minutes.ago", "%d minutes ago"), minutes)
        }
        if seconds < 86400 {
            let hours = seconds / 3600
            if hours == 1 {
                return L("time.hour.ago", "1 hour ago")
            }
            return String(format: L("time.hours.ago", "%d hours ago"), hours)
        }
        let days = seconds / 86400
        if days == 1 {
            return L("time.day.ago", "1 day ago")
        }
        return String(format: L("time.days.ago", "%d days ago"), days)
    }
}

// MARK: - Pinned Snippet Row

private struct PinnedSnippetRow: View {
    let entry: SnippetEntry
    let isCopied: Bool
    let onInsert: () -> Void

    var body: some View {
        Button(action: onInsert) {
            HStack(spacing: 8) {
                Image(systemName: isCopied ? "checkmark" : "text.cursor")
                    .font(StatusBarPanelStyle.Fonts.snippetIcon)
                    .foregroundStyle(
                        isCopied ? StatusBarPanelStyle.Colors.success : StatusBarPanelStyle.Colors.accent
                    )
                    .frame(width: 18)

                Text(entry.snippet.title)
                    .font(StatusBarPanelStyle.Fonts.snippetTitle)
                    .lineLimit(1)
                    .layoutPriority(1)

                Spacer()

                Text(isCopied ? L("statusBar.snippet.copied", "Copied") : L("statusBar.snippet.insert", "Insert"))
                    .font(StatusBarPanelStyle.Fonts.snippetAction)
                    .foregroundStyle(isCopied ? StatusBarPanelStyle.Colors.success : .secondary)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(entry.snippet.title)
        .accessibilityHint(
            isCopied
                ? L("a11y.status.snippet.copied", "Copied to the clipboard")
                : L("a11y.status.snippet.insert", "Insert this pinned snippet")
        )
    }
}

// MARK: - Timeline Row

private struct TimelineRow: View {
    let entry: UnifiedTimelineEntry

    private static var timeFormatter: DateFormatter {
        LocalizedFormatters.mediumTime
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: entry.icon)
                .font(StatusBarPanelStyle.Fonts.timelineIcon)
                .foregroundStyle(entry.iconColor)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                    .font(StatusBarPanelStyle.Fonts.timelineTitle)
                    .lineLimit(1)

                if !entry.detail.isEmpty {
                    Text(entry.detail)
                        .font(StatusBarPanelStyle.Fonts.timelineDetail)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text(Self.timeFormatter.string(from: entry.timestamp))
                .font(StatusBarPanelStyle.Fonts.timelineTimestamp)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .opacity(entry.isRateLimited ? 0.5 : 1.0)
    }
}
