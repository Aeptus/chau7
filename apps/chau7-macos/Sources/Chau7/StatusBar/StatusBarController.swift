import AppKit
import Combine
import SwiftUI
import Chau7Core

/// Controls the menu bar status item and popover panel.
/// Uses NSStatusItem + NSPopover for proper multi-monitor support instead of SwiftUI's
/// MenuBarExtra which has positioning issues on multi-monitor setups.
///
/// - Note: This is a singleton. Call `setup(model:)` from AppDelegate.applicationDidFinishLaunching
///   and `cleanup()` from applicationWillTerminate.
final class StatusBarController: NSObject {
    static let shared = StatusBarController()

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?
    private weak var model: AppModel?
    private var badgeCancellable: AnyCancellable?

    /// Panel view model — lives as long as the controller so popover doesn't recreate state.
    private var panelViewModel: CommandCenterViewModel?

    private override init() {
        super.init()
    }

    /// Initialize the status bar with the app model.
    /// - Parameter model: The app model to observe and display.
    /// - Note: Must be called from main thread.
    func setup(model: AppModel) {
        self.model = model
        self.panelViewModel = CommandCenterViewModel(model: model, onClose: { [weak self] in
            self?.closePopover()
        })

        // Create status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "bell", accessibilityDescription: L("app.name", "Chau7"))
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        // Create popover with persistent content (fix #6: no recreation on every open)
        guard let panelViewModel else { return }
        popover = NSPopover()
        popover?.contentSize = NSSize(width: 400, height: 520)
        popover?.behavior = .applicationDefined
        popover?.animates = true
        popover?.contentViewController = NSHostingController(
            rootView: StatusBarPanelView(viewModel: panelViewModel)
        )

        // Monitor for clicks outside to close popover (global events = clicks in other apps)
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePopover()
        }

        // Local monitor for clicks within the app but outside the popover
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self,
                  let popover = self.popover,
                  popover.isShown,
                  let popoverWindow = popover.contentViewController?.view.window else {
                return event
            }

            if event.window != popoverWindow {
                if let button = self.statusItem?.button,
                   let buttonWindow = button.window,
                   event.window == buttonWindow {
                    return event
                }
                self.closePopover()
            }
            return event
        }

        // Observe monitoring state changes to update icon
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateIcon),
            name: NSNotification.Name("MonitoringStateChanged"),
            object: nil
        )

        // Reactive badge updates from session state changes
        badgeCancellable = model.$claudeCodeSessions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                self?.updateBadgeAndIcon(sessions: sessions)
            }
    }

    /// Cleanup all resources. Call from applicationWillTerminate.
    func cleanup() {
        NotificationCenter.default.removeObserver(self)
        badgeCancellable?.cancel()
        badgeCancellable = nil

        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }

        statusItem = nil
        popover = nil
        panelViewModel = nil
    }

    /// Flash the status bar icon to draw attention (used by menuBarAlert action).
    func flashAlert(duration: Int, animate: Bool) {
        guard let button = statusItem?.button else { return }
        let originalImage = button.image
        let alertImage = NSImage(systemSymbolName: "bell.badge.fill", accessibilityDescription: "Alert")

        button.image = alertImage

        if animate {
            // Pulse animation: alternate icon rapidly before restoring
            let pulseCount = min(duration * 2, 10)
            for i in 0..<pulseCount {
                let delay = Double(i) * 0.5
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    button.image = (i % 2 == 0) ? alertImage : originalImage
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(duration)) {
                button.image = originalImage
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(duration)) {
                button.image = originalImage
            }
        }
        Log.info("StatusBarController: Menu bar alert for \(duration)s (animate=\(animate))")
    }

    /// Update the status bar icon based on monitoring state.
    @objc func updateIcon() {
        updateBadgeAndIcon(sessions: model?.claudeCodeSessions ?? [])
    }

    /// Update icon and badge count based on session states.
    /// Three states: bell (off), bell.badge.fill (on, clear), bell.badge.fill + count (attention needed).
    private func updateBadgeAndIcon(sessions: [ClaudeCodeMonitor.ClaudeSessionInfo]) {
        guard let button = statusItem?.button else { return }
        let isMonitoring = model?.isMonitoring ?? false
        let attentionCount = sessions.filter { $0.state == .waitingPermission || $0.state == .waitingInput }.count

        if !isMonitoring {
            button.image = NSImage(systemSymbolName: "bell", accessibilityDescription: L("app.name", "Chau7"))
            button.title = ""
        } else if attentionCount > 0 {
            button.image = NSImage(systemSymbolName: "bell.badge.fill", accessibilityDescription: L("app.name", "Chau7"))
            button.title = "\(attentionCount)"
        } else {
            button.image = NSImage(systemSymbolName: "bell.badge.fill", accessibilityDescription: L("app.name", "Chau7"))
            button.title = ""
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        if let popover, popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem?.button,
              let popover else { return }

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

        if let popoverWindow = popover.contentViewController?.view.window {
            popoverWindow.level = .popUpMenu
        }
    }

    private func closePopover() {
        popover?.performClose(nil)
    }
}

// MARK: - Command Center View Model

/// Shared state for the command center panel — survives popover open/close cycles.
/// All derived state is computed from model.claudeCodeSessions (which is @Published),
/// so SwiftUI re-evaluates automatically. No manual sync needed.
final class CommandCenterViewModel: ObservableObject {
    let model: AppModel
    let onClose: () -> Void
    @Published var showQuitConfirmation = false

    init(model: AppModel, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
    }

    /// Sessions needing user action (permission or input).
    var attentionSessions: [ClaudeCodeMonitor.ClaudeSessionInfo] {
        model.claudeCodeSessions.filter { $0.state == .waitingPermission || $0.state == .waitingInput }
    }

    var attentionCount: Int { attentionSessions.count }

    /// Active sessions excluding idle/closed, sorted by most recent activity, max 5.
    var liveSessions: [ClaudeCodeMonitor.ClaudeSessionInfo] {
        model.claudeCodeSessions
            .filter { $0.state != .idle && $0.state != .closed }
            .sorted { $0.lastActivity > $1.lastActivity }
            .prefix(5)
            .map { $0 }
    }

    /// Merged feed of notification history + raw events, deduplicated, max 8.
    /// Accepts history entries as parameter since NotificationHistory is @MainActor-isolated
    /// and this view model is not. Callers in SwiftUI views can pass the snapshot directly.
    func unifiedTimeline(historyEntries: [NotificationHistory.Entry]) -> [UnifiedTimelineEntry] {
        let rawEvents = Array(model.claudeCodeEvents.suffix(8))

        // Convert notification history entries (these win in dedup)
        var entries: [UnifiedTimelineEntry] = historyEntries.map { entry in
            let triggerLabel = NotificationTriggerCatalog.trigger(
                source: AIEventSource(rawValue: entry.source),
                type: entry.type
            )?.localizedLabel

            return UnifiedTimelineEntry(
                id: entry.id,
                icon: entry.wasRateLimited ? "bell.slash" : "bell.fill",
                iconColor: entry.wasRateLimited ? .gray : .orange,
                title: triggerLabel ?? CommandCenterViewModel.humanReadableType(entry.type),
                detail: CommandCenterViewModel.cleanDetail(tool: entry.tool, message: entry.message),
                timestamp: entry.timestamp,
                isRateLimited: entry.wasRateLimited
            )
        }

        // Track notification timestamps for dedup (within 2s = same event)
        let historyTimestamps = Set(historyEntries.map { Int($0.timestamp.timeIntervalSince1970) })

        // Add raw events that don't match a notification history entry
        for event in rawEvents {
            let eventSecond = Int(event.timestamp.timeIntervalSince1970)
            let isDuplicate = historyTimestamps.contains(where: { abs($0 - eventSecond) <= 2 })
            if !isDuplicate {
                entries.append(UnifiedTimelineEntry(
                    id: event.id,
                    icon: CommandCenterViewModel.eventIcon(for: event.type),
                    iconColor: CommandCenterViewModel.eventColor(for: event.type),
                    title: CommandCenterViewModel.humanReadableEvent(event),
                    detail: CommandCenterViewModel.humanReadableDetail(event),
                    timestamp: event.timestamp,
                    isRateLimited: false
                ))
            }
        }

        return entries
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(8)
            .map { $0 }
    }

    func focusSession(_ session: ClaudeCodeMonitor.ClaudeSessionInfo) {
        if let delegate = NSApp.delegate as? AppDelegate,
           let overlayModel = delegate.overlayModel {
            delegate.showOverlay()
            overlayModel.focusTabByTool(session.projectName)
        }
        onClose()
    }

    func executeSnippet(_ entry: SnippetEntry) {
        if let delegate = NSApp.delegate as? AppDelegate,
           let overlayModel = delegate.overlayModel,
           let session = overlayModel.selectedTab?.session {
            session.insertSnippet(entry)
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.snippet.body, forType: .string)
        }
        onClose()
    }

    // MARK: - Human-Readable Event Mapping

    private static func eventIcon(for type: ClaudeEventType) -> String {
        switch type {
        case .userPrompt: return "person.fill"
        case .toolStart: return "hammer"
        case .toolComplete: return "checkmark.circle"
        case .permissionRequest: return "exclamationmark.triangle"
        case .responseComplete: return "text.bubble"
        case .notification: return "bell"
        case .sessionEnd: return "xmark.circle"
        case .unknown: return "circle"
        }
    }

    private static func eventColor(for type: ClaudeEventType) -> Color {
        switch type {
        case .userPrompt: return .green
        case .permissionRequest: return .yellow
        case .sessionEnd: return .red
        case .responseComplete: return .blue
        case .toolComplete: return .cyan
        default: return .secondary
        }
    }

    /// Human-readable title from a raw ClaudeCodeEvent.
    private static func humanReadableEvent(_ event: ClaudeCodeEvent) -> String {
        switch event.type {
        case .userPrompt:
            return "Prompt sent"
        case .toolStart:
            return "Running \(friendlyToolName(event.toolName))"
        case .toolComplete:
            return "\(friendlyToolName(event.toolName)) done"
        case .permissionRequest:
            return "Needs permission"
        case .responseComplete:
            return "Finished responding"
        case .sessionEnd:
            return "Session ended"
        case .notification:
            return event.message.isEmpty ? "Notification" : event.message
        case .unknown:
            return "Event"
        }
    }

    /// Human-readable detail line (project name + context).
    private static func humanReadableDetail(_ event: ClaudeCodeEvent) -> String {
        let project = event.projectName
        switch event.type {
        case .toolStart, .toolComplete:
            // Show project + file context from message if available
            let file = extractFileName(from: event.message)
            if let file { return "\(project) — \(file)" }
            return project
        case .permissionRequest:
            if !event.toolName.isEmpty {
                return "\(project) — \(friendlyToolName(event.toolName))"
            }
            return project
        case .responseComplete, .sessionEnd, .userPrompt:
            return project
        default:
            return event.message.isEmpty ? project : event.message
        }
    }

    /// Human-readable type string for notification history entries.
    private static func humanReadableType(_ type: String) -> String {
        switch type {
        case "finished", "response_complete": return "Finished responding"
        case "permission", "permission_request": return "Needs permission"
        case "idle": return "Session idle"
        case "tool_called", "tool_start": return "Tool running"
        case "tool_complete": return "Tool finished"
        case "session_end": return "Session ended"
        case "user_prompt": return "Prompt sent"
        case "error": return "Error occurred"
        case "file_edited": return "File edited"
        case "command_finished": return "Command finished"
        default: return type.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Clean detail for notification history entries.
    private static func cleanDetail(tool: String, message: String) -> String {
        // If message has useful content, prefer it; otherwise show tool context
        if !message.isEmpty {
            let file = extractFileName(from: message)
            if let file { return file }
            // Truncate long messages
            if message.count > 60 { return String(message.prefix(57)) + "..." }
            return message
        }
        if !tool.isEmpty { return friendlyToolName(tool) }
        return ""
    }

    /// Map internal tool names to readable labels.
    private static func friendlyToolName(_ tool: String) -> String {
        switch tool.lowercased() {
        case "write": return "file write"
        case "read": return "file read"
        case "edit": return "file edit"
        case "bash": return "shell command"
        case "glob": return "file search"
        case "grep": return "content search"
        case "webfetch": return "web fetch"
        case "websearch": return "web search"
        case "notebookedit": return "notebook edit"
        case "todowrite": return "task update"
        case "listtool": return "file listing"
        default: return tool
        }
    }

    /// Extract a filename from a message string (e.g. path or "Editing foo.swift").
    private static func extractFileName(from message: String) -> String? {
        // Look for file paths
        if message.contains("/") {
            let components = message.components(separatedBy: "/")
            if let last = components.last, !last.isEmpty, last.contains(".") {
                return last
            }
        }
        return nil
    }
}

// MARK: - Unified Timeline Entry

struct UnifiedTimelineEntry: Identifiable {
    let id: UUID
    let icon: String
    let iconColor: Color
    let title: String
    let detail: String
    let timestamp: Date
    let isRateLimited: Bool
}

// MARK: - Status Bar Panel View

struct StatusBarPanelView: View {
    @ObservedObject var viewModel: CommandCenterViewModel

    private var model: AppModel { viewModel.model }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HeroZoneView(viewModel: viewModel)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    liveSessionsSection
                    unifiedFeedSection
                    quickCommandsSection
                }
                .padding(12)
            }
            .frame(maxHeight: 400)

            Divider()

            footerSection
        }
        .frame(width: 400)
    }

    // MARK: - Live Sessions

    private var liveSessionsSection: some View {
        let sessions = viewModel.liveSessions
        return Group {
            if !sessions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label(L("Live Sessions", "Live Sessions"), systemImage: "bubble.left.and.bubble.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)

                    ForEach(sessions) { session in
                        LiveSessionCard(session: session, onTap: {
                            viewModel.focusSession(session)
                        })
                    }
                }
                .padding(10)
                .background(Color.accentColor.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.accentColor.opacity(0.2), lineWidth: 1)
                )
            }
        }
    }

    // MARK: - Unified Feed

    private var unifiedFeedSection: some View {
        let timeline = viewModel.unifiedTimeline(historyEntries: NotificationManager.shared.history.recent(limit: 8))
        return VStack(alignment: .leading, spacing: 8) {
            Label(L("Activity", "Activity"), systemImage: "clock")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            if timeline.isEmpty {
                Text(L("No recent activity", "No recent activity"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(timeline) { entry in
                    TimelineRow(entry: entry)
                }
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Quick Commands

    private var quickCommandsSection: some View {
        let pinnedSnippets = SnippetManager.shared.entries.filter { $0.snippet.isPinned }.prefix(3)
        return VStack(alignment: .leading, spacing: 10) {
            Label(L("Quick Commands", "Quick Commands"), systemImage: "command")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            if !pinnedSnippets.isEmpty {
                ForEach(Array(pinnedSnippets)) { entry in
                    Button {
                        viewModel.executeSnippet(entry)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 9))
                                .foregroundColor(.accentColor)
                                .frame(width: 16)
                            Text(entry.snippet.title)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                Divider()
            }

            QuickSettingToggle(
                icon: "antenna.radiowaves.left.and.right",
                label: "Monitoring",
                isOn: Binding(
                    get: { self.model.isMonitoring },
                    set: { newValue in
                        self.model.isMonitoring = newValue
                        self.model.applyMonitoringState()
                        NotificationCenter.default.post(name: NSNotification.Name("MonitoringStateChanged"), object: nil)
                    }
                )
            )

            HStack {
                Spacer()
                Button {
                    (NSApp.delegate as? AppDelegate)?.showSettings()
                    viewModel.onClose()
                } label: {
                    Label(L("All Settings", "All Settings"), systemImage: "gearshape")
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Text("v\(bundleVersion)")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            Spacer()

            Button(L("Quit Chau7", "Quit Chau7")) {
                viewModel.showQuitConfirmation = true
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .popover(isPresented: $viewModel.showQuitConfirmation) {
                VStack(spacing: 10) {
                    Text(L("Quit Chau7?", "Quit Chau7?"))
                        .font(.system(size: 12, weight: .medium))
                    HStack(spacing: 8) {
                        Button(L("Cancel", "Cancel")) {
                            viewModel.showQuitConfirmation = false
                        }
                        .controlSize(.small)
                        Button(L("Quit", "Quit"), role: .destructive) {
                            NSApplication.shared.terminate(nil)
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    }
                }
                .padding(12)
            }
        }
        .padding(10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var bundleVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}

// MARK: - Hero Zone

private struct HeroZoneView: View {
    @ObservedObject var viewModel: CommandCenterViewModel

    var body: some View {
        if viewModel.attentionCount > 0 {
            attentionCard
        } else {
            allClearBar
        }
    }

    private var attentionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text("\(viewModel.attentionCount) session\(viewModel.attentionCount == 1 ? "" : "s") need\(viewModel.attentionCount == 1 ? "s" : "") attention")
                    .font(.system(size: 13, weight: .semibold))
            }

            ForEach(Array(viewModel.attentionSessions.prefix(3))) { session in
                HStack(spacing: 8) {
                    Circle()
                        .fill(session.state == .waitingPermission ? Color.yellow : Color.blue)
                        .frame(width: 6, height: 6)
                    Text(session.projectName)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    Text(session.state == .waitingPermission ? L("Permission", "Permission") : L("Input", "Input"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Go", "Go")) {
                        viewModel.focusSession(session)
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(12)
        .background(Color.yellow.opacity(0.1))
    }

    private var allClearBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(L("All clear", "All clear"))
                .font(.system(size: 13, weight: .medium))

            let total = viewModel.model.claudeCodeSessions.count
            if total > 0 {
                Text("\(total) session\(total == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 4) {
                Circle()
                    .fill(viewModel.model.isMonitoring ? Color.green : Color.gray)
                    .frame(width: 6, height: 6)
                Text(viewModel.model.isMonitoring ? L("status.active", "Active") : L("status.paused", "Paused"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Live Session Card

private struct LiveSessionCard: View {
    let session: ClaudeCodeMonitor.ClaudeSessionInfo
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    if isAnimated {
                        Circle()
                            .stroke(statusColor.opacity(0.5), lineWidth: 2)
                            .frame(width: 14, height: 14)
                            .opacity(0.6)
                    }
                }
                .frame(width: 16, height: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(session.projectName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        if let icon = stateIcon {
                            Image(systemName: icon)
                                .font(.system(size: 9))
                        }
                        Text(stateDescription)
                            .font(.system(size: 10))
                        if let tool = session.lastToolName, showTool {
                            Text("(\(tool))")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundStyle(stateColor)
                }

                Spacer()

                Text(timeAgo(session.lastActivity))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)

                Image(systemName: "chevron.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(needsAttention ? Color.yellow.opacity(0.08) : Color.primary.opacity(0.001))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.projectName), \(stateDescription), \(timeAgo(session.lastActivity))")
        .accessibilityHint("Tap to focus this session")
    }

    private var needsAttention: Bool {
        session.state == .waitingPermission || session.state == .waitingInput
    }

    private var isAnimated: Bool {
        session.state == .responding || session.state == .waitingPermission
    }

    private var showTool: Bool {
        session.state == .responding || session.state == .waitingPermission
    }

    private var statusColor: Color {
        switch session.state {
        case .active: return .green
        case .responding: return .orange
        case .waitingPermission: return .yellow
        case .waitingInput: return .blue
        case .idle: return .gray
        case .closed: return .red
        }
    }

    private var stateColor: Color {
        switch session.state {
        case .waitingPermission: return .yellow
        case .waitingInput: return .blue
        default: return .secondary
        }
    }

    private var stateIcon: String? {
        switch session.state {
        case .responding: return "gearshape.2"
        case .waitingPermission: return "exclamationmark.triangle"
        case .waitingInput: return "bubble.left.and.exclamationmark.bubble.right"
        default: return nil
        }
    }

    private var stateDescription: String {
        switch session.state {
        case .active: return "Starting..."
        case .responding: return "Working"
        case .waitingPermission: return "Needs Permission"
        case .waitingInput: return "Waiting for input"
        case .idle: return "Idle"
        case .closed: return "Closed"
        }
    }

    private func timeAgo(_ date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        return "\(seconds / 3600)h ago"
    }
}

// MARK: - Timeline Row

private struct TimelineRow: View {
    let entry: UnifiedTimelineEntry

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: entry.icon)
                .font(.system(size: 10))
                .foregroundStyle(entry.iconColor)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)

                if !entry.detail.isEmpty {
                    Text(entry.detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text(Self.timeFormatter.string(from: entry.timestamp))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .opacity(entry.isRateLimited ? 0.5 : 1.0)
    }
}

// MARK: - Quick Setting Toggle

private struct QuickSettingToggle: View {
    let icon: String
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(isOn ? .primary : .secondary)
                    .frame(width: 16)

                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(isOn ? .primary : .secondary)

                Spacer()

                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                    .foregroundColor(isOn ? .green : .gray)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isOn ? Color.accentColor.opacity(0.1) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? L("status.on", "On") : L("status.off", "Off"))
        .accessibilityHint(L("Double-tap to toggle", "Double-tap to toggle"))
        .accessibilityAddTraits(.isButton)
    }
}
