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
            button.image = NSImage(systemSymbolName: "bell", accessibilityDescription: L("app.name", "Chau7"))
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        // Create popover
        popover = NSPopover()
        popover?.contentSize = NSSize(width: 400, height: 520)
        // Use applicationDefined for full control - we handle closing via toggle and global monitor
        popover?.behavior = .applicationDefined
        popover?.animates = true
        popover?.contentViewController = NSHostingController(
            rootView: StatusBarPanelView(model: model, onClose: { [weak self] in
                self?.closePopover()
            })
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

            // If click is not in the popover window and not on the status bar button, close
            if event.window != popoverWindow {
                // Check if click is on the status bar button - if so, let togglePopover handle it
                if let button = self.statusItem?.button,
                   let buttonWindow = button.window,
                   event.window == buttonWindow {
                    // Click is on the status bar button, let togglePopover handle it
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

        // Remove event monitors to prevent memory leak
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
    }

    /// Flash the status bar icon to draw attention (used by menuBarAlert action).
    func flashAlert(duration: Int, animate: Bool) {
        guard let button = statusItem?.button else { return }
        let originalImage = button.image
        let alertImage = NSImage(systemSymbolName: "bell.badge.fill", accessibilityDescription: "Alert")

        if animate {
            button.image = alertImage
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(duration)) {
                button.image = originalImage
            }
        } else {
            button.image = alertImage
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(duration)) {
                button.image = originalImage
            }
        }
        Log.info("StatusBarController: Menu bar alert for \(duration)s")
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

            Text(L("Chau7", "Chau7"))
                .font(.system(size: 14, weight: .semibold))

            statusIndicator

            Spacer()

            Button {
                (NSApp.delegate as? AppDelegate)?.showOverlay()
                onClose()
            } label: {
                Label(L("Open Terminal", "Open Terminal"), systemImage: "macwindow")
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
            Text(model.isMonitoring ? L("status.active", "Active") : L("status.paused", "Paused"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            String(
                format: L("accessibility.monitoringStatus", "Monitoring status: %@"),
                model.isMonitoring ? L("status.active", "Active") : L("status.paused", "Paused")
            )
        )
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
            Label(L("Active Sessions", "Active Sessions"), systemImage: "bubble.left.and.bubble.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            if model.claudeCodeSessions.isEmpty {
                HStack {
                    Image(systemName: "moon.zzz")
                        .foregroundStyle(.tertiary)
                    Text(L("No active Claude Code sessions", "No active Claude Code sessions"))
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
                Label(L("Recent Activity", "Recent Activity"), systemImage: "clock")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !model.claudeCodeEvents.isEmpty {
                    Button(L("Clear", "Clear")) {
                        model.claudeCodeEvents.removeAll()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }
            }

            if model.claudeCodeEvents.isEmpty {
                Text(L("No recent events", "No recent events"))
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

    // MARK: - Quick Settings

    private var quickActionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L("Quick Settings", "Quick Settings"), systemImage: "slider.horizontal.3")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            // Row 1: Monitoring and Broadcast
            HStack(spacing: 12) {
                QuickSettingToggle(
                    icon: "antenna.radiowaves.left.and.right",
                    label: "Monitoring",
                    isOn: $model.isMonitoring
                )
                .onChange(of: model.isMonitoring) { _ in
                    model.applyMonitoringState()
                    NotificationCenter.default.post(name: NSNotification.Name("MonitoringStateChanged"), object: nil)
                }

                QuickSettingToggle(
                    icon: "dot.radiowaves.left.and.right",
                    label: "Broadcast",
                    isOn: Binding(
                        get: { FeatureSettings.shared.isBroadcastEnabled },
                        set: { FeatureSettings.shared.isBroadcastEnabled = $0 }
                    )
                )
            }

            // Row 2: Auto Theme and Syntax Highlight
            HStack(spacing: 12) {
                QuickSettingToggle(
                    icon: "sparkles",
                    label: "AI Themes",
                    isOn: Binding(
                        get: { FeatureSettings.shared.isAutoTabThemeEnabled },
                        set: { FeatureSettings.shared.isAutoTabThemeEnabled = $0 }
                    )
                )

                QuickSettingToggle(
                    icon: "textformat",
                    label: "Syntax",
                    isOn: Binding(
                        get: { FeatureSettings.shared.isSyntaxHighlightEnabled },
                        set: { FeatureSettings.shared.isSyntaxHighlightEnabled = $0 }
                    )
                )
            }

            // Row 3: Window Opacity Slider
            HStack(spacing: 8) {
                Image(systemName: "square.dashed")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)

                Text(L("Opacity", "Opacity"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Slider(
                    value: Binding(
                        get: { FeatureSettings.shared.windowOpacity },
                        set: { FeatureSettings.shared.windowOpacity = $0 }
                    ),
                    in: 0.3...1.0,
                    step: 0.1
                )
                .controlSize(.small)

                Text(
                    String(
                        format: L("status.opacityPercent", "%d%%"),
                        Int(FeatureSettings.shared.windowOpacity * 100)
                    )
                )
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 32)
            }

            Divider()

            // Row 4: Action Buttons
            HStack(spacing: 8) {
                Button {
                    model.sendTestNotification()
                } label: {
                    Label(L("Test Alert", "Test Alert"), systemImage: "bell.badge")
                }
                .controlSize(.small)

                Spacer()

                Button {
                    (NSApp.delegate as? AppDelegate)?.showSettings()
                    onClose()
                } label: {
                    Label(L("All Settings", "All Settings"), systemImage: "gearshape")
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
            Text(L("v1.0", "v1.0"))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            Spacer()

            Button(L("Quit Chau7", "Quit Chau7")) {
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
                        Text(String(format: L("status.toolSuffix", "(%@)"), tool))
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            String(
                format: L("accessibility.sessionSummary", "%@ session, %@, last active %@"),
                session.projectName,
                stateDescription,
                timeAgo(session.lastActivity)
            )
        )
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
