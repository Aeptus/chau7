import SwiftUI
import AppKit
import Chau7Core

// MARK: - AI Integration Settings

struct AIIntegrationSettingsView: View {
    @ObservedObject private var settings = FeatureSettings.shared
    let overlayModel: OverlayTabsModel?
    @State private var newCustomPattern: String = ""
    @State private var newCustomName: String = ""
    @State private var newCustomColor: TabColor = .gray

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Detection
            SettingsSectionHeader(L("settings.ai.cliDetection", "AI CLI Detection"), icon: "sparkle.magnifyingglass")

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

            Divider()
                .padding(.vertical, 8)

            // RTK Integration
            SettingsSectionHeader(L("settings.ai.rtk", "RTK Integration"), icon: "bolt.fill")

            SettingsToggle(
                label: L("settings.ai.rtk.enabled", "Enable RTK"),
                help: L(
                    "settings.ai.rtk.enabledHelp",
                    "When enabled, the RTK prefix is prepended to terminal commands."
                ),
                isOn: Binding(
                    get: { settings.isRTKEnabled },
                    set: { settings.isRTKEnabled = $0 }
                )
            )

            SettingsTextField(
                label: L("settings.ai.rtk.prefix", "RTK Prefix"),
                help: L(
                    "settings.ai.rtk.prefixHelp",
                    "Prefix text to prepend (supports per-tab overrides)."
                ),
                placeholder: "/think",
                text: Binding(
                    get: { settings.rtkPrefix },
                    set: { settings.rtkPrefix = $0 }
                ),
                width: 220,
                monospaced: true
            )

            if let overlayModel {
                let tabRows = activeTabRows(from: overlayModel.tabs)

                if !tabRows.isEmpty {
                    SettingsSectionHeader(L("settings.ai.rtk.tabs", "Tab-by-tab RTK"), icon: "list.bullet")

                            SettingsRow(L("settings.ai.rtk.applyAll", "Apply to all open tabs")) {
                                HStack(spacing: 8) {
                                    Button(L("settings.ai.rtk.enableAll", "Enable all")) {
                                        applyRTK(to: tabRows.map(\.id), enabled: true)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)

                                    Button(L("settings.ai.rtk.disableAll", "Disable all")) {
                                        applyRTK(to: tabRows.map(\.id), enabled: false)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)

                            Button(L("settings.ai.rtk.clearAllOverrides", "Use global on all")) {
                                clearRTKOverrides()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    ForEach(tabRows) { row in
                        SettingsRow(
                            row.tabTitle,
                            help: row.hasOverride
                                ? L("settings.ai.rtk.tabOverride", "Overrides global RTK setting for this tab.")
                                : L("settings.ai.rtk.tabInherit", "Uses global RTK setting.")
                        ) {
                            HStack(spacing: 12) {
                                Toggle("", isOn: Binding(
                                    get: { settings.isRTKEnabled(forTabIdentifier: row.id) },
                                    set: { value in
                                        if value == settings.isRTKEnabled {
                                            settings.clearRTKOverride(forTabIdentifier: row.id)
                                        } else {
                                            settings.setRTKOverride(value, forTabIdentifier: row.id)
                                        }
                                    }
                                ))
                                .toggleStyle(.switch)
                                .labelsHidden()

                                if row.hasOverride {
                                    Button(L("settings.ai.rtk.clearOverride", "Use global")) {
                                        settings.clearRTKOverride(forTabIdentifier: row.id)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                } else {
                    SettingsRow(L("settings.ai.rtk.tabsUnavailable", "No active tabs")) {
                        Text(L("settings.ai.rtk.waitForTabs", "Open a tab to enable per-tab settings."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()
                .padding(.vertical, 8)

            // Custom Rules
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

            // LLM Provider (embedded)
            LLMSettingsView(settings: settings)
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

    private func activeTabRows(from overlayTabs: [OverlayTab]) -> [RTKTabRow] {
        overlayTabs.compactMap { tab -> RTKTabRow? in
            guard let sessionIdentifier = tab.session?.tabIdentifier else { return nil }
            let override = settings.rtkOverride(forTabIdentifier: sessionIdentifier)
            return RTKTabRow(
                id: sessionIdentifier,
                tabTitle: tab.displayTitle.isEmpty ? "Tab" : tab.displayTitle,
                hasOverride: override != nil
            )
        }
        .sorted { lhs, rhs in
            lhs.tabTitle.localizedCaseInsensitiveCompare(rhs.tabTitle) == .orderedAscending
        }
    }

    private func applyRTK(to tabIDs: [String], enabled: Bool) {
        let uniqueTabIDs = Set(tabIDs)
        uniqueTabIDs.forEach { tabID in
            settings.setRTKOverride(enabled, forTabIdentifier: tabID)
        }
    }

    private func clearRTKOverrides() {
        guard let overlayModel else { return }
        for tab in overlayModel.tabs {
            guard let sessionIdentifier = tab.session?.tabIdentifier else { continue }
            settings.clearRTKOverride(forTabIdentifier: sessionIdentifier)
        }
    }

    private struct RTKTabRow: Identifiable {
        let id: String
        let tabTitle: String
        let hasOverride: Bool
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
