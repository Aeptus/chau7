import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Settings Window Wrapper

/// Wrapper view for the standalone settings window (opened via Cmd+,)
struct SettingsWindowView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        SettingsRootView(model: model)
    }
}

// MARK: - Menu Bar Panel View

enum StreamSelection: String, CaseIterable, Identifiable {
    case codexHistory
    case claudeHistory
    case codexTerminal
    case claudeTerminal
    case verbose

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codexHistory: return "Codex"
        case .claudeHistory: return "Claude"
        case .codexTerminal: return "Codex TTY"
        case .claudeTerminal: return "Claude TTY"
        case .verbose: return "Verbose"
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
                .help(model.isMonitoring ? "Monitoring active" : "Monitoring paused")

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

// MARK: - Stream View

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

// MARK: - Settings Root View (SettingsSection is now in FeatureSettings.swift)

struct SettingsRootView: View {
    @ObservedObject var model: AppModel
    @State private var selection: SettingsSection = .general
    @State private var searchQuery: String = ""

    private var matchingSections: Set<SettingsSection> {
        FeatureSettings.sectionsMatching(query: searchQuery)
    }

    private var filteredSections: [SettingsSection] {
        if searchQuery.isEmpty {
            return SettingsSection.allCases
        }
        return SettingsSection.allCases.filter { matchingSections.contains($0) }
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                // Search Bar
                SettingsSearchBar(searchQuery: $searchQuery)

                // Section List
                List(filteredSections, selection: $selection) { section in
                    SettingsSidebarRow(
                        section: section,
                        isHighlighted: !searchQuery.isEmpty && matchingSections.contains(section),
                        matchCount: searchQuery.isEmpty ? 0 : FeatureSettings.searchableSettings.filter { $0.section == section && $0.matches(searchQuery) }.count
                    )
                    .tag(section)
                }
                .listStyle(.sidebar)
            }
            .frame(minWidth: 200)
        } detail: {
            SettingsDetailView(selection: selection, model: model, searchQuery: searchQuery)
        }
        .frame(minWidth: 820, minHeight: 650)
        .onChange(of: searchQuery) { newQuery in
            // Auto-select first matching section when searching
            if !newQuery.isEmpty, let firstMatch = filteredSections.first {
                selection = firstMatch
            }
        }
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

            TextField("Search settings...", text: $searchQuery)
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
                Text("\(matchCount)")
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
    @ObservedObject var model: AppModel
    var searchQuery: String = ""

    private var matchingSettings: [SearchableSetting] {
        guard !searchQuery.isEmpty else { return [] }
        return FeatureSettings.searchableSettings.filter {
            $0.section == selection && $0.matches(searchQuery)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Section header with description
                sectionHeader

                // Search results hint
                if !searchQuery.isEmpty && !matchingSettings.isEmpty {
                    SearchResultsHint(matchingSettings: matchingSettings, query: searchQuery)
                }

                Divider()
                    .padding(.bottom, 16)

                // Section content
                Group {
                    switch selection {
                    case .general:
                        GeneralSettingsView(model: model)
                    case .appearance:
                        AppearanceSettingsView()
                    case .terminal:
                        TerminalSettingsView(model: model)
                    case .tabs:
                        TabsSettingsView()
                    case .input:
                        InputSettingsView()
                    case .productivity:
                        ProductivitySettingsView()
                    case .windows:
                        WindowsSettingsView()
                    case .aiIntegration:
                        AIIntegrationSettingsView(model: model)
                    case .logs:
                        LogsSettingsView(model: model)
                    case .about:
                        AboutSettingsView(model: model)
                    }
                }
            }
            .padding(24)
        }
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
                Text("Found \(matchingSettings.count) matching setting\(matchingSettings.count == 1 ? "" : "s") for \"\(query)\"")
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
                    Text("– \(setting.description)")
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

// MARK: - Reusable Components

struct SettingsSectionHeader: View {
    let title: String
    let icon: String?

    init(_ title: String, icon: String? = nil) {
        self.title = title
        self.icon = icon
    }

    var body: some View {
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .font(.headline)
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

// MARK: - Settings Layout Constants

private enum SettingsLayout {
    static let labelWidth: CGFloat = 220
    static let controlSpacing: CGFloat = 16
}

// MARK: - Generic Settings Row (for custom controls)

struct SettingsRow<Content: View>: View {
    let label: String
    let help: String?
    let content: () -> Content

    init(_ label: String, help: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.help = help
        self.content = content
    }

    var body: some View {
        HStack(alignment: .top, spacing: SettingsLayout.controlSpacing) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                if let help {
                    Text(help)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: SettingsLayout.labelWidth, alignment: .leading)

            content()

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Settings Slider

struct SettingsSlider: View {
    let label: String
    let help: String?
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var format: String = "%.0f"
    var suffix: String = ""
    var width: CGFloat = 150
    var disabled: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: SettingsLayout.controlSpacing) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                if let help {
                    Text(help)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: SettingsLayout.labelWidth, alignment: .leading)

            HStack(spacing: 8) {
                Slider(value: $value, in: range, step: step)
                    .frame(width: width)
                    .disabled(disabled)
                Text(String(format: format, value) + suffix)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 50, alignment: .trailing)
                    .foregroundStyle(disabled ? .secondary : .primary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Settings Stepper

struct SettingsStepper: View {
    let label: String
    let help: String?
    @Binding var value: Int
    let range: ClosedRange<Int>
    var suffix: String = ""
    var disabled: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: SettingsLayout.controlSpacing) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                if let help {
                    Text(help)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: SettingsLayout.labelWidth, alignment: .leading)

            Stepper(value: $value, in: range) {
                Text("\(value)\(suffix)")
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 60, alignment: .trailing)
            }
            .disabled(disabled)

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Settings Info Row (read-only display)

struct SettingsInfoRow: View {
    let label: String
    let value: String
    var valueColor: Color = .primary
    var monospaced: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: SettingsLayout.controlSpacing) {
            Text(label)
                .frame(width: SettingsLayout.labelWidth, alignment: .leading)

            Text(value)
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
                .foregroundStyle(valueColor)

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Settings Button Row

struct SettingsButtonRow: View {
    let buttons: [SettingsButton]
    var alignment: HorizontalAlignment = .leading

    struct SettingsButton: Identifiable {
        let id = UUID()
        let title: String
        var icon: String? = nil
        var style: ButtonType = .bordered
        var action: () -> Void

        enum ButtonType {
            case bordered, borderedProminent, plain
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            if alignment == .trailing {
                Spacer()
            }

            ForEach(buttons) { button in
                makeButton(button)
            }

            if alignment == .leading {
                Spacer()
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func makeButton(_ button: SettingsButton) -> some View {
        let label: some View = {
            if let icon = button.icon {
                return AnyView(Label(button.title, systemImage: icon))
            } else {
                return AnyView(Text(button.title))
            }
        }()

        switch button.style {
        case .bordered:
            Button(action: button.action) { label }
                .buttonStyle(.bordered)
        case .borderedProminent:
            Button(action: button.action) { label }
                .buttonStyle(.borderedProminent)
        case .plain:
            Button(action: button.action) { label }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
        }
    }
}

// MARK: - Settings Card (featured section with action)

struct SettingsCard<Content: View>: View {
    let content: () -> Content
    var action: (() -> Void)? = nil
    var actionLabel: String? = nil
    var actionIcon: String? = nil

    init(@ViewBuilder content: @escaping () -> Content, action: (() -> Void)? = nil, actionLabel: String? = nil, actionIcon: String? = nil) {
        self.content = content
        self.action = action
        self.actionLabel = actionLabel
        self.actionIcon = actionIcon
    }

    var body: some View {
        HStack {
            content()

            Spacer()

            if let action = action, let label = actionLabel {
                Button(action: action) {
                    if let icon = actionIcon {
                        Label(label, systemImage: icon)
                    } else {
                        Text(label)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
}

// MARK: - Settings Hint (keyboard shortcut or tip)

struct SettingsHint: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Settings Description Text

struct SettingsDescription: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.vertical, 2)
    }
}

// MARK: - Settings Shortcut Row (keyboard shortcut display)

struct SettingsShortcutRow: View {
    let label: String
    let shortcut: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(shortcut)
                .font(.system(.caption, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(4)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Settings Detection Row (AI detection display)

struct SettingsDetectionRow: View {
    let name: String
    let commands: String
    let color: Color

    var body: some View {
        HStack {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
            Text(name)
                .fontWeight(.medium)
            Spacer()
            Text(commands)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct SettingsToggle: View {
    let label: String
    let help: String
    @Binding var isOn: Bool
    var disabled: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: SettingsLayout.controlSpacing) {
            // Fixed-width label column
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                Text(help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: SettingsLayout.labelWidth, alignment: .leading)

            // Control aligned left
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(disabled)

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

struct SettingsTextField: View {
    let label: String
    let help: String?
    let placeholder: String
    @Binding var text: String
    var width: CGFloat = 200
    var monospaced: Bool = false
    var disabled: Bool = false
    var onSubmit: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: SettingsLayout.controlSpacing) {
            // Fixed-width label column
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                if let help {
                    Text(help)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: SettingsLayout.labelWidth, alignment: .leading)

            // Control aligned left
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: width)
                .font(monospaced ? .system(size: 12, design: .monospaced) : .body)
                .disabled(disabled)
                .onSubmit { onSubmit?() }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

struct SettingsNumberField: View {
    let label: String
    let help: String?
    @Binding var value: Int
    var width: CGFloat = 100
    var disabled: Bool = false
    var onSubmit: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: SettingsLayout.controlSpacing) {
            // Fixed-width label column
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                if let help {
                    Text(help)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: SettingsLayout.labelWidth, alignment: .leading)

            // Control aligned left
            TextField("", value: $value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: width)
                .disabled(disabled)
                .onSubmit { onSubmit?() }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

struct SettingsPicker<T: Hashable>: View {
    let label: String
    let help: String?
    @Binding var selection: T
    let options: [(value: T, label: String)]
    var width: CGFloat = 150
    var disabled: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: SettingsLayout.controlSpacing) {
            // Fixed-width label column
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                if let help {
                    Text(help)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: SettingsLayout.labelWidth, alignment: .leading)

            // Control aligned left
            Picker("", selection: $selection) {
                ForEach(options, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .labelsHidden()
            .frame(width: width)
            .disabled(disabled)

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings = FeatureSettings.shared
    @State private var launchAtLogin = false
    @State private var showExportSheet = false
    @State private var showImportSheet = false
    @State private var showResetConfirmation = false
    @State private var importError: String? = nil
    @State private var showCreateProfile = false
    @State private var showDeleteConfirmation = false
    @State private var profileToDelete: SettingsProfile? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Startup
            SettingsSectionHeader("Startup", icon: "power")

            SettingsToggle(
                label: "Launch at Login",
                help: "Automatically start Chau7 when you log in to your Mac",
                isOn: $launchAtLogin
            )

            SettingsTextField(
                label: L("settings.general.defaultDirectory"),
                help: L("settings.general.defaultDirectory.help"),
                placeholder: "~",
                text: $settings.defaultStartDirectory,
                width: 280,
                monospaced: true
            )

            Divider()
                .padding(.vertical, 8)

            // Language
            SettingsSectionHeader(L("settings.general.language"), icon: "globe")

            SettingsPicker(
                label: L("settings.general.language.label"),
                help: L("settings.general.language.help"),
                selection: $settings.appLanguage,
                options: AppLanguage.allCases.map { (value: $0, label: $0.displayName) }
            )

            SettingsDescription(text: L("settings.general.language.note"))

            Divider()
                .padding(.vertical, 8)

            // Settings Profiles (NEW)
            SettingsSectionHeader("Settings Profiles", icon: "person.2.fill")

            Text("Create named profiles for different workflows (Work, Personal, Presentation Mode)")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Active profile indicator
            if let activeProfile = settings.activeProfile {
                HStack {
                    Image(systemName: activeProfile.icon)
                        .foregroundColor(.accentColor)
                    Text("Active: \(activeProfile.name)")
                        .fontWeight(.medium)
                    Spacer()
                    Button("Save Current Settings") {
                        settings.saveCurrentToProfile(activeProfile)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                }
                .padding(10)
                .background(Color.accentColor.opacity(0.1))
                .cornerRadius(8)
            }

            // Profile list
            VStack(spacing: 4) {
                ForEach(settings.savedProfiles) { profile in
                    ProfileRow(
                        profile: profile,
                        isActive: profile.id == settings.activeProfileId,
                        onLoad: { settings.loadProfile(profile) },
                        onDelete: {
                            profileToDelete = profile
                            showDeleteConfirmation = true
                        }
                    )
                }
            }
            .padding(8)
            .background(Color.secondary.opacity(0.05))
            .cornerRadius(8)

            Button(action: { showCreateProfile = true }) {
                Label("Create New Profile...", systemImage: "plus.circle")
            }

            Divider()
                .padding(.vertical, 8)

            // iCloud Sync (NEW)
            SettingsSectionHeader("iCloud Sync", icon: "icloud")

            SettingsToggle(
                label: "Sync Settings via iCloud",
                help: "Keep your Chau7 settings synchronized across all your Macs",
                isOn: $settings.iCloudSyncEnabled
            )

            if settings.iCloudSyncEnabled {
                HStack(spacing: 12) {
                    Button("Sync Now") {
                        settings.syncToiCloud()
                    }

                    Button("Restore from iCloud") {
                        settings.syncFromiCloud()
                    }
                }
            }

            Divider()
                .padding(.vertical, 8)

            // Import/Export (NEW)
            SettingsSectionHeader("Settings Backup", icon: "square.and.arrow.up.on.square")

            Text("Export your settings to a JSON file or import from a backup.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("Export Settings...") {
                    exportSettings()
                }

                Button("Import Settings...") {
                    showImportSheet = true
                }
            }

            if let error = importError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.top, 4)
            }

            Divider()
                .padding(.vertical, 8)

            // Status
            SettingsSectionHeader("Status", icon: "info.circle")

            SettingsInfoRow(label: "Notifications", value: model.notificationStatus, monospaced: true)
            SettingsInfoRow(
                label: "Event Monitoring",
                value: model.isMonitoring ? "Active" : "Paused",
                valueColor: model.isMonitoring ? .green : .secondary,
                monospaced: true
            )
            SettingsInfoRow(
                label: "History Monitoring",
                value: model.isIdleMonitoring ? "Active" : "Paused",
                valueColor: model.isIdleMonitoring ? .green : .secondary,
                monospaced: true
            )
            SettingsInfoRow(
                label: "Terminal Monitoring",
                value: model.isTerminalMonitoring ? "Active" : "Paused",
                valueColor: model.isTerminalMonitoring ? .green : .secondary,
                monospaced: true
            )

            Divider()
                .padding(.vertical, 8)

            // Actions
            SettingsSectionHeader("Actions", icon: "hand.tap")

            SettingsButtonRow(buttons: [
                .init(title: "Show Overlay", icon: "rectangle.inset.filled") {
                    (NSApp.delegate as? AppDelegate)?.showOverlay()
                },
                .init(title: "Reset Window Positions", icon: "arrow.counterclockwise") {
                    FeatureSettings.shared.resetOverlayOffsets()
                },
                .init(title: "Debug Console", icon: "terminal") {
                    DebugConsoleController.shared.show()
                }
            ])

            Divider()
                .padding(.vertical, 8)

            // Reset
            SettingsSectionHeader("Reset", icon: "arrow.counterclockwise")

            SettingsButtonRow(buttons: [
                .init(title: "Reset All Settings to Defaults", style: .plain) {
                    showResetConfirmation = true
                }
            ], alignment: .trailing)
        }
        .fileImporter(
            isPresented: $showImportSheet,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            importSettings(result: result)
        }
        .alert("Reset All Settings?", isPresented: $showResetConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Reset", role: .destructive) {
                settings.resetAllToDefaults()
            }
        } message: {
            Text("This will reset all Chau7 settings to their default values. This action cannot be undone.")
        }
        .sheet(isPresented: $showCreateProfile) {
            CreateProfileSheet(settings: settings) { showCreateProfile = false }
        }
        .alert("Delete Profile?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { profileToDelete = nil }
            Button("Delete", role: .destructive) {
                if let profile = profileToDelete {
                    settings.deleteProfile(id: profile.id)
                }
                profileToDelete = nil
            }
        } message: {
            if let profile = profileToDelete {
                Text("Are you sure you want to delete the profile \"\(profile.name)\"? This action cannot be undone.")
            }
        }
    }

    private func exportSettings() {
        guard let data = settings.exportSettings() else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "chau7-settings.json"
        panel.title = "Export Chau7 Settings"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try data.write(to: url)
            } catch {
                Log.error("Failed to export settings: \(error)")
            }
        }
    }

    private func importSettings(result: Result<[URL], Error>) {
        importError = nil
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let data = try Data(contentsOf: url)
                if settings.importSettings(from: data) {
                    Log.info("Settings imported successfully")
                } else {
                    importError = "Invalid settings file format"
                }
            } catch {
                importError = "Failed to read file: \(error.localizedDescription)"
            }
        case .failure(let error):
            importError = "Import failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Profile Row

struct ProfileRow: View {
    let profile: SettingsProfile
    let isActive: Bool
    let onLoad: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: profile.icon)
                .foregroundColor(isActive ? .accentColor : .secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(profile.name)
                        .fontWeight(isActive ? .semibold : .regular)
                    if isActive {
                        Text("(Active)")
                            .font(.caption)
                            .foregroundColor(.accentColor)
                    }
                }
                Text("Created \(profile.createdAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !isActive {
                Button("Load") { onLoad() }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
            }

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(.red.opacity(0.7))
            }
            .buttonStyle(.plain)
            .disabled(isActive)
            .opacity(isActive ? 0.3 : 1)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(isActive ? Color.accentColor.opacity(0.08) : Color.clear)
        .cornerRadius(6)
    }
}

// MARK: - Create Profile Sheet

struct CreateProfileSheet: View {
    @ObservedObject var settings: FeatureSettings
    let onDismiss: () -> Void

    @State private var profileName: String = ""
    @State private var selectedIcon: String = "person.fill"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create New Profile")
                .font(.headline)

            Divider()

            TextField("Profile Name", text: $profileName)
                .textFieldStyle(.roundedBorder)

            Text("Choose Icon")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(44)), count: 8), spacing: 8) {
                ForEach(SettingsProfile.availableIcons, id: \.self) { icon in
                    Button(action: { selectedIcon = icon }) {
                        Image(systemName: icon)
                            .font(.system(size: 18))
                            .frame(width: 36, height: 36)
                            .background(selectedIcon == icon ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1))
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(selectedIcon == icon ? Color.accentColor : Color.clear, lineWidth: 2)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            HStack {
                Button("Cancel") { onDismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Create Profile") {
                    let profile = settings.createProfile(name: profileName, icon: selectedIcon)
                    settings.activeProfileId = profile.id
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

// MARK: - Appearance Settings

struct AppearanceSettingsView: View {
    @ObservedObject private var settings = FeatureSettings.shared
    @State private var selectedTheme = "auto"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Live Preview Panel (NEW)
            SettingsSectionHeader("Live Preview", icon: "rectangle.inset.filled.and.cursorarrow")

            LiveTerminalPreview(settings: settings)
                .padding(.bottom, 8)

            Divider()
                .padding(.vertical, 8)

            // Font Settings (NEW)
            SettingsSectionHeader("Font", icon: "textformat")

            SettingsPicker(
                label: "Font Family",
                help: "Choose a monospace font for the terminal",
                selection: $settings.fontFamily,
                options: FeatureSettings.availableFonts.map { (value: $0, label: $0) }
            )

            SettingsRow("Font Size", help: "Terminal font size in points (8-72)") {
                HStack {
                    Stepper(value: $settings.fontSize, in: 8...72) {
                        Text("\(settings.fontSize) pt")
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 60, alignment: .trailing)
                    }
                }
            }

            SettingsRow("Default Zoom", help: "Scale new terminal sessions (50-200%)") {
                HStack {
                    Slider(value: Binding(
                        get: { Double(settings.defaultZoomPercent) },
                        set: { settings.defaultZoomPercent = Int($0) }
                    ), in: 50...200, step: 5)
                        .frame(width: 150)
                    Text("\(settings.defaultZoomPercent)%")
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 55, alignment: .trailing)
                }
            }

            // Font Preview
            Text("The quick brown fox jumps over the lazy dog")
                .font(.custom(settings.fontFamily, size: CGFloat(settings.fontSize)))
                .padding(8)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(6)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()
                .padding(.vertical, 8)

            // Color Scheme (NEW)
            SettingsSectionHeader("Color Scheme", icon: "paintpalette")

            SettingsPicker(
                label: "Scheme",
                help: "Choose a terminal color scheme preset",
                selection: $settings.colorSchemeName,
                options: TerminalColorScheme.allPresets.map { (value: $0.name, label: $0.name) }
            )

            // Color Preview
            ColorSchemePreview(scheme: settings.currentColorScheme)
                .padding(.vertical, 8)

            Divider()
                .padding(.vertical, 8)

            // Window Transparency (NEW)
            SettingsSectionHeader("Window", icon: "square.on.square.dashed")

            SettingsRow("Window Opacity", help: "Transparency level for terminal window (30-100%)") {
                HStack {
                    Slider(value: $settings.windowOpacity, in: 0.3...1.0, step: 0.05)
                        .frame(width: 150)
                    Text("\(Int(settings.windowOpacity * 100))%")
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 45, alignment: .trailing)
                }
            }

            Divider()
                .padding(.vertical, 8)

            // Theme
            SettingsSectionHeader("System Theme", icon: "circle.lefthalf.filled")

            SettingsPicker(
                label: "Appearance",
                help: "Choose light, dark, or match system appearance",
                selection: $selectedTheme,
                options: [
                    (value: "auto", label: "System"),
                    (value: "light", label: "Light"),
                    (value: "dark", label: "Dark")
                ]
            )

            Divider()
                .padding(.vertical, 8)

            // AI Theming
            SettingsSectionHeader("AI Tab Theming", icon: "sparkles")

            SettingsToggle(
                label: "Auto Tab Themes",
                help: "Automatically color tabs based on the detected AI CLI (Claude = purple, Codex = green, etc.)",
                isOn: $settings.isAutoTabThemeEnabled
            )

            Divider()
                .padding(.vertical, 8)

            // Display Enhancements
            SettingsSectionHeader("Display Enhancements", icon: "eye")

            SettingsToggle(
                label: "Syntax Highlighting",
                help: "Highlight code syntax in terminal output for better readability",
                isOn: $settings.isSyntaxHighlightEnabled
            )

            SettingsToggle(
                label: "Clickable URLs",
                help: "Make URLs in terminal output clickable to open in browser",
                isOn: $settings.isClickableURLsEnabled
            )

            SettingsToggle(
                label: "Inline Images",
                help: "Display images inline using iTerm2's imgcat protocol (use imgcat command)",
                isOn: $settings.isInlineImagesEnabled
            )

            SettingsToggle(
                label: "Pretty Print JSON",
                help: "Automatically format JSON output with indentation and colors",
                isOn: $settings.isJSONPrettyPrintEnabled
            )

            SettingsToggle(
                label: "Line Timestamps",
                help: "Show timestamps next to each terminal line",
                isOn: $settings.isLineTimestampsEnabled
            )

            if settings.isLineTimestampsEnabled {
                SettingsTextField(
                    label: "Timestamp Format",
                    help: "Date format string (e.g., HH:mm:ss, yyyy-MM-dd HH:mm)",
                    placeholder: "HH:mm:ss",
                    text: $settings.timestampFormat,
                    width: 150,
                    monospaced: true
                )
            }

            Divider()
                .padding(.vertical, 8)

            // Reset Button
            HStack {
                Spacer()
                Button("Reset Appearance to Defaults") {
                    settings.resetAppearanceToDefaults()
                }
                .foregroundColor(.red)
            }
        }
    }
}

// MARK: - Color Scheme Preview

struct ColorSchemePreview: View {
    let scheme: TerminalColorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Background with foreground text
            HStack(spacing: 0) {
                Text("user@host:~ $ ")
                    .foregroundColor(Color(scheme.nsColor(for: scheme.green)))
                Text("ls -la")
                    .foregroundColor(Color(scheme.nsColor(for: scheme.foreground)))
            }
            .font(.system(size: 12, design: .monospaced))

            // Color palette preview
            HStack(spacing: 4) {
                ForEach([
                    scheme.black, scheme.red, scheme.green, scheme.yellow,
                    scheme.blue, scheme.magenta, scheme.cyan, scheme.white
                ], id: \.self) { hex in
                    Rectangle()
                        .fill(Color(scheme.nsColor(for: hex)))
                        .frame(width: 20, height: 16)
                        .cornerRadius(2)
                }
            }
        }
        .padding(10)
        .background(Color(scheme.nsColor(for: scheme.background)))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - Live Terminal Preview

struct LiveTerminalPreview: View {
    @ObservedObject var settings: FeatureSettings

    private var scheme: TerminalColorScheme { settings.currentColorScheme }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title bar
            HStack(spacing: 6) {
                // Traffic lights
                Circle().fill(Color.red.opacity(0.8)).frame(width: 10, height: 10)
                Circle().fill(Color.yellow.opacity(0.8)).frame(width: 10, height: 10)
                Circle().fill(Color.green.opacity(0.8)).frame(width: 10, height: 10)
                Spacer()
                Text("Terminal Preview — zsh")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(NSColor.windowBackgroundColor))

            // Terminal content
            VStack(alignment: .leading, spacing: 3) {
                // Previous command
                terminalLine(prompt: "user@mac", path: "~/Projects", command: "ls -la")
                outputLine("total 32")
                outputLine("drwxr-xr-x  5 user  staff   160 Jan 11 14:30 .", dim: true)
                outputLine("drwxr-xr-x  8 user  staff   256 Jan 10 09:15 ..", dim: true)
                fileLine("-rw-r--r--", "main.swift", .cyan)
                fileLine("-rw-r--r--", "Package.swift", .cyan)
                dirLine("drwxr-xr-x", "Sources/", .blue)

                // Current command with cursor
                HStack(spacing: 0) {
                    terminalPrompt(user: "user@mac", path: "~/Projects")
                    cursor
                }
            }
            .padding(12)
            .background(Color(scheme.nsColor(for: scheme.background)).opacity(settings.windowOpacity))
        }
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
    }

    private func terminalLine(prompt: String, path: String, command: String) -> some View {
        HStack(spacing: 0) {
            terminalPrompt(user: prompt, path: path)
            Text(command)
                .foregroundColor(Color(scheme.nsColor(for: scheme.foreground)))
        }
    }

    private func terminalPrompt(user: String, path: String) -> some View {
        HStack(spacing: 0) {
            Text(user)
                .foregroundColor(Color(scheme.nsColor(for: scheme.green)))
            Text(":")
                .foregroundColor(Color(scheme.nsColor(for: scheme.foreground)))
            Text(path)
                .foregroundColor(Color(scheme.nsColor(for: scheme.blue)))
            Text("$ ")
                .foregroundColor(Color(scheme.nsColor(for: scheme.foreground)))
        }
        .font(.custom(settings.fontFamily, size: CGFloat(settings.fontSize) * 0.85))
    }

    private func outputLine(_ text: String, dim: Bool = false) -> some View {
        Text(text)
            .font(.custom(settings.fontFamily, size: CGFloat(settings.fontSize) * 0.85))
            .foregroundColor(Color(scheme.nsColor(for: dim ? scheme.brightBlack : scheme.foreground)))
    }

    private func fileLine(_ perms: String, _ name: String, _ nameColor: FileColor) -> some View {
        HStack(spacing: 0) {
            Text(perms + "  1 user  staff   1.2K  ")
                .foregroundColor(Color(scheme.nsColor(for: scheme.foreground)))
            Text(name)
                .foregroundColor(Color(scheme.nsColor(for: colorFor(nameColor))))
        }
        .font(.custom(settings.fontFamily, size: CGFloat(settings.fontSize) * 0.85))
    }

    private func dirLine(_ perms: String, _ name: String, _ nameColor: FileColor) -> some View {
        HStack(spacing: 0) {
            Text(perms + "  3 user  staff    96B  ")
                .foregroundColor(Color(scheme.nsColor(for: scheme.foreground)))
            Text(name)
                .foregroundColor(Color(scheme.nsColor(for: colorFor(nameColor))))
                .fontWeight(.semibold)
        }
        .font(.custom(settings.fontFamily, size: CGFloat(settings.fontSize) * 0.85))
    }

    private enum FileColor { case cyan, blue, green }

    private func colorFor(_ c: FileColor) -> String {
        switch c {
        case .cyan: return scheme.cyan
        case .blue: return scheme.blue
        case .green: return scheme.green
        }
    }

    @ViewBuilder
    private var cursor: some View {
        let cursorColor = Color(scheme.nsColor(for: scheme.cursor))

        switch settings.cursorStyle {
        case "block":
            Rectangle()
                .fill(cursorColor)
                .frame(width: CGFloat(settings.fontSize) * 0.6, height: CGFloat(settings.fontSize) * 0.85)
                .opacity(settings.cursorBlink ? 0.7 : 1.0)
        case "underline":
            Rectangle()
                .fill(cursorColor)
                .frame(width: CGFloat(settings.fontSize) * 0.6, height: 2)
                .offset(y: CGFloat(settings.fontSize) * 0.35)
        case "bar":
            Rectangle()
                .fill(cursorColor)
                .frame(width: 2, height: CGFloat(settings.fontSize) * 0.85)
        default:
            Rectangle()
                .fill(cursorColor)
                .frame(width: CGFloat(settings.fontSize) * 0.6, height: CGFloat(settings.fontSize) * 0.85)
        }
    }
}

// MARK: - Terminal Settings

struct TerminalSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings = FeatureSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Shell Settings (NEW)
            SettingsSectionHeader("Shell", icon: "terminal")

            SettingsPicker(
                label: "Shell",
                help: "Choose which shell to use for new terminal sessions",
                selection: $settings.shellType,
                options: ShellType.allCases.map { (value: $0, label: $0.displayName) }
            )

            if settings.shellType == .custom {
                SettingsTextField(
                    label: "Custom Shell Path",
                    help: "Full path to your preferred shell executable",
                    placeholder: "/usr/local/bin/fish",
                    text: $settings.customShellPath,
                    width: 250,
                    monospaced: true
                )
            }

            // Shell info
            SettingsInfoRow(label: "Current Shell", value: currentShellDisplay, monospaced: true)

            SettingsTextField(
                label: "Startup Command",
                help: "Command to run automatically when a new terminal session starts",
                placeholder: "neofetch",
                text: $settings.startupCommand,
                width: 250,
                monospaced: true
            )

            Divider()
                .padding(.vertical, 8)

            // Cursor
            SettingsSectionHeader("Cursor", icon: "cursorarrow")

            SettingsPicker(
                label: "Style",
                help: "Choose the cursor shape displayed in the terminal",
                selection: $settings.cursorStyle,
                options: [
                    (value: "block", label: "Block"),
                    (value: "underline", label: "Underline"),
                    (value: "bar", label: "Bar")
                ]
            )

            SettingsToggle(
                label: "Cursor Blink",
                help: "Animate the cursor with a blinking effect",
                isOn: $settings.cursorBlink
            )

            Divider()
                .padding(.vertical, 8)

            // Scrollback
            SettingsSectionHeader("Scrollback", icon: "scroll")

            SettingsNumberField(
                label: "Buffer Size",
                help: "Number of lines to keep in scrollback history (100-100,000)",
                value: $settings.scrollbackLines,
                width: 100
            )

            Divider()
                .padding(.vertical, 8)

            // Bell
            SettingsSectionHeader("Bell", icon: "bell")

            SettingsToggle(
                label: "Bell Enabled",
                help: "Play a sound when the terminal bell character is received",
                isOn: $settings.bellEnabled
            )

            if settings.bellEnabled {
                SettingsPicker(
                    label: "Bell Sound",
                    help: "Choose the sound to play for terminal bell",
                    selection: $settings.bellSound,
                    options: [
                        (value: "default", label: "Default"),
                        (value: "subtle", label: "Subtle"),
                        (value: "none", label: "Visual Only")
                    ]
                )
            }

            Divider()
                .padding(.vertical, 8)

            // Performance
            SettingsSectionHeader("Performance", icon: "gauge.with.dots.needle.33percent")

            SettingsToggle(
                label: "Suspend Background Rendering",
                help: "Pause rendering for inactive tabs to reduce CPU usage",
                isOn: $model.isSuspendBackgroundRendering
            )

            if model.isSuspendBackgroundRendering {
                SettingsTextField(
                    label: "Suspend Delay",
                    help: "Seconds of inactivity before suspending background tabs",
                    placeholder: "30",
                    text: $model.suspendRenderDelayText,
                    width: 80
                )
            }

            Divider()
                .padding(.vertical, 8)

            // Reset Button
            HStack {
                Spacer()
                Button("Reset Terminal to Defaults") {
                    settings.resetTerminalToDefaults()
                }
                .foregroundColor(.red)
            }
        }
    }

    private var currentShellDisplay: String {
        switch settings.shellType {
        case .system:
            return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        case .custom:
            let path = settings.customShellPath.trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? "(not set)" : path
        default:
            return settings.shellType.rawValue
        }
    }
}

// MARK: - Tabs Settings

struct TabsSettingsView: View {
    @ObservedObject private var settings = FeatureSettings.shared
    @State private var newTabPosition = "end"
    @State private var showTabBarAlways = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Behavior
            SettingsSectionHeader("Behavior", icon: "rectangle.stack.badge.plus")

            SettingsPicker(
                label: "New Tab Position",
                help: "Where to insert newly created tabs",
                selection: $newTabPosition,
                options: [
                    (value: "end", label: "At End"),
                    (value: "after", label: "After Current")
                ]
            )

            SettingsPicker(
                label: "Last Tab Close",
                help: "Choose what happens when closing the final tab",
                selection: $settings.lastTabCloseBehavior,
                options: LastTabCloseBehavior.allCases.map { (value: $0, label: $0.displayName) }
            )

            SettingsToggle(
                label: "Always Show Tab Bar",
                help: "Show the tab bar even when only one tab is open",
                isOn: $showTabBarAlways
            )

            Divider()
                .padding(.vertical, 8)

            // Appearance
            SettingsSectionHeader("Appearance", icon: "paintpalette")

            SettingsToggle(
                label: "Last Command Badge",
                help: "Show the most recent command in the tab status area",
                isOn: $settings.isLastCommandBadgeEnabled
            )

            SettingsToggle(
                label: "AI Product Icons",
                help: "Display SF Symbol icons for detected AI CLIs in tabs",
                isOn: $settings.isAutoTabThemeEnabled
            )

            Divider()
                .padding(.vertical, 8)

            // Keyboard
            SettingsSectionHeader("Keyboard Navigation", icon: "keyboard")

            VStack(alignment: .leading, spacing: 4) {
                SettingsShortcutRow(label: "New Tab", shortcut: "⌘T")
                SettingsShortcutRow(label: "Close Tab", shortcut: "⌘W")
                SettingsShortcutRow(label: "Next Tab", shortcut: "⌘⇧] or ⌃Tab")
                SettingsShortcutRow(label: "Previous Tab", shortcut: "⌘⇧[ or ⌃⇧Tab")
                SettingsShortcutRow(label: "Switch to Tab 1-9", shortcut: "⌘1-9")
                SettingsShortcutRow(label: "Rename Tab", shortcut: "⌘⇧R")
            }
            .padding(8)
            .background(Color.secondary.opacity(0.05))
            .cornerRadius(8)
        }
    }
}

// MARK: - Input Settings

struct InputSettingsView: View {
    @ObservedObject private var settings = FeatureSettings.shared
    @State private var editingShortcut: KeyboardShortcut? = nil
    @State private var showShortcutEditor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Keyboard
            SettingsSectionHeader("Keyboard", icon: "keyboard")

            SettingsPicker(
                label: "Keybinding Preset",
                help: "Choose a keyboard shortcut preset that matches your workflow",
                selection: $settings.keybindingPreset,
                options: [
                    (value: "default", label: "Default"),
                    (value: "vim", label: "Vim"),
                    (value: "emacs", label: "Emacs")
                ]
            )

            Divider()
                .padding(.vertical, 8)

            // Keyboard Shortcuts Editor (NEW)
            SettingsSectionHeader("Keyboard Shortcuts", icon: "command")

            Text("Click on a shortcut to customize it. Conflicts will be highlighted.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(settings.customShortcuts) { shortcut in
                    KeyboardShortcutRow(
                        shortcut: shortcut,
                        hasConflict: !settings.shortcutConflicts(for: shortcut).isEmpty,
                        onEdit: {
                            editingShortcut = shortcut
                            showShortcutEditor = true
                        }
                    )
                }
            }
            .padding(8)
            .background(Color.secondary.opacity(0.05))
            .cornerRadius(8)

            HStack {
                Button("Reset Shortcuts to Defaults") {
                    settings.resetShortcutsToDefaults()
                }
                .foregroundColor(.orange)
            }

            Divider()
                .padding(.vertical, 8)

            // Mouse
            SettingsSectionHeader("Mouse", icon: "computermouse")

            SettingsToggle(
                label: "Copy on Select",
                help: "Automatically copy text to clipboard when you select it with the mouse",
                isOn: $settings.isCopyOnSelectEnabled
            )

            SettingsToggle(
                label: "Cmd+Click Paths",
                help: "Open file paths in your editor when you Cmd+click them in the terminal",
                isOn: $settings.isCmdClickPathsEnabled
            )

            if settings.isCmdClickPathsEnabled {
                SettingsPicker(
                    label: "URL Handler",
                    help: "Choose which browser opens when Cmd+clicking a URL",
                    selection: $settings.urlHandler,
                    options: URLHandler.allCases.map { (value: $0, label: $0.displayName) }
                )

                SettingsTextField(
                    label: "Default Editor",
                    help: "Editor to open files with (leave empty for system default or $EDITOR)",
                    placeholder: "/usr/local/bin/code",
                    text: $settings.defaultEditor,
                    width: 250,
                    monospaced: true
                )
            }

            SettingsToggle(
                label: "Option+Click Cursor",
                help: "Move cursor to clicked position by pressing Option and clicking (like iTerm2)",
                isOn: $settings.isOptionClickCursorEnabled
            )

            Divider()
                .padding(.vertical, 8)

            // Broadcast
            SettingsSectionHeader("Broadcast", icon: "antenna.radiowaves.left.and.right")

            SettingsToggle(
                label: "Broadcast Input",
                help: "Send keyboard input to all open tabs simultaneously (useful for multi-server commands)",
                isOn: $settings.isBroadcastEnabled
            )

            Divider()
                .padding(.vertical, 8)

            // Reset Button
            HStack {
                Spacer()
                Button("Reset Input to Defaults") {
                    settings.resetInputToDefaults()
                }
                .foregroundColor(.red)
            }
        }
        .sheet(isPresented: $showShortcutEditor) {
            if let shortcut = editingShortcut {
                ShortcutEditorSheet(shortcut: shortcut, settings: settings) {
                    showShortcutEditor = false
                    editingShortcut = nil
                }
            }
        }
    }
}

// MARK: - Keyboard Shortcut Row

struct KeyboardShortcutRow: View {
    let shortcut: KeyboardShortcut
    let hasConflict: Bool
    let onEdit: () -> Void

    var body: some View {
        Button(action: onEdit) {
            HStack {
                Text(KeyboardShortcut.actionDisplayName(shortcut.action))
                    .foregroundColor(hasConflict ? .orange : .primary)
                Spacer()
                Text(shortcut.displayString)
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(hasConflict ? Color.orange.opacity(0.2) : Color.secondary.opacity(0.1))
                    .cornerRadius(4)
                    .foregroundColor(hasConflict ? .orange : .primary)
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }
}

// MARK: - Shortcut Editor Sheet

struct ShortcutEditorSheet: View {
    let shortcut: KeyboardShortcut
    @ObservedObject var settings: FeatureSettings
    let onDismiss: () -> Void

    @State private var key: String
    @State private var useCmd: Bool
    @State private var useShift: Bool
    @State private var useCtrl: Bool
    @State private var useOpt: Bool

    init(shortcut: KeyboardShortcut, settings: FeatureSettings, onDismiss: @escaping () -> Void) {
        self.shortcut = shortcut
        self.settings = settings
        self.onDismiss = onDismiss
        _key = State(initialValue: shortcut.key)
        _useCmd = State(initialValue: shortcut.modifiers.contains("cmd"))
        _useShift = State(initialValue: shortcut.modifiers.contains("shift"))
        _useCtrl = State(initialValue: shortcut.modifiers.contains("ctrl"))
        _useOpt = State(initialValue: shortcut.modifiers.contains("opt"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Shortcut: \(KeyboardShortcut.actionDisplayName(shortcut.action))")
                .font(.headline)

            Divider()

            HStack {
                Text("Key")
                Spacer()
                TextField("Key", text: $key)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .font(.system(.body, design: .monospaced))
            }

            Text("Modifiers")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                Toggle("⌘ Cmd", isOn: $useCmd)
                Toggle("⇧ Shift", isOn: $useShift)
                Toggle("⌃ Ctrl", isOn: $useCtrl)
                Toggle("⌥ Opt", isOn: $useOpt)
            }

            // Preview
            HStack {
                Text("Preview:")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(previewString)
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(4)
            }

            // Conflict warning
            if !conflicts.isEmpty {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("Conflicts with: \(conflicts.map { KeyboardShortcut.actionDisplayName($0.action) }.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            Divider()

            HStack {
                Button("Cancel") {
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save") {
                    saveShortcut()
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(key.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private var modifiers: [String] {
        var mods: [String] = []
        if useCtrl { mods.append("ctrl") }
        if useOpt { mods.append("opt") }
        if useShift { mods.append("shift") }
        if useCmd { mods.append("cmd") }
        return mods
    }

    private var previewString: String {
        var parts: [String] = []
        if useCtrl { parts.append("⌃") }
        if useOpt { parts.append("⌥") }
        if useShift { parts.append("⇧") }
        if useCmd { parts.append("⌘") }
        parts.append(key.uppercased())
        return parts.joined()
    }

    private var conflicts: [KeyboardShortcut] {
        let testShortcut = KeyboardShortcut(action: shortcut.action, key: key, modifiers: modifiers)
        return settings.shortcutConflicts(for: testShortcut)
    }

    private func saveShortcut() {
        let updated = KeyboardShortcut(action: shortcut.action, key: key, modifiers: modifiers)
        settings.updateShortcut(updated)
    }
}

// MARK: - Productivity Settings

struct ProductivitySettingsView: View {
    @ObservedObject private var settings = FeatureSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Snippets
            SettingsSectionHeader("Snippets", icon: "text.badge.plus")

            // Quick summary and manage button
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Reusable text snippets with placeholders")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    HStack(spacing: 12) {
                        Label("\(SnippetManager.shared.entries.filter { $0.source == .global }.count) User", systemImage: "person.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        if SnippetManager.shared.repoRoot != nil {
                            Label("\(SnippetManager.shared.entries.filter { $0.source == .repo }.count) Repo", systemImage: "folder.fill")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Spacer()

                Button {
                    if let appDelegate = NSApp.delegate as? AppDelegate {
                        appDelegate.showSnippetsSettings()
                    }
                } label: {
                    Label("Manage Snippets", systemImage: "text.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(12)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)

            // Shortcut hint
            HStack(spacing: 4) {
                Image(systemName: "keyboard")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Text("Press ⌘; to open snippet picker in terminal")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            SettingsToggle(
                label: "Enable Snippets",
                help: "Use reusable text snippets with placeholders",
                isOn: $settings.isSnippetsEnabled
            )
            .onChange(of: settings.isSnippetsEnabled) { _ in
                SnippetManager.shared.refreshConfiguration()
            }

            SettingsToggle(
                label: "Repository Snippets",
                help: "Load snippets from the current git repository (.chau7/snippets.json)",
                isOn: $settings.isRepoSnippetsEnabled,
                disabled: !settings.isSnippetsEnabled
            )
            .onChange(of: settings.isRepoSnippetsEnabled) { _ in
                SnippetManager.shared.refreshConfiguration()
            }

            SettingsPicker(
                label: "Insert Mode",
                help: "How snippets are inserted into the terminal",
                selection: $settings.snippetInsertMode,
                options: [
                    (value: "expand", label: "Expand (type)"),
                    (value: "paste", label: "Paste")
                ],
                disabled: !settings.isSnippetsEnabled
            )

            SettingsToggle(
                label: "Placeholder Navigation",
                help: "Enable Tab key navigation between snippet placeholders",
                isOn: $settings.snippetPlaceholdersEnabled,
                disabled: !settings.isSnippetsEnabled || settings.snippetInsertMode == "paste"
            )

            Divider()
                .padding(.vertical, 8)

            // Clipboard History
            SettingsSectionHeader("Clipboard History", icon: "doc.on.clipboard")

            SettingsToggle(
                label: "Enable Clipboard History",
                help: "Keep a history of copied text for quick access",
                isOn: $settings.isClipboardHistoryEnabled
            )

            SettingsNumberField(
                label: "Maximum Items",
                help: "Number of clipboard entries to remember (1-500)",
                value: $settings.clipboardHistoryMaxItems,
                width: 80,
                disabled: !settings.isClipboardHistoryEnabled
            )

            Divider()
                .padding(.vertical, 8)

            // Bookmarks
            SettingsSectionHeader("Bookmarks", icon: "bookmark")

            SettingsToggle(
                label: "Enable Bookmarks",
                help: "Save and recall positions in terminal scrollback",
                isOn: $settings.isBookmarksEnabled
            )

            SettingsNumberField(
                label: "Maximum Per Tab",
                help: "Number of bookmarks allowed per tab (1-200)",
                value: $settings.maxBookmarksPerTab,
                width: 80,
                disabled: !settings.isBookmarksEnabled
            )

            Divider()
                .padding(.vertical, 8)

            // Search
            SettingsSectionHeader("Search", icon: "magnifyingglass")

            SettingsToggle(
                label: "Semantic Search",
                help: "Enable command-aware search through terminal history (requires shell integration)",
                isOn: $settings.isSemanticSearchEnabled
            )

            VStack(alignment: .leading, spacing: 6) {
                SettingsToggle(
                    label: "Default Case Sensitive",
                    help: "Start new find sessions with case-sensitive matching",
                    isOn: $settings.findCaseSensitiveDefault
                )

                SettingsToggle(
                    label: "Default Regex",
                    help: "Start new find sessions with regex matching enabled",
                    isOn: $settings.findRegexDefault
                )
            }
            .padding(8)
            .background(Color.secondary.opacity(0.05))
            .cornerRadius(8)

            VStack(alignment: .leading, spacing: 4) {
                SettingsShortcutRow(label: "Find", shortcut: "⌘F")
                SettingsShortcutRow(label: "Find Next", shortcut: "⌘G")
                SettingsShortcutRow(label: "Find Previous", shortcut: "⌘⇧G")
            }
            .padding(8)
            .background(Color.secondary.opacity(0.05))
            .cornerRadius(8)

            Divider()
                .padding(.vertical, 8)

            // Reset Button
            SettingsButtonRow(buttons: [
                .init(title: "Reset Productivity to Defaults", style: .plain) {
                    settings.resetProductivityToDefaults()
                }
            ], alignment: .trailing)
        }
    }
}

// MARK: - Windows Settings

struct WindowsSettingsView: View {
    @ObservedObject private var settings = FeatureSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Overlay
            SettingsSectionHeader("Overlay Window", icon: "macwindow")

            SettingsButtonRow(buttons: [
                .init(title: "Show Overlay", icon: "rectangle.inset.filled") {
                    (NSApp.delegate as? AppDelegate)?.showOverlay()
                },
                .init(title: "Reset Position", icon: "arrow.counterclockwise") {
                    FeatureSettings.shared.resetOverlayOffsets()
                }
            ])

            SettingsDescription(text: "The overlay window remembers its position per workspace and restores it automatically.")

            Divider()
                .padding(.vertical, 8)

            // Dropdown Terminal
            SettingsSectionHeader("Dropdown Terminal", icon: "rectangle.topthird.inset.filled")

            SettingsToggle(
                label: "Enable Dropdown",
                help: "Show a Quake-style dropdown terminal with a global hotkey",
                isOn: $settings.isDropdownEnabled
            )

            if settings.isDropdownEnabled {
                SettingsTextField(
                    label: "Hotkey",
                    help: "Global keyboard shortcut to toggle dropdown (e.g., ⌃`, ⌘Space)",
                    placeholder: "ctrl+`",
                    text: $settings.dropdownHotkey,
                    width: 120,
                    monospaced: true
                )

                SettingsRow("Height", help: "Dropdown height as percentage of screen (10-100%)") {
                    HStack(spacing: 8) {
                        Slider(value: $settings.dropdownHeight, in: 0.1...1.0, step: 0.05)
                            .frame(width: 150)
                        Text("\(Int(settings.dropdownHeight * 100))%")
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 50, alignment: .trailing)
                    }
                }
            }

            Divider()
                .padding(.vertical, 8)

            // Split Panes
            SettingsSectionHeader("Split Panes", icon: "rectangle.split.2x1")

            SettingsToggle(
                label: "Enable Split Panes",
                help: "Allow splitting terminal into multiple panes within a single tab",
                isOn: $settings.isSplitPanesEnabled
            )

            if settings.isSplitPanesEnabled {
                VStack(alignment: .leading, spacing: 4) {
                    SettingsShortcutRow(label: "Split Horizontal", shortcut: "⌘D")
                    SettingsShortcutRow(label: "Split Vertical", shortcut: "⌘⇧D")
                    SettingsShortcutRow(label: "Navigate Panes", shortcut: "⌘⌥Arrow")
                }
                .padding(8)
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(8)
            }
        }
    }
}

// MARK: - AI Integration Settings

struct AIIntegrationSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings = FeatureSettings.shared
    @State private var newCustomPattern: String = ""
    @State private var newCustomName: String = ""
    @State private var newCustomColor: TabColor = .gray

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Detection
            SettingsSectionHeader("AI CLI Detection", icon: "sparkle.magnifyingglass")

            Text("Chau7 automatically detects these AI CLIs and applies appropriate theming:")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                SettingsDetectionRow(name: "Claude Code", commands: "claude, claude-code", color: .purple)
                SettingsDetectionRow(name: "OpenAI Codex", commands: "codex, codex-cli", color: .green)
                SettingsDetectionRow(name: "Gemini", commands: "gemini", color: .blue)
                SettingsDetectionRow(name: "ChatGPT", commands: "chatgpt, gpt", color: .green)
                SettingsDetectionRow(name: "GitHub Copilot", commands: "gh copilot, copilot", color: .orange)
                SettingsDetectionRow(name: "Aider", commands: "aider, aider-chat", color: .pink)
                SettingsDetectionRow(name: "Cursor", commands: "cursor", color: .teal)
            }
            .padding(8)
            .background(Color.secondary.opacity(0.05))
            .cornerRadius(8)

            Divider()
                .padding(.vertical, 8)

            SettingsSectionHeader("Custom Detection Rules", icon: "slider.horizontal.3")

            Text("Add command or output patterns to tag custom AI CLIs.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                ForEach($settings.customAIDetectionRules) { $rule in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Pattern")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                TextField("mycli, /opt/ai/bin", text: $rule.pattern)
                                    .textFieldStyle(.roundedBorder)
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Display Name")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                TextField("My AI", text: $rule.displayName)
                                    .textFieldStyle(.roundedBorder)
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Color")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Picker("Color", selection: $rule.colorName) {
                                    ForEach(TabColor.allCases) { color in
                                        Text(color.rawValue.capitalized).tag(color.rawValue)
                                    }
                                }
                                .frame(width: 120)
                            }

                            Button {
                                if let index = settings.customAIDetectionRules.firstIndex(where: { $0.id == rule.id }) {
                                    settings.customAIDetectionRules.remove(at: index)
                                }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove rule")
                        }
                    }
                    .padding(8)
                    .background(Color.secondary.opacity(0.05))
                    .cornerRadius(8)
                }

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Pattern")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("cli-name", text: $newCustomPattern)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Display Name")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("Custom AI", text: $newCustomName)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Color")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("Color", selection: $newCustomColor) {
                            ForEach(TabColor.allCases) { color in
                                Text(color.rawValue.capitalized).tag(color)
                            }
                        }
                        .frame(width: 120)
                    }

                    Button("Add") {
                        let trimmed = newCustomPattern.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        let name = newCustomName.trimmingCharacters(in: .whitespacesAndNewlines)
                        let rule = CustomAIDetectionRule(
                            pattern: trimmed,
                            displayName: name,
                            colorName: newCustomColor.rawValue
                        )
                        settings.customAIDetectionRules.append(rule)
                        newCustomPattern = ""
                        newCustomName = ""
                        newCustomColor = .gray
                    }
                    .disabled(newCustomPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            Divider()
                .padding(.vertical, 8)

            // Notifications
            SettingsSectionHeader("Notifications", icon: "bell")

            SettingsInfoRow(label: "Status", value: model.notificationStatus, monospaced: true)

            if let warning = model.notificationWarning {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                .padding(.vertical, 4)
            }

            SettingsButtonRow(buttons: [
                .init(title: "Request Permission", icon: "bell.badge") {
                    model.requestNotificationPermission()
                },
                .init(title: "System Settings", icon: "gear") {
                    model.openNotificationSettings()
                },
                .init(title: "Send Test", icon: "paperplane") {
                    model.sendTestNotification()
                }
            ])

            Divider()
                .padding(.vertical, 8)

            // Notification Filters (NEW)
            SettingsSectionHeader("Notification Filters", icon: "line.3.horizontal.decrease.circle")

            Text("Choose which events trigger notifications:")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                NotificationFilterToggle(
                    label: "Task Finished",
                    help: "Notify when an AI task completes successfully",
                    isOn: $settings.notificationFilters.taskFinished
                )

                NotificationFilterToggle(
                    label: "Task Failed",
                    help: "Notify when an AI task fails or encounters an error",
                    isOn: $settings.notificationFilters.taskFailed
                )

                NotificationFilterToggle(
                    label: "Needs Validation",
                    help: "Notify when an AI task needs human review or approval",
                    isOn: $settings.notificationFilters.needsValidation
                )

                NotificationFilterToggle(
                    label: "Permission Request",
                    help: "Notify when a tool requires permission to proceed",
                    isOn: $settings.notificationFilters.permissionRequest
                )

                NotificationFilterToggle(
                    label: "Tool Complete",
                    help: "Notify when individual tools complete execution",
                    isOn: $settings.notificationFilters.toolComplete
                )

                NotificationFilterToggle(
                    label: "Session End",
                    help: "Notify when an AI session terminates",
                    isOn: $settings.notificationFilters.sessionEnd
                )

                NotificationFilterToggle(
                    label: "Command Idle",
                    help: "Notify when terminal becomes idle after command execution",
                    isOn: $settings.notificationFilters.commandIdle
                )
            }
            .padding(8)
            .background(Color.secondary.opacity(0.05))
            .cornerRadius(8)

            Divider()
                .padding(.vertical, 8)

            // Event Monitoring
            SettingsSectionHeader("Event Monitoring", icon: "waveform.path.ecg")

            SettingsToggle(
                label: "Monitor AI Events",
                help: "Watch for AI CLI events like task completion, failures, and permission requests",
                isOn: $model.isMonitoring
            )
            .onChange(of: model.isMonitoring) { _ in
                model.applyMonitoringState()
            }

            SettingsTextField(
                label: "Event Log Path",
                help: "Path to the AI event log file",
                placeholder: "~/.ai-events.log",
                text: $model.logPath,
                width: 280,
                monospaced: true,
                onSubmit: { model.restartTailer() }
            )

            SettingsButtonRow(buttons: [
                .init(title: "Restart Monitor", icon: "arrow.clockwise") {
                    model.restartTailer()
                },
                .init(title: "Reveal in Finder", icon: "folder") {
                    model.revealLogInFinder()
                }
            ])
        }
    }
}

// MARK: - Notification Filter Toggle

struct NotificationFilterToggle: View {
    let label: String
    let help: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 13))
                Text(help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}

// MARK: - Logs Settings

struct LogsSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // History Logs
            SettingsSectionHeader("History Logs", icon: "clock.arrow.circlepath")

            SettingsToggle(
                label: "Monitor History Logs",
                help: "Watch AI CLI history files for session activity and idle detection",
                isOn: $model.isIdleMonitoring
            )
            .onChange(of: model.isIdleMonitoring) { _ in
                model.applyIdleMonitoringState()
            }

            SettingsTextField(
                label: "Idle Seconds",
                help: "Seconds of inactivity before sending idle notification",
                placeholder: "300",
                text: $model.idleSecondsText,
                width: 80,
                onSubmit: { model.restartIdleMonitors() }
            )

            SettingsTextField(
                label: "Stale Seconds",
                help: "Seconds before marking a session as closed",
                placeholder: "3600",
                text: $model.staleSecondsText,
                width: 80,
                onSubmit: { model.restartIdleMonitors() }
            )

            SettingsTextField(
                label: "Codex History Path",
                help: nil,
                placeholder: "~/.codex/history.jsonl",
                text: $model.codexHistoryPath,
                width: 300,
                monospaced: true,
                onSubmit: { model.restartIdleMonitors() }
            )

            SettingsTextField(
                label: "Claude History Path",
                help: nil,
                placeholder: "~/.claude/history.jsonl",
                text: $model.claudeHistoryPath,
                width: 300,
                monospaced: true,
                onSubmit: { model.restartIdleMonitors() }
            )

            SettingsButtonRow(buttons: [
                .init(title: "Restart Monitors", icon: "arrow.clockwise") {
                    model.restartIdleMonitors()
                },
                .init(title: "Clear History", icon: "trash") {
                    model.clearHistory()
                }
            ])

            Divider()
                .padding(.vertical, 8)

            // Terminal Logs
            SettingsSectionHeader("Terminal Logs", icon: "doc.text")

            SettingsToggle(
                label: "Monitor Terminal Logs",
                help: "Watch PTY wrapper output files for terminal activity",
                isOn: $model.isTerminalMonitoring
            )
            .onChange(of: model.isTerminalMonitoring) { _ in
                model.applyTerminalMonitoringState()
            }

            SettingsToggle(
                label: "Normalize Output",
                help: "Strip ANSI codes and control characters from log display",
                isOn: $model.isTerminalNormalize
            )
            .onChange(of: model.isTerminalNormalize) { _ in
                model.restartTerminalMonitors()
            }

            SettingsToggle(
                label: "Render ANSI Styling",
                help: "Display ANSI colors and formatting in log viewer",
                isOn: $model.isTerminalAnsi
            )

            SettingsTextField(
                label: "Codex Terminal Log",
                help: nil,
                placeholder: "~/Library/Logs/Chau7/codex-pty.log",
                text: $model.codexTerminalPath,
                width: 300,
                monospaced: true,
                onSubmit: { model.restartTerminalMonitors() }
            )

            SettingsTextField(
                label: "Claude Terminal Log",
                help: nil,
                placeholder: "~/Library/Logs/Chau7/claude-pty.log",
                text: $model.claudeTerminalPath,
                width: 300,
                monospaced: true,
                onSubmit: { model.restartTerminalMonitors() }
            )

            SettingsButtonRow(buttons: [
                .init(title: "Restart Monitors", icon: "arrow.clockwise") {
                    model.restartTerminalMonitors()
                },
                .init(title: "Reload Last Lines", icon: "arrow.clockwise.circle") {
                    model.reloadTerminalPrefill()
                },
                .init(title: "Clear Logs", icon: "trash") {
                    model.clearTerminalLogs()
                }
            ])

            Divider()
                .padding(.vertical, 8)

            // Sessions
            SettingsSectionHeader("Active Sessions", icon: "person.2")

            if model.sessionStatuses.isEmpty {
                Text("No sessions tracked yet.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.sessionStatuses.sorted(by: { $0.lastSeen > $1.lastSeen })) { status in
                        HStack {
                            Circle()
                                .fill(status.state == .active ? Color.green : Color.gray)
                                .frame(width: 8, height: 8)
                            Text("\(status.tool)")
                                .fontWeight(.medium)
                            Text(String(status.sessionId.prefix(8)))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(status.state.rawValue.uppercased())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }
}

// MARK: - About Settings

struct AboutSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // App Info
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Chau7")
                        .font(.title)
                        .fontWeight(.bold)
                    Text("AI CLI Terminal Companion")
                        .foregroundStyle(.secondary)
                    Text(bundleVersion)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 8)

            Divider()
                .padding(.vertical, 8)

            // Version Details
            SettingsSectionHeader("Version Information", icon: "info.circle")

            VStack(alignment: .leading, spacing: 4) {
                SettingsInfoRow(label: "Application", value: ProcessInfo.processInfo.processName, monospaced: true)
                SettingsInfoRow(label: "Bundle ID", value: Bundle.main.bundleIdentifier ?? "Not bundled", monospaced: true)
                SettingsInfoRow(label: "Version", value: bundleVersion, monospaced: true)
            }
            .padding(8)
            .background(Color.secondary.opacity(0.05))
            .cornerRadius(8)

            Divider()
                .padding(.vertical, 8)

            // System Info
            SettingsSectionHeader("System Information", icon: "desktopcomputer")

            VStack(alignment: .leading, spacing: 4) {
                SettingsInfoRow(label: "macOS", value: ProcessInfo.processInfo.operatingSystemVersionString, monospaced: true)
                SettingsInfoRow(label: "Architecture", value: machineArchitecture, monospaced: true)
                SettingsInfoRow(label: "Shell", value: ProcessInfo.processInfo.environment["SHELL"] ?? "Unknown", monospaced: true)
            }
            .padding(8)
            .background(Color.secondary.opacity(0.05))
            .cornerRadius(8)

            Divider()
                .padding(.vertical, 8)

            // Links
            SettingsSectionHeader("Links", icon: "link")

            HStack(spacing: 16) {
                Link(destination: URL(string: "https://github.com/anthropics/chau7")!) {
                    Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }

                Link(destination: URL(string: "https://github.com/anthropics/chau7/issues")!) {
                    Label("Report Issue", systemImage: "exclamationmark.bubble")
                }

                Link(destination: URL(string: "https://github.com/anthropics/chau7/blob/main/README.md")!) {
                    Label("Documentation", systemImage: "book")
                }
            }
            .buttonStyle(.link)

            Divider()
                .padding(.vertical, 8)

            // Logs
            SettingsSectionHeader("Application Log", icon: "doc.text")

            SettingsInfoRow(label: "Log Path", value: model.logFilePath, monospaced: true)

            SettingsButtonRow(buttons: [
                .init(title: "Reveal in Finder", icon: "folder") {
                    model.revealLogFile()
                },
                .init(title: "Debug Console", icon: "terminal") {
                    DebugConsoleController.shared.show()
                }
            ])

            Divider()
                .padding(.vertical, 8)

            // Acknowledgments
            SettingsSectionHeader("Acknowledgments", icon: "heart")

            SettingsDescription(text: "Chau7 is built with SwiftTerm for terminal emulation.")
            SettingsDescription(text: "Copyright © 2024-2025. All rights reserved.")
        }
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
            return "Development Build"
        }
    }

    private var machineArchitecture: String {
        #if arch(arm64)
        return "Apple Silicon (arm64)"
        #elseif arch(x86_64)
        return "Intel (x86_64)"
        #else
        return "Unknown"
        #endif
    }
}
