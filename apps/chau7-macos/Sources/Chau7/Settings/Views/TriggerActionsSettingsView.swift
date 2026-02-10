import SwiftUI
import Chau7Core

// MARK: - Trigger Actions Settings View

struct TriggerActionsSettingsView: View {
    @ObservedObject private var settings = FeatureSettings.shared
    @State private var expandedTriggerId: String? = nil
    @State private var showingActionPicker = false
    @State private var selectedTriggerId: String? = nil
    @State private var editingAction: (triggerId: String, config: NotificationActionConfig)? = nil

    private var triggerGroups: [(source: NotificationTriggerSourceInfo, triggers: [NotificationTrigger])] {
        NotificationTriggerCatalog.sources
            .sorted { $0.sortOrder < $1.sortOrder }
            .compactMap { source in
                let triggers = NotificationTriggerCatalog
                    .triggers(for: source.id)
                    .filter { $0.displayContexts.contains(.settings) }
                guard !triggers.isEmpty else { return nil }
                return (source, triggers)
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSectionHeader(L("settings.notifications.actions", "Trigger Actions"), icon: "bolt.circle")

            Text(L("settings.notifications.actions.description", "Configure what happens when each trigger fires. Click a trigger to expand and manage its actions."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

            ForEach(triggerGroups, id: \.source.id) { group in
                TriggerGroupSection(
                    source: group.source,
                    triggers: group.triggers,
                    expandedTriggerId: $expandedTriggerId,
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
                        if var actions = settings.triggerActionBindings[triggerId],
                           let index = actions.firstIndex(where: { $0.id == actionId }) {
                            var action = actions[index]
                            action = NotificationActionConfig(
                                id: action.id,
                                actionType: action.actionType,
                                enabled: enabled,
                                config: action.config
                            )
                            actions[index] = action
                            settings.triggerActionBindings[triggerId] = actions
                        }
                    }
                )
            }
        }
        .sheet(isPresented: $showingActionPicker) {
            if let triggerId = selectedTriggerId {
                ActionPickerSheet(triggerId: triggerId) { actionType in
                    let newAction = NotificationActionConfig(actionType: actionType, enabled: true)
                    settings.addActionToTrigger(triggerId, action: newAction)
                    // Immediately open config if required
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

// Helper for sheet binding
private struct EditingActionItem: Identifiable {
    let triggerId: String
    let config: NotificationActionConfig
    var id: UUID { config.id }
}

// MARK: - Trigger Group Section

private struct TriggerGroupSection: View {
    let source: NotificationTriggerSourceInfo
    let triggers: [NotificationTrigger]
    @Binding var expandedTriggerId: String?
    let onAddAction: (String) -> Void
    let onEditAction: (String, NotificationActionConfig) -> Void
    let onDeleteAction: (String, UUID) -> Void
    let onToggleAction: (String, UUID, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: source.icon)
                    .foregroundStyle(.secondary)
                Text(source.localizedLabel)
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }
            .padding(.top, 8)

            ForEach(triggers) { trigger in
                TriggerRow(
                    trigger: trigger,
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
    }
}

private extension NotificationTriggerSourceInfo {
    var icon: String {
        switch id {
        case .eventsLog: return "doc.text"
        case .terminalSession: return "terminal"
        case .historyMonitor: return "clock.arrow.circlepath"
        case .claudeCode: return "brain"
        case .app: return "app"
        default: return "bell"
        }
    }
}

// MARK: - Trigger Row

private struct TriggerRow: View {
    let trigger: NotificationTrigger
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

    private var isEnabled: Bool {
        settings.notificationTriggerState.isEnabled(for: trigger)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            Button(action: onToggleExpand) {
                HStack {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(trigger.localizedLabel)
                            .font(.body)
                            .foregroundStyle(isEnabled ? .primary : .secondary)
                        Text(trigger.localizedDescription)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
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
                        .fill(isEnabled ? Color.green : Color.gray.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(isExpanded ? Color.secondary.opacity(0.05) : Color.clear)
            .cornerRadius(6)

            // Expanded content
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
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
                    .padding(.bottom, 8)
                }
                .padding(.top, 4)
                .background(Color.secondary.opacity(0.03))
            }
        }
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(8)
    }
}

// MARK: - Action Row

private struct ActionRow: View {
    let action: NotificationActionConfig
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onToggle: (Bool) -> Void

    private var actionInfo: NotificationActionInfo? {
        NotificationActionCatalog.action(for: action.actionType)
    }

    var body: some View {
        HStack(spacing: 12) {
            // Toggle
            Toggle("", isOn: Binding(
                get: { action.enabled },
                set: { onToggle($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()

            // Icon
            Image(systemName: actionInfo?.icon ?? "bolt")
                .font(.body)
                .foregroundStyle(action.enabled ? .primary : .secondary)
                .frame(width: 20)

            // Label
            VStack(alignment: .leading, spacing: 1) {
                Text(actionInfo.map { L($0.labelKey, $0.labelFallback) } ?? action.actionType.rawValue)
                    .font(.caption)
                    .foregroundStyle(action.enabled ? .primary : .secondary)

                if let summary = actionConfigSummary() {
                    Text(summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Edit button
            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)

            // Delete button
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundColor(.red.opacity(0.8))
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 6)
    }

    private func actionConfigSummary() -> String? {
        let config = action.config
        switch action.actionType {
        case .playSound:
            return config["sound"]
        case .runScript:
            if let script = config["script"] {
                return String(script.prefix(40)) + (script.count > 40 ? "..." : "")
            }
            return nil
        case .webhook:
            return config["url"]
        case .sendSlack, .sendDiscord:
            return config["webhookUrl"].map { String($0.prefix(30)) + "..." }
        case .dockerBump:
            return config["container"]
        case .dockerCompose:
            return config["operation"]
        case .openURL:
            return config["url"]
        case .voiceAnnounce:
            return config["voice"]
        default:
            return nil
        }
    }
}

// MARK: - Action Picker Sheet

struct ActionPickerSheet: View {
    let triggerId: String
    let onSelect: (NotificationActionType) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var filteredCategories: [(category: ActionCategory, actions: [NotificationActionInfo])] {
        let query = searchText.lowercased().trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            return NotificationActionCatalog.byCategory
        }
        return NotificationActionCatalog.byCategory.compactMap { category, actions in
            let filtered = actions.filter {
                $0.labelFallback.lowercased().contains(query) ||
                $0.descriptionFallback.lowercased().contains(query)
            }
            return filtered.isEmpty ? nil : (category, filtered)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(L("settings.notifications.selectAction", "Select Action"))
                    .font(.headline)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            // Search
            TextField(L("settings.notifications.searchActions", "Search actions..."), text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
                .padding(.bottom, 8)

            Divider()

            // Action list
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(filteredCategories, id: \.category) { category, actions in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: category.icon)
                                    .foregroundStyle(.secondary)
                                Text(category.displayName)
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                            }
                            .padding(.horizontal)

                            ForEach(actions) { actionInfo in
                                ActionPickerRow(actionInfo: actionInfo) {
                                    onSelect(actionInfo.type)
                                    dismiss()
                                }
                            }
                        }
                    }
                }
                .padding(.vertical)
            }
        }
        .frame(width: 500, height: 600)
    }
}

private struct ActionPickerRow: View {
    let actionInfo: NotificationActionInfo
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Image(systemName: actionInfo.icon)
                    .font(.title3)
                    .foregroundStyle(.primary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(L(actionInfo.labelKey, actionInfo.labelFallback))
                            .font(.body)
                            .foregroundStyle(.primary)
                        if actionInfo.requiresConfig {
                            Image(systemName: "gearshape")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(L(actionInfo.descriptionKey, actionInfo.descriptionFallback))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Image(systemName: "plus.circle")
                    .foregroundColor(.accentColor)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(6)
        .padding(.horizontal)
    }
}

// MARK: - Action Config Sheet

struct ActionConfigSheet: View {
    let triggerId: String
    let actionConfig: NotificationActionConfig
    let onSave: (NotificationActionConfig) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var configValues: [String: String] = [:]
    @State private var isEnabled: Bool = true

    private var actionInfo: NotificationActionInfo? {
        NotificationActionCatalog.action(for: actionConfig.actionType)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                if let info = actionInfo {
                    Image(systemName: info.icon)
                        .font(.title2)
                    Text(L(info.labelKey, info.labelFallback))
                        .font(.headline)
                }
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            // Config fields
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Enabled toggle
                    Toggle(L("settings.notifications.actionEnabled", "Action Enabled"), isOn: $isEnabled)
                        .padding(.horizontal)

                    if let info = actionInfo {
                        Text(L(info.descriptionKey, info.descriptionFallback))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)

                        Divider()
                            .padding(.vertical, 8)

                        ForEach(info.configFields) { field in
                            ConfigFieldView(
                                field: field,
                                value: Binding(
                                    get: { configValues[field.id] ?? field.defaultValue ?? "" },
                                    set: { configValues[field.id] = $0 }
                                )
                            )
                        }

                        if info.configFields.isEmpty {
                            Text(L("settings.notifications.noConfigNeeded", "This action requires no additional configuration."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal)
                        }
                    }
                }
                .padding(.vertical)
            }

            Divider()

            // Footer buttons
            HStack {
                Button(L("button.cancel", "Cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(L("button.save", "Save")) {
                    saveAndDismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 450, height: 500)
        .onAppear {
            configValues = actionConfig.config
            isEnabled = actionConfig.enabled
        }
    }

    private func saveAndDismiss() {
        let updatedConfig = NotificationActionConfig(
            id: actionConfig.id,
            actionType: actionConfig.actionType,
            enabled: isEnabled,
            config: configValues.filter { !$0.value.isEmpty }
        )
        onSave(updatedConfig)
        dismiss()
    }
}

// MARK: - Config Field View

private struct ConfigFieldView: View {
    let field: ActionConfigField
    @Binding var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(L(field.labelKey, field.labelFallback))
                    .font(.caption)
                    .fontWeight(.medium)
                if field.required {
                    Text(L("*", "*"))
                        .foregroundColor(.red)
                }
            }

            switch field.type {
            case .text, .secretText:
                TextField(field.placeholder ?? "", text: $value)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: field.type == .secretText ? .monospaced : .default))

            case .textArea:
                TextEditor(text: $value)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 60, maxHeight: 100)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
                    .overlay(alignment: .topLeading) {
                        if value.isEmpty, let placeholder = field.placeholder {
                            Text(placeholder)
                                .foregroundStyle(.secondary.opacity(0.5))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                    }

            case .number:
                TextField(field.placeholder ?? "0", text: $value)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)

            case .toggle:
                Toggle("", isOn: Binding(
                    get: { value.lowercased() == "true" || value == "1" },
                    set: { value = $0 ? "true" : "false" }
                ))
                .labelsHidden()

            case .picker:
                if let options = field.options {
                    Picker("", selection: $value) {
                        ForEach(options) { option in
                            Text(option.label).tag(option.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }

            case .filePath:
                HStack {
                    TextField(field.placeholder ?? "", text: $value)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))

                    Button(action: selectFile) {
                        Image(systemName: "folder")
                    }
                }

            case .soundPicker:
                Picker("", selection: $value) {
                    Text(L("Default", "Default")).tag("default")
                    Text(L("Basso", "Basso")).tag("Basso")
                    Text(L("Blow", "Blow")).tag("Blow")
                    Text(L("Bottle", "Bottle")).tag("Bottle")
                    Text(L("Frog", "Frog")).tag("Frog")
                    Text(L("Funk", "Funk")).tag("Funk")
                    Text(L("Glass", "Glass")).tag("Glass")
                    Text(L("Hero", "Hero")).tag("Hero")
                    Text(L("Morse", "Morse")).tag("Morse")
                    Text(L("Ping", "Ping")).tag("Ping")
                    Text(L("Pop", "Pop")).tag("Pop")
                    Text(L("Purr", "Purr")).tag("Purr")
                    Text(L("Sosumi", "Sosumi")).tag("Sosumi")
                    Text(L("Submarine", "Submarine")).tag("Submarine")
                    Text(L("Tink", "Tink")).tag("Tink")
                }
                .labelsHidden()
                .frame(width: 150)

                Button(action: previewSound) {
                    Image(systemName: "speaker.wave.2")
                }
            }
        }
        .padding(.horizontal)
    }

    private func selectFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = field.id.contains("Dir") || field.id.contains("Path") && !field.id.contains("file")
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            value = url.path
        }
    }

    private func previewSound() {
        if value == "default" || value.isEmpty {
            NSSound.beep()
        } else if let sound = NSSound(named: NSSound.Name(value)) {
            sound.play()
        } else {
            let systemPath = "/System/Library/Sounds/\(value).aiff"
            if let sound = NSSound(contentsOfFile: systemPath, byReference: true) {
                sound.play()
            } else {
                NSSound.beep()
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
struct TriggerActionsSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        TriggerActionsSettingsView()
            .frame(width: 600, height: 800)
    }
}
#endif
