import SwiftUI

// MARK: - Logs Settings

struct LogsSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // History Logs
            SettingsSectionHeader("History Logs", icon: "clock.arrow.circlepath")

            SettingsToggle(
                label: "Monitor History Logs",
                help: "Watch AI CLI history files for session activity and idle detection",
                isOn: $model.isIdleMonitoring
            )
            .onChange(of: model.isIdleMonitoring) { _ in
                model.applyIdleMonitoringState()
            }

            SettingsTextField(
                label: "Idle Seconds",
                help: "Seconds of inactivity before sending idle notification",
                placeholder: "300",
                text: $model.idleSecondsText,
                width: 80,
                onSubmit: { model.restartIdleMonitors() }
            )

            SettingsTextField(
                label: "Stale Seconds",
                help: "Seconds before marking a session as closed",
                placeholder: "3600",
                text: $model.staleSecondsText,
                width: 80,
                onSubmit: { model.restartIdleMonitors() }
            )

            SettingsTextField(
                label: "Codex History Path",
                help: nil,
                placeholder: "~/.codex/history.jsonl",
                text: $model.codexHistoryPath,
                width: 300,
                monospaced: true,
                onSubmit: { model.restartIdleMonitors() }
            )

            SettingsTextField(
                label: "Claude History Path",
                help: nil,
                placeholder: "~/.claude/history.jsonl",
                text: $model.claudeHistoryPath,
                width: 300,
                monospaced: true,
                onSubmit: { model.restartIdleMonitors() }
            )

            SettingsButtonRow(buttons: [
                .init(title: "Restart Monitors", icon: "arrow.clockwise") {
                    model.restartIdleMonitors()
                },
                .init(title: "Clear History", icon: "trash") {
                    model.clearHistory()
                }
            ])

            Divider()
                .padding(.vertical, 8)

            // Terminal Logs
            SettingsSectionHeader("Terminal Logs", icon: "doc.text")

            SettingsToggle(
                label: "Monitor Terminal Logs",
                help: "Watch PTY wrapper output files for terminal activity",
                isOn: $model.isTerminalMonitoring
            )
            .onChange(of: model.isTerminalMonitoring) { _ in
                model.applyTerminalMonitoringState()
            }

            SettingsToggle(
                label: "Normalize Output",
                help: "Strip ANSI codes and control characters from log display",
                isOn: $model.isTerminalNormalize
            )
            .onChange(of: model.isTerminalNormalize) { _ in
                model.restartTerminalMonitors()
            }

            SettingsToggle(
                label: "Render ANSI Styling",
                help: "Display ANSI colors and formatting in log viewer",
                isOn: $model.isTerminalAnsi
            )

            SettingsTextField(
                label: "Codex Terminal Log",
                help: nil,
                placeholder: "~/Library/Logs/Chau7/codex-pty.log",
                text: $model.codexTerminalPath,
                width: 300,
                monospaced: true,
                onSubmit: { model.restartTerminalMonitors() }
            )

            SettingsTextField(
                label: "Claude Terminal Log",
                help: nil,
                placeholder: "~/Library/Logs/Chau7/claude-pty.log",
                text: $model.claudeTerminalPath,
                width: 300,
                monospaced: true,
                onSubmit: { model.restartTerminalMonitors() }
            )

            SettingsButtonRow(buttons: [
                .init(title: "Restart Monitors", icon: "arrow.clockwise") {
                    model.restartTerminalMonitors()
                },
                .init(title: "Reload Last Lines", icon: "arrow.clockwise.circle") {
                    model.reloadTerminalPrefill()
                },
                .init(title: "Clear Logs", icon: "trash") {
                    model.clearTerminalLogs()
                }
            ])

            Divider()
                .padding(.vertical, 8)

            // Sessions
            SettingsSectionHeader("Active Sessions", icon: "person.2")

            if model.sessionStatuses.isEmpty {
                Text("No sessions tracked yet.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.sessionStatuses.sorted(by: { $0.lastSeen > $1.lastSeen })) { status in
                        HStack {
                            Circle()
                                .fill(status.state == .active ? Color.green : Color.gray)
                                .frame(width: 8, height: 8)
                            Text("\(status.tool)")
                                .fontWeight(.medium)
                            Text(String(status.sessionId.prefix(8)))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(status.state.rawValue.uppercased())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }
}
