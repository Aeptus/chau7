import SwiftUI
import AppKit
import Chau7Core

// MARK: - AI Integration Settings

struct AIIntegrationSettingsView: View {
    @Bindable private var settings = FeatureSettings.shared
    @State private var newCustomPattern = ""
    @State private var newCustomName = ""
    @State private var newCustomColor: TabColor = .gray

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Custom Rules (actionable — first)
            SettingsSectionHeader(L("settings.ai.customDetectionRules", "Custom Detection Rules"), icon: "slider.horizontal.3")

            Text(L("settings.ai.customRulesDescription", "Add command or output patterns to tag custom AI CLIs."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

            // Existing rules
            ForEach($settings.customAIDetectionRules) { $rule in
                CustomRuleRow(rule: $rule) {
                    if let index = settings.customAIDetectionRules.firstIndex(where: { $0.id == rule.id }) {
                        settings.customAIDetectionRules.remove(at: index)
                    }
                }
            }

            // Add new rule
            SettingsRow(L("settings.ai.addNewRule", "Add New Rule")) {
                HStack(spacing: 8) {
                    TextField(L("settings.ai.patternPlaceholder", "Pattern"), text: $newCustomPattern)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)

                    TextField(L("settings.ai.namePlaceholder", "Name"), text: $newCustomName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)

                    Picker("", selection: $newCustomColor) {
                        ForEach(TabColor.allCases) { color in
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(color.color)
                                    .frame(width: 8, height: 8)
                                Text(color.rawValue.capitalized)
                            }
                            .tag(color)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 100)

                    Button(L("settings.ai.add", "Add")) {
                        addNewRule()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(newCustomPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            Divider()
                .padding(.vertical, 8)

            // LLM Provider (actionable — second)
            LLMSettingsView(settings: settings)

            Divider()
                .padding(.vertical, 8)

            // Built-in Detection (read-only reference — last)
            SettingsSectionHeader(L("settings.ai.cliDetection", "Built-in AI CLI Detection"), icon: "sparkle.magnifyingglass")

            Text(L("settings.ai.detectionDescription", "Chau7 automatically detects these AI CLIs and applies appropriate theming:"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

            SettingsDetectionRow(name: "Claude Code", commands: "claude, claude-code", color: TabColor.purple.color)
            SettingsDetectionRow(name: "OpenAI Codex", commands: "codex, codex-cli", color: TabColor.green.color)
            SettingsDetectionRow(name: "Gemini", commands: "gemini", color: TabColor.blue.color)
            SettingsDetectionRow(name: "ChatGPT", commands: "chatgpt, gpt", color: TabColor.green.color)
            SettingsDetectionRow(name: "GitHub Copilot", commands: "gh copilot, copilot", color: TabColor.orange.color)
            SettingsDetectionRow(name: "Aider", commands: "aider, aider-chat", color: TabColor.pink.color)
            SettingsDetectionRow(name: "Cursor", commands: "cursor", color: TabColor.teal.color)
        }
    }

    private func addNewRule() {
        let trimmed = newCustomPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let name = newCustomName.trimmingCharacters(in: .whitespacesAndNewlines)
        let rule = CustomAIDetectionRule(
            pattern: trimmed,
            displayName: name,
            colorName: newCustomColor.rawValue
        )
        settings.customAIDetectionRules.append(rule)
        newCustomPattern = ""
        newCustomName = ""
        newCustomColor = .gray
    }

}

// MARK: - Custom Rule Row

private struct CustomRuleRow: View {
    @Binding var rule: CustomAIDetectionRule
    let onDelete: () -> Void

    var body: some View {
        SettingsRow(rule.displayName.isEmpty ? rule.pattern : rule.displayName) {
            HStack(spacing: 8) {
                Circle()
                    .fill(TabColor(rawValue: rule.colorName)?.color ?? Color.gray)
                    .frame(width: 10, height: 10)

                Text(rule.pattern)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .help(L("settings.ai.removeRule", "Remove rule"))
            }
        }
    }
}
