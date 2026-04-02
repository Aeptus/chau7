import SwiftUI
import AppKit
import Chau7Core

// MARK: - Debug Console View

/// A hidden debug console accessible via Cmd+Shift+L (when enabled).
/// Shows real-time state, token optimizer runtime, event history, and allows generating bug reports.
struct DebugConsoleView: View {
    private enum AnalyticsMode: String, CaseIterable {
        case apiCalls = "API Calls"
        case aiRuns = "AI Runs"
        case repos = "Repos"
    }

    var appModel: AppModel
    @ObservedObject var overlayModel: OverlayTabsModel
    @ObservedObject private var settings = FeatureSettings.shared
    @State private var selectedTab = 0
    @State private var showAllEvents = true
    @State private var logFilter = ""
    @State private var autoRefresh = true
    @State private var refreshTimer: Timer?
    @State private var logs: [String] = []
    @State private var showAllLagEvents = false
    @State private var perfSnapshot: FeatureProfiler.Snapshot = .empty
    @State private var perfShowSlowOnly = true
    @State private var ctoRuntimeSnapshot: CTORuntimeSnapshot = CTORuntimeMonitor.shared.snapshot()
    @State private var ctoGainStats: CTOGainStats?
    @State private var ctoDailyGainEntries: [CTOManager.DailyGainEntry] = []
    @State private var ctoCommandLog: [CTOManager.CommandLogEntry] = []
    @State private var ctoShowAdvanced = false
    @State private var ctoTimePeriod: CTOTimePeriod = .session
    @State private var analyticsMode: AnalyticsMode = .apiCalls
    @State private var aiPerTabStats: [TabTokenConsumption] = []
    @State private var providerStats: [ProviderConsumptionStats] = []
    @State private var dailyCostTrend: [(date: String, cost: Double, tokens: Int, pricedRunCount: Int, totalRunCount: Int)] = []
    @State private var proxyStats: APICallStats = .init()
    @State private var proxyProviderStats: [ProxyProviderAnalytics] = []
    @State private var proxyDailyTrend: [ProxyDailyAnalyticsPoint] = []
    @State private var recentProxyCalls: [APICallEvent] = []
    @State private var repoAnalytics: [(path: String, name: String, stats: RepoStats)] = []
    @State private var ptyLogInfo: [(name: String, size: UInt64)] = []
    @State private var ctoPerSessionGain: [String: CTOGainStats] = [:]
    // Category & level filtering
    @State private var enabledCategories: Set<LogCategory> = Set(LogCategory.allCases)
    @State private var enabledLevels: Set = ["INFO", "WARN", "ERROR", "TRACE", "DEBUG"]
    @State private var bugReportDescription = ""
    @State private var lastReportPath: String?

    let onClose: () -> Void

    private let msFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header

            Divider()

            // Tab picker
            Picker("", selection: $selectedTab) {
                Text(L("State", "State")).tag(0)
                Text(L("debug.optimizer", "Token Optimizer")).tag(1)
                Text(L("Events", "Events")).tag(2)
                Text(L("Lag", "Lag")).tag(3)
                Text(L("debug.perfTab", "Perf")).tag(4)
                Text(L("Logs", "Logs")).tag(5)
                Text(L("Report", "Report")).tag(6)
                Text("Analytics").tag(7)
                Text("Health").tag(8)
            }
            .pickerStyle(.segmented)
            .padding(8)

            Divider()

            // Content
            Group {
                switch selectedTab {
                case 0: stateView
                case 1: tokenOptimizerView
                case 2: eventsView
                case 3: lagTimelineView
                case 4: performanceView
                case 5: logsView
                case 6: reportView
                case 7: analyticsView
                case 8: healthDashboardView
                default: stateView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 700, height: 500)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { startRefresh() }
        .onDisappear { stopRefresh() }
        .onChange(of: selectedTab) {
            if selectedTab == 1 {
                refreshCTOData()
            }
        }
        .onChange(of: ctoTimePeriod) {
            refreshCTOData()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "ladybug.fill")
                .font(.system(size: 16))
                .foregroundStyle(.orange)

            Text(L("Debug Console", "Debug Console"))
                .font(.system(size: 14, weight: .semibold))

            Spacer()

            Toggle(L("Auto-refresh", "Auto-refresh"), isOn: $autoRefresh)
                .toggleStyle(.switch)
                .controlSize(.small)
                .onChange(of: autoRefresh) {
                    if autoRefresh { startRefresh() } else { stopRefresh() }
                }

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
    }

    // MARK: - State View

    private var stateView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                applicationStateView
                tabsStateView
                performanceSummaryView
                performanceSettingsView
                featureFlagsView
            }
            .padding()
        }
    }

    private var applicationStateView: some View {
        GroupBox(L("Application", "Application")) {
            VStack(alignment: .leading, spacing: 4) {
                stateRow(L("debug.monitoring", "Monitoring"), value: appModel.isMonitoring ? L("status.active", "Active") : L("status.paused", "Paused"))
                stateRow(L("debug.tabs", "Tabs"), value: overlayModel.tabs.count.formatted())
                stateRow(L("debug.activeTab", "Active Tab"), value: ((overlayModel.tabs.firstIndex { $0.id == overlayModel.selectedTabID } ?? 0) + 1).formatted())
                stateRow(L("debug.claudeSessions", "Claude Sessions"), value: appModel.claudeCodeSessions.count.formatted())
                stateRow(L("debug.eventCount", "Event Count"), value: appModel.recentEvents.count.formatted())
                stateRow(L("debug.claudeEventCount", "Claude Event Count"), value: appModel.claudeCodeEvents.count.formatted())
            }
        }
    }

    private var tabsStateView: some View {
        GroupBox(L("Tabs", "Tabs")) {
            ForEach(Array(overlayModel.tabs.enumerated()), id: \.element.id) { index, tab in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(String(format: L("debug.tabNumber", "Tab %d"), index + 1))
                            .font(.system(size: 11, weight: .semibold))
                        if tab.id == overlayModel.selectedTabID {
                            Text(L("(active)", "(active)"))
                                .font(.system(size: 10))
                                .foregroundStyle(.green)
                        }
                        Spacer()
                        Text(tab.session?.status.rawValue ?? L("status.noSession", "no session"))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    Group {
                        stateRow(L("debug.title", "Title"), value: tab.customTitle ?? tab.session?.title ?? L("status.noTerminal", "(no terminal)"))
                        stateRow(L("debug.app", "App"), value: tab.session?.aiDisplayAppName ?? L("status.none", "none"))
                        stateRow(L("debug.directory", "Directory"), value: tab.session?.currentDirectory ?? "")
                        stateRow(L("debug.inputLag", "Input Lag"), value: tab.session?.inputLatencySummary ?? L("status.notAvailable", "n/a"))
                        stateRow(L("debug.outputLag", "Output Lag"), value: tab.session?.outputLatencySummary ?? L("status.notAvailable", "n/a"))
                        stateRow(L("debug.highlightLag", "Highlight Lag"), value: tab.session?.dangerousHighlightLatencySummary ?? L("status.notAvailable", "n/a"))
                        if tab.session?.isGitRepo == true {
                            stateRow(L("debug.gitBranch", "Git Branch"), value: tab.session?.gitBranch ?? L("status.unknown", "unknown"))
                        }
                    }
                    .padding(.leading, 8)

                    if index < overlayModel.tabs.count - 1 {
                        Divider()
                    }
                }
            }
        }
    }

    private var performanceSummaryView: some View {
        GroupBox(L("debug.performanceSummary", "Performance Summary")) {
            if let activeTab = overlayModel.tabs.first(where: { $0.id == overlayModel.selectedTabID }),
               let session = activeTab.session {
                VStack(alignment: .leading, spacing: 4) {
                    stateRow(L("debug.inputP50P95", "Input p50/p95"), value: session.inputLatencyPercentilesSummary)
                    stateRow(L("debug.outputP50P95", "Output p50/p95"), value: session.outputLatencyPercentilesSummary)
                    stateRow(L("debug.highlightP50P95", "Highlight p50/p95"), value: session.dangerousHighlightPercentilesSummary)
                }
                .padding(.vertical, 2)
            } else {
                Text(L("status.notAvailable", "n/a"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }
        }
    }

    private var featureFlagsView: some View {
        GroupBox(L("Feature Flags", "Feature Flags")) {
            let features = FeatureSettings.shared
            VStack(alignment: .leading, spacing: 4) {
                flagRow(L("debug.feature.snippets", "Snippets"), enabled: features.isSnippetsEnabled)
                flagRow(L("debug.feature.repoSnippets", "Repo Snippets"), enabled: features.isRepoSnippetsEnabled)
                flagRow(L("debug.feature.broadcast", "Broadcast Mode"), enabled: features.isBroadcastEnabled)
                flagRow(L("debug.feature.clipboard", "Clipboard History"), enabled: features.isClipboardHistoryEnabled)
                flagRow(L("debug.feature.bookmarks", "Bookmarks"), enabled: features.isBookmarksEnabled)
            }
        }
    }

    private var performanceSettingsView: some View {
        GroupBox(L("debug.performance", "Performance")) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle(L("debug.highlightLowPower", "Low-Power Highlighting"), isOn: $settings.dangerousOutputHighlightLowPowerEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                performanceSettingRow(
                    L("debug.highlightIdleDelay", "Highlight Idle Delay (ms)"),
                    value: $settings.dangerousOutputHighlightIdleDelayMs,
                    range: 0 ... 5000,
                    step: 50
                )
                performanceSettingRow(
                    L("debug.highlightMaxInterval", "Highlight Max Interval (ms)"),
                    value: $settings.dangerousOutputHighlightMaxIntervalMs,
                    range: 250 ... 10000,
                    step: 250
                )
            }
            .padding(.vertical, 4)
        }
    }

    private func stateRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func flagRow(_ label: String, enabled: Bool) -> some View {
        HStack {
            Circle()
                .fill(enabled ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 11))
            Spacer()
            Text(enabled ? L("status.on", "On").uppercased() : L("status.off", "Off").uppercased())
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(enabled ? .green : .secondary)
        }
    }

    private func performanceSettingRow(
        _ label: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int
    ) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
            Spacer()
            TextField("", value: value, formatter: msFormatter)
                .frame(width: 60)
            Stepper("", value: value, in: range, step: step)
                .labelsHidden()
        }
    }

    // MARK: - Token Optimizer View

    private var tokenOptimizerView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                // Time period picker
                Picker("Period", selection: $ctoTimePeriod) {
                    ForEach(CTOTimePeriod.allCases, id: \.self) { period in
                        Text(period.rawValue).tag(period)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(ctoPeriodNote)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                // Hero: key metrics
                ctoHeroSection

                // Per-tab breakdown
                ctoPerTabSection

                // Provider consumption
                providerConsumptionSection

                // Recent commands log
                ctoRecentCommandsSection

                // Advanced telemetry (collapsible)
                ctoAdvancedSection

                // Actions
                HStack(spacing: 8) {
                    Button("Refresh") { refreshCTOData() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("Reset Monitor") {
                        CTORuntimeMonitor.shared.reset()
                        refreshCTOData()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Spacer()
                    Text("Global Mode: \(ctoRuntimeSnapshot.mode)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
        }
    }

    // MARK: - CTO Hero Metrics

    private var ctoHeroSection: some View {
        GroupBox {
            let log = ctoFilteredLog
            let filteredStats = ctoFilteredGainStats
            HStack(spacing: 0) {
                ctoHeroMetric(
                    title: "Command Rate",
                    value: ctoFilteredRate,
                    color: ctoFilteredRateColor
                )
                Divider().frame(height: 40)
                ctoHeroMetric(
                    title: ctoSavingsMetricTitle(base: "Token Rate"),
                    value: filteredStats.map { String(format: "%.0f%%", $0.savingsPct) } ?? "--",
                    color: ctoTokenRateColor
                )
                Divider().frame(height: 40)
                ctoHeroMetric(
                    title: ctoSavingsMetricTitle(base: "Tokens Saved"),
                    value: filteredStats.map { formatTokenCount($0.savedTokens) } ?? "--",
                    color: .green
                )
                Divider().frame(height: 40)
                ctoHeroMetric(
                    title: "Optimized",
                    value: log.isEmpty ? "--" : "\(log.filter { $0.outcome == "optimized" }.count)",
                    color: .blue
                )
                Divider().frame(height: 40)
                ctoHeroMetric(
                    title: "Fallthrough",
                    value: log.isEmpty ? "--" : "\(log.filter { $0.outcome == "fallthrough" }.count)",
                    color: .orange
                )
                Divider().frame(height: 40)
                ctoHeroMetric(
                    title: "Skipped",
                    value: log.isEmpty ? "--" : "\(log.filter { $0.outcome == "skipped" }.count)",
                    color: .secondary
                )
            }
        }
    }

    private func ctoHeroMetric(title: String, value: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    /// Optimization rate excluding intentionally skipped commands.
    private var ctoFilteredRate: String {
        let log = ctoFilteredLog.filter { $0.outcome != "skipped" }
        guard !log.isEmpty else { return "--" }
        let optimized = log.filter { $0.outcome == "optimized" }.count
        let rate = Double(optimized) / Double(log.count) * 100
        return String(format: "%.0f%%", rate)
    }

    private var ctoFilteredRateColor: Color {
        let log = ctoFilteredLog.filter { $0.outcome != "skipped" }
        guard !log.isEmpty else { return .secondary }
        let optimized = log.filter { $0.outcome == "optimized" }.count
        let rate = Double(optimized) / Double(log.count) * 100
        if rate >= 80 { return .green }
        if rate >= 50 { return .orange }
        return .red
    }

    private var ctoTokenRateColor: Color {
        guard let stats = ctoFilteredGainStats else { return .secondary }
        let pct = stats.savingsPct
        if pct >= 40 { return .green }
        if pct >= 20 { return .orange }
        return .red
    }

    private var ctoPeriodNote: String {
        switch ctoTimePeriod {
        case .session:
            return "Command counts use the selected period. Token savings come from daily optimizer totals, so Session shows today's savings."
        case .today, .week, .all:
            return "Command counts and token savings use the selected period."
        }
    }

    private func ctoSavingsMetricTitle(base: String) -> String {
        ctoTimePeriod == .session ? "\(base) (Day)" : base
    }

    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1000 { return String(format: "%.1fK", Double(count) / 1000) }
        return "\(count)"
    }

    private func formatCost(_ cost: Double) -> String {
        if cost >= 1.0 { return String(format: "$%.2f", cost) }
        if cost >= 0.01 { return String(format: "$%.3f", cost) }
        if cost > 0 { return String(format: "$%.4f", cost) }
        return "--"
    }

    // MARK: - CTO Per-Tab Breakdown

    private var ctoPerTabSection: some View {
        GroupBox("Per-Tab Stats") {
            let log = ctoFilteredLog
            if log.isEmpty, aiPerTabStats.isEmpty {
                Text("No command data yet")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    // Header row
                    HStack(spacing: 0) {
                        Text("Tab")
                            .frame(width: 90, alignment: .leading)
                        Text("Cmds")
                            .frame(width: 40, alignment: .trailing)
                        Text("Opt")
                            .frame(width: 40, alignment: .trailing)
                        Text("Fall")
                            .frame(width: 40, alignment: .trailing)
                        Text("Skip")
                            .frame(width: 40, alignment: .trailing)
                        Text("Rate")
                            .frame(width: 45, alignment: .trailing)
                        Text("In Tok")
                            .frame(width: 55, alignment: .trailing)
                        Text("Out Tok")
                            .frame(width: 55, alignment: .trailing)
                        Text("Cost")
                            .frame(width: 50, alignment: .trailing)
                        Text("CTO Saved")
                            .frame(width: 65, alignment: .trailing)
                        Spacer()
                    }
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)

                    Divider()

                    let tabStats = ctoPerTabStats(from: log)
                    let allSessionIDs = Set(tabStats.map(\.sessionID)).union(aiPerTabStats.map(\.tabID))

                    ForEach(Array(allSessionIDs).sorted(by: { a, b in
                        // Sort by total AI tokens (input+output), then by CTO command count as tiebreaker
                        let aTokens = aiPerTabStats.first { $0.tabID == a }.map { $0.totalInputTokens + $0.totalOutputTokens } ?? 0
                        let bTokens = aiPerTabStats.first { $0.tabID == b }.map { $0.totalInputTokens + $0.totalOutputTokens } ?? 0
                        if aTokens != bTokens { return aTokens > bTokens }
                        let aCmds = tabStats.first { $0.sessionID == a }?.total ?? 0
                        let bCmds = tabStats.first { $0.sessionID == b }?.total ?? 0
                        return aCmds > bCmds
                    }), id: \.self) { sessionID in
                        let tabStat = tabStats.first { $0.sessionID == sessionID }
                        let aiStat = aiPerTabStats.first { $0.tabID == sessionID }
                        let ctoSaved = ctoPerSessionGain[sessionID]

                        HStack(spacing: 0) {
                            Text(ctoTabLabel(for: sessionID))
                                .frame(width: 90, alignment: .leading)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text("\(tabStat?.total ?? 0)")
                                .frame(width: 40, alignment: .trailing)
                            Text("\(tabStat?.optimized ?? 0)")
                                .foregroundStyle(.green)
                                .frame(width: 40, alignment: .trailing)
                            Text("\(tabStat?.fallthrough ?? 0)")
                                .foregroundStyle(.orange)
                                .frame(width: 40, alignment: .trailing)
                            Text("\(tabStat?.skipped ?? 0)")
                                .foregroundStyle(.secondary)
                                .frame(width: 40, alignment: .trailing)
                            Text(tabStat.map { String(format: "%.0f%%", $0.rate) } ?? "--")
                                .foregroundStyle(tabStat.map { $0.rate >= 80 ? Color.green : $0.rate >= 50 ? .orange : .red } ?? .secondary)
                                .frame(width: 45, alignment: .trailing)
                            Text(aiStat.map { formatTokenCount($0.totalInputTokens) } ?? "--")
                                .frame(width: 55, alignment: .trailing)
                            Text(aiStat.map { formatTokenCount($0.totalOutputTokens) } ?? "--")
                                .frame(width: 55, alignment: .trailing)
                            Text(aiStat.map { formatCost($0.totalCostUSD) } ?? "--")
                                .frame(width: 50, alignment: .trailing)
                            Text(ctoSaved.map { formatTokenCount($0.savedTokens) } ?? "--")
                                .foregroundStyle(.green)
                                .frame(width: 65, alignment: .trailing)
                            Spacer()
                        }
                        .font(.system(size: 10, design: .monospaced))
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    // MARK: - Provider Consumption

    private var providerConsumptionSection: some View {
        GroupBox("Provider Consumption") {
            if providerStats.isEmpty {
                Text("No AI run data yet")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 0) {
                        Text("Provider")
                            .frame(width: 120, alignment: .leading)
                        Text("Runs")
                            .frame(width: 50, alignment: .trailing)
                        Text("Input")
                            .frame(width: 70, alignment: .trailing)
                        Text("Output")
                            .frame(width: 70, alignment: .trailing)
                        Text("Total")
                            .frame(width: 70, alignment: .trailing)
                        Text("Cost")
                            .frame(width: 65, alignment: .trailing)
                        Spacer()
                    }
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)

                    Divider()

                    ForEach(providerStats) { stat in
                        HStack(spacing: 0) {
                            Text(stat.provider)
                                .frame(width: 120, alignment: .leading)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Text("\(stat.runCount)")
                                .frame(width: 50, alignment: .trailing)
                            Text(formatTokenCount(stat.totalInputTokens))
                                .frame(width: 70, alignment: .trailing)
                            Text(formatTokenCount(stat.totalOutputTokens))
                                .frame(width: 70, alignment: .trailing)
                            Text(formatTokenCount(stat.totalInputTokens + stat.totalOutputTokens))
                                .frame(width: 70, alignment: .trailing)
                            Text(formatCost(stat.totalCostUSD))
                                .frame(width: 65, alignment: .trailing)
                            Spacer()
                        }
                        .font(.system(size: 10, design: .monospaced))
                        .padding(.vertical, 2)
                    }

                    // Totals row
                    Divider()
                    let totalRuns = providerStats.reduce(0) { $0 + $1.runCount }
                    let totalIn = providerStats.reduce(0) { $0 + $1.totalInputTokens }
                    let totalOut = providerStats.reduce(0) { $0 + $1.totalOutputTokens }
                    let totalCost = providerStats.reduce(0.0) { $0 + $1.totalCostUSD }
                    HStack(spacing: 0) {
                        Text("Total")
                            .frame(width: 120, alignment: .leading)
                        Text("\(totalRuns)")
                            .frame(width: 50, alignment: .trailing)
                        Text(formatTokenCount(totalIn))
                            .frame(width: 70, alignment: .trailing)
                        Text(formatTokenCount(totalOut))
                            .frame(width: 70, alignment: .trailing)
                        Text(formatTokenCount(totalIn + totalOut))
                            .frame(width: 70, alignment: .trailing)
                        Text(formatCost(totalCost))
                            .frame(width: 65, alignment: .trailing)
                        Spacer()
                    }
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private struct CTOTabStat {
        let sessionID: String
        let total: Int
        let optimized: Int
        let `fallthrough`: Int
        let skipped: Int
        /// Rate excludes skipped commands (intentional bypass).
        var rate: Double {
            let meaningful = total - skipped
            return meaningful > 0 ? Double(optimized) / Double(meaningful) * 100 : 0
        }
    }

    private func ctoPerTabStats(from log: [CTOManager.CommandLogEntry]) -> [CTOTabStat] {
        var grouped: [String: (optimized: Int, fallthrough: Int, skipped: Int, total: Int)] = [:]
        for entry in log {
            var stats = grouped[entry.sessionID, default: (0, 0, 0, 0)]
            stats.total += 1
            if entry.outcome == "optimized" { stats.optimized += 1 }
            if entry.outcome == "fallthrough" { stats.fallthrough += 1 }
            if entry.outcome == "skipped" { stats.skipped += 1 }
            grouped[entry.sessionID] = stats
        }
        return grouped.map { sessionID, stats in
            CTOTabStat(sessionID: sessionID, total: stats.total, optimized: stats.optimized, fallthrough: stats.fallthrough, skipped: stats.skipped)
        }.sorted { $0.total > $1.total }
    }

    private struct DebugTabDescriptor {
        let label: String
        let providerBadge: String?
    }

    private func ctoTabLabel(for sessionID: String) -> String {
        let telemetry = aiPerTabStats.first(where: { $0.tabID == sessionID })
        return debugTabDescriptor(
            for: sessionID,
            fallbackProvider: telemetry?.lastProvider,
            fallbackLocationPath: telemetry?.lastLocationPath
        ).label
    }

    private func debugTabDescriptor(
        for sessionID: String,
        fallbackProvider: String? = nil,
        fallbackLocationPath: String? = nil
    ) -> DebugTabDescriptor {
        if let (tab, session) = liveTabContext(for: sessionID) {
            let customTitle = trimmedTabTitle(tab.customTitle)
            let providerName = providerDisplayName(from: session.effectiveAIProvider)
            let baseTitle = trimmedTabTitle(tab.customTitle)
                ?? session.aiDisplayAppName
                ?? providerName
                ?? tab.displayTitle
            let repoName = liveRepoName(for: session)
            let disambiguator = splitSessionDisambiguator(
                for: session,
                in: tab,
                excluding: [baseTitle, repoName, customTitle]
            )
            let label = composedTabLabel(
                baseTitle: baseTitle,
                repoName: repoName,
                disambiguator: disambiguator
            )
            let providerBadge = providerBadgeLabel(
                providerName: providerName,
                customTitle: customTitle,
                composedLabel: label
            )
            return DebugTabDescriptor(label: label, providerBadge: providerBadge)
        }

        let baseTitle = providerDisplayName(from: fallbackProvider) ?? String(sessionID.prefix(8))
        return DebugTabDescriptor(
            label: composedTabLabel(
                baseTitle: baseTitle,
                repoName: locationDisplayName(from: fallbackLocationPath)
            ),
            providerBadge: nil
        )
    }

    private func liveTabContext(for sessionID: String) -> (tab: OverlayTab, session: TerminalSessionModel)? {
        for tab in overlayModel.tabs {
            if let session = tab.splitController.root.allSessions.first(where: { $0.tabIdentifier == sessionID }) {
                return (tab, session)
            }
        }
        return nil
    }

    private func trimmedTabTitle(_ title: String?) -> String? {
        guard let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func liveRepoName(for session: TerminalSessionModel) -> String? {
        if let model = session.repositoryModel {
            return model.repoName
        }
        if let gitRootPath = session.gitRootPath,
           !gitRootPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: gitRootPath).lastPathComponent
        }
        return nil
    }

    private func locationDisplayName(from path: String?) -> String? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private func providerDisplayName(from provider: String?) -> String? {
        guard let trimmed = provider?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }

        let normalized = AIResumeParser.normalizeProviderName(trimmed) ?? trimmed.lowercased()
        if let tool = AIToolRegistry.allTools.first(where: { tool in
            tool.displayName.lowercased() == normalized
                || tool.resumeProviderKey == normalized
                || tool.commandNames.contains(normalized)
        }) {
            return tool.displayName
        }
        return trimmed.capitalized
    }

    private func splitSessionDisambiguator(
        for session: TerminalSessionModel,
        in tab: OverlayTab,
        excluding values: [String?]
    ) -> String? {
        guard tab.splitController.root.allSessions.count > 1 else { return nil }
        let excluded = Set(values.compactMap { value in
            value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })

        let candidates = [
            trimmedTabTitle(session.aiDisplayAppName),
            providerDisplayName(from: session.effectiveAIProvider),
            locationDisplayName(from: session.currentDirectory)
        ]
        for candidate in candidates {
            guard let candidate else { continue }
            let normalized = candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !normalized.isEmpty, !excluded.contains(normalized) {
                return candidate
            }
        }
        return String(session.tabIdentifier.prefix(4)).uppercased()
    }

    private func providerBadgeLabel(
        providerName: String?,
        customTitle: String?,
        composedLabel: String
    ) -> String? {
        guard let providerName,
              customTitle != nil,
              !composedLabel.localizedCaseInsensitiveContains(providerName) else {
            return nil
        }
        return providerName
    }

    private func composedTabLabel(baseTitle: String, repoName: String?, disambiguator: String? = nil) -> String {
        let title: String
        if let disambiguator,
           !disambiguator.isEmpty,
           disambiguator.caseInsensitiveCompare(baseTitle) != .orderedSame {
            title = "\(baseTitle) · \(disambiguator)"
        } else {
            title = baseTitle
        }

        guard let repoName = repoName,
              !repoName.isEmpty,
              title.caseInsensitiveCompare(repoName) != .orderedSame else {
            return title
        }
        return "\(title) - \(repoName)"
    }

    // MARK: - CTO Recent Commands

    private var ctoRecentCommandsSection: some View {
        GroupBox("Recent Commands") {
            let log = ctoFilteredLog
            if log.isEmpty {
                Text("No commands logged yet. Commands are logged when CTO is active.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(log.suffix(20).reversed()) { entry in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(ctoOutcomeColor(entry.outcome))
                                .frame(width: 6, height: 6)
                            Text(entry.timestamp, formatter: compactDateFormatter)
                                .frame(width: 80, alignment: .leading)
                            Text(entry.command)
                                .frame(width: 80, alignment: .leading)
                            Text(entry.outcome)
                                .foregroundStyle(ctoOutcomeColor(entry.outcome))
                                .frame(width: 80, alignment: .leading)
                            if entry.exitCode != 0, entry.outcome == "error" {
                                Text("exit \(entry.exitCode)")
                                    .foregroundStyle(.red)
                            }
                            Spacer()
                        }
                        .font(.system(size: 10, design: .monospaced))
                        .opacity(entry.isIntentionalSkip ? 0.5 : 1.0)
                    }
                }
            }
        }
    }

    private func ctoOutcomeColor(_ outcome: String) -> Color {
        switch outcome {
        case "optimized": return .green
        case "fallthrough": return .orange
        case "skipped": return Color(nsColor: .tertiaryLabelColor)
        default: return .red
        }
    }

    // MARK: - CTO Advanced Telemetry

    private var ctoAdvancedSection: some View {
        DisclosureGroup("Advanced Telemetry", isExpanded: $ctoShowAdvanced) {
            VStack(alignment: .leading, spacing: 8) {
                let health = ctoRuntimeSnapshot.assessment
                let healthColor: Color = switch health.state {
                case .healthy: .green
                case .warning: .orange
                case .critical: .red
                }

                // Health + metrics
                VStack(alignment: .leading, spacing: 6) {
                    Text("Runtime telemetry below is monitor-lifetime and ignores the period filter.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    statRow(icon: "checkmark.seal.fill", iconColor: healthColor, label: "Runtime health", value: health.state.rawValue)
                    statRow(icon: "star.circle", iconColor: healthColor, label: "Health score", value: "\(health.score)/100")
                    statRow(icon: "arrow.triangle.2.circlepath", iconColor: .blue, label: "Recalculations", value: "\(ctoRuntimeSnapshot.recalcCount)")
                    statRow(icon: "plus.circle", iconColor: .green, label: "Flags created", value: "\(ctoRuntimeSnapshot.createdCount)")
                    statRow(icon: "minus.circle", iconColor: .red, label: "Flags removed", value: "\(ctoRuntimeSnapshot.removedCount)")
                    statRow(icon: "equal.circle", iconColor: .secondary, label: "Unchanged", value: "\(ctoRuntimeSnapshot.unchangedCount)")
                    statRow(icon: "percent", iconColor: .secondary, label: "Change rate", value: String(format: "%.1f%%", ctoRuntimeSnapshot.decisionsChangeRatePercent))
                    statRow(icon: "speedometer", iconColor: .blue, label: "Decisions/min", value: String(format: "%.1f", ctoRuntimeSnapshot.decisionsPerMinute))
                    statRow(icon: "clock", iconColor: .secondary, label: "Uptime", value: ctoFormatDuration(ctoRuntimeSnapshot.uptimeSeconds))
                    statRow(icon: "person.2.circle", iconColor: .secondary, label: "Active sessions", value: "\(ctoRuntimeSnapshot.activeSessionCount) / \(ctoRuntimeSnapshot.trackedSessions)")
                }

                // Deferred stats
                if ctoRuntimeSnapshot.deferredSetCount > 0 {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        statRow(
                            icon: "clock.arrow.2.circlepath",
                            iconColor: .orange,
                            label: "Deferred set / flush / skip",
                            value: "\(ctoRuntimeSnapshot.deferredSetCount) / \(ctoRuntimeSnapshot.deferredFlushCount) / \(ctoRuntimeSnapshot.deferredSkipCount)"
                        )
                        statRow(
                            icon: "clock",
                            iconColor: .orange,
                            label: "Deferred delay (min/avg/max)",
                            value: "\(ctoFormatDelay(ctoRuntimeSnapshot.deferredFlushDelayMinMs)) / \(ctoFormatDelay(ctoRuntimeSnapshot.deferredFlushDelayAverageMs.map { Int($0.rounded()) })) / \(ctoFormatDelay(ctoRuntimeSnapshot.deferredFlushDelayMaxMs))"
                        )
                    }
                }

                // Health signals
                if !health.issues.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(health.issues, id: \.self) { issue in
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.orange)
                                Text(tokenOptimizerHealthIssueLabel(issue))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                // Reason breakdown
                if !ctoRuntimeSnapshot.reasonBreakdown.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Decision Reasons")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        let total = ctoRuntimeSnapshot.reasonBreakdown.values.reduce(0, +)
                        ForEach(ctoRuntimeSnapshot.reasonBreakdown.sorted(by: { $0.key < $1.key }), id: \.key) { reason, count in
                            HStack(spacing: 8) {
                                Text(reason)
                                    .frame(width: 140, alignment: .leading)
                                Text("\(count) (\(String(format: "%.0f%%", total > 0 ? Double(count) / Double(total) * 100 : 0)))")
                            }
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                        }
                    }
                }

                // Recent decisions
                if !ctoRuntimeSnapshot.recentDecisions.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Recent Decisions")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        ForEach(ctoRuntimeSnapshot.recentDecisions.suffix(6).reversed()) { decision in
                            HStack(spacing: 6) {
                                Image(systemName: decision.changed ? "bolt.fill" : "equal.circle")
                                    .font(.system(size: 9))
                                    .foregroundStyle(decision.changed ? .green : .secondary)
                                Text(decision.timestamp, formatter: compactDateFormatter)
                                    .frame(width: 75, alignment: .leading)
                                Text(String(decision.sessionID.prefix(8)))
                                Text(decision.reason.rawValue)
                            }
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.top, 4)
        }
        .font(.system(size: 11))
    }

    // MARK: - Events View

    private var eventsView: some View {
        VStack(spacing: 0) {
            Picker("", selection: $showAllEvents) {
                Text("All Events").tag(true)
                Text("Claude Events").tag(false)
            }
            .pickerStyle(.segmented)
            .padding(8)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(eventsForDisplay) { event in
                        aiEventRow(event)
                    }
                }
                .padding()
            }
        }
    }

    private var eventsForDisplay: [AIEvent] {
        let mappedClaudeEvents = appModel.claudeCodeEvents.compactMap { event in
            let rawEvent = AIEvent(
                source: .claudeCode,
                type: event.type.rawValue,
                tool: event.toolName.isEmpty ? (event.hook.isEmpty ? "Claude" : event.hook) : event.toolName,
                message: event.message,
                ts: DateFormatters.iso8601.string(from: event.timestamp)
            )

            switch NotificationProviderAdapterRegistry.adapt(rawEvent) {
            case .emit(let adapted, _):
                return adapted
            case .drop:
                return nil
            }
        }

        if showAllEvents {
            return Array(appModel.recentEvents.reversed())
        }
        return Array(mappedClaudeEvents.reversed())
    }

    private func aiEventRow(_ event: AIEvent) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(event.type.uppercased())
                    .font(.system(size: 10, design: .monospaced))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(aiEventTypeColor(event.type).opacity(0.2))
                    .foregroundStyle(aiEventTypeColor(event.type))
                    .clipShape(RoundedRectangle(cornerRadius: 3))

                Text(event.tool.isEmpty ? event.source.rawValue : event.tool)
                    .font(.system(size: 11, weight: .medium))

                Spacer()

                Text(formatEventTime(event.ts))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if !event.message.isEmpty {
                Text(event.message)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func aiEventTypeColor(_ type: String) -> Color {
        let semanticKind = NotificationSemanticMapping.kind(rawType: type)
        switch semanticKind {
        case .taskFailed:
            return .red
        case .permissionRequired:
            return .yellow
        case .waitingForInput, .attentionRequired, .idle:
            return .orange
        case .taskFinished:
            return .purple
        default:
            break
        }
        let normalized = type.lowercased()
        if normalized.contains("tool") || normalized.contains("process_") {
            return .blue
        }
        return .gray
    }

    private func formatEventTime(_ timestamp: String) -> String {
        if let parsed = DateFormatters.iso8601.date(from: timestamp) {
            return formatTime(parsed)
        }
        return timestamp
    }

    // MARK: - Lag Timeline View

    private var lagTimelineView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Toggle(L("debug.lagAllTabs", "All tabs"), isOn: $showAllLagEvents)
                    .toggleStyle(.switch)
                    .controlSize(.small)

                Spacer()

                Button(L("debug.lagClear", "Clear")) {
                    clearLagTimeline(all: showAllLagEvents)
                }
                .controlSize(.small)
            }
            .padding(8)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if lagEventsSorted.isEmpty {
                        Text(L("debug.lagEmpty", "No lag spikes recorded yet."))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 20)
                    } else {
                        ForEach(lagEventsSorted) { event in
                            lagEventRow(event)
                        }
                    }
                }
                .padding(8)
            }
        }
    }

    private var lagEventsSorted: [TerminalSessionModel.LagEvent] {
        let sessions = overlayModel.tabs.compactMap { $0.session }
        let events: [TerminalSessionModel.LagEvent]
        if showAllLagEvents {
            events = sessions.flatMap { $0.lagTimeline }
        } else if let active = overlayModel.tabs.first(where: { $0.id == overlayModel.selectedTabID })?.session {
            events = active.lagTimeline
        } else {
            events = []
        }
        return events.sorted { $0.timestamp > $1.timestamp }
    }

    private func lagEventRow(_ event: TerminalSessionModel.LagEvent) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Circle()
                    .fill(lagKindColor(event.kind))
                    .frame(width: 8, height: 8)

                Text(event.kind.rawValue.uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(lagKindColor(event.kind))

                Text(formatTime(event.timestamp))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)

                Spacer()

                Text("\(event.elapsedMs)ms")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
            }

            HStack(spacing: 10) {
                Text("avg \(event.averageMs)ms")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)

                if let p50 = event.p50, let p95 = event.p95 {
                    Text("p50/p95 \(p50)/\(p95)ms")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Text("n=\(event.sampleCount)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)

                Spacer()
            }

            Text("\(event.tabTitle) • \(event.appName) • \(event.cwd)")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func lagKindColor(_ kind: TerminalSessionModel.LagKind) -> Color {
        switch kind {
        case .input: return .blue
        case .output: return .purple
        case .highlight: return .orange
        }
    }

    private func clearLagTimeline(all: Bool) {
        if all {
            for tab in overlayModel.tabs {
                tab.session?.clearLagTimeline()
            }
        } else {
            overlayModel.tabs.first(where: { $0.id == overlayModel.selectedTabID })?.session?.clearLagTimeline()
        }
    }

    // MARK: - Performance View

    private let perfSlowThresholdMs = 8

    private var performanceView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Toggle(L("debug.perfSlowOnly", "Slow only"), isOn: $perfShowSlowOnly)
                    .toggleStyle(.switch)
                    .controlSize(.small)

                Spacer()

                Text("\(L("debug.perfUpdated", "Updated")) \(formatTime(perfSnapshot.asOf))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    performanceSummarySection(
                        title: L("debug.perfLast10s", "Last 10s"),
                        totals: perfSnapshot.totalsLast10s
                    )
                    performanceSummarySection(
                        title: L("debug.perfLast60s", "Last 60s"),
                        totals: perfSnapshot.totalsLast60s
                    )
                    performanceEventsSection
                }
                .padding(8)
            }
        }
    }

    private func performanceSummarySection(title: String, totals: [FeatureMetric: FeatureTotals]) -> some View {
        let ordered = totals
            .filter { $0.value.count > 0 } // swiftlint:disable:this empty_count
            .sorted { $0.value.totalMs > $1.value.totalMs }
        return GroupBox(title) {
            if ordered.isEmpty {
                Text(L("debug.perfEmpty", "No performance events recorded yet."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(L("debug.perfFeature", "Feature"))
                            .font(.system(size: 10, weight: .semibold))
                        Spacer()
                        Text(L("debug.perfTotal", "Total"))
                            .font(.system(size: 10, weight: .semibold))
                        Text(L("debug.perfAvg", "Avg"))
                            .font(.system(size: 10, weight: .semibold))
                        Text(L("debug.perfMax", "Max"))
                            .font(.system(size: 10, weight: .semibold))
                        Text(L("debug.perfCount", "Count"))
                            .font(.system(size: 10, weight: .semibold))
                        Text(L("debug.perfBytes", "Bytes"))
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(.secondary)

                    ForEach(ordered, id: \.key) { feature, stats in
                        HStack(spacing: 8) {
                            Text(feature.displayName)
                                .font(.system(size: 11, weight: .semibold))
                            Spacer()
                            Text("\(Int(stats.totalMs.rounded()))ms")
                                .font(.system(size: 10, design: .monospaced))
                            Text("\(Int(stats.averageMs.rounded()))ms")
                                .font(.system(size: 10, design: .monospaced))
                            Text("\(Int(stats.maxMs.rounded()))ms")
                                .font(.system(size: 10, design: .monospaced))
                            Text("\(stats.count)")
                                .font(.system(size: 10, design: .monospaced))
                            Text(formatBytes(stats.totalBytes))
                                .font(.system(size: 10, design: .monospaced))
                                .frame(minWidth: 60, alignment: .trailing)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var performanceEventsSection: some View {
        let events = perfSnapshot.recentEvents.filter { event in
            !perfShowSlowOnly || event.durationMs >= perfSlowThresholdMs
        }
        return GroupBox(L("debug.perfRecent", "Recent Events")) {
            if events.isEmpty {
                Text(L("debug.perfEmpty", "No performance events recorded yet."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(events.prefix(160)) { event in
                        performanceEventRow(event)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func performanceEventRow(_ event: FeatureEvent) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(event.feature.displayName)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.blue)

                Text(formatTime(event.timestamp))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)

                Spacer()

                Text("\(event.durationMs)ms")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))

                if event.bytes > 0 {
                    Text(formatBytes(event.bytes))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            if let metadata = event.metadata, !metadata.isEmpty {
                Text(metadata)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func formatBytes(_ bytes: Int) -> String {
        guard bytes > 0 else { return "-" }
        return LocalizedFormatters.fileSize.string(fromByteCount: Int64(bytes))
    }

    // MARK: - Logs View

    private var logsView: some View {
        VStack(spacing: 0) {
            // Text filter row
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(L("Filter logs...", "Filter logs..."), text: $logFilter)
                    .textFieldStyle(.plain)

                Button(L("Refresh", "Refresh")) {
                    loadLogs()
                }
                .controlSize(.small)

                Button(L("Open File", "Open File")) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: Log.filePath))
                }
                .controlSize(.small)
            }
            .padding(8)

            Divider()

            // Level filters
            HStack(spacing: 4) {
                Text(L("Level:", "Level:"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                ForEach(["TRACE", "DEBUG", "INFO", "WARN", "ERROR"], id: \.self) { level in
                    levelFilterChip(level)
                }
                Spacer()
                Button(L("All", "All")) {
                    enabledLevels = ["INFO", "DEBUG", "WARN", "ERROR", "TRACE"]
                }
                .controlSize(.mini)
                Button(L("Errors", "Errors")) {
                    enabledLevels = ["WARN", "ERROR"]
                }
                .controlSize(.mini)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            // Category filters
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    Text(L("Category:", "Category:"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    ForEach(LogCategory.allCases, id: \.self) { category in
                        categoryFilterChip(category)
                    }
                }
                .padding(.horizontal, 8)
            }
            .padding(.vertical, 4)

            Divider()

            // Logs content - Use TextEditor for proper text selection
            TextEditor(text: .constant(filteredLogs.joined(separator: "\n")))
                .font(.system(size: 10, design: .monospaced))
                .scrollContentBackground(.hidden)
                .background(Color.clear)

            // Status bar
            HStack {
                Text(
                    String(
                        format: L("debug.logCount", "%d / %d entries"),
                        filteredLogs.count,
                        logs.count
                    )
                )
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                Spacer()
                if let mem = PerfTracker.currentMemoryMB() {
                    Text(String(format: L("debug.memoryUsage", "Memory: %.1f MB"), mem))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .onAppear { loadLogs() }
    }

    private func levelFilterChip(_ level: String) -> some View {
        let isEnabled = enabledLevels.contains(level)
        return Button {
            if isEnabled {
                enabledLevels.remove(level)
            } else {
                enabledLevels.insert(level)
            }
        } label: {
            Text(level)
                .font(.system(size: 9, weight: .medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(isEnabled ? levelColor(level).opacity(0.3) : Color.gray.opacity(0.2))
                .foregroundStyle(isEnabled ? levelColor(level) : .secondary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func categoryFilterChip(_ category: LogCategory) -> some View {
        let isEnabled = enabledCategories.contains(category)
        return Button {
            if isEnabled {
                enabledCategories.remove(category)
            } else {
                enabledCategories.insert(category)
            }
        } label: {
            HStack(spacing: 2) {
                Text(category.emoji)
                    .font(.system(size: 8))
                Text(category.rawValue)
                    .font(.system(size: 9, weight: .medium))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(isEnabled ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.2))
            .foregroundStyle(isEnabled ? .primary : .secondary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func levelColor(_ level: String) -> Color {
        switch level {
        case "ERROR": return .red
        case "WARN": return .yellow
        case "DEBUG": return .orange
        case "TRACE": return .gray
        default: return .blue
        }
    }

    private var filteredLogs: [String] {
        logs.filter { line in
            // Level filter
            let levelMatch = enabledLevels.contains { level in
                logLineContains(level, in: line)
            }
            guard levelMatch else { return false }

            // Category filter
            // Check if line has ANY category tag (LogEnhanced format)
            let hasAnyCategory = LogCategory.allCases.contains { category in
                lineContains(category: category.rawValue, in: line)
            }
            if hasAnyCategory {
                // If it has a category, check if that category is enabled
                let categoryMatch = enabledCategories.contains { category in
                    lineContains(category: category.rawValue, in: line)
                }
                guard categoryMatch else { return false }
            }
            // If no category tag (standard Log.info() format), always pass category filter

            // Text filter
            if !logFilter.isEmpty {
                return line.localizedCaseInsensitiveContains(logFilter)
            }
            return true
        }
    }

    private func loadLogs() {
        guard let content = FileOperations.readString(from: Log.filePath) else {
            logs = ["(Unable to read log file)"]
            return
        }
        logs = Array(content.components(separatedBy: .newlines).suffix(200).reversed())
    }

    private func logLineContains(_ level: String, in line: String) -> Bool {
        let upper = level.uppercased()
        if line.contains("[\(upper)]") { return true }
        if line.contains("\"level\":\"\(upper)\"") { return true }
        if line.contains("\"level\":\"\(upper.lowercased())\"") { return true }
        return false
    }

    private func lineContains(category: String, in line: String) -> Bool {
        if line.contains("[\(category)]") { return true }
        if line.contains("\"category\":\"\(category)\"") { return true }
        if line.contains("\"category\":\"\(category.lowercased())\"") { return true }
        return false
    }

    // MARK: - Report View

    // MARK: - Analytics Tab

    private var analyticsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("", selection: $analyticsMode) {
                    ForEach(AnalyticsMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                switch analyticsMode {
                case .apiCalls:
                    proxyAnalyticsView
                case .aiRuns:
                    runAnalyticsView
                case .repos:
                    repoAnalyticsView
                }
            }
            .padding()
        }
        .onAppear {
            refreshAnalyticsData()
        }
    }

    private var proxyAnalyticsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Proxy API Summary") {
                if proxyStats.callCount == 0 {
                    Text("No proxy-captured API calls yet.").foregroundStyle(.secondary)
                } else {
                    HStack {
                        Text("Calls: \(proxyStats.callCount)")
                        Spacer()
                        Text("Tokens: \(proxyStats.totalTokens)")
                        Spacer()
                        Text(String(format: "Cost: $%.4f", proxyStats.totalCost)).bold()
                        Spacer()
                        Text(String(format: "Avg latency: %.0fms", proxyStats.averageLatencyMs))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            GroupBox("Calls by Provider") {
                if proxyProviderStats.isEmpty {
                    Text("No provider data yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(proxyProviderStats) { stat in
                        HStack {
                            Text(stat.provider.capitalized).bold()
                            Spacer()
                            Text("\(stat.callCount) calls")
                                .foregroundStyle(.secondary)
                            Text("\(stat.totalTokens) tokens")
                                .foregroundStyle(.secondary)
                            Text(String(format: "$%.4f", stat.totalCostUSD))
                                .monospaced()
                        }
                    }
                }
            }

            GroupBox("Daily Proxy Cost (Last 7 Days)") {
                if proxyDailyTrend.isEmpty {
                    Text("No daily proxy data yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(proxyDailyTrend) { day in
                        HStack {
                            Text(day.date).monospaced().font(.caption)
                            Spacer()
                            Text("\(day.callCount) calls")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                            Text("\(day.totalTokens) tokens")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                            Text(String(format: "$%.4f", day.totalCostUSD))
                                .monospaced()
                                .bold()
                        }
                    }
                }
            }

            GroupBox("Recent Proxy Calls") {
                if recentProxyCalls.isEmpty {
                    Text("No recent proxy calls recorded.").foregroundStyle(.secondary)
                } else {
                    ForEach(recentProxyCalls.prefix(15)) { call in
                        HStack {
                            Text(call.provider.displayName)
                                .font(.system(size: 11, weight: .semibold))
                            Text(call.model)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                            Text("\(call.totalTokens) tokens")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                            Text(call.formattedCost)
                                .monospaced()
                            Text(call.formattedLatency)
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                    }
                }
            }
        }
    }

    private var runAnalyticsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Run Telemetry by Provider") {
                if providerStats.isEmpty {
                    Text("No AI run telemetry yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(providerStats, id: \.provider) { stat in
                        HStack {
                            Text(stat.provider).bold()
                            Spacer()
                            Text("\(stat.runCount) runs")
                                .foregroundStyle(.secondary)
                            Text("\(stat.totalBillableTokens) billable-ish tokens")
                                .foregroundStyle(.secondary)
                            Text(runCostLabel(for: stat))
                                .monospaced()
                                .foregroundStyle(stat.pricedRunCount > 0 ? .primary : .secondary)
                        }
                    }
                }
            }

            GroupBox("Run Tokens by Tab") {
                if aiPerTabStats.isEmpty {
                    Text("No per-tab run data yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(aiPerTabStats.prefix(20), id: \.tabID) { stat in
                        let descriptor = debugTabDescriptor(
                            for: stat.tabID,
                            fallbackProvider: stat.lastProvider,
                            fallbackLocationPath: stat.lastLocationPath
                        )
                        HStack {
                            Text(descriptor.label)
                                .lineLimit(1)
                            if let provider = descriptor.providerBadge {
                                Text(provider)
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            }
                            Spacer()
                            Text("billable: \(stat.totalBillableTokens)")
                                .foregroundStyle(.secondary)
                            Text(runCostLabel(for: stat))
                                .monospaced()
                                .foregroundStyle(stat.pricedRunCount > 0 ? .primary : .secondary)
                        }
                    }
                }
            }

            GroupBox("Run Cost Coverage (Last 7 Days)") {
                if dailyCostTrend.isEmpty {
                    Text("No daily run data yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(dailyCostTrend, id: \.date) { day in
                        HStack {
                            Text(day.date).monospaced().font(.caption)
                            Spacer()
                            Text("\(day.tokens) tokens")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                            Text(runCostLabel(cost: day.cost, pricedCount: day.pricedRunCount, missingCount: max(0, day.totalRunCount - day.pricedRunCount)))
                                .monospaced()
                                .bold()
                                .foregroundStyle(day.pricedRunCount > 0 ? .primary : .secondary)
                        }
                    }
                }
            }

            GroupBox("Run Summary") {
                let totalRuns = TelemetryStore.shared.runCount()
                let totalTokens = providerStats.reduce(0) { $0 + $1.totalBillableTokens }
                let totalPricedRuns = providerStats.reduce(0) { $0 + $1.pricedRunCount }
                let totalMissingCostRuns = providerStats.reduce(0) { $0 + $1.missingCostRunCount }
                let totalCost = providerStats.reduce(0.0) { $0 + $1.totalCostUSD }
                HStack {
                    Text("Runs: \(totalRuns)")
                    Spacer()
                    Text("Billable-ish tokens: \(totalTokens)")
                    Spacer()
                    Text(runCostLabel(cost: totalCost, pricedCount: totalPricedRuns, missingCount: totalMissingCostRuns))
                        .bold()
                }
            }

            HStack {
                Spacer()
                Button("Rebuild Transcript Metrics") {
                    // TelemetryStore uses SQLite without internal serialization,
                    // so run the repair on main to avoid concurrent access.
                    let report = TelemetryRepairService.shared.rebuildTranscriptDerivedRuns()
                    Log.info("DebugConsole: rebuilt telemetry transcript metrics inspected=\(report.inspectedRuns) rebuilt=\(report.rebuiltRuns) invalidated=\(report.invalidatedRuns)")
                    refreshAnalyticsData()
                }
            }

        }
    }

    private var repoAnalyticsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            if repoAnalytics.isEmpty {
                Text("No repositories tracked yet.").foregroundStyle(.secondary)
            } else {
                GroupBox("Repository Overview") {
                    ForEach(repoAnalytics, id: \.path) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.blue)
                                Text(entry.name)
                                    .font(.system(size: 12, weight: .semibold))
                                Spacer()
                                if let lastActive = [entry.stats.lastCommandAt, entry.stats.lastRunAt].compactMap({ $0 }).max() {
                                    Text(relativeTimeString(lastActive))
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                }
                            }

                            HStack(spacing: 12) {
                                if entry.stats.totalCommands > 0 {
                                    Text("\(entry.stats.totalCommands) cmds")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                    let rate = entry.stats.successRate
                                    Text(String(format: "%.0f%%", rate * 100))
                                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                                        .foregroundStyle(rate > 0.9 ? .green : rate > 0.7 ? .yellow : .red)
                                }
                                if entry.stats.totalRuns > 0 {
                                    Text("\(entry.stats.totalRuns) runs")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                                if entry.stats.totalTokens > 0 {
                                    Text(repoFormatTokens(entry.stats.totalTokens))
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.blue)
                                }
                                if entry.stats.totalCost > 0 {
                                    Text(String(format: "$%.2f", entry.stats.totalCost))
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.orange)
                                }
                                Spacer()
                                if !entry.stats.providers.isEmpty {
                                    ForEach(entry.stats.providers, id: \.self) { provider in
                                        Text(provider.capitalized)
                                            .font(.system(size: 9, weight: .medium))
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .background(Color.secondary.opacity(0.15))
                                            .clipShape(RoundedRectangle(cornerRadius: 3))
                                    }
                                }
                            }

                            if !entry.stats.topTools.isEmpty {
                                HStack(spacing: 6) {
                                    ForEach(entry.stats.topTools.prefix(4), id: \.tool) { t in
                                        Text("\(t.tool) \u{00d7}\(t.count)")
                                            .font(.system(size: 9, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 2)
                        Divider()
                    }
                }
            }
        }
    }

    private func relativeTimeString(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }

    private func repoFormatTokens(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1000 { return String(format: "%.0fK", Double(count) / 1000) }
        return "\(count)"
    }

    private var healthDashboardView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Session Overview") {
                    let tabCount = overlayModel.tabs.count
                    let idleCount = overlayModel.tabs.filter { tab in
                        guard let session = tab.displaySession ?? tab.session,
                              tab.id != overlayModel.selectedTabID else { return false }
                        return Date().timeIntervalSince(session.lastActivityDate) > 600
                    }.count
                    let osc133Count = overlayModel.tabs.filter { ($0.session?.hasShellIntegration) == true }.count
                    VStack(alignment: .leading, spacing: 4) {
                        healthRow("Tabs", value: "\(tabCount) total, \(idleCount) idle, \(tabCount - idleCount) active")
                        healthRow("Shell integration (OSC 133)", value: "\(osc133Count)/\(tabCount) tabs")
                        healthRow("Suspended tabs", value: "\(overlayModel.suspendedTabIDs.count)")
                    }
                }

                GroupBox("PTY Logs") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(ptyLogInfo, id: \.name) { log in
                            let sizeStr = log.size > 1024 * 1024
                                ? String(format: "%.1fMB", Double(log.size) / 1_048_576)
                                : "\(log.size / 1024)KB"
                            healthRow(log.name, value: sizeStr, warn: log.size > 10 * 1024 * 1024)
                        }
                        if ptyLogInfo.isEmpty {
                            Text("No PTY logs").foregroundStyle(.secondary)
                        }
                    }
                }

                GroupBox("Metal Rendering") {
                    VStack(alignment: .leading, spacing: 4) {
                        healthRow("Atlas mode", value: "Per-renderer")
                        healthRow("Ligatures enabled", value: FeatureSettings.shared.enableLigatures ? "Yes" : "No")
                    }
                }

                GroupBox("Notification Reliability") {
                    let history = NotificationManager.shared.history.recent(limit: 100)
                    let completed = history.filter { $0.deliveryState == NotificationHistory.DeliveryState.completed.rawValue }.count
                    let dropped = history.filter { $0.deliveryState == NotificationHistory.DeliveryState.dropped.rawValue }.count
                    let retries = history.filter { $0.deliveryState == NotificationHistory.DeliveryState.retryScheduled.rawValue }.count
                    let rateLimited = history.filter(\.wasRateLimited).count
                    let authoritative = history.filter { $0.reliability == AIEventReliability.authoritative.rawValue }.count
                    VStack(alignment: .leading, spacing: 4) {
                        healthRow("Ledger entries", value: "\(history.count)")
                        healthRow("Completed", value: "\(completed)", warn: completed == 0 && !history.isEmpty)
                        healthRow("Dropped", value: "\(dropped)", warn: dropped > 0)
                        healthRow("Retry scheduled", value: "\(retries)", warn: retries > 0)
                        healthRow("Rate limited", value: "\(rateLimited)", warn: rateLimited > 0)
                        healthRow("Authoritative events", value: "\(authoritative)")
                    }
                }
            }
            .padding()
        }
        .onAppear { loadHealthData() }
    }

    private func loadHealthData() {
        DispatchQueue.global(qos: .utility).async {
            let logDir = RuntimeIsolation.expandTilde(in: "~/Library/Logs/Chau7")
            let files = (try? FileManager.default.contentsOfDirectory(atPath: logDir).filter { $0.hasSuffix(".log") }) ?? []
            let info = files.map { file -> (name: String, size: UInt64) in
                let path = (logDir as NSString).appendingPathComponent(file)
                let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0
                return (file, size)
            }.sorted { $0.size > $1.size }
            DispatchQueue.main.async { ptyLogInfo = info }
        }
    }

    private func healthRow(_ label: String, value: String, warn: Bool = false) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .monospaced()
                .foregroundStyle(warn ? .red : .primary)
        }
    }

    private var reportView: some View {
        VStack(spacing: 16) {
            GroupBox(L("Generate Bug Report", "Generate Bug Report")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Describe the issue:", "Describe the issue:"))
                        .font(.system(size: 11, weight: .medium))

                    TextEditor(text: $bugReportDescription)
                        .font(.system(size: 11))
                        .frame(height: 100)
                        .border(Color.gray.opacity(0.3))

                    HStack {
                        Button(L("Generate Github Report", "Generate Github Report")) {
                            if let issueURL = BugReporter.shared.prefilledIssueURL(userDescription: bugReportDescription) {
                                lastReportPath = issueURL.absoluteString
                                NSWorkspace.shared.open(issueURL)
                            } else {
                                lastReportPath = nil
                            }
                        }
                        .buttonStyle(.borderedProminent)

                        Button(L("Save Report", "Save Report")) {
                            lastReportPath = BugReporter.shared.generateReport(userDescription: bugReportDescription)
                        }

                        Button(L("Open Reports Folder", "Open Reports Folder")) {
                            BugReporter.shared.openReportsFolder()
                        }
                    }

                    if let path = lastReportPath {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text(L("Report draft:", "Report draft:"))
                                .font(.system(size: 10))
                            Text(path)
                                .font(.system(size: 10, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }

            GroupBox(L("Quick Actions", "Quick Actions")) {
                HStack(spacing: 12) {
                    Button(L("Capture Snapshot", "Capture Snapshot")) {
                        let snapshot = StateSnapshot.capture(from: appModel, overlayModel: overlayModel)
                        if let path = snapshot.save() {
                            lastReportPath = path
                        }
                    }

                    Button(L("Copy State JSON", "Copy State JSON")) {
                        let snapshot = StateSnapshot.capture(from: appModel, overlayModel: overlayModel)
                        if let data = JSONOperations.encode(snapshot, context: "debug state snapshot"),
                           let json = String(data: data, encoding: .utf8) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(json, forType: .string)
                        }
                    }

                    Button(L("Clear Event History", "Clear Event History")) {
                        appModel.claudeCodeEvents.removeAll()
                        appModel.recentEvents.removeAll()
                    }
                    .foregroundStyle(.red)
                }
            }

            Spacer()
        }
        .padding()
    }

    // MARK: - Helpers

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: date)
    }

    private func statRow(icon: String, iconColor: Color, label: String, value: String) -> some View {
        HStack {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(iconColor)
                .frame(width: 18)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func refreshCTOData() {
        ctoRuntimeSnapshot = CTORuntimeMonitor.shared.snapshot()
        ctoCommandLog = CTOManager.shared.readCommandLog()

        // Load telemetry aggregations, filtered by the same time period as CTO data
        let cutoff: Date? = ctoTimePeriod == .all ? nil : ctoTimePeriodCutoff
        let tabStats = TelemetryStore.shared.tokenUsagePerTab(after: cutoff)
        let provStats = TelemetryStore.shared.consumptionPerProvider(after: cutoff)
        aiPerTabStats = tabStats
        providerStats = provStats

        Task {
            let response = await CTOManager.shared.fetchDailyGainStats()
            await MainActor.run {
                ctoGainStats = response?.summary
                ctoDailyGainEntries = response?.daily ?? []
            }

            // Fetch per-session CTO gain stats concurrently
            let sessionIDs = Array(Set(ctoCommandLog.map(\.sessionID)).union(tabStats.map(\.tabID))).filter { !$0.isEmpty }
            let gainMap = await withTaskGroup(of: (String, CTOGainStats?).self) { group -> [String: CTOGainStats] in
                for sid in sessionIDs {
                    group.addTask {
                        let stats = await CTOManager.shared.fetchGainStatsForSession(sid)
                        return (sid, stats)
                    }
                }
                var map: [String: CTOGainStats] = [:]
                for await (sid, stats) in group {
                    if let stats { map[sid] = stats }
                }
                return map
            }
            await MainActor.run {
                ctoPerSessionGain = gainMap
            }
        }
    }

    private func refreshAnalyticsData() {
        aiPerTabStats = TelemetryStore.shared.tokenUsagePerTab()
        providerStats = TelemetryStore.shared.consumptionPerProvider()
        dailyCostTrend = TelemetryStore.shared.dailyCostTrend()

        proxyStats = ProxyAnalyticsStore.shared.overallStats()
        proxyProviderStats = ProxyAnalyticsStore.shared.providerStats()
        proxyDailyTrend = ProxyAnalyticsStore.shared.dailyTrend()
        recentProxyCalls = ProxyAnalyticsStore.shared.recentCalls()

        repoAnalytics = settings.recentRepoRoots.map { root in
            let stats = RepoStatsProvider.stats(for: root)
            let name = URL(fileURLWithPath: root).lastPathComponent
            return (path: root, name: name, stats: stats)
        }
        .sorted { lhs, rhs in
            let lhsDate = [lhs.stats.lastCommandAt, lhs.stats.lastRunAt].compactMap { $0 }.max() ?? .distantPast
            let rhsDate = [rhs.stats.lastCommandAt, rhs.stats.lastRunAt].compactMap { $0 }.max() ?? .distantPast
            return lhsDate > rhsDate
        }
    }

    private func runCostLabel(for stat: ProviderConsumptionStats) -> String {
        runCostLabel(cost: stat.totalCostUSD, pricedCount: stat.pricedRunCount, missingCount: stat.missingCostRunCount)
    }

    private func runCostLabel(for stat: TabTokenConsumption) -> String {
        runCostLabel(cost: stat.totalCostUSD, pricedCount: stat.pricedRunCount, missingCount: stat.missingCostRunCount)
    }

    private func runCostLabel(cost: Double, pricedCount: Int, missingCount: Int) -> String {
        if pricedCount == 0 {
            return missingCount > 0 ? "cost unavailable" : "no cost data"
        }
        let prefix = String(format: "$%.4f", cost)
        if missingCount > 0 {
            return "\(prefix) partial"
        }
        return prefix
    }

    /// Command log filtered by the selected time period.
    private var ctoFilteredLog: [CTOManager.CommandLogEntry] {
        guard ctoTimePeriod != .all else { return ctoCommandLog }
        return ctoCommandLog.filter { $0.timestamp >= ctoTimePeriodCutoff }
    }

    /// Gain stats filtered by the selected time period using daily breakdown data.
    private var ctoFilteredGainStats: CTOGainStats? {
        guard ctoTimePeriod != .all else { return ctoGainStats }
        guard !ctoDailyGainEntries.isEmpty else { return ctoGainStats }
        return CTOManager.aggregateDailyStats(ctoDailyGainEntries, since: ctoTimePeriodCutoff)
    }

    /// Cutoff date for the selected time period.
    private var ctoTimePeriodCutoff: Date {
        switch ctoTimePeriod {
        case .session:
            return ctoRuntimeSnapshot.firstSeenAt
        case .today:
            return Calendar.current.startOfDay(for: Date())
        case .week:
            return Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? .distantPast
        case .all:
            return .distantPast
        }
    }

    private func ctoFormatDuration(_ seconds: Int) -> String {
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

    private func ctoFormatDuration(_ seconds: Double) -> String {
        if seconds < 1.0 {
            return String(format: "%.0fms", seconds * 1000.0)
        }
        return ctoFormatDuration(Int(seconds))
    }

    private func ctoFormatDelay(_ value: Int?) -> String {
        guard let value else { return "n/a" }
        return "\(value)ms"
    }

    private func tokenOptimizerHealthIssueLabel(_ issue: CTORuntimeAssessmentIssue) -> String {
        switch issue {
        case .lowChangeRate:
            L("cto.runtime.issue.lowChangeRate", "Decision change rate is low")
        case .highDeferredSkips:
            L("cto.runtime.issue.highDeferredSkips", "Too many deferred skips")
        case .lowDeferredFlushRate:
            L("cto.runtime.issue.lowDeferredFlushRate", "Deferred flushes are not resolving")
        case .staleDecisions:
            L("cto.runtime.issue.staleDecisions", "No recent decisions")
        case .modeOffWithTrackedSessions:
            L("cto.runtime.issue.modeOffWithTrackedSessions", "Mode is off while sessions are tracked")
        case .lowDecisionThroughput:
            L("cto.runtime.issue.lowDecisionThroughput", "No decisions despite tracked sessions")
        }
    }

    private var compactDateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }

    private func startRefresh() {
        stopRefresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            // Force view refresh
            if selectedTab == 4 {
                perfSnapshot = FeatureProfiler.shared.snapshot()
            }
            if selectedTab == 1 {
                refreshCTOData()
            }
            if selectedTab == 5 {
                loadLogs()
            }
            if selectedTab == 7 {
                refreshAnalyticsData()
            }
        }
    }

    private func stopRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
}

// MARK: - CTO Time Period

enum CTOTimePeriod: String, CaseIterable {
    case session = "Session"
    case today = "Today"
    case week = "7 Days"
    case all = "All Time"
}

// MARK: - Debug Console Controller

/// Controls the debug console window
final class DebugConsoleController {
    static let shared = DebugConsoleController()
    private init() {}

    private var window: NSWindow?
    var windowAppearance: NSAppearance? {
        didSet {
            window?.appearance = windowAppearance
        }
    }

    private weak var appModel: AppModel?
    private weak var overlayModel: OverlayTabsModel?

    func configure(appModel: AppModel, overlayModel: OverlayTabsModel) {
        self.appModel = appModel
        self.overlayModel = overlayModel
        BugReporter.shared.configure(appModel: appModel, overlayModel: overlayModel)
    }

    func toggle() {
        if let window, window.isVisible {
            window.orderOut(nil)
        } else {
            show()
        }
    }

    func show() {
        guard let appModel, let overlayModel else {
            Log.warn("Debug console not configured")
            return
        }

        if window == nil {
            let view = DebugConsoleView(
                appModel: appModel,
                overlayModel: overlayModel,
                onClose: { [weak self] in self?.window?.orderOut(nil) }
            )
            let hostingView = NSHostingView(rootView: view)

            let newWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            newWindow.title = "Chau7 Debug Console"
            newWindow.contentView = hostingView
            newWindow.center()
            newWindow.isReleasedWhenClosed = false
            newWindow.appearance = windowAppearance

            window = newWindow
        }

        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
