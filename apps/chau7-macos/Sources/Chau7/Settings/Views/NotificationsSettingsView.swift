import SwiftUI
import AppKit
import Chau7Core

// MARK: - Notifications Settings

struct NotificationsSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings = FeatureSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Status & Permissions
            SettingsSectionHeader(L("settings.notifications.status", "Status & Permissions"), icon: "bell")

            SettingsInfoRow(
                label: L("settings.notifications.status.label", "Status"),
                value: model.notificationStatus,
                monospaced: true
            )

            if let warning = model.notificationWarning {
                SettingsRow(L("settings.notifications.warning", "Warning")) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text(warning)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            SettingsButtonRow(buttons: [
                .init(title: L("settings.notifications.requestPermission", "Request Permission"), icon: "bell.badge") {
                    model.requestNotificationPermission()
                },
                .init(title: L("settings.notifications.systemSettings", "System Settings"), icon: "gear") {
                    model.openNotificationSettings()
                },
                .init(title: L("settings.notifications.sendTest", "Send Test"), icon: "paperplane") {
                    model.sendTestNotification()
                }
            ])

            Divider()
                .padding(.vertical, 8)

            // Notification Filters - now in its own component
            NotificationFiltersSection()

            Divider()
                .padding(.vertical, 8)

            // Trigger Actions
            TriggerActionsSettingsView()

            Divider()
                .padding(.vertical, 8)

            // Event Detection Thresholds
            EventDetectionThresholdsSection()

            Divider()
                .padding(.vertical, 8)

            // Event Monitoring
            SettingsSectionHeader(L("settings.notifications.eventMonitoring", "Event Monitoring"), icon: "waveform.path.ecg")

            SettingsToggle(
                label: L("settings.notifications.monitorAIEvents", "Monitor AI Events"),
                help: L("settings.notifications.monitorAIEvents.help", "Watch for AI CLI events like task completion, failures, and permission requests"),
                isOn: $model.isMonitoring
            )
            .onChange(of: model.isMonitoring) { _ in
                model.applyMonitoringState()
            }

            SettingsTextField(
                label: L("settings.notifications.eventLogPath", "Event Log Path"),
                help: L("settings.notifications.eventLogPath.help", "Path to the AI event log file"),
                placeholder: "~/.ai-events.log",
                text: $model.logPath,
                width: 280,
                monospaced: true,
                onSubmit: { model.restartTailer() }
            )

            SettingsButtonRow(buttons: [
                .init(title: L("settings.notifications.restartMonitor", "Restart Monitor"), icon: "arrow.clockwise") {
                    model.restartTailer()
                },
                .init(title: L("settings.notifications.revealInFinder", "Reveal in Finder"), icon: "folder") {
                    model.revealLogInFinder()
                }
            ])
        }
    }
}

// MARK: - Shared Types

fileprivate enum TriggerCategory: String, CaseIterable, Identifiable {
    case core = "Core"
    case shell = "Shell"
    case aiApps = "AI Coding Apps"
    case app = "App"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .core: return "bell.badge"
        case .shell: return "terminal"
        case .aiApps: return "brain"
        case .app: return "app.badge"
        }
    }

    var sources: [AIEventSource] {
        switch self {
        case .core:
            return [.eventsLog, .terminalSession, .historyMonitor]
        case .shell:
            return [.shell]
        case .aiApps:
            return [.claudeCode, .codex, .cursor, .windsurf, .copilot, .aider, .cline, .continueAI]
        case .app:
            return [.app]
        }
    }
}

fileprivate struct TriggerGroup: Identifiable {
    let id: String
    let source: NotificationTriggerSourceInfo
    let triggers: [NotificationTrigger]
}

// MARK: - Notification Filters Section

private struct NotificationFiltersSection: View {
    @ObservedObject private var settings = FeatureSettings.shared
    @State private var expandedCategories: Set<TriggerCategory> = [.aiApps]
    @State private var expandedSources: Set<String> = []

    private func triggerGroups(for category: TriggerCategory) -> [TriggerGroup] {
        category.sources.compactMap { sourceId in
            guard let source = NotificationTriggerCatalog.sources.first(where: { $0.id == sourceId }) else {
                return nil
            }
            let triggers = NotificationTriggerCatalog
                .triggers(for: sourceId)
                .filter { $0.displayContexts.contains(.settings) }
            guard !triggers.isEmpty else { return nil }
            return TriggerGroup(id: source.id.rawValue, source: source, triggers: triggers)
        }
    }

    private func binding(for trigger: NotificationTrigger) -> Binding<Bool> {
        Binding(
            get: { settings.notificationTriggerState.isEnabled(for: trigger) },
            set: { newValue in
                var state = settings.notificationTriggerState
                state.setEnabled(newValue, for: trigger)
                settings.notificationTriggerState = state
            }
        )
    }

    private func enableAll(for category: TriggerCategory) {
        let allTriggersForCategory = triggerGroups(for: category).flatMap(\.triggers)
        var state = settings.notificationTriggerState
        for trigger in allTriggersForCategory {
            state.setEnabled(true, for: trigger)
        }
        settings.notificationTriggerState = state
    }

    private func disableAll(for category: TriggerCategory) {
        let allTriggersForCategory = triggerGroups(for: category).flatMap(\.triggers)
        var state = settings.notificationTriggerState
        for trigger in allTriggersForCategory {
            state.setEnabled(false, for: trigger)
        }
        settings.notificationTriggerState = state
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSectionHeader(L("settings.notifications.filters", "Notification Filters"), icon: "line.3.horizontal.decrease.circle")

            Text(L("settings.notifications.filtersDescription", "Choose which events trigger notifications:"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

            ForEach(TriggerCategory.allCases, id: \.self) { category in
                let groups = triggerGroups(for: category)
                let allTriggersForCategory = groups.flatMap(\.triggers)
                if !groups.isEmpty {
                    CategorySection(
                        category: category,
                        groups: groups,
                        enabledCount: allTriggersForCategory.filter { settings.notificationTriggerState.isEnabled(for: $0) }.count,
                        totalCount: allTriggersForCategory.count,
                        isExpanded: expandedCategories.contains(category),
                        expandedSources: $expandedSources,
                        onToggleExpand: {
                            if expandedCategories.contains(category) {
                                expandedCategories.remove(category)
                            } else {
                                expandedCategories.insert(category)
                            }
                        },
                        onEnableAll: { enableAll(for: category) },
                        onDisableAll: { disableAll(for: category) },
                        triggerBinding: binding
                    )
                }
            }
        }
    }
}

// MARK: - Category Section

private struct CategorySection: View {
    let category: TriggerCategory
    let groups: [TriggerGroup]
    let enabledCount: Int
    let totalCount: Int
    let isExpanded: Bool
    @Binding var expandedSources: Set<String>
    let onToggleExpand: () -> Void
    let onEnableAll: () -> Void
    let onDisableAll: () -> Void
    let triggerBinding: (NotificationTrigger) -> Binding<Bool>

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Category header
            HStack(spacing: 8) {
                Button(action: onToggleExpand) {
                    HStack(spacing: 6) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 12)

                        Image(systemName: category.icon)
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)

                        Text(category.rawValue)
                            .font(.caption)
                            .fontWeight(.semibold)

                        Text(
                            String(
                                format: L("notifications.enabledCount", "(%d/%d)"),
                                enabledCount,
                                totalCount
                            )
                        )
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                if isExpanded {
                    HStack(spacing: 4) {
                        Button(action: onEnableAll) {
                            Text(L("settings.notifications.enableAll", "All"))
                                .font(.caption2)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)

                        Button(action: onDisableAll) {
                            Text(L("settings.notifications.disableAll", "None"))
                                .font(.caption2)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(Color.primary.opacity(0.03))
            .cornerRadius(6)

            // Expanded content
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(groups) { group in
                        let groupEnabledCount = group.triggers.filter { triggerBinding($0).wrappedValue }.count
                        SourceSection(
                            group: group,
                            enabledCount: groupEnabledCount,
                            isExpanded: expandedSources.contains(group.id),
                            onToggleExpand: {
                                if expandedSources.contains(group.id) {
                                    expandedSources.remove(group.id)
                                } else {
                                    expandedSources.insert(group.id)
                                }
                            },
                            triggerBinding: triggerBinding
                        )
                    }
                }
                .padding(.leading, 16)
                .padding(.top, 8)
            }
        }
    }
}

// MARK: - Source Section

private struct SourceSection: View {
    let group: TriggerGroup
    let enabledCount: Int
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    let triggerBinding: (NotificationTrigger) -> Binding<Bool>

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Source header
            Button(action: onToggleExpand) {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 10)

                    Text(group.source.localizedLabel)
                        .font(.caption)
                        .fontWeight(.medium)

                    Text(
                        String(
                            format: L("notifications.enabledCount", "(%d/%d)"),
                            enabledCount,
                            group.triggers.count
                        )
                    )
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Spacer()
                }
            }
            .buttonStyle(.plain)

            // Triggers
            if isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(group.triggers) { trigger in
                        TriggerRow(trigger: trigger, isOn: triggerBinding(trigger))
                    }
                }
                .padding(.leading, 16)
            }
        }
    }
}

// MARK: - Trigger Row

private struct TriggerRow: View {
    let trigger: NotificationTrigger
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $isOn)
                .toggleStyle(.checkbox)
                .labelsHidden()

            VStack(alignment: .leading, spacing: 1) {
                Text(trigger.localizedLabel)
                    .font(.caption)
                    .foregroundStyle(isOn ? .primary : .secondary)

                if !trigger.localizedDescription.isEmpty {
                    Text(trigger.localizedDescription)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer()
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Event Detection Thresholds Section

private struct EventDetectionThresholdsSection: View {
    @ObservedObject private var settings = FeatureSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSectionHeader(L("settings.notifications.thresholds", "Detection Thresholds"), icon: "slider.horizontal.3")

            Text(L("settings.notifications.thresholds.description", "Configure when shell and app events should trigger notifications."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

            // Shell Event Settings
            Group {
                HStack {
                    Image(systemName: "terminal")
                        .foregroundStyle(.secondary)
                    Text(L("settings.notifications.shell", "Shell Events"))
                        .font(.subheadline)
                        .fontWeight(.medium)
                }

                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("settings.notifications.longRunningThreshold", "Long-Running (seconds)"))
                            .font(.caption)
                        TextField(L("60", "60"), value: Binding(
                            get: { settings.shellEventConfig.longRunningThresholdSeconds },
                            set: {
                                var config = settings.shellEventConfig
                                config.longRunningThresholdSeconds = $0
                                settings.shellEventConfig = config
                            }
                        ), formatter: NumberFormatter())
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    }

                    Toggle(L("settings.notifications.notifyDirectoryChange", "Directory Change"), isOn: Binding(
                        get: { settings.shellEventConfig.notifyOnDirectoryChange },
                        set: {
                            var config = settings.shellEventConfig
                            config.notifyOnDirectoryChange = $0
                            settings.shellEventConfig = config
                        }
                    ))
                    .font(.caption)

                    Toggle(L("settings.notifications.notifyGitBranch", "Git Branch"), isOn: Binding(
                        get: { settings.shellEventConfig.notifyOnGitBranchChange },
                        set: {
                            var config = settings.shellEventConfig
                            config.notifyOnGitBranchChange = $0
                            settings.shellEventConfig = config
                        }
                    ))
                    .font(.caption)
                }
                .padding(.leading, 24)
            }

            Divider()
                .padding(.vertical, 4)

            // App Event Settings
            Group {
                HStack {
                    Image(systemName: "app")
                        .foregroundStyle(.secondary)
                    Text(L("settings.notifications.app", "App Events"))
                        .font(.subheadline)
                        .fontWeight(.medium)
                }

                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("settings.notifications.inactivityThreshold", "Inactivity (minutes)"))
                            .font(.caption)
                        TextField(L("0", "0"), value: Binding(
                            get: { settings.appEventConfig.inactivityThresholdMinutes },
                            set: {
                                var config = settings.appEventConfig
                                config.inactivityThresholdMinutes = $0
                                settings.appEventConfig = config
                            }
                        ), formatter: NumberFormatter())
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        Text(L("0 = disabled", "0 = disabled"))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("settings.notifications.memoryThreshold", "Memory (MB)"))
                            .font(.caption)
                        TextField(L("0", "0"), value: Binding(
                            get: { settings.appEventConfig.memoryThresholdMB },
                            set: {
                                var config = settings.appEventConfig
                                config.memoryThresholdMB = $0
                                settings.appEventConfig = config
                            }
                        ), formatter: NumberFormatter())
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        Text(L("0 = disabled", "0 = disabled"))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.leading, 24)

                // Tab notifications (can be noisy)
                HStack(spacing: 16) {
                    Toggle(L("settings.notifications.notifyTabOpen", "Tab Open"), isOn: Binding(
                        get: { settings.appEventConfig.notifyOnTabOpen },
                        set: {
                            var config = settings.appEventConfig
                            config.notifyOnTabOpen = $0
                            settings.appEventConfig = config
                        }
                    ))
                    .font(.caption)

                    Toggle(L("settings.notifications.notifyTabClose", "Tab Close"), isOn: Binding(
                        get: { settings.appEventConfig.notifyOnTabClose },
                        set: {
                            var config = settings.appEventConfig
                            config.notifyOnTabClose = $0
                            settings.appEventConfig = config
                        }
                    ))
                    .font(.caption)
                }
                .padding(.leading, 24)
            }
        }
    }
}
