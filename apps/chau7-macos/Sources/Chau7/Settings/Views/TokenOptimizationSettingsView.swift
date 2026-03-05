import SwiftUI

// MARK: - Token Optimization Settings

/// Top-level settings view for token optimization — combining optimization
/// mode selection, input prefix, per-tab overrides, optimizer status, and
/// token savings analytics.
struct TokenOptimizationSettingsView: View {
    @ObservedObject private var settings = FeatureSettings.shared
    let overlayModel: OverlayTabsModel?
    @State private var wrapperHealth: [RTKManager.WrapperHealth] = []
    @State private var mdRendererInstalled = false
    @State private var optimizerInstalled = false
    @State private var gainStats: RTKManager.RTKGainStats?
    @State private var isLoadingStats = false
    @State private var runtimeSnapshot: RTKRuntimeSnapshot = RTKRuntimeMonitor.shared.snapshot()

    init(overlayModel: OverlayTabsModel? = nil) {
        self.overlayModel = overlayModel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Mode Selection
            SettingsSectionHeader(
                L("rtk.settings.mode", "Optimization Mode"),
                icon: "bolt.horizontal.circle"
            )

            SettingsPicker(
                label: L("rtk.settings.mode.label", "Mode"),
                help: L("rtk.settings.mode.help", "Controls when token-optimized command output is active"),
                selection: modeBinding,
                options: TokenOptimizationMode.allCases.map { mode in
                    (value: mode.rawValue, label: mode.displayName)
                }
            )

            modeDescriptionView

            if settings.tokenOptimizationMode != .off {
                Divider()
                    .padding(.vertical, 8)

                // Input Prefix
                SettingsSectionHeader(L("rtk.settings.prefix", "Input Prefix"), icon: "wand.and.stars")

                SettingsToggle(
                    label: L("settings.ai.rtk.enabled", "Enable Input Prefix"),
                    help: L(
                        "settings.ai.rtk.enabledHelp",
                        "When enabled, the prefix text is prepended to terminal input."
                    ),
                    isOn: Binding(
                        get: { settings.isRTKEnabled },
                        set: { settings.isRTKEnabled = $0 }
                    )
                )

                SettingsTextField(
                    label: L("settings.ai.rtk.prefix", "Input Prefix"),
                    help: L(
                        "settings.ai.rtk.prefixHelp",
                        "Prefix text to prepend (supports per-tab overrides)."
                    ),
                    placeholder: "/think",
                    text: Binding(
                        get: { settings.rtkPrefix },
                        set: { settings.rtkPrefix = $0 }
                    ),
                    width: 220,
                    monospaced: true
                )

                Divider()
                    .padding(.vertical, 8)

                // Optimizer
                SettingsSectionHeader(
                    L("rtk.settings.optimizer", "Optimizer"),
                    icon: "checkmark.shield"
                )

                optimizerStatusView

                // Wrapper script health
                installationHealthView

                Divider()
                    .padding(.vertical, 8)

                // RTK Runtime Telemetry
                SettingsSectionHeader(
                    L("rtk.settings.rtkRuntime", "RTK Runtime Telemetry"),
                    icon: "chart.xyaxis.line"
                )

                rtkRuntimeStatsView

                Divider()
                    .padding(.vertical, 8)

                // Token Savings
                SettingsSectionHeader(
                    L("rtk.settings.savings", "Token Savings"),
                    icon: "chart.bar"
                )

                tokenSavingsView

                Divider()
                    .padding(.vertical, 8)

                // Per-Tab Control
                SettingsSectionHeader(
                    L("rtk.settings.perTab", "Per-Tab Control"),
                    icon: "rectangle.stack"
                )

                perTabInfoView

                if let overlayModel {
                    perTabOverridesView(overlayModel: overlayModel)
                }

                Divider()
                    .padding(.vertical, 8)

                // Optimized Commands
                SettingsSectionHeader(
                    L("rtk.settings.commands", "Optimized Commands"),
                    icon: "terminal"
                )

                commandsList

                Divider()
                    .padding(.vertical, 8)

                // How It Works
                SettingsSectionHeader(
                    L("rtk.settings.howItWorks", "How It Works"),
                    icon: "questionmark.circle"
                )

                howItWorksView
            }
        }
        .onAppear {
            refreshAll()
        }
        .onChange(of: settings.tokenOptimizationMode) { _ in
            refreshAll()
        }
    }

    // MARK: - Mode Binding

    private var modeBinding: Binding<String> {
        Binding(
            get: { settings.tokenOptimizationMode.rawValue },
            set: { newValue in
                if let mode = TokenOptimizationMode(rawValue: newValue) {
                    settings.tokenOptimizationMode = mode
                }
            }
        )
    }

    // MARK: - Mode Description

    @ViewBuilder
    private var modeDescriptionView: some View {
        let mode = settings.tokenOptimizationMode
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: modeIcon(for: mode))
                .font(.system(size: 24))
                .foregroundStyle(modeColor(for: mode))
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(mode.displayName)
                    .font(.headline)
                Text(mode.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if mode != .off {
                    Text(modeDetail(for: mode))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(8)
    }

    private func modeIcon(for mode: TokenOptimizationMode) -> String {
        switch mode {
        case .off: return "wand.and.stars"
        case .allTabs: return "wand.and.stars"
        case .aiOnly: return "sparkles"
        case .manual: return "hand.tap"
        }
    }

    private func modeColor(for mode: TokenOptimizationMode) -> Color {
        switch mode {
        case .off: return .secondary
        case .allTabs: return .yellow
        case .aiOnly: return .purple
        case .manual: return .blue
        }
    }

    private func modeDetail(for mode: TokenOptimizationMode) -> String {
        switch mode {
        case .off:
            return ""
        case .allTabs:
            return L("rtk.mode.allTabs.detail", "All tabs optimized by default. A red wand badge appears on tabs you opt out.")
        case .aiOnly:
            return L("rtk.mode.aiOnly.detail", "AI tabs auto-optimize. Yellow wand when you force a tab on, red wand when you force off.")
        case .manual:
            return L("rtk.mode.manual.detail", "No tabs optimized by default. A yellow wand badge appears on tabs you opt in.")
        }
    }

    // MARK: - Optimizer Status

    @ViewBuilder
    private var optimizerStatusView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("rtk.optimizer.desc", "The optimizer filters and compresses command output before it reaches your LLM context, typically saving 60-90% of tokens. It ships built-in — no external dependencies required."))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                if optimizerInstalled {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("rtk.optimizer.installed", "Installed"))
                            .font(.body)
                        Text(RTKManager.shared.optimizerPath.path)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.orange)
                    Text(L("rtk.optimizer.notInstalled", "Not installed — commands will pass through unoptimized"))
                        .font(.body)
                }

                Spacer()

                Button(L("rtk.optimizer.reinstall", "Reinstall from Bundle")) {
                    if let bundlePath = Bundle.main.url(forResource: "chau7-optim", withExtension: nil) {
                        RTKManager.shared.installOptimizer(from: bundlePath)
                    }
                    refreshAll()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Installation Health

    @ViewBuilder
    private var installationHealthView: some View {
        let allGood = !wrapperHealth.isEmpty && wrapperHealth.allSatisfy { $0.isInstalled && $0.isExecutable }

        HStack(spacing: 8) {
            Image(systemName: allGood ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(allGood ? .green : .orange)
            Text(allGood
                ? L("rtk.health.allGood", "All wrapper scripts installed and executable")
                : L("rtk.health.issues", "Some wrapper scripts need attention"))
                .font(.body)
            Spacer()
            Button(L("rtk.health.reinstall", "Reinstall")) {
                RTKManager.shared.setup()
                refreshAll()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 4)

        VStack(alignment: .leading, spacing: 4) {
            ForEach(wrapperHealth) { item in
                HStack(spacing: 8) {
                    Image(systemName: item.isInstalled && item.isExecutable
                        ? "checkmark.circle.fill"
                        : item.isInstalled ? "exclamationmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(item.isInstalled && item.isExecutable
                            ? .green
                            : item.isInstalled ? .orange : .red)
                    Text(item.command)
                        .font(.system(.body, design: .monospaced))
                    if item.command == "cat" && mdRendererInstalled {
                        Text("+ md")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.purple)
                    }
                    Spacer()
                    if !item.isInstalled {
                        Text(L("rtk.health.missing", "Missing"))
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else if !item.isExecutable {
                        Text(L("rtk.health.notExecutable", "Not executable"))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            // Markdown renderer status
            Divider().padding(.vertical, 2)
            HStack(spacing: 8) {
                Image(systemName: mdRendererInstalled ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(mdRendererInstalled ? .green : .secondary)
                Text("chau7-md")
                    .font(.system(.body, design: .monospaced))
                Text(L("rtk.health.mdRenderer", "Markdown renderer"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !mdRendererInstalled {
                    Text(L("rtk.health.mdNotInstalled", "Not installed"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if mdRendererInstalled {
                Text(L("rtk.health.mdDesc", "cat README.md renders with ANSI formatting in terminal"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 28)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Token Savings

    @ViewBuilder
    private var rtkRuntimeStatsView: some View {
        let health = runtimeSnapshot.assessment
        let healthColor: Color = switch health.state {
        case .healthy:
            .green
        case .warning:
            .orange
        case .critical:
            .red
        }
        let healthSummary = switch health.state {
        case .healthy:
            L("rtk.runtime.healthSummaryHealthy", "Healthy")
        case .warning:
            L("rtk.runtime.healthSummaryWarning", "Needs review")
        case .critical:
            L("rtk.runtime.healthSummaryCritical", "Requires attention")
        }

        VStack(alignment: .leading, spacing: 8) {
            statRow(
                icon: "checkmark.seal.fill",
                iconColor: healthColor,
                label: L("rtk.runtime.health", "Runtime health"),
                value: healthSummary
            )
            statRow(
                icon: "star.circle",
                iconColor: healthColor,
                label: L("rtk.runtime.healthScore", "Health score"),
                value: "\(health.score)/100"
            )
            statRow(
                icon: "percent",
                iconColor: .secondary,
                label: L("rtk.runtime.changeRate", "Decision change rate"),
                value: "\(String(format: "%.1f%%", runtimeSnapshot.decisionsChangeRatePercent))"
            )
            statRow(
                icon: "clock",
                iconColor: .secondary,
                label: L("rtk.runtime.deferredSkipRate", "Deferred skip rate"),
                value: "\(String(format: "%.1f%%", runtimeSnapshot.deferredSkipRatePercent))"
            )
            statRow(
                icon: "clock.arrow.circlepath",
                iconColor: .secondary,
                label: L("rtk.runtime.deferredFlushRate", "Deferred flush rate"),
                value: "\(String(format: "%.1f%%", runtimeSnapshot.deferredFlushRatePercent))"
            )
            statRow(
                icon: "person.2.circle",
                iconColor: .secondary,
                label: L("rtk.runtime.activeSessionRatio", "Active sessions ratio"),
                value: "\(String(format: "%.1f%%", runtimeSnapshot.activeSessionRatioPercent))"
            )
            if let lastDecisionAge = runtimeSnapshot.ageSinceLastDecisionSeconds {
                statRow(
                    icon: "clock.fill",
                    iconColor: .secondary,
                    label: L("rtk.runtime.lastDecisionAge", "Last decision age"),
                    value: formatDuration(lastDecisionAge)
                )
            }
            if let avgInterval = runtimeSnapshot.decisionIntervalAverageSeconds {
                statRow(
                    icon: "timer",
                    iconColor: .secondary,
                    label: L("rtk.runtime.decisionIntervalAvg", "Decision interval (avg)"),
                    value: formatDuration(avgInterval)
                )
            }
            if let minInterval = runtimeSnapshot.decisionIntervalMinSeconds {
                statRow(
                    icon: "timer",
                    iconColor: .secondary,
                    label: L("rtk.runtime.decisionIntervalMin", "Decision interval (min)"),
                    value: formatDuration(minInterval)
                )
            }
            if let maxInterval = runtimeSnapshot.decisionIntervalMaxSeconds {
                statRow(
                    icon: "timer",
                    iconColor: .secondary,
                    label: L("rtk.runtime.decisionIntervalMax", "Decision interval (max)"),
                    value: formatDuration(maxInterval)
                )
            }

            if !health.issues.isEmpty {
                Text(L("rtk.runtime.healthSignals", "Health signals"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                ForEach(health.issues, id: \.self) { issue in
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                        Text(healthIssueLabel(issue))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text(L("rtk.runtime.noHealthSignals", "No health signals"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            statRow(
                icon: "clock",
                iconColor: .secondary,
                label: L("rtk.runtime.uptime", "Monitor uptime"),
                value: formatDuration(runtimeSnapshot.uptimeSeconds)
            )
            statRow(
                icon: "speedometer",
                iconColor: .purple,
                label: L("rtk.runtime.rate", "Decisions/min"),
                value: String(format: "%.1f", runtimeSnapshot.decisionsPerMinute)
            )
            statRow(
                icon: "arrow.clockwise",
                iconColor: .blue,
                label: L("rtk.runtime.recalcCount", "Decision recalculations"),
                value: "\(runtimeSnapshot.recalcCount)"
            )
            statRow(
                icon: "plus.circle",
                iconColor: .green,
                label: L("rtk.runtime.createdCount", "Created flags"),
                value: "\(runtimeSnapshot.createdCount)"
            )
            statRow(
                icon: "minus.circle",
                iconColor: .red,
                label: L("rtk.runtime.removedCount", "Removed flags"),
                value: "\(runtimeSnapshot.removedCount)"
            )
            statRow(
                icon: "minus.circle",
                iconColor: .secondary,
                label: L("rtk.runtime.unchangedCount", "Unchanged"),
                value: "\(runtimeSnapshot.unchangedCount)"
            )
            statRow(
                icon: "arrow.triangle.2.circlepath",
                iconColor: .green,
                label: L("rtk.runtime.setupCount", "Runtime setups"),
                value: "\(runtimeSnapshot.setupCount)"
            )
            statRow(
                icon: "arrow.triangle.2.circlepath.circle.fill",
                iconColor: .orange,
                label: L("rtk.runtime.teardownCount", "Runtime teardowns"),
                value: "\(runtimeSnapshot.teardownCount)"
            )
            statRow(
                icon: "paintbrush.pointed.fill",
                iconColor: .blue,
                label: L("rtk.runtime.modeChangeCount", "Mode changes"),
                value: "\(runtimeSnapshot.modeChangeCount)"
            )
            statRow(
                icon: "clock.badge.questionmark",
                iconColor: .secondary,
                label: L("rtk.runtime.pendingDeferred", "Pending deferred sessions"),
                value: "\(runtimeSnapshot.pendingDeferredSessions)"
            )
            statRow(
                icon: "clock.arrow.2.circlepath",
                iconColor: .orange,
                label: L("rtk.runtime.deferredSet", "Deferred sets"),
                value: "\(runtimeSnapshot.deferredSetCount)"
            )
            statRow(
                icon: "clock",
                iconColor: .orange,
                label: L("rtk.runtime.deferredFlush", "Deferred flushes"),
                value: "\(runtimeSnapshot.deferredFlushCount)"
            )
            statRow(
                icon: "timer",
                iconColor: .orange,
                label: L("rtk.runtime.deferredSkip", "Deferred skips"),
                value: "\(runtimeSnapshot.deferredSkipCount)"
            )
            statRow(
                icon: "gauge.with.dots.needle.bottom.50percent",
                iconColor: .orange,
                label: L("rtk.runtime.deferredDelayCount", "Deferred delay samples"),
                value: "\(runtimeSnapshot.deferredFlushDelayCount)"
            )
            statRow(
                icon: "speedometer",
                iconColor: .blue,
                label: L("rtk.runtime.deferredDelayMin", "Deferred delay (min / max / avg / last)"),
                value: "\(formatDelay(runtimeSnapshot.deferredFlushDelayMinMs)) / " +
                    "\(formatDelay(runtimeSnapshot.deferredFlushDelayMaxMs)) / " +
                    "\(formatDelay(runtimeSnapshot.deferredFlushDelayAverageMs.map { Int($0.rounded()) })) / " +
                    "\(formatDelay(runtimeSnapshot.deferredFlushDelayLastMs))"
            )

            if !runtimeSnapshot.reasonBreakdown.isEmpty {
                Text(L("rtk.runtime.reasonBreakdown", "Decision reasons"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)

                let totalReasonCount = runtimeSnapshot.reasonBreakdown.values.reduce(0, +)
                ForEach(runtimeSnapshot.reasonBreakdown.sorted(by: { $0.key < $1.key }), id: \.key) { reason, count in
                    let ratio = totalReasonCount > 0
                        ? (Double(count) / Double(totalReasonCount) * 100)
                        : 0
                    HStack(spacing: 8) {
                        Image(systemName: "list.bullet.rectangle.portrait")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(reason)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 160, alignment: .leading)
                        Text("\(count) (\(String(format: "%.1f%%", ratio)))")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !runtimeSnapshot.recentDecisions.isEmpty {
                Text(L("rtk.runtime.recentDecisions", "Recent decisions"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)

                ForEach(runtimeSnapshot.recentDecisions.prefix(5)) { decision in
                    HStack(spacing: 8) {
                        Image(systemName: decision.changed ? "bolt.fill" : "clock.arrow.2.circlepath")
                            .font(.system(size: 11))
                            .foregroundStyle(decision.changed ? .green : .orange)
                        Text("\(decision.timestamp, formatter: compactDateFormatter)")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 150, alignment: .leading)
                        Text("\(decision.sessionID.prefix(8))")
                            .font(.system(.caption, design: .monospaced))
                        Text("\(decision.mode) \(decision.override) \(decision.reason.rawValue)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text(L("rtk.runtime.noRecentDecisions", "No decisions recorded yet"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button(L("rtk.runtime.refresh", "Refresh")) {
                    refreshRuntimeStats()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(L("rtk.runtime.reset", "Reset")) {
                    resetRuntimeStats()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            HStack {
                Spacer()
                Text(L("rtk.runtime.trackedSessions", "Tracked") + ": \(runtimeSnapshot.trackedSessions)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func formatDuration(_ seconds: Int) -> String {
        guard seconds >= 0 else { return "0s" }
        let hrs = seconds / 3600
        let mins = (seconds % 3600) / 60
        let secs = seconds % 60

        if hrs > 0 {
            return String(format: "%dh %02dm %02ds", hrs, mins, secs)
        }
        if mins > 0 {
            return String(format: "%dm %02ds", mins, secs)
        }
        return String(format: "%ds", secs)
    }

    private func healthIssueLabel(_ issue: RTKRuntimeAssessmentIssue) -> String {
        switch issue {
        case .lowChangeRate:
            L("rtk.runtime.issue.lowChangeRate", "Decision change rate is low")
        case .highDeferredSkips:
            L("rtk.runtime.issue.highDeferredSkips", "Too many deferred skips")
        case .lowDeferredFlushRate:
            L("rtk.runtime.issue.lowDeferredFlushRate", "Deferred flushes are not resolving")
        case .staleDecisions:
            L("rtk.runtime.issue.staleDecisions", "No recent decisions")
        case .modeOffWithTrackedSessions:
            L("rtk.runtime.issue.modeOffWithTrackedSessions", "Mode is off while sessions are tracked")
        case .lowDecisionThroughput:
            L("rtk.runtime.issue.lowDecisionThroughput", "No decisions despite tracked sessions")
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        if seconds < 1.0 {
            return String(format: "%.0fms", seconds * 1000.0)
        }
        return formatDuration(Int(seconds))
    }

    private func formatDelay(_ value: Int?) -> String {
        guard let value else { return "n/a" }
        return "\(value)ms"
    }

    private func refreshRuntimeStats() {
        runtimeSnapshot = RTKRuntimeMonitor.shared.snapshot()
    }

    private func resetRuntimeStats() {
        RTKRuntimeMonitor.shared.reset()
        runtimeSnapshot = RTKRuntimeMonitor.shared.snapshot()
    }

    private var compactDateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }

    @ViewBuilder
    private var tokenSavingsView: some View {
        if isLoadingStats {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(L("rtk.savings.loading", "Loading token savings..."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        } else if let stats = gainStats, stats.commands > 0 {
            // Stats available
            VStack(alignment: .leading, spacing: 6) {
                statRow(
                    icon: "number",
                    iconColor: .blue,
                    label: L("rtk.savings.totalCommands", "Total commands"),
                    value: "\(stats.commands)"
                )
                statRow(
                    icon: "arrow.right.circle",
                    iconColor: .secondary,
                    label: L("rtk.savings.inputTokens", "Input tokens"),
                    value: formatNumber(stats.inputTokens)
                )
                statRow(
                    icon: "arrow.left.circle",
                    iconColor: .secondary,
                    label: L("rtk.savings.outputTokens", "Output tokens"),
                    value: formatNumber(stats.outputTokens)
                )
                statRow(
                    icon: "arrow.down.circle.fill",
                    iconColor: .green,
                    label: L("rtk.savings.savedTokens", "Tokens saved"),
                    value: formatNumber(stats.savedTokens)
                )
                statRow(
                    icon: "percent",
                    iconColor: .green,
                    label: L("rtk.savings.avgSavings", "Avg savings"),
                    value: String(format: "%.1f%%", stats.savingsPct)
                )
                statRow(
                    icon: "clock",
                    iconColor: .secondary,
                    label: L("rtk.savings.avgResponseTime", "Avg response time"),
                    value: "\(stats.avgTimeMs)ms"
                )
            }

            HStack {
                Spacer()
                Button(L("rtk.savings.refresh", "Refresh")) {
                    loadGainStats()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.top, 4)
        } else {
            HStack(spacing: 8) {
                Image(systemName: "chart.bar")
                    .foregroundStyle(.secondary)
                Text(L("rtk.savings.noData", "No token savings data yet. Run some commands with optimization active to see analytics."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L("rtk.savings.refresh", "Refresh")) {
                    loadGainStats()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func statRow(icon: String, iconColor: Color, label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .frame(width: 20)
            Text(label)
                .font(.body)
            Spacer()
            Text(value)
                .font(.system(.body, design: .monospaced))
                .fontWeight(.semibold)
        }
        .padding(.vertical, 2)
    }

    private func formatNumber(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    // MARK: - Per-Tab Info

    @ViewBuilder
    private var perTabInfoView: some View {
        let mode = settings.tokenOptimizationMode
        VStack(alignment: .leading, spacing: 8) {
            switch mode {
            case .off:
                EmptyView()
            case .allTabs:
                infoRow(
                    icon: "wand.and.stars",
                    iconColor: .yellow,
                    text: L("rtk.perTab.allTabs.default", "All tabs optimized by default — no badge shown")
                )
                infoRow(
                    icon: "wand.and.stars",
                    iconColor: .red,
                    text: L("rtk.perTab.allTabs.optOut", "Red wand appears on tabs you opt out")
                )
            case .aiOnly:
                infoRow(
                    icon: "wand.and.stars",
                    iconColor: .yellow,
                    text: L("rtk.perTab.aiOnly.detected", "Yellow wand when you force a tab on")
                )
                infoRow(
                    icon: "wand.and.stars",
                    iconColor: .red,
                    text: L("rtk.perTab.aiOnly.cycle", "Red wand when you force a tab off")
                )
            case .manual:
                infoRow(
                    icon: "wand.and.stars",
                    iconColor: .yellow,
                    text: L("rtk.perTab.manual.optIn", "Yellow wand appears on tabs you opt in")
                )
                infoRow(
                    icon: "wand.and.stars",
                    iconColor: .secondary,
                    text: L("rtk.perTab.manual.default", "No badge on tabs following the default")
                )
            }
        }
    }

    @ViewBuilder
    private func infoRow(icon: String, iconColor: Color, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 20)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Per-Tab Overrides (Live)

    @ViewBuilder
    private func perTabOverridesView(overlayModel: OverlayTabsModel) -> some View {
        let tabRows = activeTabRows(from: overlayModel.tabs)

        if !tabRows.isEmpty {
            SettingsRow(L("settings.ai.rtk.applyAll", "Apply to all open tabs")) {
                HStack(spacing: 8) {
                    Button(L("settings.ai.rtk.enableAll", "Enable all")) {
                        applyRTK(to: tabRows.map(\.id), enabled: true)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button(L("settings.ai.rtk.disableAll", "Disable all")) {
                        applyRTK(to: tabRows.map(\.id), enabled: false)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button(L("settings.ai.rtk.clearAllOverrides", "Use global on all")) {
                        clearRTKOverrides(overlayModel: overlayModel)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            ForEach(tabRows) { row in
                SettingsRow(
                    row.tabTitle,
                    help: row.hasOverride
                        ? L("settings.ai.rtk.tabOverride", "Overrides global optimization setting for this tab.")
                        : L("settings.ai.rtk.tabInherit", "Uses global optimization setting.")
                ) {
                    HStack(spacing: 12) {
                        Toggle("", isOn: Binding(
                            get: { settings.isRTKEnabled(forTabIdentifier: row.id) },
                            set: { value in
                                if value == settings.isRTKEnabled {
                                    settings.clearRTKOverride(forTabIdentifier: row.id)
                                } else {
                                    settings.setRTKOverride(value, forTabIdentifier: row.id)
                                }
                            }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()

                        if row.hasOverride {
                            Button(L("settings.ai.rtk.clearOverride", "Use global")) {
                                settings.clearRTKOverride(forTabIdentifier: row.id)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }
        } else {
            SettingsRow(L("settings.ai.rtk.tabsUnavailable", "No active tabs")) {
                Text(L("settings.ai.rtk.waitForTabs", "Open a tab to enable per-tab settings."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func activeTabRows(from overlayTabs: [OverlayTab]) -> [RTKTabRow] {
        overlayTabs.compactMap { tab -> RTKTabRow? in
            guard let sessionIdentifier = tab.session?.tabIdentifier else { return nil }
            let override = settings.rtkOverride(forTabIdentifier: sessionIdentifier)
            return RTKTabRow(
                id: sessionIdentifier,
                tabTitle: tab.displayTitle.isEmpty ? "Tab" : tab.displayTitle,
                hasOverride: override != nil
            )
        }
        .sorted { lhs, rhs in
            lhs.tabTitle.localizedCaseInsensitiveCompare(rhs.tabTitle) == .orderedAscending
        }
    }

    private func applyRTK(to tabIDs: [String], enabled: Bool) {
        let uniqueTabIDs = Set(tabIDs)
        uniqueTabIDs.forEach { tabID in
            settings.setRTKOverride(enabled, forTabIdentifier: tabID)
        }
    }

    private func clearRTKOverrides(overlayModel: OverlayTabsModel) {
        for tab in overlayModel.tabs {
            guard let sessionIdentifier = tab.session?.tabIdentifier else { continue }
            settings.clearRTKOverride(forTabIdentifier: sessionIdentifier)
        }
    }

    // MARK: - Commands List

    @ViewBuilder
    private var commandsList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(RTKManager.supportedCommands, id: \.self) { command in
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.green)
                    Text(command)
                        .font(.system(.body, design: .monospaced))

                    if let sub = RTKManager.rtkRewriteMap[command] {
                        Text("→ optim \(sub)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.purple)
                    } else {
                        Text("exec only")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - How It Works

    @ViewBuilder
    private var howItWorksView: some View {
        VStack(alignment: .leading, spacing: 10) {
            // What the optimizer does
            Text(L("rtk.howItWorks.optimizerTitle", "The Optimizer"))
                .font(.caption)
                .fontWeight(.semibold)

            Text(L("rtk.howItWorks.optimizerDesc", "chau7-optim is a built-in binary (based on rtk) that intercepts command output and compresses it for LLM consumption. For example, `cat large_file.rs` strips comments and blank lines, `git diff` condenses to changed lines only, and `cargo build` filters out Compiling... progress, keeping only errors."))
                .font(.caption)
                .foregroundStyle(.secondary)

            codeRow("~/.chau7/bin/chau7-optim")

            // How wrappers work
            Text(L("rtk.howItWorks.wrappersTitle", "Wrapper Scripts"))
                .font(.caption)
                .fontWeight(.semibold)
                .padding(.top, 4)

            Text(L("rtk.howItWorks.desc", "When active, Chau7 prepends a directory of wrapper scripts to your PATH. Each wrapper shadows a real binary (cat, ls, git, etc.) and decides whether to optimize:"))
                .font(.caption)
                .foregroundStyle(.secondary)

            codeRow("~/.chau7/rtk_bin/")

            // Decision flow
            Text(L("rtk.howItWorks.flow", "Decision flow for each command:"))
                .font(.caption)
                .fontWeight(.semibold)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 4) {
                flowRow("1.", "Check for a per-session flag file — if absent, exec the real binary directly (zero overhead)")
                flowRow("2.", "If the flag is set and the optimizer is installed, route through chau7-optim for filtered output")
                flowRow("3.", "Special case: cat on .md files routes through chau7-md for ANSI-formatted markdown")
                flowRow("4.", "Fallback: exec the real binary unmodified")
            }

            // Flag files
            Text(L("rtk.howItWorks.flagDir", "Per-session flag files:"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            codeRow("~/.chau7/rtk_active/<SESSION_ID>")

            Text(L("rtk.howItWorks.cleanup", "All flag files and wrappers are cleaned up when the app quits or when the mode is set to Off."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func flowRow(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(number)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .trailing)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func codeRow(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(4)
    }

    // MARK: - Actions

    private func refreshAll() {
        wrapperHealth = RTKManager.shared.checkInstallation()
        mdRendererInstalled = RTKManager.shared.isMarkdownRendererInstalled
        optimizerInstalled = RTKManager.shared.isOptimizerInstalled
        loadGainStats()
        refreshRuntimeStats()
    }

    private func loadGainStats() {
        isLoadingStats = true
        Task {
            let stats = await RTKManager.shared.fetchGainStats()
            await MainActor.run {
                gainStats = stats
                isLoadingStats = false
            }
        }
    }

    private struct RTKTabRow: Identifiable {
        let id: String
        let tabTitle: String
        let hasOverride: Bool
    }
}

// MARK: - Preview

#if DEBUG
struct TokenOptimizationSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        TokenOptimizationSettingsView()
            .frame(width: 500, height: 700)
    }
}
#endif
