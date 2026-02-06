import SwiftUI
import AppKit

// MARK: - Debug Console View

/// A hidden debug console accessible via Cmd+Shift+L (when enabled).
/// Shows real-time state, active contexts, event history, and allows generating bug reports.
struct DebugConsoleView: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var overlayModel: OverlayTabsModel
    @ObservedObject private var settings = FeatureSettings.shared
    @State private var selectedTab = 0
    @State private var logFilter = ""
    @State private var autoRefresh = true
    @State private var refreshTimer: Timer?
    @State private var logs: [String] = []
    @State private var showAllLagEvents = false
    @State private var perfSnapshot: FeatureProfiler.Snapshot = .empty
    @State private var perfShowSlowOnly = true
    // Category & level filtering
    @State private var enabledCategories: Set<LogCategory> = Set(LogCategory.allCases)
    @State private var enabledLevels: Set<String> = ["INFO", "WARN", "ERROR", "TRACE"]
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
                Text(L("Contexts", "Contexts")).tag(1)
                Text(L("Events", "Events")).tag(2)
                Text(L("Lag", "Lag")).tag(3)
                Text(L("debug.perfTab", "Perf")).tag(4)
                Text(L("Logs", "Logs")).tag(5)
                Text(L("Report", "Report")).tag(6)
            }
            .pickerStyle(.segmented)
            .padding(8)

            Divider()

            // Content
            Group {
                switch selectedTab {
                case 0: stateView
                case 1: contextsView
                case 2: eventsView
                case 3: lagTimelineView
                case 4: performanceView
                case 5: logsView
                case 6: reportView
                default: stateView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 700, height: 500)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { startRefresh() }
        .onDisappear { stopRefresh() }
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
                .onChange(of: autoRefresh) { newValue in
                    if newValue { startRefresh() } else { stopRefresh() }
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
                stateRow(L("debug.eventCount", "Event Count"), value: appModel.claudeCodeEvents.count.formatted())
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
                        stateRow(L("debug.app", "App"), value: tab.session?.activeAppName ?? L("status.none", "none"))
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
                    range: 0...5000,
                    step: 50
                )
                performanceSettingRow(
                    L("debug.highlightMaxInterval", "Highlight Max Interval (ms)"),
                    value: $settings.dangerousOutputHighlightMaxIntervalMs,
                    range: 250...10000,
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

    // MARK: - Contexts View

    private var contextsView: some View {
        VStack(spacing: 0) {
            // Active contexts
            GroupBox(String(format: L("debug.activeContexts", "Active Contexts (%d)"), DebugContext.active.count)) {
                if DebugContext.active.isEmpty {
                    Text(L("No active contexts", "No active contexts"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding()
                } else {
                    ForEach(DebugContext.active, id: \.id) { ctx in
                        contextRow(ctx, isActive: true)
                    }
                }
            }
            .padding()

            Divider()

            // History
            GroupBox(String(format: L("debug.recentHistory", "Recent History (%d)"), DebugContext.history.count)) {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(DebugContext.history.reversed(), id: \.id) { ctx in
                            contextRow(ctx, isActive: false)
                        }
                    }
                }
            }
            .padding()
        }
    }

    private func contextRow(_ ctx: DebugContext, isActive: Bool) -> some View {
        HStack {
            Text(ctx.id)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(isActive ? .orange : .secondary)
                .frame(width: 60, alignment: .leading)

            Text(ctx.operation)
                .font(.system(size: 11))
                .lineLimit(1)

            Spacer()

            let duration = Int(Date().timeIntervalSince(ctx.startTime) * 1000)
            Text(String(format: L("debug.durationMs", "%dms"), duration))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Events View

    private var eventsView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(appModel.claudeCodeEvents.reversed()) { event in
                    eventRow(event)
                }
            }
            .padding()
        }
    }

    private func eventRow(_ event: ClaudeCodeEvent) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(event.type.rawValue)
                    .font(.system(size: 10, design: .monospaced))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(eventTypeColor(event.type).opacity(0.2))
                    .foregroundStyle(eventTypeColor(event.type))
                    .clipShape(RoundedRectangle(cornerRadius: 3))

                Text(event.toolName.isEmpty ? event.hook : event.toolName)
                    .font(.system(size: 11, weight: .medium))

                Spacer()

                Text(formatTime(event.timestamp))
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

    private func eventTypeColor(_ type: ClaudeEventType) -> Color {
        switch type {
        case .userPrompt: return .green
        case .toolStart: return .blue
        case .toolComplete: return .cyan
        case .permissionRequest: return .yellow
        case .responseComplete: return .purple
        case .notification: return .orange
        case .sessionEnd: return .red
        case .unknown: return .gray
        }
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
            .filter { $0.value.count > 0 }
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
                ForEach(["TRACE", "INFO", "WARN", "ERROR"], id: \.self) { level in
                    levelFilterChip(level)
                }
                Spacer()
                Button(L("All", "All")) {
                    enabledLevels = ["INFO", "WARN", "ERROR", "TRACE"]
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
        case "TRACE": return .gray
        default: return .blue
        }
    }

    private var filteredLogs: [String] {
        logs.filter { line in
            // Level filter
            let levelMatch = enabledLevels.contains { level in
                line.contains("[\(level)]")
            }
            guard levelMatch else { return false }

            // Category filter
            // Check if line has ANY category tag (LogEnhanced format)
            let hasAnyCategory = LogCategory.allCases.contains { category in
                line.contains("[\(category.rawValue)]")
            }
            if hasAnyCategory {
                // If it has a category, check if that category is enabled
                let categoryMatch = enabledCategories.contains { category in
                    line.contains("[\(category.rawValue)]")
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

    private func logLine(_ line: String) -> some View {
        Text(line)
            .foregroundStyle(logLineColor(line))
            .textSelection(.enabled)
    }

    private func logLineColor(_ line: String) -> Color {
        if line.contains("[ERROR]") { return .red }
        if line.contains("[WARN]") { return .yellow }
        if line.contains("[TRACE]") { return .secondary }
        return .primary
    }

    private func loadLogs() {
        guard let content = FileOperations.readString(from: Log.filePath) else {
            logs = ["(Unable to read log file)"]
            return
        }
        logs = content.components(separatedBy: .newlines).suffix(200).reversed()
    }

    // MARK: - Report View

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
                        Button(L("Generate Report", "Generate Report")) {
                            lastReportPath = BugReporter.shared.generateReport(userDescription: bugReportDescription)
                        }
                        .buttonStyle(.borderedProminent)

                        Button(L("Open Reports Folder", "Open Reports Folder")) {
                            BugReporter.shared.openReportsFolder()
                        }
                    }

                    if let path = lastReportPath {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text(L("Report saved to:", "Report saved to:"))
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

    private func startRefresh() {
        stopRefresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            // Force view refresh
            if selectedTab == 4 {
                perfSnapshot = FeatureProfiler.shared.snapshot()
            }
            if selectedTab == 5 {
                loadLogs()
            }
        }
    }

    private func stopRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
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
