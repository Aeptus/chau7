import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Chau7Core

// MARK: - Settings Window Wrapper

/// Wrapper view for the standalone settings window (opened via Cmd+,)
struct SettingsWindowView: View {
    var model: AppModel
    let overlayModel: OverlayTabsModel?

    var body: some View {
        SettingsRootView(model: model, overlayModel: overlayModel)
    }
}

// MARK: - Menu Bar Panel View

enum StreamSelection: Hashable, Identifiable {
    case history(providerKey: String)
    case terminal(providerKey: String)
    case verbose

    var id: String {
        switch self {
        case .history(let k): return "history-\(k)"
        case .terminal(let k): return "terminal-\(k)"
        case .verbose: return "verbose"
        }
    }

    var title: String {
        switch self {
        case .history(let k):
            return AIToolRegistry.allTools.first { $0.resumeProviderKey == k }?.displayName ?? k.capitalized
        case .terminal(let k):
            let name = AIToolRegistry.allTools.first { $0.resumeProviderKey == k }?.displayName ?? k.capitalized
            return "\(name) TTY"
        case .verbose: return L("statusbar.verbose", "Verbose")
        }
    }

    /// Default selections for the picker (backward-compat with known tools)
    static var defaultSelections: [StreamSelection] {
        [
            .history(providerKey: "codex"),
            .history(providerKey: "claude"),
            .terminal(providerKey: "codex"),
            .terminal(providerKey: "claude"),
            .verbose
        ]
    }
}

struct MenuBarPanelView: View {
    @Bindable var model: AppModel
    @State private var streamSelection: StreamSelection = .history(providerKey: "codex")

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            notificationsSection
            Divider()
            activitySection
            Divider()
            streamSection
            Divider()
            quickToggles
            footer
        }
        .padding(12)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(L("Chau7", "Chau7"))
                .font(.headline)

            Circle()
                .fill(model.isMonitoring ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
                .help(model.isMonitoring ? L("statusbar.monitoringActive", "Monitoring active") : L("statusbar.monitoringPaused", "Monitoring paused"))

            Spacer()

            Button(L("Show Overlay", "Show Overlay")) {
                (NSApp.delegate as? AppDelegate)?.showOverlay()
            }
            .controlSize(.small)

            Button(L("Settings...", "Settings...")) {
                (NSApp.delegate as? AppDelegate)?.showSettings()
            }
            .controlSize(.small)
        }
    }

    private var notificationsSection: some View {
        let isBundled = Bundle.main.bundleIdentifier != nil
        return VStack(alignment: .leading, spacing: 6) {
            Text(L("Notifications", "Notifications"))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            LabeledContent("Status", value: model.notificationStatus)

            if let warning = model.notificationWarning {
                Text(warning)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button(L("Request Permission", "Request Permission")) { model.requestNotificationPermission() }
                Button(L("Test", "Test")) { model.sendTestNotification() }
            }
            .controlSize(.small)
            .disabled(!isBundled)
        }
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("Activity", "Activity"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L("Clear", "Clear")) { model.recentEvents.removeAll() }
                    .controlSize(.mini)
            }

            if displayableRecentEvents.isEmpty {
                Text(L("No recent events", "No recent events"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(displayableRecentEvents) { event in
                        HStack(alignment: .top, spacing: 6) {
                            Text(eventTypeLabel(for: event))
                                .font(.system(size: 10, weight: .semibold))
                                .frame(width: 70, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(event.tool)
                                    .font(.system(size: 11, weight: .semibold))
                                Text(event.message)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
            }
        }
    }

    private var displayableRecentEvents: [AIEvent] {
        let filtered = model.recentEvents.filter { event in
            guard let trigger = NotificationTriggerCatalog.trigger(for: event) else { return true }
            return trigger.displayContexts.contains(.activity)
        }
        return Array(filtered.suffix(8).reversed())
    }

    private func eventTypeLabel(for event: AIEvent) -> String {
        if let trigger = NotificationTriggerCatalog.trigger(for: event) {
            return trigger.localizedLabel.uppercased()
        }
        return event.type.uppercased()
    }

    private var streamSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Streams", "Streams"))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Picker(L("Stream", "Stream"), selection: $streamSelection) {
                ForEach(StreamSelection.defaultSelections) { selection in
                    Text(selection.title).tag(selection)
                }
            }
            .pickerStyle(.segmented)

            StreamView(selection: streamSelection, model: model)
                .frame(height: 160)
        }
    }

    private var quickToggles: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Quick Toggles", "Quick Toggles"))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Toggle(L("Monitor AI events", "Monitor AI events"), isOn: $model.isMonitoring)
                .onChange(of: model.isMonitoring) {
                    model.applyMonitoringState()
                }

            Toggle(L("Monitor history logs", "Monitor history logs"), isOn: $model.isIdleMonitoring)
                .onChange(of: model.isIdleMonitoring) {
                    model.applyIdleMonitoringState()
                }

            Toggle(L("Monitor terminal logs", "Monitor terminal logs"), isOn: $model.isTerminalMonitoring)
                .onChange(of: model.isTerminalMonitoring) {
                    model.applyTerminalMonitoringState()
                }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.logFilePath)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 8) {
                Button(L("Reveal Log", "Reveal Log")) { model.revealLogFile() }
                    .controlSize(.small)
                Spacer()
                Button(L("Quit Chau7", "Quit Chau7")) { NSApplication.shared.terminate(nil) }
                    .controlSize(.small)
            }
        }
    }
}

// MARK: - Stream View

struct StreamView: View {
    let selection: StreamSelection
    var model: AppModel
    var settings = FeatureSettings.shared

    private static let timeFormatter = LocalizedFormatters.mediumTime

    var body: some View {
        switch selection {
        case .history(let key):
            historyList(entries: model.toolHistoryEntries[key] ?? [])
        case .terminal(let key):
            terminalLogView(lines: model.toolTerminalLines[key] ?? [])
        case .verbose:
            logList(lines: model.logLines)
        }
    }

    @ViewBuilder
    private func historyList(entries: [HistoryEntry]) -> some View {
        if entries.isEmpty {
            Text(L("No history yet.", "No history yet."))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(entries.indices, id: \.self) { index in
                        let entry = entries[index]
                        let date = Date(timeIntervalSince1970: entry.timestamp)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(
                                String(
                                    format: L("history.entry.timestamp", "%@ - %@"),
                                    Self.timeFormatter.string(from: date),
                                    String(entry.sessionId.prefix(8))
                                )
                            )
                            .font(.system(size: 11, weight: .semibold))
                            Text(entry.summary)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                        Divider()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func logList(lines: [String]) -> some View {
        if lines.isEmpty {
            Text(L("No logs yet.", "No logs yet."))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(lines.indices, id: \.self) { index in
                        let line = lines[index]
                        lineView(for: line, isInput: line.hasPrefix("[INPUT]"))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func terminalLogView(lines: [String]) -> some View {
        if lines.isEmpty {
            Text(L("No logs yet.", "No logs yet."))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        } else if model.isTerminalAnsi {
            AnsiLogView(
                lines: lines,
                baseFont: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                baseForeground: NSColor.textColor,
                baseBackground: NSColor.textBackgroundColor
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(lines.indices, id: \.self) { index in
                        let line = lines[index]
                        let display = model.isTerminalNormalize ? TerminalNormalizer.normalize(line) : line
                        lineView(for: display, isInput: display.hasPrefix("[INPUT]"))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func lineView(for line: String, isInput: Bool) -> some View {
        let prettyLine = settings.isJSONPrettyPrintEnabled
            ? (JSONPrettyPrinter.prettyPrint(line) ?? line)
            : line
        if settings.isSyntaxHighlightEnabled {
            let attributed = SyntaxHighlighter.shared.highlight(prettyLine)
            Text(AttributedString(attributed))
                .font(.system(size: 11, design: .monospaced))
        } else {
            Text(prettyLine)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(isInput ? .primary : .secondary)
        }
    }
}

// MARK: - Settings Root View (SettingsSection is now in SettingsSearch.swift)

struct SettingsRootView: View {
    var model: AppModel
    let overlayModel: OverlayTabsModel?
    @State private var selection: SettingsSection = .general
    @State private var searchQuery = ""

    private var matchingSections: Set<SettingsSection> {
        FeatureSettings.sectionsMatching(query: searchQuery)
    }

    private var isSearching: Bool {
        !searchQuery.isEmpty
    }

    private var filteredSections: [SettingsSection] {
        if searchQuery.isEmpty {
            return SettingsSection.allCases
        }
        return SettingsSection.allCases.filter { matchingSections.contains($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ProfileSelectorBar(overlayModel: overlayModel)

            NavigationSplitView {
                VStack(spacing: 0) {
                    // Search Bar
                    SettingsSearchBar(searchQuery: $searchQuery)

                    // Section List — grouped when browsing, flat when searching
                    List(selection: $selection) {
                        if isSearching {
                            ForEach(filteredSections) { section in
                                sidebarRow(for: section)
                            }
                        } else {
                            ForEach(SettingsSectionGroup.allCases) { group in
                                Section(header: Text(group.title)) {
                                    ForEach(group.sections, id: \.self) { section in
                                        sidebarRow(for: section)
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.sidebar)
                }
                .frame(minWidth: 220)
            } detail: {
                SettingsDetailView(
                    selection: selection,
                    model: model,
                    overlayModel: overlayModel,
                    searchQuery: searchQuery
                )
            }
        }
        .frame(minWidth: 860, minHeight: 650)
        .onChange(of: searchQuery) {
            // Auto-select first matching section when searching
            if !searchQuery.isEmpty, let firstMatch = filteredSections.first {
                selection = firstMatch
            }
        }
    }

    private func sidebarRow(for section: SettingsSection) -> some View {
        SettingsSidebarRow(
            section: section,
            isHighlighted: isSearching && matchingSections.contains(section),
            matchCount: isSearching ? FeatureSettings.searchableSettings.filter { $0.section == section && $0.matches(searchQuery) }.count : 0
        )
        .tag(section)
    }
}

// MARK: - Settings Search Bar

struct SettingsSearchBar: View {
    @Binding var searchQuery: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField(L("Search settings...", "Search settings..."), text: $searchQuery)
                .textFieldStyle(.plain)
                .focused($isFocused)

            if !searchQuery.isEmpty {
                Button(action: { searchQuery = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Settings Sidebar Row

struct SettingsSidebarRow: View {
    let section: SettingsSection
    let isHighlighted: Bool
    let matchCount: Int

    var body: some View {
        HStack {
            Label(section.title, systemImage: section.systemImage)
                .foregroundColor(isHighlighted ? .accentColor : .primary)

            if matchCount > 0 {
                Spacer()
                Text(matchCount.formatted())
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor)
                    .clipShape(Capsule())
            }
        }
    }
}

// MARK: - Settings Detail View

struct SettingsDetailView: View {
    let selection: SettingsSection
    var model: AppModel
    let overlayModel: OverlayTabsModel?
    var searchQuery = ""

    private var matchingSettings: [SearchableSetting] {
        guard !searchQuery.isEmpty else { return [] }
        return FeatureSettings.searchableSettings.filter {
            $0.section == selection && $0.matches(searchQuery)
        }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                // Section header with description
                sectionHeader

                // Search results hint
                if !searchQuery.isEmpty, !matchingSettings.isEmpty {
                    SearchResultsHint(matchingSettings: matchingSettings, query: searchQuery)
                }

                Divider()
                    .padding(.bottom, 16)

                // Section content
                Group {
                    switch selection {
                    // Essentials
                    case .general:
                        GeneralSettingsView(model: model)
                    case .profilesBackup:
                        ProfilesBackupSettingsView()
                    case .about:
                        AboutSettingsView(model: model)
                    // Look & Feel
                    case .fontColors:
                        FontColorsSettingsView()
                    case .display:
                        DisplaySettingsView()
                    case .tabs:
                        TabsSettingsView()
                    case .hoverCard:
                        HoverCardSettingsView()
                    case .repositories:
                        RepositoriesSettingsView()
                    // Terminal
                    case .shell:
                        ShellSettingsView()
                    case .scrollbackPerf:
                        ScrollbackPerfSettingsView(model: model)
                    case .dangerousCommands:
                        DangerousCommandSettingsView()
                    case .graphics:
                        GraphicsSettingsView()
                    case .minimalMode:
                        MinimalModeSettingsView()
                    // Input & Productivity
                    case .keyboardMouse:
                        InputSettingsView()
                    case .snippetsTools:
                        ProductivitySettingsView()
                    case .editor:
                        EditorSettingsView()
                    // Integrations
                    case .aiDetection:
                        AIIntegrationSettingsView()
                    case .tokenOptimization:
                        TokenOptimizationSettingsView(overlayModel: overlayModel)
                    case .mcpControl:
                        MCPSettingsView()
                    case .remoteControl:
                        RemoteSettingsView()
                    case .apiProxy:
                        ProxySettingsView()
                    // Monitoring
                    case .notifications:
                        NotificationsSettingsView(model: model)
                    case .logsHistory:
                        LogsSettingsView(model: model)
                    }
                }
            }
            .padding(24)
        }
        .id(selection)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var sectionHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(selection.title)
                .font(.title2)
                .fontWeight(.semibold)
            Text(selection.description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 12)
    }
}

// MARK: - Search Results Hint

struct SearchResultsHint: View {
    let matchingSettings: [SearchableSetting]
    let query: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                Text(
                    String(
                        format: L("settings.searchResults", "Found %d matching settings for \"%@\""),
                        matchingSettings.count,
                        query
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            ForEach(matchingSettings) { setting in
                HStack {
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundColor(.accentColor)
                    Text(setting.title)
                        .font(.caption)
                        .foregroundColor(.accentColor)
                    Text(String(format: L("settings.searchResultDetail", "– %@"), setting.description))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.1))
        .cornerRadius(8)
        .padding(.bottom, 8)
    }
}

// Note: Reusable settings components moved to SettingsComponents.swift
// Note: Individual settings views moved to SettingsViews/ folder
