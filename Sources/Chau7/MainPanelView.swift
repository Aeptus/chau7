import SwiftUI
import AppKit

/// Wrapper view for the standalone settings window (opened via Cmd+,)
struct SettingsWindowView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        SettingsRootView(model: model)
    }
}

enum StreamSelection: String, CaseIterable, Identifiable {
    case codexHistory
    case claudeHistory
    case codexTerminal
    case claudeTerminal
    case verbose

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codexHistory:
            return "Codex"
        case .claudeHistory:
            return "Claude"
        case .codexTerminal:
            return "Codex TTY"
        case .claudeTerminal:
            return "Claude TTY"
        case .verbose:
            return "Verbose"
        }
    }
}

struct MenuBarPanelView: View {
    @ObservedObject var model: AppModel
    @State private var streamSelection: StreamSelection = .codexHistory

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
            Text("Chau7")
                .font(.headline)

            Circle()
                .fill(model.isMonitoring ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
                .help(model.isMonitoring ? "Monitoring on" : "Monitoring off")

            Spacer()

            Button("Show Overlay") {
                (NSApp.delegate as? AppDelegate)?.showOverlay()
            }
            .controlSize(.small)

            Button("Settings...") {
                (NSApp.delegate as? AppDelegate)?.showSettings()
            }
            .controlSize(.small)
        }
    }

    private var notificationsSection: some View {
        let isBundled = Bundle.main.bundleIdentifier != nil
        return VStack(alignment: .leading, spacing: 6) {
            Text("Notifications")
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
                Button("Request Permission") { model.requestNotificationPermission() }
                Button("Test") { model.sendTestNotification() }
            }
            .controlSize(.small)
            .disabled(!isBundled)
        }
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Activity")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { model.recentEvents.removeAll() }
                    .controlSize(.mini)
            }

            if model.recentEvents.isEmpty {
                Text("No recent events")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.recentEvents.suffix(8).reversed()) { event in
                        HStack(alignment: .top, spacing: 6) {
                            Text(event.type.uppercased())
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

    private var streamSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Streams")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Picker("Stream", selection: $streamSelection) {
                ForEach(StreamSelection.allCases) { selection in
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
            Text("Quick Toggles")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Toggle("Monitor AI events", isOn: $model.isMonitoring)
                .onChange(of: model.isMonitoring) { _ in
                    model.applyMonitoringState()
                }

            Toggle("Monitor history logs", isOn: $model.isIdleMonitoring)
                .onChange(of: model.isIdleMonitoring) { _ in
                    model.applyIdleMonitoringState()
                }

            Toggle("Monitor terminal logs", isOn: $model.isTerminalMonitoring)
                .onChange(of: model.isTerminalMonitoring) { _ in
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
                Button("Reveal Log") { model.revealLogFile() }
                    .controlSize(.small)

                Spacer()

                Button("Quit Chau7") { NSApplication.shared.terminate(nil) }
                    .controlSize(.small)
            }
        }
    }
}

struct StreamView: View {
    let selection: StreamSelection
    @ObservedObject var model: AppModel

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    var body: some View {
        switch selection {
        case .codexHistory:
            historyList(entries: model.codexHistoryEntries)
        case .claudeHistory:
            historyList(entries: model.claudeHistoryEntries)
        case .codexTerminal:
            terminalLogView(lines: model.codexTerminalLines)
        case .claudeTerminal:
            terminalLogView(lines: model.claudeTerminalLines)
        case .verbose:
            logList(lines: model.logLines)
        }
    }

    @ViewBuilder
    private func historyList(entries: [HistoryEntry]) -> some View {
        if entries.isEmpty {
            Text("No history yet.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(entries.indices, id: \.self) { index in
                        let entry = entries[index]
                        let date = Date(timeIntervalSince1970: entry.timestamp)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(Self.timeFormatter.string(from: date)) - \(entry.sessionId.prefix(8))")
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
            Text("No logs yet.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(lines.indices, id: \.self) { index in
                        let line = lines[index]
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(line.hasPrefix("[INPUT]") ? .primary : .secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func terminalLogView(lines: [String]) -> some View {
        if lines.isEmpty {
            Text("No logs yet.")
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
                        Text(display)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(display.hasPrefix("[INPUT]") ? .primary : .secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case notifications
    case terminal
    case tabs
    case input
    case history
    case logs
    case advanced
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:
            return "General"
        case .notifications:
            return "Notifications"
        case .terminal:
            return "Terminal"
        case .tabs:
            return "Tabs & Appearance"
        case .input:
            return "Input & Selection"
        case .history:
            return "History & Bookmarks"
        case .logs:
            return "Logs & Monitoring"
        case .advanced:
            return "Advanced"
        case .about:
            return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general:
            return "gearshape"
        case .notifications:
            return "bell"
        case .terminal:
            return "terminal"
        case .tabs:
            return "rectangle.grid.2x2"
        case .input:
            return "keyboard"
        case .history:
            return "clock.arrow.circlepath"
        case .logs:
            return "doc.text.magnifyingglass"
        case .advanced:
            return "slider.horizontal.3"
        case .about:
            return "info.circle"
        }
    }
}

struct SettingsRootView: View {
    @ObservedObject var model: AppModel
    @State private var selection: SettingsSection = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .frame(minWidth: 180)
        } detail: {
            SettingsDetailView(selection: selection, model: model)
        }
        .frame(minWidth: 720, minHeight: 560)
    }
}

struct SettingsDetailView: View {
    let selection: SettingsSection
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            switch selection {
            case .general:
                GeneralSettingsView(model: model)
            case .notifications:
                NotificationsSettingsView(model: model)
            case .terminal:
                TerminalSettingsView(model: model)
            case .tabs:
                TabsAppearanceSettingsView()
            case .input:
                InputSelectionSettingsView()
            case .history:
                HistoryBookmarksSettingsView()
            case .logs:
                LogsMonitoringSettingsView(model: model)
            case .advanced:
                AdvancedSettingsView()
            case .about:
                AboutSettingsView(model: model)
            }
        }
        .navigationTitle(selection.title)
    }
}

struct GeneralSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("Actions") {
                Button("Show Overlay") { (NSApp.delegate as? AppDelegate)?.showOverlay() }
            }

            Section("Overlays") {
                Button("Restore default overlay positions") {
                    FeatureSettings.shared.resetOverlayOffsets()
                }
            }

            Section("Status") {
                LabeledContent("Notifications", value: model.notificationStatus)
                LabeledContent("Event monitoring", value: model.isMonitoring ? "On" : "Off")
                LabeledContent("History monitoring", value: model.isIdleMonitoring ? "On" : "Off")
                LabeledContent("Terminal monitoring", value: model.isTerminalMonitoring ? "On" : "Off")
            }
        }
        .padding()
    }
}

struct NotificationsSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let isBundled = Bundle.main.bundleIdentifier != nil
        return Form {
            Section("Status") {
                LabeledContent("Permissions", value: model.notificationStatus)
                if let warning = model.notificationWarning {
                    Text(warning)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Actions") {
                HStack(spacing: 8) {
                    Button("Request Permission") { model.requestNotificationPermission() }
                    Button("Open System Settings") { model.openNotificationSettings() }
                    Button("Test Notification") { model.sendTestNotification() }
                }
                .disabled(!isBundled)
            }
        }
        .padding()
    }
}

struct TerminalSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings = FeatureSettings.shared

    var body: some View {
        Form {
            Section("Cursor") {
                Picker("Style", selection: $settings.cursorStyle) {
                    Text("Block").tag("block")
                    Text("Underline").tag("underline")
                    Text("Bar").tag("bar")
                }
                Toggle("Blink", isOn: $settings.cursorBlink)
            }

            Section("Scrollback") {
                TextField("Lines", value: $settings.scrollbackLines, format: .number)
                    .frame(width: 120)
            }

            Section("Bell") {
                Toggle("Enabled", isOn: $settings.bellEnabled)
                if settings.bellEnabled {
                    Picker("Sound", selection: $settings.bellSound) {
                        Text("Default").tag("default")
                        Text("Subtle").tag("subtle")
                        Text("None").tag("none")
                    }
                }
            }

            Section("Display") {
                Toggle("Line timestamps", isOn: $settings.isLineTimestampsEnabled)

                if settings.isLineTimestampsEnabled {
                    TextField("Timestamp format", text: $settings.timestampFormat)
                        .font(.system(size: 11, design: .monospaced))
                }

                Toggle("Syntax highlighting", isOn: $settings.isSyntaxHighlightEnabled)
                Toggle("Clickable URLs", isOn: $settings.isClickableURLsEnabled)
                Toggle("Pretty print JSON", isOn: $settings.isJSONPrettyPrintEnabled)
            }

            Section("Background Rendering") {
                Toggle("Suspend background tab rendering", isOn: $model.isSuspendBackgroundRendering)

                TextField("Suspend after seconds", text: $model.suspendRenderDelayText)
                    .frame(width: 160)
                    .disabled(!model.isSuspendBackgroundRendering)
            }
        }
        .padding()
    }
}

struct TabsAppearanceSettingsView: View {
    @ObservedObject private var settings = FeatureSettings.shared

    var body: some View {
        Form {
            Section("Appearance") {
                Toggle("Auto tab themes by AI", isOn: $settings.isAutoTabThemeEnabled)
                Toggle("Last command badge", isOn: $settings.isLastCommandBadgeEnabled)
            }
        }
        .padding()
    }
}

struct InputSelectionSettingsView: View {
    @ObservedObject private var settings = FeatureSettings.shared

    var body: some View {
        Form {
            Section("Selection") {
                Toggle("Copy on select", isOn: $settings.isCopyOnSelectEnabled)
                Toggle("Cmd+click paths", isOn: $settings.isCmdClickPathsEnabled)

                if settings.isCmdClickPathsEnabled {
                    TextField("Default editor", text: $settings.defaultEditor)
                        .font(.system(size: 11, design: .monospaced))
                }
            }

            Section("Input") {
                Toggle("Broadcast input", isOn: $settings.isBroadcastEnabled)

                Picker("Keybindings", selection: $settings.keybindingPreset) {
                    Text("Default").tag("default")
                    Text("Vim").tag("vim")
                    Text("Emacs").tag("emacs")
                }
            }
        }
        .padding()
    }
}

struct HistoryBookmarksSettingsView: View {
    @ObservedObject private var settings = FeatureSettings.shared

    var body: some View {
        Form {
            Section("Clipboard history") {
                Toggle("Enabled", isOn: $settings.isClipboardHistoryEnabled)
                TextField("Max items", value: $settings.clipboardHistoryMaxItems, format: .number)
                    .frame(width: 120)
                    .disabled(!settings.isClipboardHistoryEnabled)
            }

            Section("Bookmarks") {
                Toggle("Enabled", isOn: $settings.isBookmarksEnabled)
                TextField("Max per tab", value: $settings.maxBookmarksPerTab, format: .number)
                    .frame(width: 120)
                    .disabled(!settings.isBookmarksEnabled)
            }

            Section("Snippets") {
                Toggle("Enabled", isOn: $settings.isSnippetsEnabled)
                    .onChange(of: settings.isSnippetsEnabled) { _ in
                        SnippetManager.shared.refreshConfiguration()
                    }

                Toggle("Repo snippets", isOn: $settings.isRepoSnippetsEnabled)
                    .disabled(!settings.isSnippetsEnabled)
                    .onChange(of: settings.isRepoSnippetsEnabled) { _ in
                        SnippetManager.shared.refreshConfiguration()
                    }

                TextField("Repo path", text: $settings.repoSnippetPath)
                    .font(.system(size: 11, design: .monospaced))
                    .disabled(!settings.isSnippetsEnabled || !settings.isRepoSnippetsEnabled)
                    .onSubmit { SnippetManager.shared.refreshConfiguration() }
                    .onChange(of: settings.repoSnippetPath) { _ in
                        SnippetManager.shared.refreshConfiguration()
                    }

                Picker("Insert mode", selection: $settings.snippetInsertMode) {
                    Text("Expand").tag("expand")
                    Text("Paste").tag("paste")
                }
                .disabled(!settings.isSnippetsEnabled)

                Toggle("Expand placeholders", isOn: $settings.snippetPlaceholdersEnabled)
                    .disabled(!settings.isSnippetsEnabled || settings.snippetInsertMode == "paste")
            }
        }
        .padding()
    }
}

struct LogsMonitoringSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("Event Log") {
                Toggle("Monitor AI events", isOn: $model.isMonitoring)
                    .onChange(of: model.isMonitoring) { _ in
                        model.applyMonitoringState()
                    }

                TextField("Event log path", text: $model.logPath)
                    .font(.system(size: 11, design: .monospaced))
                    .onSubmit {
                        model.restartTailer()
                    }

                HStack(spacing: 8) {
                    Button("Restart") { model.restartTailer() }
                    Button("Reveal") { model.revealLogInFinder() }
                }
            }

            Section("History Logs") {
                Toggle("Monitor history logs", isOn: $model.isIdleMonitoring)
                    .onChange(of: model.isIdleMonitoring) { _ in
                        model.applyIdleMonitoringState()
                    }

                TextField("Idle seconds", text: $model.idleSecondsText)
                    .frame(width: 120)
                    .onSubmit {
                        model.restartIdleMonitors()
                    }

                TextField("Stale seconds", text: $model.staleSecondsText)
                    .frame(width: 120)
                    .onSubmit {
                        model.restartIdleMonitors()
                    }

                TextField("Codex history path", text: $model.codexHistoryPath)
                    .font(.system(size: 11, design: .monospaced))
                    .onSubmit {
                        model.restartIdleMonitors()
                    }

                TextField("Claude history path", text: $model.claudeHistoryPath)
                    .font(.system(size: 11, design: .monospaced))
                    .onSubmit {
                        model.restartIdleMonitors()
                    }

                HStack(spacing: 8) {
                    Button("Restart") { model.restartIdleMonitors() }
                    Button("Clear") { model.clearHistory() }
                }
            }

            Section("Terminal Logs") {
                Toggle("Monitor terminal logs", isOn: $model.isTerminalMonitoring)
                    .onChange(of: model.isTerminalMonitoring) { _ in
                        model.applyTerminalMonitoringState()
                    }

                Toggle("Normalize terminal output", isOn: $model.isTerminalNormalize)
                    .onChange(of: model.isTerminalNormalize) { _ in
                        model.restartTerminalMonitors()
                    }

                Toggle("Render ANSI styling", isOn: $model.isTerminalAnsi)

                TextField("Codex terminal log", text: $model.codexTerminalPath)
                    .font(.system(size: 11, design: .monospaced))
                    .onSubmit {
                        model.restartTerminalMonitors()
                    }

                TextField("Claude terminal log", text: $model.claudeTerminalPath)
                    .font(.system(size: 11, design: .monospaced))
                    .onSubmit {
                        model.restartTerminalMonitors()
                    }

                HStack(spacing: 8) {
                    Button("Restart") { model.restartTerminalMonitors() }
                    Button("Reload last lines") { model.reloadTerminalPrefill() }
                    Button("Clear") { model.clearTerminalLogs() }
                }
            }

            Section("Sessions") {
                if model.sessionStatuses.isEmpty {
                    Text("No sessions tracked yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.sessionStatuses.sorted(by: { $0.lastSeen > $1.lastSeen })) { status in
                        HStack {
                            Text("\(status.tool) - \(status.sessionId.prefix(8))")
                            Spacer()
                            Text(status.state.rawValue.uppercased())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding()
    }
}

struct AdvancedSettingsView: View {
    @ObservedObject private var settings = FeatureSettings.shared

    var body: some View {
        Form {
            Section("Features") {
                Toggle("Split panes", isOn: $settings.isSplitPanesEnabled)
                Toggle("Semantic search", isOn: $settings.isSemanticSearchEnabled)
                Toggle("Dropdown terminal", isOn: $settings.isDropdownEnabled)

                if settings.isDropdownEnabled {
                    TextField("Dropdown hotkey", text: $settings.dropdownHotkey)
                        .font(.system(size: 11, design: .monospaced))

                    TextField("Dropdown height %", value: $settings.dropdownHeight, format: .number)
                        .frame(width: 120)
                }
            }
        }
        .padding()
    }
}

struct AboutSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("Version") {
                LabeledContent("App", value: ProcessInfo.processInfo.processName)
                LabeledContent("Bundle ID", value: Bundle.main.bundleIdentifier ?? "Unknown")
                LabeledContent("Version", value: bundleVersion)
            }

            Section("Logs") {
                Text(model.logFilePath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Button("Reveal Log") { model.revealLogFile() }
            }
        }
        .padding()
    }

    private var bundleVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (short, build) {
        case let (short?, build?):
            return "\(short) (\(build))"
        case let (short?, nil):
            return short
        case let (nil, build?):
            return build
        default:
            return "Unknown"
        }
    }
}
