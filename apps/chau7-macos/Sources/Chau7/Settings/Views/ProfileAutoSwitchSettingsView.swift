import SwiftUI
import Chau7Core

/// Settings view for configuring automatic profile switching rules.
struct ProfileAutoSwitchSettingsView: View {
    @ObservedObject var switcher: ProfileAutoSwitcher
    @ObservedObject var settings: FeatureSettings

    @State private var showingEditor = false
    @State private var editingRule: ProfileSwitchRule?
    @State private var showingDeleteAlert = false
    @State private var ruleToDelete: ProfileSwitchRule?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSectionHeader(L("Profile Auto-Switching"))

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
                .padding(8)
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
                    .padding(.vertical, 8)
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
        .alert("Delete Rule?", isPresented: $showingDeleteAlert) {
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
            VStack(alignment: .leading, spacing: 2) {
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
    @State private var triggerType: ProfileSwitchTrigger = .directory(path: "")
    @State private var triggerValue = ""
    @State private var envKey = ""
    @State private var envValue = ""
    @State private var profileName = ""
    @State private var priority = 0

    var body: some View {
        VStack(spacing: 16) {
            Text(rule == nil ? "Add Rule" : "Edit Rule")
                .font(.headline)

            TextField(L("Rule Name", "Rule Name"), text: $name)
                .textFieldStyle(.roundedBorder)

            // Trigger value
            TextField(L("Trigger Value (path, hostname, etc.)", "Trigger Value (path, hostname, etc.)"), text: $triggerValue)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))

            // Profile picker
            Picker(L("Target Profile", "Target Profile"), selection: $profileName) {
                ForEach(profiles) { profile in
                    Text(profile.name).tag(profile.name)
                }
            }

            // Priority
            Stepper("Priority: \(priority)", value: $priority, in: 0 ... 100)

            Toggle(L("Enabled", "Enabled"), isOn: $isEnabled)

            HStack {
                Button(L("Cancel", "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(rule == nil ? "Add" : "Save") {
                    let trigger = ProfileSwitchTrigger.directory(path: triggerValue)
                    let newRule = ProfileSwitchRule(
                        id: rule?.id ?? UUID(),
                        name: name,
                        isEnabled: isEnabled,
                        trigger: trigger,
                        profileName: profileName,
                        priority: priority
                    )
                    onSave(newRule)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || triggerValue.isEmpty)
            }
        }
        .padding()
        .frame(width: 400)
        .onAppear {
            if let rule = rule {
                name = rule.name
                isEnabled = rule.isEnabled
                profileName = rule.profileName
                priority = rule.priority
                switch rule.trigger {
                case .directory(let path): triggerValue = path
                case .gitRepository(let n): triggerValue = n
                case .sshHost(let h): triggerValue = h
                case .processRunning(let n): triggerValue = n
                case .environmentVariable(let k, let v):
                    envKey = k
                    envValue = v
                    triggerValue = "\(k)=\(v)"
                }
            } else {
                profileName = profiles.first?.name ?? ""
            }
        }
    }
}
