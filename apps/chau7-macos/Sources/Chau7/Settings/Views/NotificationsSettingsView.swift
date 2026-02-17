import SwiftUI
import AppKit
import Chau7Core

// MARK: - Notifications Settings

/// Top-level notification settings view with segmented sub-navigation.
/// Three tabs: Triggers (unified filter+action management), Thresholds, Monitoring.
struct NotificationsSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings = FeatureSettings.shared
    @State private var selectedTab: NotificationTab = .triggers

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Sub-navigation
            Picker("", selection: $selectedTab) {
                ForEach(NotificationTab.allCases, id: \.self) { tab in
                    Text(tab.label).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.bottom, 4)

            switch selectedTab {
            case .triggers:
                TriggersTabView(model: model)
            case .thresholds:
                EventDetectionThresholdsSection()
            case .monitoring:
                EventMonitoringSection(model: model)
            }
        }
    }
}

// MARK: - Tab Enum

private enum NotificationTab: String, CaseIterable {
    case triggers
    case thresholds
    case monitoring

    var label: String {
        switch self {
        case .triggers: return L("settings.notifications.tab.triggers", "Triggers")
        case .thresholds: return L("settings.notifications.tab.thresholds", "Thresholds")
        case .monitoring: return L("settings.notifications.tab.monitoring", "Monitoring")
        }
    }
}

// MARK: - Triggers Tab (Status + Unified Triggers)

private struct TriggersTabView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings = FeatureSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Status & Permissions
            StatusPermissionsSection(model: model)

            Divider()
                .padding(.vertical, 4)

            // Unified Trigger Management
            UnifiedTriggerSection()
        }
    }
}

// MARK: - Status & Permissions Section

private struct StatusPermissionsSection: View {
    @ObservedObject var model: AppModel

    private var isNotDetermined: Bool {
        model.notificationStatus == "NotDetermined" || model.notificationStatus == "Unknown"
    }

    private var isDenied: Bool {
        model.notificationStatus == "Denied"
    }

    private var isAuthorized: Bool {
        model.notificationStatus == "Authorized" || model.notificationStatus == "Provisional"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isNotDetermined {
                // Onboarding card for first-time users
                SettingsCard(content: {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(
                            L("settings.notifications.onboarding.title", "Enable Notifications"),
                            systemImage: "bell.badge"
                        )
                        .font(.headline)
                        Text(L("settings.notifications.onboarding.description",
                            "Get notified when AI tasks complete, fail, or need your attention."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }, action: {
                    model.requestNotificationPermission()
                }, actionLabel: L("settings.notifications.onboarding.action", "Enable Notifications"),
                   actionIcon: "bell.badge"
                )
            } else {
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

                if isDenied {
                    SettingsHint(
                        icon: "arrow.right.circle",
                        text: L("settings.notifications.denied.hint",
                                "Notifications are denied. Open System Settings to enable them.")
                    )
                    SettingsButtonRow(buttons: [
                        .init(title: L("settings.notifications.systemSettings", "System Settings"), icon: "gear") {
                            model.openNotificationSettings()
                        }
                    ])
                } else if isAuthorized {
                    SettingsButtonRow(buttons: [
                        .init(title: L("settings.notifications.sendTest", "Send Test"), icon: "paperplane") {
                            model.sendTestNotification()
                        },
                        .init(title: L("settings.notifications.systemSettings", "System Settings"), icon: "gear") {
                            model.openNotificationSettings()
                        }
                    ])
                }
            }
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

// MARK: - Unified Trigger Section

/// Merges the old "Notification Filters" and "Trigger Actions" sections into one.
/// Each trigger row shows its enable/disable toggle AND its action chain in one place.
private struct UnifiedTriggerSection: View {
    @ObservedObject private var settings = FeatureSettings.shared
    @State private var expandedCategories: Set<TriggerCategory> = [.aiApps]
    @State private var expandedSources: Set<String> = []
    @State private var expandedTriggerId: String? = nil
    @State private var showingActionPicker = false
    @State private var selectedTriggerId: String? = nil
    @State private var editingAction: (triggerId: String, config: NotificationActionConfig)? = nil

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

    private func triggerBinding(for trigger: NotificationTrigger) -> Binding<Bool> {
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
            SettingsSectionHeader(L("settings.notifications.triggers", "Notification Triggers"), icon: "line.3.horizontal.decrease.circle")

            Text(L("settings.notifications.triggersDescription", "Enable triggers and configure what happens when they fire:"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

            ForEach(TriggerCategory.allCases, id: \.self) { category in
                let groups = triggerGroups(for: category)
                let allTriggersForCategory = groups.flatMap(\.triggers)
                if !groups.isEmpty {
                    UnifiedCategorySection(
                        category: category,
                        groups: groups,
                        enabledCount: allTriggersForCategory.filter { settings.notificationTriggerState.isEnabled(for: $0) }.count,
                        totalCount: allTriggersForCategory.count,
                        isExpanded: expandedCategories.contains(category),
                        expandedSources: $expandedSources,
                        expandedTriggerId: $expandedTriggerId,
                        onToggleExpand: {
                            if expandedCategories.contains(category) {
                                expandedCategories.remove(category)
                            } else {
                                expandedCategories.insert(category)
                            }
                        },
                        onEnableAll: { enableAll(for: category) },
                        onDisableAll: { disableAll(for: category) },
                        triggerBinding: triggerBinding,
                        onAddAction: { triggerId in
                            selectedTriggerId = triggerId
                            showingActionPicker = true
                        },
                        onEditAction: { triggerId, config in
                            editingAction = (triggerId, config)
                        },
                        onDeleteAction: { triggerId, actionId in
                            settings.removeActionFromTrigger(triggerId, actionId: actionId)
                        },
                        onToggleAction: { triggerId, actionId, enabled in
                            settings.setActionEnabled(enabled, triggerId: triggerId, actionId: actionId)
                        }
                    )
                }
            }
        }
        .sheet(isPresented: $showingActionPicker) {
            if let triggerId = selectedTriggerId {
                ActionPickerSheet(triggerId: triggerId) { actionType in
                    let newAction = NotificationActionConfig(actionType: actionType, enabled: true)
                    settings.addActionToTrigger(triggerId, action: newAction)
                    if let info = NotificationActionCatalog.action(for: actionType), info.requiresConfig {
                        editingAction = (triggerId, newAction)
                    }
                }
            }
        }
        .sheet(item: Binding(
            get: { editingAction.map { EditingActionItem(triggerId: $0.triggerId, config: $0.config) } },
            set: { editingAction = $0.map { ($0.triggerId, $0.config) } }
        )) { item in
            ActionConfigSheet(triggerId: item.triggerId, actionConfig: item.config) { updatedConfig in
                settings.updateActionInTrigger(item.triggerId, action: updatedConfig)
            }
        }
    }
}

// MARK: - Unified Category Section

private struct UnifiedCategorySection: View {
    let category: TriggerCategory
    let groups: [TriggerGroup]
    let enabledCount: Int
    let totalCount: Int
    let isExpanded: Bool
    @Binding var expandedSources: Set<String>
    @Binding var expandedTriggerId: String?
    let onToggleExpand: () -> Void
    let onEnableAll: () -> Void
    let onDisableAll: () -> Void
    let triggerBinding: (NotificationTrigger) -> Binding<Bool>
    let onAddAction: (String) -> Void
    let onEditAction: (String, NotificationActionConfig) -> Void
    let onDeleteAction: (String, UUID) -> Void
    let onToggleAction: (String, UUID, Bool) -> Void

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
                    if enabledCount == 0 {
                        SettingsHint(
                            icon: "bell.slash",
                            text: L("settings.notifications.categoryDisabled",
                                    "No triggers enabled in this category.")
                        )
                        .padding(.leading, 16)
                        .padding(.top, 4)
                    }

                    ForEach(groups) { group in
                        let groupEnabledCount = group.triggers.filter { triggerBinding($0).wrappedValue }.count
                        UnifiedSourceSection(
                            group: group,
                            enabledCount: groupEnabledCount,
                            isExpanded: expandedSources.contains(group.id),
                            expandedTriggerId: $expandedTriggerId,
                            onToggleExpand: {
                                if expandedSources.contains(group.id) {
                                    expandedSources.remove(group.id)
                                } else {
                                    expandedSources.insert(group.id)
                                }
                            },
                            triggerBinding: triggerBinding,
                            onAddAction: onAddAction,
                            onEditAction: onEditAction,
                            onDeleteAction: onDeleteAction,
                            onToggleAction: onToggleAction
                        )
                    }
                }
                .padding(.leading, 16)
                .padding(.top, 8)
            }
        }
    }
}

// MARK: - Unified Source Section

private struct UnifiedSourceSection: View {
    let group: TriggerGroup
    let enabledCount: Int
    let isExpanded: Bool
    @Binding var expandedTriggerId: String?
    let onToggleExpand: () -> Void
    let triggerBinding: (NotificationTrigger) -> Binding<Bool>
    let onAddAction: (String) -> Void
    let onEditAction: (String, NotificationActionConfig) -> Void
    let onDeleteAction: (String, UUID) -> Void
    let onToggleAction: (String, UUID, Bool) -> Void

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
                        UnifiedTriggerRow(
                            trigger: trigger,
                            isOn: triggerBinding(trigger),
                            isExpanded: expandedTriggerId == trigger.id,
                            onToggleExpand: {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    expandedTriggerId = expandedTriggerId == trigger.id ? nil : trigger.id
                                }
                            },
                            onAddAction: { onAddAction(trigger.id) },
                            onEditAction: { config in onEditAction(trigger.id, config) },
                            onDeleteAction: { actionId in onDeleteAction(trigger.id, actionId) },
                            onToggleAction: { actionId, enabled in onToggleAction(trigger.id, actionId, enabled) }
                        )
                    }
                }
                .padding(.leading, 16)
            }
        }
    }
}

// MARK: - Unified Trigger Row

/// Single row that combines enable/disable toggle with action management.
/// Collapsed: shows checkbox + label + action count badge + enabled dot + chevron.
/// Expanded: shows inline action list with add/edit/delete controls.
private struct UnifiedTriggerRow: View {
    let trigger: NotificationTrigger
    @Binding var isOn: Bool
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    let onAddAction: () -> Void
    let onEditAction: (NotificationActionConfig) -> Void
    let onDeleteAction: (UUID) -> Void
    let onToggleAction: (UUID, Bool) -> Void

    @ObservedObject private var settings = FeatureSettings.shared

    private var actions: [NotificationActionConfig] {
        settings.triggerActionBindings[trigger.id] ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack(spacing: 8) {
                // Enable/disable toggle
                Toggle("", isOn: $isOn)
                    .toggleStyle(.checkbox)
                    .labelsHidden()

                // Trigger info (clickable to expand actions)
                Button(action: onToggleExpand) {
                    HStack(spacing: 6) {
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

                        // Action count badge
                        if !actions.isEmpty {
                            Text(actions.count.formatted())
                                .font(.caption2)
                                .fontWeight(.medium)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.2))
                                .foregroundColor(.accentColor)
                                .cornerRadius(4)
                        }

                        // Enabled indicator
                        Circle()
                            .fill(isOn ? Color.green : Color.gray.opacity(0.3))
                            .frame(width: 8, height: 8)

                        // Expand chevron
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: 12)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
            .background(isExpanded ? Color.secondary.opacity(0.05) : Color.clear)
            .cornerRadius(4)

            // Expanded: action management
            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    if actions.isEmpty {
                        HStack {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.secondary)
                            Text(L("settings.notifications.noActions", "No actions configured. Using default notification."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 28)
                        .padding(.vertical, 4)
                    } else {
                        ForEach(actions) { action in
                            ActionRow(
                                action: action,
                                onEdit: { onEditAction(action) },
                                onDelete: { onDeleteAction(action.id) },
                                onToggle: { enabled in onToggleAction(action.id, enabled) }
                            )
                        }
                    }

                    // Add action button
                    Button(action: onAddAction) {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                            Text(L("settings.notifications.addAction", "Add Action"))
                        }
                        .font(.caption)
                        .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 4)
                }
                .padding(.top, 4)
                .padding(.leading, 20)
                .background(Color.secondary.opacity(0.03))
            }
        }
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
                        TextField(
                            L("60", "60"),
                            value: $settings.shellEventConfig.nested(\.longRunningThresholdSeconds, min: 0),
                            formatter: NumberFormatter()
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    }

                    Toggle(
                        L("settings.notifications.notifyDirectoryChange", "Directory Change"),
                        isOn: $settings.shellEventConfig.nested(\.notifyOnDirectoryChange)
                    )
                    .font(.caption)

                    Toggle(
                        L("settings.notifications.notifyGitBranch", "Git Branch"),
                        isOn: $settings.shellEventConfig.nested(\.notifyOnGitBranchChange)
                    )
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
                        TextField(
                            L("0", "0"),
                            value: $settings.appEventConfig.nested(\.inactivityThresholdMinutes, min: 0),
                            formatter: NumberFormatter()
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        Text(L("0 = disabled", "0 = disabled"))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("settings.notifications.memoryThreshold", "Memory (MB)"))
                            .font(.caption)
                        TextField(
                            L("0", "0"),
                            value: $settings.appEventConfig.nested(\.memoryThresholdMB, min: 0),
                            formatter: NumberFormatter()
                        )
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
                    Toggle(
                        L("settings.notifications.notifyTabOpen", "Tab Open"),
                        isOn: $settings.appEventConfig.nested(\.notifyOnTabOpen)
                    )
                    .font(.caption)

                    Toggle(
                        L("settings.notifications.notifyTabClose", "Tab Close"),
                        isOn: $settings.appEventConfig.nested(\.notifyOnTabClose)
                    )
                    .font(.caption)
                }
                .padding(.leading, 24)
            }
        }
    }
}

// MARK: - Event Monitoring Section

private struct EventMonitoringSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
