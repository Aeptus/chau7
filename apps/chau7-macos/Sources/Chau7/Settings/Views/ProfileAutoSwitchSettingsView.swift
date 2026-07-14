import SwiftUI
import Chau7Core

/// Settings view for configuring automatic profile switching rules.
struct ProfileAutoSwitchSettingsView: View {
    var switcher: ProfileAutoSwitcher
    var settings: FeatureSettings

    @State private var showingEditor = false
    @State private var editingRule: ProfileSwitchRule?
    @State private var showingDeleteAlert = false
    @State private var ruleToDelete: ProfileSwitchRule?

    var body: some View {
        VStack(alignment: .leading, spacing: Chau7Style.Settings.pageSectionSpacing) {
            SettingsSectionHeader(L("Profile Auto-Switching"), anchorID: "profileAutoSwitch")

            SettingsToggle(
                label: L("Enable automatic profile switching"),
                help: L("Automatically switch settings profiles based on your terminal context"),
                isOn: Binding(
                    get: { switcher.isEnabled },
                    set: { switcher.isEnabled = $0 }
                )
            )

            // Active status
            if switcher.isActive, let rule = switcher.currentMatchedRule {
                HStack {
                    Image(systemName: "arrow.triangle.swap")
                        .foregroundColor(.blue)
                    Text(String(format: L("profileAutoSwitch.active", "Active: %@ → %@"), rule.name, rule.profileName))
                        .font(.caption)
                    Spacer()
                    Button(L("Restore", "Restore")) {
                        switcher.restorePreviousProfile()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(Chau7Style.Settings.inlineControlSpacing)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(6)
            }

            Divider()

            // Rules list
            SettingsSectionHeader(L("Switch Rules"))

            if switcher.rules.isEmpty {
                Text(L("No rules configured. Add a rule to automatically switch profiles."))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, Chau7Style.Settings.separatorVerticalPadding)
            } else {
                ForEach(switcher.rules.sortedByPriority()) { rule in
                    ruleRow(rule)
                    Divider()
                }
            }

            // Add button
            Button {
                editingRule = nil
                showingEditor = true
            } label: {
                Label(L("Add Rule"), systemImage: "plus")
            }
            .buttonStyle(.bordered)
        }
        .sheet(isPresented: $showingEditor) {
            RuleEditorSheet(
                rule: editingRule,
                profiles: settings.savedProfiles,
                onSave: { rule in
                    if editingRule != nil {
                        switcher.updateRule(rule)
                    } else {
                        switcher.addRule(rule)
                    }
                }
            )
        }
        .alert(L("alert.deleteRule.title", "Delete Rule?"), isPresented: $showingDeleteAlert) {
            Button(L("Delete", "Delete"), role: .destructive) {
                if let rule = ruleToDelete {
                    switcher.deleteRule(id: rule.id)
                }
            }
            Button(L("Cancel", "Cancel"), role: .cancel) {}
        } message: {
            Text(L("This cannot be undone.", "This cannot be undone."))
        }
    }

    private func ruleRow(_ rule: ProfileSwitchRule) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: Chau7Style.Spacing.xxxSmall) {
                HStack {
                    Text(rule.name)
                        .fontWeight(.medium)
                    if !rule.isEnabled {
                        Text(L("DISABLED", "DISABLED"))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 4)
                            .background(Color.secondary.opacity(0.2))
                            .cornerRadius(3)
                    }
                }
                Text(rule.trigger.displaySummary + " → " + rule.profileName)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Text(String(format: L("profileAutoSwitch.priority", "P%d"), rule.priority))
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.secondary)

            Button {
                editingRule = rule
                showingEditor = true
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)

            Button {
                ruleToDelete = rule
                showingDeleteAlert = true
            } label: {
                Image(systemName: "trash")
                    .foregroundColor(.red)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Rule Editor Sheet

private struct RuleEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let rule: ProfileSwitchRule?
    let profiles: [SettingsProfile]
    let onSave: (ProfileSwitchRule) -> Void

    @State private var name = ""
    @State private var isEnabled = true
    @State private var triggerKind: ProfileSwitchTriggerKind = .directory
    @State private var triggerValue = ""
    @State private var envKey = ""
    @State private var envValue = ""
    @State private var profileName = ""
    @State private var priority = 0

    var body: some View {
        VStack(alignment: .leading, spacing: Chau7Style.Settings.pageSectionSpacing) {
            Text(rule == nil ? "Add Rule" : "Edit Rule")
                .font(.headline)

            TextField(L("Rule Name", "Rule Name"), text: $name)
                .textFieldStyle(.roundedBorder)

            Picker(L("profileAutoSwitch.triggerType", "Trigger"), selection: $triggerKind) {
                ForEach(ProfileSwitchTriggerKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.menu)

            if triggerKind == .environmentVariable {
                HStack(spacing: Chau7Style.Settings.inlineControlSpacing) {
                    TextField(L("profileAutoSwitch.envKey", "Variable"), text: $envKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    TextField(L("profileAutoSwitch.envValue", "Value"), text: $envValue)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
            } else {
                TextField(triggerKind.placeholder, text: $triggerValue)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            SettingsDescription(triggerKind.help)

            // Profile picker
            Picker(L("Target Profile", "Target Profile"), selection: $profileName) {
                ForEach(profiles) { profile in
                    Text(profile.name).tag(profile.name)
                }
            }

            if profiles.isEmpty {
                SettingsDescription(L("profileAutoSwitch.noProfiles", "Create a settings profile before adding an auto-switch rule."))
            }

            // Priority
            Stepper("Priority: \(priority)", value: $priority, in: 0 ... 100)

            Toggle(L("Enabled", "Enabled"), isOn: $isEnabled)

            HStack {
                Button(L("Cancel", "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(rule == nil ? "Add" : "Save") {
                    guard let trigger = buildTrigger() else { return }
                    let newRule = ProfileSwitchRule(
                        id: rule?.id ?? UUID(),
                        name: trimmed(name),
                        isEnabled: isEnabled,
                        trigger: trigger,
                        profileName: profileName,
                        priority: priority
                    )
                    onSave(newRule)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(Chau7Style.Settings.contentPadding)
        .frame(width: 460)
        .onAppear {
            if let rule = rule {
                name = rule.name
                isEnabled = rule.isEnabled
                profileName = rule.profileName
                priority = rule.priority
                switch rule.trigger {
                case .directory(let path):
                    triggerKind = .directory
                    triggerValue = path
                case .gitRepository(let n):
                    triggerKind = .gitRepository
                    triggerValue = n
                case .sshHost(let h):
                    triggerKind = .sshHost
                    triggerValue = h
                case .processRunning(let n):
                    triggerKind = .processRunning
                    triggerValue = n
                case .environmentVariable(let k, let v):
                    triggerKind = .environmentVariable
                    envKey = k
                    envValue = v
                }
            } else {
                profileName = profiles.first?.name ?? ""
            }
        }
    }

    private var canSave: Bool {
        !trimmed(name).isEmpty && !profileName.isEmpty && buildTrigger() != nil
    }

    private func buildTrigger() -> ProfileSwitchTrigger? {
        switch triggerKind {
        case .directory:
            let value = trimmed(triggerValue)
            return value.isEmpty ? nil : .directory(path: value)
        case .gitRepository:
            let value = trimmed(triggerValue)
            return value.isEmpty ? nil : .gitRepository(name: value)
        case .sshHost:
            let value = trimmed(triggerValue)
            return value.isEmpty ? nil : .sshHost(hostname: value)
        case .processRunning:
            let value = trimmed(triggerValue)
            return value.isEmpty ? nil : .processRunning(name: value)
        case .environmentVariable:
            let key = trimmed(envKey)
            let value = trimmed(envValue)
            guard !key.isEmpty, !value.isEmpty else { return nil }
            return .environmentVariable(key: key, value: value)
        }
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum ProfileSwitchTriggerKind: String, CaseIterable, Identifiable {
    case directory
    case gitRepository
    case sshHost
    case processRunning
    case environmentVariable

    var id: String { rawValue }

    var title: String {
        switch self {
        case .directory: L("profileAutoSwitch.trigger.directory", "Directory")
        case .gitRepository: L("profileAutoSwitch.trigger.gitRepository", "Git Repository")
        case .sshHost: L("profileAutoSwitch.trigger.sshHost", "SSH Host")
        case .processRunning: L("profileAutoSwitch.trigger.process", "Process")
        case .environmentVariable: L("profileAutoSwitch.trigger.environment", "Environment Variable")
        }
    }

    var placeholder: String {
        switch self {
        case .directory: L("profileAutoSwitch.placeholder.directory", "Directory path or glob, e.g. ~/Work/**")
        case .gitRepository: L("profileAutoSwitch.placeholder.gitRepository", "Repository folder name")
        case .sshHost: L("profileAutoSwitch.placeholder.sshHost", "SSH hostname")
        case .processRunning: L("profileAutoSwitch.placeholder.process", "Process name")
        case .environmentVariable: ""
        }
    }

    var help: String {
        switch self {
        case .directory:
            L("profileAutoSwitch.help.directory", "Matches the terminal working directory. Supports * and ** wildcards.")
        case .gitRepository:
            L("profileAutoSwitch.help.gitRepository", "Matches the repository folder name from the current directory.")
        case .sshHost:
            L("profileAutoSwitch.help.sshHost", "Matches the active SSH host exactly, case-insensitively.")
        case .processRunning:
            L("profileAutoSwitch.help.process", "Matches when the named process is detected in the terminal context.")
        case .environmentVariable:
            L("profileAutoSwitch.help.environment", "Matches when the terminal environment contains the exact key/value pair.")
        }
    }
}
