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
        VStack(alignment: .leading, spacing: Chau7Style.Settings.pageSectionSpacing) {
            // Custom Rules (actionable — first)
            SettingsSectionHeader(
                L("settings.ai.customDetectionRules", "Custom Detection Rules"),
                icon: "slider.horizontal.3",
                anchorID: "aiCustomDetection"
            )

            Text(L("settings.ai.customRulesDescription", "Add command or output patterns to tag custom AI CLIs."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Chau7Style.Settings.inlineControlSpacing) {
                        newRulePatternField
                        newRuleNameField
                        newRuleColorPicker
                        addRuleButton
                    }

                    VStack(alignment: .leading, spacing: Chau7Style.Settings.inlineControlSpacing) {
                        newRulePatternField
                        newRuleNameField
                        HStack(spacing: Chau7Style.Settings.inlineControlSpacing) {
                            newRuleColorPicker
                            addRuleButton
                        }
                    }
                }
            }

            SettingsDivider()

            SettingsSectionHeader(
                L("settings.ai.usageDisplay", "Usage Display"),
                icon: "chart.bar.doc.horizontal",
                anchorID: "aiUsageDisplay"
            )

            SettingsRow(
                L("settings.ai.numberFormat", "Number Format"),
                help: L("settings.ai.numberFormat.help", "Controls token, cost, and dashboard number formatting independently from app language.")
            ) {
                Picker("", selection: $settings.regionalNumberFormat) {
                    ForEach(RegionalNumberFormat.allCases) { format in
                        Text("\(format.displayName) (\(format.example))").tag(format)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(minWidth: 180, idealWidth: 220, maxWidth: 260, alignment: .leading)
                .accessibilityLabel(L("settings.ai.numberFormat", "Number Format"))
            }

            SettingsDivider()

            // LLM Provider (actionable — second)
            LLMSettingsView(settings: settings)

            SettingsDivider()

            // Built-in Detection (read-only reference — last)
            SettingsSectionHeader(
                L("settings.ai.cliDetection", "Built-in AI CLI Detection"),
                icon: "sparkle.magnifyingglass",
                anchorID: "aiDetection"
            )

            Text(L("settings.ai.detectionDescription", "Chau7 automatically detects these AI CLIs and applies appropriate theming:"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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

    private var newRulePatternField: some View {
        TextField(L("settings.ai.patternPlaceholder", "Pattern"), text: $newCustomPattern)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 120, idealWidth: 160, maxWidth: 220)
            .accessibilityLabel(L("settings.ai.patternPlaceholder", "Pattern"))
    }

    private var newRuleNameField: some View {
        TextField(L("settings.ai.namePlaceholder", "Name"), text: $newCustomName)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 120, idealWidth: 150, maxWidth: 220)
            .accessibilityLabel(L("settings.ai.namePlaceholder", "Name"))
    }

    private var newRuleColorPicker: some View {
        Picker("", selection: $newCustomColor) {
            ForEach(TabColor.allCases) { color in
                HStack(spacing: 4) {
                    Circle()
                        .fill(color.color)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text(color.rawValue.capitalized)
                }
                .tag(color)
            }
        }
        .labelsHidden()
        .frame(minWidth: 120, idealWidth: 140, maxWidth: 180)
        .accessibilityLabel(L("settings.ai.color", "Color"))
    }

    private var addRuleButton: some View {
        Button(L("settings.ai.add", "Add")) {
            addNewRule()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(newCustomPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

}

// MARK: - Custom Rule Row

private struct CustomRuleRow: View {
    @Binding var rule: CustomAIDetectionRule
    let onDelete: () -> Void

    var body: some View {
        SettingsRow(rule.displayName.isEmpty ? rule.pattern : rule.displayName) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Chau7Style.Settings.inlineControlSpacing) {
                    ruleColor
                    rulePattern
                    Spacer(minLength: 8)
                    deleteButton
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: Chau7Style.Settings.inlineControlSpacing) {
                        ruleColor
                        rulePattern
                    }
                    deleteButton
                }
            }
        }
    }

    private var ruleColor: some View {
        Circle()
            .fill(TabColor(rawValue: rule.colorName)?.color ?? Color.gray)
            .frame(width: 10, height: 10)
            .accessibilityHidden(true)
    }

    private var rulePattern: some View {
        Text(rule.pattern)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var deleteButton: some View {
        Button {
            onDelete()
        } label: {
            Label(L("settings.ai.removeRule", "Remove rule"), systemImage: "trash")
                .labelStyle(.iconOnly)
                .foregroundStyle(.red)
        }
        .buttonStyle(.borderless)
        .help(L("settings.ai.removeRule", "Remove rule"))
        .accessibilityLabel(L("settings.ai.removeRule", "Remove rule"))
    }
}
