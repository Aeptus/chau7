import SwiftUI
import AppKit
import Chau7Core

// MARK: - Notifications Settings

/// Top-level notification settings view with a simplified AI-first front door.
/// Advanced trigger plumbing stays available, but no longer leads the screen.
struct NotificationsSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings = FeatureSettings.shared
    @State private var selectedTab: NotificationTab = .overview

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
            case .overview:
                OverviewTabView(model: model, onOpenAdvanced: { selectedTab = .advanced })
            case .advanced:
                AdvancedTriggersTabView(model: model)
            case .thresholds:
                EventDetectionThresholdsSection()
            case .behavior:
                BehaviorTabView()
            case .monitoring:
                EventMonitoringSection(model: model)
            case .history:
                NotificationHistoryTabView()
            }
        }
    }
}

// MARK: - Tab Enum

private enum NotificationTab: String, CaseIterable {
    case overview
    case advanced
    case thresholds
    case behavior
    case monitoring
    case history

    var label: String {
        switch self {
        case .overview: return L("settings.notifications.tab.overview", "AI Tools")
        case .advanced: return L("settings.notifications.tab.advanced", "Advanced")
        case .thresholds: return L("settings.notifications.tab.thresholds", "Thresholds")
        case .behavior: return L("settings.notifications.tab.behavior", "Behavior")
        case .monitoring: return L("settings.notifications.tab.monitoring", "Monitoring")
        case .history: return L("settings.notifications.tab.history", "History")
        }
    }
}

// MARK: - Overview Tab

private struct OverviewTabView: View {
    @ObservedObject var model: AppModel
    let onOpenAdvanced: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StatusPermissionsSection(model: model)

            Divider()
                .padding(.vertical, 4)

            AINotificationOverviewSection(onOpenAdvanced: onOpenAdvanced)
        }
    }
}

// MARK: - Advanced Tab

private struct AdvancedTriggersTabView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StatusPermissionsSection(model: model)

            Divider()
                .padding(.vertical, 4)

            UnifiedTriggerSection()
        }
    }
}

// MARK: - Status & Permissions Section

private struct StatusPermissionsSection: View {
    @ObservedObject var model: AppModel

    private var permissionState: AppModel.NotificationPermissionState {
        model.notificationPermissionState
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSectionHeader(L("settings.notifications.status", "Status & Permissions"), icon: "bell")

            SettingsInfoRow(
                label: L("settings.notifications.status.label", "Status"),
                value: permissionState.localizedLabel,
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

            if permissionState == .unavailableNotBundled {
                SettingsHint(
                    icon: "xmark.octagon",
                    text: L("settings.notifications.unavailable.hint", "Launch the app as a bundle to enable system notifications.")
                )
            } else if permissionState.showRequestPermissionAction {
                SettingsButtonRow(buttons: [
                    .init(title: L("settings.notifications.requestPermission", "Request Permission"), icon: "person.badge.plus") {
                        model.requestNotificationPermission()
                    }
                ])
            } else if permissionState.requiresSystemSettingsAction {
                SettingsButtonRow(buttons: [
                    .init(title: L("settings.notifications.systemSettings", "System Settings"), icon: "gear") {
                        model.openNotificationSettings()
                    }
                ])
            } else {
                SettingsButtonRow(buttons: [
                    .init(
                        title: L("settings.notifications.sendTest", "Send Test"),
                        icon: "paperplane",
                        action: {
                            model.sendTestNotification()
                        }
                    ),
                    .init(
                        title: L("settings.notifications.systemSettings", "System Settings"),
                        icon: "gear",
                        action: {
                            model.openNotificationSettings()
                        }
                    )
                ])
            }
        }
    }
}

// MARK: - AI Overview

private struct AINotificationOverviewSection: View {
    @ObservedObject private var settings = FeatureSettings.shared
    let onOpenAdvanced: () -> Void

    private let aiGroup = NotificationTriggerCatalog.aiCodingGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSectionHeader(L("settings.notifications.aiOverview", "AI Notification Essentials"), icon: "brain")

            Text(L("settings.notifications.aiOverview.description", "Choose the only things AI tools should interrupt you for by default."))
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(AINotificationPrimaryEvent.allCases) { event in
                AINotificationCard(
                    event: event,
                    isEnabled: enabledBinding(for: event),
                    preference: preference(for: event),
                    onUpdatePreference: { updatePreference($0, for: event) },
                    overrideCount: perSourceOverrideCount(for: event)
                )
            }

            SettingsHint(
                icon: "slider.horizontal.3",
                text: L(
                    "settings.notifications.aiOverview.advancedHint",
                    "Use Advanced for per-tool overrides, extra triggers, scripts, and event-source specific rules."
                )
            )

            SettingsButtonRow(buttons: [
                .init(
                    title: L("settings.notifications.openAdvanced", "Open Advanced Rules"),
                    icon: "slider.horizontal.3",
                    action: onOpenAdvanced
                )
            ])
        }
    }

    private func enabledBinding(for event: AINotificationPrimaryEvent) -> Binding<Bool> {
        return Binding(
            get: {
                AINotificationSettingsBridge.isEffectivelyEnabled(
                    for: event,
                    state: settings.notificationTriggerState,
                    group: aiGroup
                )
            },
            set: { newValue in
                settings.notificationTriggerState = AINotificationSettingsBridge.updatedStateForPrimaryToggle(
                    settings.notificationTriggerState,
                    event: event,
                    enabled: newValue,
                    group: aiGroup
                )
            }
        )
    }

    private func preference(for event: AINotificationPrimaryEvent) -> AINotificationPrimaryPreference {
        let triggerId = AINotificationSettingsBridge.managedTriggerTypes(for: event)
            .map { aiGroup.groupTriggerId(for: $0) }
            .first { !(settings.groupActionBindings[$0] ?? []).isEmpty }
            ?? AINotificationSettingsBridge.groupTriggerId(for: event, group: aiGroup)
        return AINotificationSettingsBridge.preference(
            for: event,
            currentActions: settings.groupActionBindings[triggerId] ?? [],
            defaultActions: NotificationSettings.defaultGroupActionBindings[triggerId] ?? []
        )
    }

    private func updatePreference(_ preference: AINotificationPrimaryPreference, for event: AINotificationPrimaryEvent) {
        var bindings = settings.groupActionBindings
        for triggerType in AINotificationSettingsBridge.managedTriggerTypes(for: event) {
            let triggerId = aiGroup.groupTriggerId(for: triggerType)
            bindings[triggerId] = AINotificationSettingsBridge.updatedActions(
                for: event,
                preference: preference,
                currentActions: bindings[triggerId] ?? [],
                defaultActions: NotificationSettings.defaultGroupActionBindings[triggerId] ?? []
            )
        }
        settings.groupActionBindings = bindings
    }

    private func perSourceOverrideCount(for event: AINotificationPrimaryEvent) -> Int {
        let triggerTypes = Set(AINotificationSettingsBridge.managedTriggerTypes(for: event))
        return NotificationTriggerCatalog.all.filter {
            aiGroup.contains(source: $0.source)
                && triggerTypes.contains($0.type)
                && settings.notificationTriggerState.hasPerTriggerOverride(for: $0)
        }.count
    }
}

private struct AINotificationCard: View {
    let event: AINotificationPrimaryEvent
    @Binding var isEnabled: Bool
    let preference: AINotificationPrimaryPreference
    let onUpdatePreference: (AINotificationPrimaryPreference) -> Void
    let overrideCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Toggle("", isOn: $isEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()

                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                        .font(.headline)
                    Text(event.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if overrideCount > 0 {
                    Text("\(overrideCount) override\(overrideCount == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.orange.opacity(0.12))
                        .cornerRadius(5)
                }
            }

            HStack(spacing: 18) {
                overviewToggle(
                    label: L("settings.notifications.primary.banner", "Banner"),
                    value: preference.showNotification,
                    enabled: isEnabled
                ) { newValue in
                    mutatePreference { $0.showNotification = newValue }
                }

                overviewToggle(
                    label: L("settings.notifications.primary.highlight", "Highlight Tab"),
                    value: preference.styleTab,
                    enabled: isEnabled
                ) { newValue in
                    mutatePreference { $0.styleTab = newValue }
                }

                overviewToggle(
                    label: L("settings.notifications.primary.sound", "Sound"),
                    value: preference.playSound,
                    enabled: isEnabled
                ) { newValue in
                    mutatePreference { $0.playSound = newValue }
                }

                overviewToggle(
                    label: L("settings.notifications.primary.dockBounce", "Dock Bounce"),
                    value: preference.dockBounce,
                    enabled: isEnabled
                ) { newValue in
                    mutatePreference { $0.dockBounce = newValue }
                }
            }
            .padding(.leading, 40)

            if preference.hasAdditionalActions {
                Text(L(
                    "settings.notifications.primary.extraActions",
                    "Advanced actions are attached to this event and will be preserved."
                ))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.leading, 40)
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.035))
        .cornerRadius(10)
    }

    private func overviewToggle(label: String, value: Bool, enabled: Bool, onChange: @escaping (Bool) -> Void) -> some View {
        Toggle(label, isOn: Binding(get: { value }, set: onChange))
            .toggleStyle(.checkbox)
            .font(.caption)
            .disabled(!enabled)
    }

    private func mutatePreference(_ mutate: (inout AINotificationPrimaryPreference) -> Void) {
        var updated = preference
        mutate(&updated)
        onUpdatePreference(updated)
    }
}

// MARK: - Shared Types

private enum TriggerCategory: String, CaseIterable, Identifiable {
    case core
    case shell
    case aiApps
    case app

    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .core:
            return L("settings.notifications.triggerCategory.core", "Core")
        case .shell:
            return L("settings.notifications.triggerCategory.shell", "Shell")
        case .aiApps:
            return L("settings.notifications.triggerCategory.aiApps", "AI Coding Apps")
        case .app:
            return L("settings.notifications.triggerCategory.app", "App")
        }
    }

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
            return [.claudeCode, .codex, .gemini, .chatgpt, .cursor, .windsurf, .copilot, .aider, .cline, .cody, .amazonQ, .devin, .goose, .mentat, .continueAI, .runtime]
        case .app:
            return [.app, .apiProxy, .unknown]
        }
    }
}

private struct TriggerGroup: Identifiable {
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
    @State private var expandedTriggerId: String?
    @State private var showingActionPicker = false
    @State private var selectedTriggerId: String?
    @State private var editingAction: (triggerId: String, config: NotificationActionConfig)?

    private func isGroupTriggerId(_ id: String) -> Bool {
        NotificationTriggerCatalog.allGroupTriggerIds.contains(id)
    }

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
        if category == .aiApps {
            // Set group overrides (not 80 individual overrides)
            var state = settings.notificationTriggerState
            let group = NotificationTriggerCatalog.aiCodingGroup
            for type in group.triggerTypes {
                state.setGroupEnabled(true, groupId: group.id, type: type)
            }
            // Clear all per-source overrides so they inherit cleanly
            let allTriggersForCategory = triggerGroups(for: category).flatMap(\.triggers)
            for trigger in allTriggersForCategory {
                state.removeOverride(for: trigger)
            }
            settings.notificationTriggerState = state
        } else {
            let allTriggersForCategory = triggerGroups(for: category).flatMap(\.triggers)
            var state = settings.notificationTriggerState
            for trigger in allTriggersForCategory {
                state.setEnabled(true, for: trigger)
            }
            settings.notificationTriggerState = state
        }
    }

    private func disableAll(for category: TriggerCategory) {
        if category == .aiApps {
            var state = settings.notificationTriggerState
            let group = NotificationTriggerCatalog.aiCodingGroup
            for type in group.triggerTypes {
                state.setGroupEnabled(false, groupId: group.id, type: type)
            }
            let allTriggersForCategory = triggerGroups(for: category).flatMap(\.triggers)
            for trigger in allTriggersForCategory {
                state.removeOverride(for: trigger)
            }
            settings.notificationTriggerState = state
        } else {
            let allTriggersForCategory = triggerGroups(for: category).flatMap(\.triggers)
            var state = settings.notificationTriggerState
            for trigger in allTriggersForCategory {
                state.setEnabled(false, for: trigger)
            }
            settings.notificationTriggerState = state
        }
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
                            if isGroupTriggerId(triggerId) {
                                settings.removeActionFromGroup(triggerId, actionId: actionId)
                            } else {
                                settings.removeActionFromTrigger(triggerId, actionId: actionId)
                            }
                        },
                        onToggleAction: { triggerId, actionId, enabled in
                            if isGroupTriggerId(triggerId) {
                                settings.setGroupActionEnabled(enabled, groupId: triggerId, actionId: actionId)
                            } else {
                                settings.setActionEnabled(enabled, triggerId: triggerId, actionId: actionId)
                            }
                        }
                    )
                }
            }
        }
        .sheet(isPresented: $showingActionPicker) {
            if let triggerId = selectedTriggerId {
                ActionPickerSheet(triggerId: triggerId) { actionType in
                    let newAction = NotificationActionConfig(actionType: actionType, enabled: true)
                    if isGroupTriggerId(triggerId) {
                        settings.addActionToGroup(triggerId, action: newAction)
                    } else {
                        settings.addActionToTrigger(triggerId, action: newAction)
                    }
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
                if isGroupTriggerId(item.triggerId) {
                    settings.updateActionInGroup(item.triggerId, action: updatedConfig)
                } else {
                    settings.updateActionInTrigger(item.triggerId, action: updatedConfig)
                }
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

                        Text(category.label)
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
                            text: L(
                                "settings.notifications.categoryDisabled",
                                "No triggers enabled in this category."
                            )
                        )
                        .padding(.leading, 16)
                        .padding(.top, 4)
                    }

                    if category == .aiApps {
                        // Group-level triggers
                        AICodingGroupSection(
                            expandedTriggerId: $expandedTriggerId,
                            onAddAction: onAddAction,
                            onEditAction: onEditAction,
                            onDeleteAction: onDeleteAction,
                            onToggleAction: onToggleAction
                        )

                        Divider()
                            .padding(.horizontal, 8)

                        // Per-source overrides (collapsible)
                        PerSourceOverridesSection(
                            groups: groups,
                            expandedSources: $expandedSources,
                            expandedTriggerId: $expandedTriggerId,
                            triggerBinding: triggerBinding,
                            onAddAction: onAddAction,
                            onEditAction: onEditAction,
                            onDeleteAction: onDeleteAction,
                            onToggleAction: onToggleAction
                        )
                    } else {
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

// MARK: - AI Coding Group Section

private struct AICodingGroupSection: View {
    @ObservedObject private var settings = FeatureSettings.shared
    @Binding var expandedTriggerId: String?
    let onAddAction: (String) -> Void
    let onEditAction: (String, NotificationActionConfig) -> Void
    let onDeleteAction: (String, UUID) -> Void
    let onToggleAction: (String, UUID, Bool) -> Void

    private let group = NotificationTriggerCatalog.aiCodingGroup
    private let groupInfos = NotificationTriggerCatalog.groupTriggerInfos(for: NotificationTriggerCatalog.aiCodingGroup)

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up")
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
                Text(L("settings.notifications.allAISources", "All AI Sources"))
                    .font(.caption)
                    .fontWeight(.medium)
                Spacer()
            }
            .padding(.bottom, 2)

            ForEach(groupInfos) { info in
                GroupTriggerRow(
                    info: info,
                    group: group,
                    isExpanded: expandedTriggerId == info.id,
                    onToggleExpand: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            expandedTriggerId = expandedTriggerId == info.id ? nil : info.id
                        }
                    },
                    onAddAction: { onAddAction(info.id) },
                    onEditAction: { config in onEditAction(info.id, config) },
                    onDeleteAction: { actionId in onDeleteAction(info.id, actionId) },
                    onToggleAction: { actionId, enabled in onToggleAction(info.id, actionId, enabled) }
                )
            }
        }
    }
}

// MARK: - Group Trigger Row

private struct GroupTriggerRow: View {
    let info: GroupTriggerInfo
    let group: NotificationTriggerGroup
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    let onAddAction: () -> Void
    let onEditAction: (NotificationActionConfig) -> Void
    let onDeleteAction: (UUID) -> Void
    let onToggleAction: (UUID, Bool) -> Void

    @ObservedObject private var settings = FeatureSettings.shared

    private var isOn: Bool {
        settings.notificationTriggerState.isGroupEnabled(
            groupId: group.id,
            type: info.type,
            defaultEnabled: info.defaultEnabled
        )
    }

    private var overrideCount: Int {
        // Count how many per-source triggers have per-trigger overrides for this type
        let triggers = NotificationTriggerCatalog.all.filter {
            group.contains(source: $0.source) && $0.type == info.type
        }
        return triggers.filter { settings.notificationTriggerState.hasPerTriggerOverride(for: $0) }.count
    }

    private var actions: [NotificationActionConfig] {
        settings.groupActionBindings[info.id] ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(
                    get: { isOn },
                    set: { newValue in
                        var state = settings.notificationTriggerState
                        state.setGroupEnabled(newValue, groupId: group.id, type: info.type)
                        settings.notificationTriggerState = state
                    }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()

                Button(action: onToggleExpand) {
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(info.labelFallback)
                                .font(.caption)
                                .foregroundStyle(isOn ? .primary : .secondary)

                            Text(info.descriptionFallback)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }

                        Spacer()

                        // Override count badge
                        if overrideCount > 0 {
                            Text("\(overrideCount)/\(group.sources.count) overridden")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.1))
                                .cornerRadius(4)
                        }

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

                        Circle()
                            .fill(isOn ? Color.green : Color.gray.opacity(0.3))
                            .frame(width: 8, height: 8)

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

            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    if actions.isEmpty {
                        HStack {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.secondary)
                            Text(L("settings.notifications.noGroupActions", "No group actions configured. Using default notification."))
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

// MARK: - Per-Source Overrides Section

private struct PerSourceOverridesSection: View {
    let groups: [TriggerGroup]
    @Binding var expandedSources: Set<String>
    @Binding var expandedTriggerId: String?
    let triggerBinding: (NotificationTrigger) -> Binding<Bool>
    let onAddAction: (String) -> Void
    let onEditAction: (String, NotificationActionConfig) -> Void
    let onDeleteAction: (String, UUID) -> Void
    let onToggleAction: (String, UUID, Bool) -> Void

    @State private var isOverridesExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: { withAnimation { isOverridesExpanded.toggle() } }) {
                HStack(spacing: 6) {
                    Image(systemName: isOverridesExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                    Image(systemName: "person.2")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(L("settings.notifications.perSourceOverrides", "Per-Source Overrides"))
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            if isOverridesExpanded {
                ForEach(groups) { group in
                    let groupEnabledCount = group.triggers.filter { triggerBinding($0).wrappedValue }.count
                    OverrideSourceSection(
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
                .padding(.leading, 16)
            }
        }
    }
}

// MARK: - Override Source Section (per-source with inheritance)

private struct OverrideSourceSection: View {
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

    @ObservedObject private var settings = FeatureSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
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

            if isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(group.triggers) { trigger in
                        OverrideTriggerRow(
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

// MARK: - Override Trigger Row (shows inheritance)

private struct OverrideTriggerRow: View {
    let trigger: NotificationTrigger
    @Binding var isOn: Bool
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    let onAddAction: () -> Void
    let onEditAction: (NotificationActionConfig) -> Void
    let onDeleteAction: (UUID) -> Void
    let onToggleAction: (UUID, Bool) -> Void

    @ObservedObject private var settings = FeatureSettings.shared

    private var hasOverride: Bool {
        settings.notificationTriggerState.hasPerTriggerOverride(for: trigger)
    }

    private var actions: [NotificationActionConfig] {
        settings.triggerActionBindings[trigger.id] ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Toggle("", isOn: $isOn)
                    .toggleStyle(.checkbox)
                    .labelsHidden()

                Button(action: onToggleExpand) {
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(trigger.localizedLabel)
                                .font(.caption)
                                .foregroundStyle(hasOverride ? (isOn ? .primary : .secondary) : .secondary)
                                .italic(!hasOverride)

                            if !hasOverride {
                                Text(L("settings.notifications.inheritedFromGroup", "Inherited from group"))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .italic()
                            } else if !trigger.localizedDescription.isEmpty {
                                Text(trigger.localizedDescription)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }

                        Spacer()

                        // Reset button when per-trigger override exists
                        if hasOverride {
                            Button(action: {
                                var state = settings.notificationTriggerState
                                state.removeOverride(for: trigger)
                                settings.notificationTriggerState = state
                            }) {
                                Text(L("settings.notifications.reset", "Reset"))
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                            .buttonStyle(.plain)
                        }

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

                        Circle()
                            .fill(isOn ? Color.green : Color.gray.opacity(0.3))
                            .frame(width: 8, height: 8)

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

// MARK: - Behavior Tab (Conditions + Rate Limiting)

private struct BehaviorTabView: View {
    @ObservedObject private var settings = FeatureSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Rate Limiting
            RateLimitingSection()

            Divider()
                .padding(.vertical, 4)

            // Default Conditions
            DefaultConditionsSection()
        }
    }
}

// MARK: - Rate Limiting Section

private struct RateLimitingSection: View {
    @ObservedObject private var settings = FeatureSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSectionHeader(L("settings.notifications.rateLimiting", "Rate Limiting"), icon: "gauge.with.dots.needle.33percent")

            Text(L("settings.notifications.rateLimiting.description", "Prevent notification spam from burst events. Applies per-trigger independently."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("settings.notifications.maxPerMinute", "Max per minute"))
                        .font(.caption)
                    TextField(
                        "5",
                        value: Binding(
                            get: { settings.notificationRateLimitConfig.maxPerMinute },
                            set: { settings.notificationRateLimitConfig.maxPerMinute = max(1, $0) }
                        ),
                        formatter: NumberFormatter()
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    Text(L("settings.notifications.maxPerMinute.help", "Token refill rate"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(L("settings.notifications.burstAllowance", "Burst allowance"))
                        .font(.caption)
                    TextField(
                        "3",
                        value: Binding(
                            get: { settings.notificationRateLimitConfig.burstAllowance },
                            set: { settings.notificationRateLimitConfig.burstAllowance = max(0, $0) }
                        ),
                        formatter: NumberFormatter()
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    Text(L("settings.notifications.burstAllowance.help", "Extra burst above rate"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(L("settings.notifications.cooldown", "Cooldown (seconds)"))
                        .font(.caption)
                    TextField(
                        "10",
                        value: Binding(
                            get: { Int(settings.notificationRateLimitConfig.cooldownSeconds) },
                            set: { settings.notificationRateLimitConfig.cooldownSeconds = TimeInterval(max(0, $0)) }
                        ),
                        formatter: NumberFormatter()
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    Text(L("settings.notifications.cooldown.help", "Min gap between same trigger"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.leading, 8)
        }
    }
}

// MARK: - Default Conditions Section

private struct DefaultConditionsSection: View {
    @ObservedObject private var settings = FeatureSettings.shared
    @State private var selectedTriggerId: String?

    private var configuredTriggers: [(trigger: NotificationTrigger, condition: TriggerCondition)] {
        NotificationTriggerCatalog.all
            .filter { settings.notificationTriggerState.isEnabled(for: $0) }
            .map { ($0, settings.conditionForTrigger($0.id)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSectionHeader(L("settings.notifications.conditions", "Trigger Conditions"), icon: "checklist")

            Text(L("settings.notifications.conditions.description", "Control when enabled triggers are allowed to fire. Conditions are evaluated before rate limiting."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

            // Per-trigger condition editor
            ForEach(configuredTriggers, id: \.trigger.id) { item in
                ConditionRow(
                    trigger: item.trigger,
                    condition: item.condition,
                    isExpanded: selectedTriggerId == item.trigger.id,
                    onToggleExpand: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedTriggerId = selectedTriggerId == item.trigger.id ? nil : item.trigger.id
                        }
                    },
                    onChange: { newCondition in
                        settings.setConditionForTrigger(item.trigger.id, condition: newCondition)
                    }
                )
            }

            if configuredTriggers.isEmpty {
                SettingsHint(
                    icon: "bell.slash",
                    text: L("settings.notifications.noEnabledTriggers", "No triggers are currently enabled. Enable triggers in the Triggers tab first.")
                )
            }
        }
    }
}

private struct ConditionRow: View {
    let trigger: NotificationTrigger
    let condition: TriggerCondition
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    let onChange: (TriggerCondition) -> Void

    private var hasCustomConditions: Bool {
        condition != .default
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggleExpand) {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 10)

                    Text(trigger.localizedLabel)
                        .font(.caption)

                    if hasCustomConditions {
                        Image(systemName: "slider.horizontal.3")
                            .font(.caption2)
                            .foregroundColor(.accentColor)
                    }

                    Spacer()

                    Text(trigger.source.rawValue)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .padding(.vertical, 3)

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(
                        L("settings.notifications.condition.respectDND", "Respect Focus/DND mode"),
                        isOn: Binding(
                            get: { condition.respectDND },
                            set: { var c = condition
                                c.respectDND = $0
                                onChange(c)
                            }
                        )
                    )
                    .font(.caption)

                    Toggle(
                        L("settings.notifications.condition.onlyWhenUnfocused", "Only when app is in background"),
                        isOn: Binding(
                            get: { condition.onlyWhenUnfocused },
                            set: { var c = condition
                                c.onlyWhenUnfocused = $0
                                onChange(c)
                            }
                        )
                    )
                    .font(.caption)

                    Toggle(
                        L("settings.notifications.condition.onlyWhenTabInactive", "Only when triggering tab is not selected"),
                        isOn: Binding(
                            get: { condition.onlyWhenTabInactive },
                            set: { var c = condition
                                c.onlyWhenTabInactive = $0
                                onChange(c)
                            }
                        )
                    )
                    .font(.caption)

                    if condition != .default {
                        Button(action: { onChange(.default) }) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.uturn.backward")
                                Text(L("settings.notifications.condition.reset", "Reset to defaults"))
                            }
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, 24)
                .padding(.vertical, 4)
                .padding(.bottom, 4)
            }
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - Notification History Tab

private struct NotificationHistoryTabView: View {
    @State private var entries: [NotificationHistory.Entry] = []
    @State private var refreshToken = UUID()

    private var summaryText: String {
        let completed = entries.filter { $0.deliveryState == NotificationHistory.DeliveryState.completed.rawValue }.count
        let dropped = entries.filter { $0.deliveryState == NotificationHistory.DeliveryState.dropped.rawValue }.count
        let retries = entries.filter { $0.deliveryState == NotificationHistory.DeliveryState.retryScheduled.rawValue }.count
        let authoritative = entries.filter { $0.reliability == AIEventReliability.authoritative.rawValue }.count
        return "completed \(completed)  dropped \(dropped)  retrying \(retries)  authoritative \(authoritative)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSectionHeader(L("settings.notifications.history", "Notification History"), icon: "clock.arrow.circlepath")

            HStack {
                Text(L("settings.notifications.history.description", "Recent notification events (last 100, in-memory only)."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !entries.isEmpty {
                    Text(summaryText)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                Button(action: refreshHistory) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)

                Button(action: clearHistory) {
                    Text(L("settings.notifications.history.clear", "Clear"))
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }

            if entries.isEmpty {
                SettingsHint(
                    icon: "clock",
                    text: L("settings.notifications.history.empty", "No notification events recorded yet.")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(entries) { entry in
                            NotificationHistoryEntryRow(entry: entry)
                        }
                    }
                }
                .frame(maxHeight: 400)
            }
        }
        .onAppear { refreshHistory() }
        .id(refreshToken)
    }

    private func refreshHistory() {
        Task { @MainActor in
            entries = NotificationManager.shared.history.recent(limit: 100)
            refreshToken = UUID()
        }
    }

    private func clearHistory() {
        Task { @MainActor in
            NotificationManager.shared.history.clear()
            entries = []
            refreshToken = UUID()
        }
    }
}

private struct NotificationHistoryEntryRow: View {
    let entry: NotificationHistory.Entry

    private var timeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: entry.timestamp)
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(timeString)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)

            if entry.wasRateLimited {
                Image(systemName: "gauge.with.dots.needle.100percent")
                    .font(.caption2)
                    .foregroundColor(.orange)
                    .help("Rate limited")
            } else {
                Image(systemName: "bell.fill")
                    .font(.caption2)
                    .foregroundColor(.green)
            }

            Text(entry.triggerId ?? entry.deliveryState)
                .font(.caption.monospaced())
                .foregroundStyle(.primary)
                .lineLimit(1)

            if !entry.actionsExecuted.isEmpty {
                Text(entry.actionsExecuted.joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Text(entry.reliability)
                .font(.caption2.monospaced())
                .foregroundStyle(entry.reliability == AIEventReliability.authoritative.rawValue ? .green : .secondary)

            Spacer()

            let status = [
                entry.didDispatchBanner ? "banner" : nil,
                entry.didStyleTab ? "style" : nil,
                entry.dropReason
            ]
            .compactMap { $0 }
            .joined(separator: " · ")

            Text(status.isEmpty ? String(entry.message.prefix(40) + (entry.message.count > 40 ? "..." : "")) : status)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .background(rowBackground)
        .cornerRadius(3)
    }

    private var rowBackground: Color {
        if entry.wasRateLimited {
            return Color.orange.opacity(0.05)
        }
        if entry.deliveryState == NotificationHistory.DeliveryState.dropped.rawValue {
            return Color.red.opacity(0.05)
        }
        if entry.deliveryState == NotificationHistory.DeliveryState.retryScheduled.rawValue {
            return Color.yellow.opacity(0.06)
        }
        return Color.clear
    }
}
