import AppKit
import SwiftUI

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
    private var eventMonitor: Any?
    private weak var model: AppModel?

    private override init() {
        super.init()
    }

    /// Initialize the status bar with the app model.
    /// - Parameter model: The app model to observe and display.
    /// - Note: Must be called from main thread.
    func setup(model: AppModel) {
        self.model = model

        // Create status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "bell", accessibilityDescription: "Chau7")
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        // Create popover
        popover = NSPopover()
        popover?.contentSize = NSSize(width: 400, height: 520)
        popover?.behavior = .transient
        popover?.animates = true
        popover?.contentViewController = NSHostingController(
            rootView: StatusBarPanelView(model: model, onClose: { [weak self] in
                self?.closePopover()
            })
        )

        // Monitor for clicks outside to close popover
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            if self?.popover?.isShown == true {
                self?.closePopover()
            }
        }

        // Observe monitoring state changes to update icon
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateIcon),
            name: NSNotification.Name("MonitoringStateChanged"),
            object: nil
        )
    }

    /// Cleanup all resources. Call from applicationWillTerminate.
    func cleanup() {
        // Remove notification observer to prevent crashes
        NotificationCenter.default.removeObserver(self)

        // Remove event monitor to prevent memory leak
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }

        statusItem = nil
        popover = nil
    }

    /// Update the status bar icon based on monitoring state.
    @objc func updateIcon() {
        guard let button = statusItem?.button else { return }
        let isMonitoring = model?.isMonitoring ?? false
        let iconName = isMonitoring ? "bell.badge.fill" : "bell"
        button.image = NSImage(systemSymbolName: iconName, accessibilityDescription: "Chau7")
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
              let popover,
              let model else { return }  // Safe unwrap - don't show if model is gone

        // Update content before showing (ensures fresh data)
        popover.contentViewController = NSHostingController(
            rootView: StatusBarPanelView(model: model, onClose: { [weak self] in
                self?.closePopover()
            })
        )

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

        // Ensure popover window is on the correct screen (multi-monitor fix)
        if let popoverWindow = popover.contentViewController?.view.window {
            popoverWindow.level = .popUpMenu
        }
    }

    private func closePopover() {
        popover?.performClose(nil)
    }
}

// MARK: - Improved Status Bar Panel View

struct StatusBarPanelView: View {
    @ObservedObject var model: AppModel
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            Divider()
            scrollableContent
            Divider()
            footerSection
        }
        .frame(width: 400)
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 10) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)

            Text("Chau7")
                .font(.system(size: 14, weight: .semibold))

            statusIndicator

            Spacer()

            Button {
                (NSApp.delegate as? AppDelegate)?.showOverlay()
                onClose()
            } label: {
                Label("Open Terminal", systemImage: "macwindow")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var statusIndicator: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(model.isMonitoring ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
            Text(model.isMonitoring ? "Active" : "Paused")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Scrollable Content

    private var scrollableContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                claudeSessionsSection
                recentActivitySection
                quickActionsSection
            }
            .padding(12)
        }
        .frame(maxHeight: 380)
    }

    // MARK: - Claude Sessions (Most Useful!)

    private var claudeSessionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Active Sessions", systemImage: "bubble.left.and.bubble.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            if model.claudeCodeSessions.isEmpty {
                HStack {
                    Image(systemName: "moon.zzz")
                        .foregroundStyle(.tertiary)
                    Text("No active Claude Code sessions")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            } else {
                ForEach(Array(model.claudeCodeSessions.sorted(by: { $0.lastActivity > $1.lastActivity }).prefix(5))) { session in
                    SessionRow(session: session)
                }
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Recent Activity

    private var recentActivitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Recent Activity", systemImage: "clock")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !model.claudeCodeEvents.isEmpty {
                    Button("Clear") {
                        model.claudeCodeEvents.removeAll()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }
            }

            if model.claudeCodeEvents.isEmpty {
                Text("No recent events")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(model.claudeCodeEvents.suffix(6).reversed()) { event in
                    EventRow(event: event)
                }
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Quick Actions

    private var quickActionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Quick Actions", systemImage: "bolt")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Toggle(isOn: $model.isMonitoring) {
                    Label("Monitor", systemImage: "antenna.radiowaves.left.and.right")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .onChange(of: model.isMonitoring) { _ in
                    model.applyMonitoringState()
                    NotificationCenter.default.post(name: NSNotification.Name("MonitoringStateChanged"), object: nil)
                }

                Button {
                    model.sendTestNotification()
                } label: {
                    Label("Test Alert", systemImage: "bell.badge")
                }
                .controlSize(.small)

                Button {
                    (NSApp.delegate as? AppDelegate)?.showSettings()
                    onClose()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Text("v1.0")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            Spacer()

            Button("Quit Chau7") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Session Row

private struct SessionRow: View {
    let session: ClaudeCodeMonitor.ClaudeSessionInfo

    var body: some View {
        HStack(spacing: 8) {
            // Animated indicator for active states
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
        }
        .padding(.vertical, 4)
    }

    private var isAnimated: Bool {
        switch session.state {
        case .responding, .waitingPermission:
            return true
        default:
            return false
        }
    }

    private var showTool: Bool {
        switch session.state {
        case .responding, .waitingPermission:
            return true
        default:
            return false
        }
    }

    private var statusColor: Color {
        switch session.state {
        case .active:
            return .green
        case .responding:
            return .orange
        case .waitingPermission:
            return .yellow
        case .waitingInput:
            return .blue
        case .idle:
            return .gray
        case .closed:
            return .red
        }
    }

    private var stateColor: Color {
        switch session.state {
        case .waitingPermission:
            return .yellow
        case .waitingInput:
            return .blue
        default:
            return .secondary
        }
    }

    private var stateIcon: String? {
        switch session.state {
        case .responding:
            return "gearshape.2"
        case .waitingPermission:
            return "exclamationmark.triangle"
        case .waitingInput:
            return "bubble.left.and.exclamationmark.bubble.right"
        default:
            return nil
        }
    }

    private var stateDescription: String {
        switch session.state {
        case .active:
            return "Starting..."
        case .responding:
            return "Working"
        case .waitingPermission:
            return "Needs Permission"
        case .waitingInput:
            return "Waiting for input"
        case .idle:
            return "Idle"
        case .closed:
            return "Closed"
        }
    }

    private func timeAgo(_ date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60 {
            return "now"
        } else if seconds < 3600 {
            return "\(seconds / 60)m ago"
        } else {
            return "\(seconds / 3600)h ago"
        }
    }
}

// MARK: - Event Row

private struct EventRow: View {
    let event: ClaudeCodeEvent

    // Static formatter to avoid recreating on every render (expensive)
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: eventIcon)
                .font(.system(size: 10))
                .foregroundStyle(eventColor)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(displayTitle)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)

                if !event.message.isEmpty {
                    Text(event.message)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text(timeString)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private var displayTitle: String {
        if !event.toolName.isEmpty {
            return event.toolName
        }
        switch event.type {
        case .responseComplete:
            return "Response Complete"
        case .sessionEnd:
            return "Session Ended"
        default:
            return event.hook
        }
    }

    private var eventIcon: String {
        switch event.type {
        case .userPrompt:
            return "person.fill"
        case .toolStart:
            return "hammer"
        case .toolComplete:
            return "checkmark.circle"
        case .permissionRequest:
            return "exclamationmark.triangle"
        case .responseComplete:
            return "text.bubble"
        case .notification:
            return "bell"
        case .sessionEnd:
            return "xmark.circle"
        case .unknown:
            return "circle"
        }
    }

    private var eventColor: Color {
        switch event.type {
        case .userPrompt:
            return .green
        case .permissionRequest:
            return .yellow
        case .sessionEnd:
            return .red
        case .responseComplete:
            return .blue
        case .toolComplete:
            return .cyan
        default:
            return .secondary
        }
    }

    private var timeString: String {
        Self.timeFormatter.string(from: event.timestamp)
    }
}
