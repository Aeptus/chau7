import SwiftUI
import AppKit

// MARK: - Debug Console View

/// A hidden debug console accessible via Cmd+Shift+L (when enabled).
/// Shows real-time state, active contexts, event history, and allows generating bug reports.
struct DebugConsoleView: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var overlayModel: OverlayTabsModel
    @State private var selectedTab = 0
    @State private var logFilter = ""
    @State private var autoRefresh = true
    @State private var refreshTimer: Timer?
    @State private var logs: [String] = []
    @State private var bugReportDescription = ""
    @State private var lastReportPath: String?

    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header

            Divider()

            // Tab picker
            Picker("", selection: $selectedTab) {
                Text("State").tag(0)
                Text("Contexts").tag(1)
                Text("Events").tag(2)
                Text("Logs").tag(3)
                Text("Report").tag(4)
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
                case 3: logsView
                case 4: reportView
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

            Text("Debug Console")
                .font(.system(size: 14, weight: .semibold))

            Spacer()

            Toggle("Auto-refresh", isOn: $autoRefresh)
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
                featureFlagsView
            }
            .padding()
        }
    }

    private var applicationStateView: some View {
        GroupBox("Application") {
            VStack(alignment: .leading, spacing: 4) {
                stateRow("Monitoring", value: appModel.isMonitoring ? "Active" : "Paused")
                stateRow("Tabs", value: "\(overlayModel.tabs.count)")
                stateRow("Active Tab", value: "\((overlayModel.tabs.firstIndex { $0.id == overlayModel.selectedTabID } ?? 0) + 1)")
                stateRow("Claude Sessions", value: "\(appModel.claudeCodeSessions.count)")
                stateRow("Event Count", value: "\(appModel.claudeCodeEvents.count)")
            }
        }
    }

    private var tabsStateView: some View {
        GroupBox("Tabs") {
            ForEach(Array(overlayModel.tabs.enumerated()), id: \.element.id) { index, tab in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Tab \(index + 1)")
                            .font(.system(size: 11, weight: .semibold))
                        if tab.id == overlayModel.selectedTabID {
                            Text("(active)")
                                .font(.system(size: 10))
                                .foregroundStyle(.green)
                        }
                        Spacer()
                        Text(tab.session?.status.rawValue ?? "no session")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    Group {
                        stateRow("Title", value: tab.customTitle ?? tab.session?.title ?? "(no terminal)")
                        stateRow("App", value: tab.session?.activeAppName ?? "none")
                        stateRow("Directory", value: tab.session?.currentDirectory ?? "")
                        stateRow("Input Lag", value: tab.session?.inputLatencySummary ?? "n/a")
                        if tab.session?.isGitRepo == true {
                            stateRow("Git Branch", value: tab.session?.gitBranch ?? "unknown")
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

    private var featureFlagsView: some View {
        GroupBox("Feature Flags") {
            let features = FeatureSettings.shared
            VStack(alignment: .leading, spacing: 4) {
                flagRow("Snippets", enabled: features.isSnippetsEnabled)
                flagRow("Repo Snippets", enabled: features.isRepoSnippetsEnabled)
                flagRow("Broadcast Mode", enabled: features.isBroadcastEnabled)
                flagRow("Clipboard History", enabled: features.isClipboardHistoryEnabled)
                flagRow("Bookmarks", enabled: features.isBookmarksEnabled)
            }
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
            Text(enabled ? "ON" : "OFF")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(enabled ? .green : .secondary)
        }
    }

    // MARK: - Contexts View

    private var contextsView: some View {
        VStack(spacing: 0) {
            // Active contexts
            GroupBox("Active Contexts (\(DebugContext.active.count))") {
                if DebugContext.active.isEmpty {
                    Text("No active contexts")
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
            GroupBox("Recent History (\(DebugContext.history.count))") {
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
            Text("\(duration)ms")
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

    // MARK: - Logs View

    private var logsView: some View {
        VStack(spacing: 0) {
            // Filter
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter logs...", text: $logFilter)
                    .textFieldStyle(.plain)

                Button("Refresh") {
                    loadLogs()
                }
                .controlSize(.small)

                Button("Open File") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: Log.filePath))
                }
                .controlSize(.small)
            }
            .padding(8)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filteredLogs, id: \.self) { line in
                        logLine(line)
                    }
                }
                .padding(8)
            }
            .font(.system(size: 10, design: .monospaced))
        }
        .onAppear { loadLogs() }
    }

    private var filteredLogs: [String] {
        if logFilter.isEmpty {
            return logs
        }
        return logs.filter { $0.localizedCaseInsensitiveContains(logFilter) }
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
            GroupBox("Generate Bug Report") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Describe the issue:")
                        .font(.system(size: 11, weight: .medium))

                    TextEditor(text: $bugReportDescription)
                        .font(.system(size: 11))
                        .frame(height: 100)
                        .border(Color.gray.opacity(0.3))

                    HStack {
                        Button("Generate Report") {
                            lastReportPath = BugReporter.shared.generateReport(userDescription: bugReportDescription)
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Open Reports Folder") {
                            BugReporter.shared.openReportsFolder()
                        }
                    }

                    if let path = lastReportPath {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Report saved to:")
                                .font(.system(size: 10))
                            Text(path)
                                .font(.system(size: 10, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }

            GroupBox("Quick Actions") {
                HStack(spacing: 12) {
                    Button("Capture Snapshot") {
                        let snapshot = StateSnapshot.capture(from: appModel, overlayModel: overlayModel)
                        if let path = snapshot.save() {
                            lastReportPath = path
                        }
                    }

                    Button("Copy State JSON") {
                        let snapshot = StateSnapshot.capture(from: appModel, overlayModel: overlayModel)
                        if let data = JSONOperations.encode(snapshot, context: "debug state snapshot"),
                           let json = String(data: data, encoding: .utf8) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(json, forType: .string)
                        }
                    }

                    Button("Clear Event History") {
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
            if selectedTab == 3 {
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
