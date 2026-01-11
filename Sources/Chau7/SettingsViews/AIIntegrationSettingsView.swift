import SwiftUI
import AppKit

// MARK: - AI Integration Settings

struct AIIntegrationSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings = FeatureSettings.shared
    @State private var newCustomPattern: String = ""
    @State private var newCustomName: String = ""
    @State private var newCustomColor: TabColor = .gray

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Detection
            SettingsSectionHeader("AI CLI Detection", icon: "sparkle.magnifyingglass")

            Text("Chau7 automatically detects these AI CLIs and applies appropriate theming:")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                SettingsDetectionRow(name: "Claude Code", commands: "claude, claude-code", color: .purple)
                SettingsDetectionRow(name: "OpenAI Codex", commands: "codex, codex-cli", color: .green)
                SettingsDetectionRow(name: "Gemini", commands: "gemini", color: .blue)
                SettingsDetectionRow(name: "ChatGPT", commands: "chatgpt, gpt", color: .green)
                SettingsDetectionRow(name: "GitHub Copilot", commands: "gh copilot, copilot", color: .orange)
                SettingsDetectionRow(name: "Aider", commands: "aider, aider-chat", color: .pink)
                SettingsDetectionRow(name: "Cursor", commands: "cursor", color: .teal)
            }
            .padding(8)
            .background(Color.secondary.opacity(0.05))
            .cornerRadius(8)

            Divider()
                .padding(.vertical, 8)

            SettingsSectionHeader("Custom Detection Rules", icon: "slider.horizontal.3")

            Text("Add command or output patterns to tag custom AI CLIs.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                ForEach($settings.customAIDetectionRules) { $rule in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Pattern")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                TextField("mycli, /opt/ai/bin", text: $rule.pattern)
                                    .textFieldStyle(.roundedBorder)
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Display Name")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                TextField("My AI", text: $rule.displayName)
                                    .textFieldStyle(.roundedBorder)
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Color")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Picker("Color", selection: $rule.colorName) {
                                    ForEach(TabColor.allCases) { color in
                                        Text(color.rawValue.capitalized).tag(color.rawValue)
                                    }
                                }
                                .frame(width: 120)
                            }

                            Button {
                                if let index = settings.customAIDetectionRules.firstIndex(where: { $0.id == rule.id }) {
                                    settings.customAIDetectionRules.remove(at: index)
                                }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove rule")
                        }
                    }
                    .padding(8)
                    .background(Color.secondary.opacity(0.05))
                    .cornerRadius(8)
                }

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Pattern")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("cli-name", text: $newCustomPattern)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Display Name")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("Custom AI", text: $newCustomName)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Color")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("Color", selection: $newCustomColor) {
                            ForEach(TabColor.allCases) { color in
                                Text(color.rawValue.capitalized).tag(color)
                            }
                        }
                        .frame(width: 120)
                    }

                    Button("Add") {
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
                    .disabled(newCustomPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            Divider()
                .padding(.vertical, 8)

            // Notifications
            SettingsSectionHeader("Notifications", icon: "bell")

            SettingsInfoRow(label: "Status", value: model.notificationStatus, monospaced: true)

            if let warning = model.notificationWarning {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                .padding(.vertical, 4)
            }

            SettingsButtonRow(buttons: [
                .init(title: "Request Permission", icon: "bell.badge") {
                    model.requestNotificationPermission()
                },
                .init(title: "System Settings", icon: "gear") {
                    model.openNotificationSettings()
                },
                .init(title: "Send Test", icon: "paperplane") {
                    model.sendTestNotification()
                }
            ])

            Divider()
                .padding(.vertical, 8)

            // Notification Filters (NEW)
            SettingsSectionHeader("Notification Filters", icon: "line.3.horizontal.decrease.circle")

            Text("Choose which events trigger notifications:")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                NotificationFilterToggle(
                    label: "Task Finished",
                    help: "Notify when an AI task completes successfully",
                    isOn: $settings.notificationFilters.taskFinished
                )

                NotificationFilterToggle(
                    label: "Task Failed",
                    help: "Notify when an AI task fails or encounters an error",
                    isOn: $settings.notificationFilters.taskFailed
                )

                NotificationFilterToggle(
                    label: "Needs Validation",
                    help: "Notify when an AI task needs human review or approval",
                    isOn: $settings.notificationFilters.needsValidation
                )

                NotificationFilterToggle(
                    label: "Permission Request",
                    help: "Notify when a tool requires permission to proceed",
                    isOn: $settings.notificationFilters.permissionRequest
                )

                NotificationFilterToggle(
                    label: "Tool Complete",
                    help: "Notify when individual tools complete execution",
                    isOn: $settings.notificationFilters.toolComplete
                )

                NotificationFilterToggle(
                    label: "Session End",
                    help: "Notify when an AI session terminates",
                    isOn: $settings.notificationFilters.sessionEnd
                )

                NotificationFilterToggle(
                    label: "Command Idle",
                    help: "Notify when terminal becomes idle after command execution",
                    isOn: $settings.notificationFilters.commandIdle
                )
            }
            .padding(8)
            .background(Color.secondary.opacity(0.05))
            .cornerRadius(8)

            Divider()
                .padding(.vertical, 8)

            // Event Monitoring
            SettingsSectionHeader("Event Monitoring", icon: "waveform.path.ecg")

            SettingsToggle(
                label: "Monitor AI Events",
                help: "Watch for AI CLI events like task completion, failures, and permission requests",
                isOn: $model.isMonitoring
            )
            .onChange(of: model.isMonitoring) { _ in
                model.applyMonitoringState()
            }

            SettingsTextField(
                label: "Event Log Path",
                help: "Path to the AI event log file",
                placeholder: "~/.ai-events.log",
                text: $model.logPath,
                width: 280,
                monospaced: true,
                onSubmit: { model.restartTailer() }
            )

            SettingsButtonRow(buttons: [
                .init(title: "Restart Monitor", icon: "arrow.clockwise") {
                    model.restartTailer()
                },
                .init(title: "Reveal in Finder", icon: "folder") {
                    model.revealLogInFinder()
                }
            ])
        }
    }
}

// MARK: - Notification Filter Toggle

struct NotificationFilterToggle: View {
    let label: String
    let help: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 13))
                Text(help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}
