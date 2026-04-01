import SwiftUI
import Chau7Core

// MARK: - Tab Hover Card

/// Rich info card that appears when hovering over a tab chip.
/// Outer wrapper resolves the tab by ID; inner `TabHoverCardContent` holds
/// `@ObservedObject var session` for live updates (same pattern as `TabSessionContent`).
struct TabHoverCard: View {
    @ObservedObject var overlayModel: OverlayTabsModel
    let anchorX: CGFloat

    private var tab: OverlayTab? {
        guard let id = overlayModel.hoverCardTabID else { return nil }
        return overlayModel.tabs.first(where: { $0.id == id })
    }

    var body: some View {
        if let tab, let session = tab.displaySession {
            GeometryReader { geo in
                let cardWidth: CGFloat = 280
                let padding: CGFloat = 12
                // Edge-clamp: keep the card within the window bounds
                let minX = padding
                let maxX = geo.size.width - cardWidth - padding
                let idealX = anchorX - cardWidth / 2
                let clampedX = min(max(idealX, minX), maxX)

                TabHoverCardContent(
                    tab: tab,
                    session: session,
                    isSuspended: overlayModel.suspendedTabIDs.contains(tab.id),
                    isBroadcastIncluded: overlayModel.isBroadcastMode
                        && !overlayModel.broadcastExcludedTabIDs.contains(tab.id),
                    onHoverChanged: { isHovering in
                        if isHovering {
                            overlayModel.hoverCardMouseEntered()
                        } else {
                            overlayModel.hoverCardMouseExited()
                        }
                    },
                    onToggleCTO: { overlayModel.toggleTokenOpt(for: tab.id) }
                )
                .frame(width: cardWidth)
                .fixedSize(horizontal: false, vertical: true)
                .offset(x: clampedX, y: 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .transition(.opacity.animation(.easeInOut(duration: 0.12)))
        }
    }
}

// MARK: - Card Content (reactive via @ObservedObject)

private struct TabHoverCardContent: View {
    let tab: OverlayTab
    @ObservedObject var session: TerminalSessionModel
    @ObservedObject private var settings = FeatureSettings.shared
    @ObservedObject private var conflictDetector = ConflictDetector.shared
    let isSuspended: Bool
    let isBroadcastIncluded: Bool
    let onHoverChanged: (Bool) -> Void
    let onToggleCTO: () -> Void

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private var statusLabel: (text: String, color: Color) {
        switch session.status {
        case .idle:
            return ("Idle", .secondary)
        case .running:
            return ("Running", .green)
        case .waitingForInput:
            return ("Waiting", .orange)
        case .stuck:
            return ("Stuck", .red)
        case .exited:
            return ("Exited", .secondary)
        }
    }

    private var aiLogo: Image? {
        guard let appName = session.aiDisplayAppName else { return nil }
        return AIAgentLogo.image(forAppName: appName)
    }

    private var footerSessionId: String? {
        guard let raw = session.effectiveAISessionId else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AIResumeParser.isValidSessionId(trimmed) else { return nil }
        return trimmed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // MARK: Header

            headerRow
            Divider().background(Color.white.opacity(0.1))

            // MARK: Info Rows

            VStack(alignment: .leading, spacing: 8) {
                if settings.hoverCardShowDirectory { directoryRow }
                if settings.hoverCardShowGitBranch { gitRow }
                if settings.hoverCardShowShellIntegration { shellIntegrationRow }
                if settings.hoverCardShowDevServer { devServerRow }
                if settings.hoverCardShowProcesses { processInfoSection }
                if settings.hoverCardShowLastCommand { lastCommandRow }
                if settings.hoverCardShowAISession { aiSessionRow }
                if settings.hoverCardShowRepoStats { repoStatsRow }
                if settings.hoverCardShowConflicts { conflictsRow }
                if settings.hoverCardShowTokenOptimization { tokenOptRow }
                if settings.hoverCardShowBroadcast { broadcastRow }
                suspendedRow
                if settings.hoverCardShowNotificationState { notificationRow }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            // MARK: Footer

            if settings.hoverCardShowFooter {
                Divider().background(Color.white.opacity(0.1))
                footerRow
            }
        }
        .background(Color(red: 0.10, green: 0.10, blue: 0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
        .onHover { onHoverChanged($0) }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 8) {
            // AI logo or color dot
            if let logo = aiLogo {
                logo.resizable().frame(width: 16, height: 16)
                    .opacity(session.isAIRunning ? 1.0 : 0.35)
            } else {
                Circle()
                    .fill(tab.effectiveColor.color)
                    .frame(width: 10, height: 10)
            }

            Text(tab.displayTitle)
                .font(.custom("Avenir Next", size: 13).weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(.primary)

            Spacer()

            // Status pill
            let status = statusLabel
            HStack(spacing: 4) {
                Circle()
                    .fill(status.color)
                    .frame(width: 6, height: 6)
                Text(status.text)
                    .font(.custom("Avenir Next", size: 11).weight(.medium))
                    .foregroundStyle(status.color)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Directory

    private var directoryRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(session.displayPath())
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    // MARK: - Git Branch

    @ViewBuilder
    private var gitRow: some View {
        if session.isGitRepo, let branch = session.gitBranch, !branch.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(branch)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
        }
    }

    private var shellIntegrationRow: some View {
        HStack(spacing: 8) {
            Image(systemName: session.hasShellIntegration ? "checkmark.seal.fill" : "exclamationmark.triangle")
                .font(.system(size: 11))
                .foregroundStyle(session.hasShellIntegration ? .green : .orange)
                .frame(width: 16)
            Text(session.hasShellIntegration ? "Shell integration active" : "Heuristic detection")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Dev Server

    @ViewBuilder
    private var devServerRow: some View {
        if let server = session.devServer {
            HStack(spacing: 8) {
                let isVite = server.name.compare("Vite", options: .caseInsensitive) == .orderedSame
                Image(systemName: isVite ? "bolt.fill" : "server.rack")
                    .font(.system(size: 11))
                    .foregroundStyle(isVite ? .yellow : .secondary)
                    .frame(width: 16)

                Text(server.name)
                    .font(.custom("Avenir Next", size: 12).weight(.medium))
                    .foregroundStyle(.primary)

                if let port = server.port {
                    Text(":\(port)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if let url = server.url, let nsURL = URL(string: url) {
                    Button {
                        NSWorkspace.shared.open(nsURL)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 11))
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open \(url)")
                }
            }
        }
    }

    // MARK: - Last Command

    @ViewBuilder
    private var lastCommandRow: some View {
        if let cmd = tab.lastCommand {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)

                Text(cmd.command)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                if let code = cmd.exitCode {
                    Text(code == 0 ? "✓" : "✗")
                        .foregroundStyle(code == 0 ? .green : .red)
                        .font(.system(size: 12))
                }

                if cmd.duration != nil {
                    Text(cmd.durationString)
                        .font(.custom("Avenir Next", size: 11).weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Process Info

    @ViewBuilder
    private var processInfoSection: some View {
        if let snapshot = session.processGroup, !snapshot.children.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                // Aggregate summary row
                HStack(spacing: 8) {
                    Image(systemName: "cpu")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)

                    Text("Processes")
                        .font(.custom("Avenir Next", size: 12).weight(.medium))
                        .foregroundStyle(.primary)

                    Spacer()

                    Text(snapshot.formattedTotalCPU)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(snapshot.totalCPU > 50 ? .orange : .secondary)

                    Text(snapshot.formattedTotalRSS)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                // Per-child rows (capped at 5)
                ForEach(Array(snapshot.children.prefix(5))) { child in
                    HStack(spacing: 8) {
                        Spacer().frame(width: 16)

                        Text(child.name)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Text("(\(child.pid))")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)

                        Spacer()

                        Text(child.formattedCPU)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(child.cpuPercent > 25 ? .orange : .secondary)

                        Text(child.formattedRSS)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                // Overflow indicator
                if snapshot.children.count > 5 {
                    HStack(spacing: 8) {
                        Spacer().frame(width: 16)
                        Text("+\(snapshot.children.count - 5) more")
                            .font(.custom("Avenir Next", size: 11).weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Token Optimization

    @ViewBuilder
    private var tokenOptRow: some View {
        let mode = FeatureSettings.shared.tokenOptimizationMode
        if mode != .off {
            let isActive = tab.isTokenOptActive
            let hasOverride = tab.optimizerOverrideState != nil
            let canToggle = FeatureSettings.shared.allowTabCTOToggle
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 11))
                    .foregroundStyle(isActive ? .yellow : .secondary)
                    .frame(width: 16)

                Text("Token Optimization")
                    .font(.custom("Avenir Next", size: 12).weight(.medium))
                    .foregroundStyle(.primary)

                Spacer()

                if hasOverride {
                    Text(isActive ? "Forced On" : "Forced Off")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(isActive ? .yellow : .red)
                } else {
                    Text(isActive ? "Active" : "Off")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(isActive ? .green : .secondary)
                }

                if canToggle {
                    Button(action: onToggleCTO) {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(L("cto.hovercard.toggle", "Toggle token optimization for this tab"))
                }
            }
        }
    }

    // MARK: - Broadcast

    @ViewBuilder
    private var broadcastRow: some View {
        if isBroadcastIncluded {
            HStack(spacing: 8) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .frame(width: 16)

                Text("Broadcast")
                    .font(.custom("Avenir Next", size: 12).weight(.medium))
                    .foregroundStyle(.primary)

                Spacer()

                Text("Included")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Suspended

    @ViewBuilder
    private var suspendedRow: some View {
        if isSuspended {
            HStack(spacing: 8) {
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)

                Text("Rendering")
                    .font(.custom("Avenir Next", size: 12).weight(.medium))
                    .foregroundStyle(.primary)

                Spacer()

                Text("Suspended")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Notification State

    @ViewBuilder
    private var notificationRow: some View {
        if let style = tab.notificationStyle {
            let summary = notificationSummary(for: style)
            HStack(spacing: 8) {
                if let icon = style.icon {
                    Image(systemName: icon)
                        .font(.system(size: 11))
                        .foregroundStyle(style.iconColor ?? style.titleColor ?? .secondary)
                        .frame(width: 16)
                } else {
                    Image(systemName: "bell.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(style.titleColor ?? .secondary)
                        .frame(width: 16)
                }

                Text("Notification")
                    .font(.custom("Avenir Next", size: 12).weight(.medium))
                    .foregroundStyle(.primary)

                Spacer()

                Text(summary.label)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(summary.color)
            }
        }
    }

    private func notificationSummary(for style: TabNotificationStyle) -> (label: String, color: Color) {
        if style.icon == TabNotificationStyle.error.icon ||
            style.titleColor == .red ||
            style.iconColor == .red ||
            style.borderColor == .red {
            return ("Error", .red)
        }

        if style.icon == TabNotificationStyle.success.icon ||
            style.titleColor == .green ||
            style.iconColor == .green {
            return ("Success", .green)
        }

        if style.icon == TabNotificationStyle.attention.icon ||
            style.persistent ||
            style.badgeText != nil ||
            style.borderWidth > 0 ||
            style.titleColor == .yellow ||
            style.iconColor == .yellow {
            return ("Attention", .yellow)
        }

        if style.icon == TabNotificationStyle.waiting.icon ||
            style.isItalic {
            return ("Waiting", .orange)
        }

        return ("Active", style.titleColor ?? .secondary)
    }

    // MARK: - AI Session Summary

    @ViewBuilder
    private var aiSessionRow: some View {
        let tabID = tab.id.uuidString
        // Try active run first, fall back to most recent completed run for this tab
        let run: TelemetryRun? = TelemetryRecorder.shared.activeRunForTab(tabID)
            ?? TelemetryStore.shared.listRuns(filter: TelemetryRunFilter(limit: 1)).first(where: { $0.tabID == tabID })
        if let run {
            VStack(alignment: .leading, spacing: 4) {
                // Provider + model
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                        .font(.system(size: 11))
                        .foregroundStyle(.purple)
                        .frame(width: 16)
                    Text("\(run.provider.capitalized)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                    if let model = run.model {
                        Text(model)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                // Tokens + cost + turns
                HStack(spacing: 12) {
                    let inTokens = run.totalInputTokens ?? 0
                    let outTokens = run.totalOutputTokens ?? 0
                    if inTokens + outTokens > 0 {
                        Text(formatTokens(inTokens) + " in / " + formatTokens(outTokens) + " out")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    if let cost = run.costUSD, cost > 0 {
                        Text(String(format: "$%.2f", cost))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.orange)
                    }
                    if run.turnCount > 0 {
                        Text("\(run.turnCount) turns")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 24)

                // Top tool calls
                let tools = TelemetryStore.shared.toolCallSummary(runID: run.id)
                if !tools.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(tools.prefix(3), id: \.tool) { entry in
                            Text("\(entry.tool) \u{00d7}\(entry.count)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.leading, 24)
                }
            }
        }
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1000 { return String(format: "%.0fK", Double(count) / 1000) }
        return "\(count)"
    }

    // MARK: - Repo Stats

    @ViewBuilder
    private var repoStatsRow: some View {
        let repoRoot = session.gitRootPath ?? session.displayPath()
        let stats = RepoStatsProvider.stats(for: repoRoot)
        if stats.totalRuns > 0 || stats.totalCommands > 0 {
            HStack(spacing: 6) {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.blue)
                    .frame(width: 16)
                let parts = repoStatsParts(stats)
                Text(parts.joined(separator: " \u{00b7} "))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func repoStatsParts(_ stats: RepoStats) -> [String] {
        var parts: [String] = []
        if stats.totalRuns > 0 { parts.append("\(stats.totalRuns) runs") }
        if stats.totalTokens > 0 { parts.append(formatTokens(stats.totalTokens)) }
        if stats.totalCost > 0 { parts.append(String(format: "$%.2f", stats.totalCost)) }
        if stats.totalCommands > 0 { parts.append("\(stats.totalCommands) cmds") }
        return parts
    }

    // MARK: - Conflicts

    @ViewBuilder
    private var conflictsRow: some View {
        let conflicts = ConflictDetector.shared.conflictsForTab(tab.id)
        if !conflicts.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .frame(width: 16)
                    Text("File Conflicts (\(conflicts.count))")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.orange)
                }
                ForEach(conflicts.prefix(3)) { conflict in
                    Text(conflict.filePath)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.leading, 24)
                }
                if conflicts.count > 3 {
                    Text("+\(conflicts.count - 3) more")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 24)
                }
            }
        }
    }

    // MARK: - Footer

    private var footerRow: some View {
        HStack {
            Image(systemName: "clock")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(Self.relativeFormatter.localizedString(for: tab.createdAt, relativeTo: Date()))
                .font(.custom("Avenir Next", size: 11).weight(.medium))
                .foregroundStyle(.secondary)
            if let footerSessionId {
                Text("•")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(footerSessionId)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if !tab.bookmarks.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text("\(tab.bookmarks.count)")
                        .font(.custom("Avenir Next", size: 11).weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
