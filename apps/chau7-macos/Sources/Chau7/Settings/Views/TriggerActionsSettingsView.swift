import SwiftUI
import Chau7Core

// MARK: - Shared Types

/// Helper for sheet binding in unified trigger management
struct EditingActionItem: Identifiable {
    let triggerId: String
    let config: NotificationActionConfig
    var id: UUID { config.id }
}

// MARK: - Action Row

/// Displays a single configured action with toggle, icon, label, edit/delete buttons.
/// Used by UnifiedTriggerRow when a trigger is expanded to show its action chain.
struct ActionRow: View {
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

struct ConfigFieldView: View {
    let field: ActionConfigField
    @Binding var value: String

    /// Dynamically discovered macOS system sounds (cached on first access)
    private static let systemSounds: [String] = {
        let soundsDir = "/System/Library/Sounds"
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: soundsDir) else { return [] }
        return files
            .filter { $0.hasSuffix(".aiff") }
            .map { String($0.dropLast(5)) }
            .sorted()
    }()

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
                HStack {
                    Picker("", selection: $value) {
                        Text(L("Default", "Default")).tag("default")
                        ForEach(Self.systemSounds, id: \.self) { sound in
                            Text(sound).tag(sound)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)

                    Button(action: previewSound) {
                        Image(systemName: "speaker.wave.2")
                    }
                }
            }
        }
        .padding(.horizontal)
    }

    private func selectFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = field.id.contains("Dir") || (field.id.contains("Path") && !field.id.contains("file"))
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
struct ActionPickerSheet_Previews: PreviewProvider {
    static var previews: some View {
        ActionPickerSheet(triggerId: "test.trigger") { _ in }
            .frame(width: 500, height: 600)
    }
}
#endif
