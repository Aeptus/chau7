import SwiftUI

// MARK: - Logs Settings

struct LogsSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // History Logs
            SettingsSectionHeader(L("settings.logs.historyLogs", "History Logs"), icon: "clock.arrow.circlepath")

            SettingsToggle(
                label: L("settings.logs.monitorHistoryLogs", "Monitor History Logs"),
                help: L("settings.logs.monitorHistoryLogs.help", "Watch AI CLI history files for session activity and idle detection"),
                isOn: $model.isIdleMonitoring
            )
            .onChange(of: model.isIdleMonitoring) { _ in
                model.applyIdleMonitoringState()
            }

            SettingsTextField(
                label: L("settings.logs.idleSeconds", "Idle Seconds"),
                help: L("settings.logs.idleSeconds.help", "Seconds of inactivity before sending idle notification"),
                placeholder: "300",
                text: $model.idleSecondsText,
                width: 80,
                onSubmit: { model.restartIdleMonitors() }
            )

            SettingsTextField(
                label: L("settings.logs.staleSeconds", "Stale Seconds"),
                help: L("settings.logs.staleSeconds.help", "Seconds before marking a session as closed"),
                placeholder: "3600",
                text: $model.staleSecondsText,
                width: 80,
                onSubmit: { model.restartIdleMonitors() }
            )

            SettingsTextField(
                label: L("settings.logs.codexHistoryPath", "Codex History Path"),
                help: L("settings.logs.codexHistoryPath.help", "Path to the OpenAI Codex history file"),
                placeholder: "~/.codex/history.jsonl",
                text: $model.codexHistoryPath,
                width: 300,
                monospaced: true,
                onSubmit: { model.restartIdleMonitors() }
            )

            SettingsTextField(
                label: L("settings.logs.claudeHistoryPath", "Claude History Path"),
                help: L("settings.logs.claudeHistoryPath.help", "Path to the Claude Code history file"),
                placeholder: "~/.claude/history.jsonl",
                text: $model.claudeHistoryPath,
                width: 300,
                monospaced: true,
                onSubmit: { model.restartIdleMonitors() }
            )

            SettingsButtonRow(buttons: [
                .init(title: L("settings.logs.restartMonitors", "Restart Monitors"), icon: "arrow.clockwise") {
                    model.restartIdleMonitors()
                },
                .init(title: L("settings.logs.clearHistory", "Clear History"), icon: "trash") {
                    model.clearHistory()
                }
            ])

            Divider()
                .padding(.vertical, 8)

            // Terminal Logs
            SettingsSectionHeader(L("settings.logs.terminalLogs", "Terminal Logs"), icon: "doc.text")

            SettingsToggle(
                label: L("settings.logs.monitorTerminalLogs", "Monitor Terminal Logs"),
                help: L("settings.logs.monitorTerminalLogs.help", "Watch PTY wrapper output files for terminal activity"),
                isOn: $model.isTerminalMonitoring
            )
            .onChange(of: model.isTerminalMonitoring) { _ in
                model.applyTerminalMonitoringState()
            }

            SettingsToggle(
                label: L("settings.logs.normalizeOutput", "Normalize Output"),
                help: L("settings.logs.normalizeOutput.help", "Strip ANSI codes and control characters from log display"),
                isOn: $model.isTerminalNormalize
            )
            .onChange(of: model.isTerminalNormalize) { _ in
                model.restartTerminalMonitors()
            }

            SettingsToggle(
                label: L("settings.logs.renderAnsiStyling", "Render ANSI Styling"),
                help: L("settings.logs.renderAnsiStyling.help", "Display ANSI colors and formatting in log viewer"),
                isOn: $model.isTerminalAnsi
            )

            SettingsTextField(
                label: L("settings.logs.codexTerminalLog", "Codex Terminal Log"),
                help: L("settings.logs.codexTerminalLog.help", "Path to the Codex PTY wrapper log file"),
                placeholder: "~/Library/Logs/Chau7/codex-pty.log",
                text: $model.codexTerminalPath,
                width: 300,
                monospaced: true,
                onSubmit: { model.restartTerminalMonitors() }
            )

            SettingsTextField(
                label: L("settings.logs.claudeTerminalLog", "Claude Terminal Log"),
                help: L("settings.logs.claudeTerminalLog.help", "Path to the Claude PTY wrapper log file"),
                placeholder: "~/Library/Logs/Chau7/claude-pty.log",
                text: $model.claudeTerminalPath,
                width: 300,
                monospaced: true,
                onSubmit: { model.restartTerminalMonitors() }
            )

            SettingsButtonRow(buttons: [
                .init(title: L("settings.logs.restartMonitors", "Restart Monitors"), icon: "arrow.clockwise") {
                    model.restartTerminalMonitors()
                },
                .init(title: L("settings.logs.reloadLastLines", "Reload Last Lines"), icon: "arrow.clockwise.circle") {
                    model.reloadTerminalPrefill()
                },
                .init(title: L("settings.logs.clearLogs", "Clear Logs"), icon: "trash") {
                    model.clearTerminalLogs()
                }
            ])

            Divider()
                .padding(.vertical, 8)

            // Sessions
            SettingsSectionHeader(L("settings.logs.activeSessions", "Active Sessions"), icon: "person.2")

            if model.sessionStatuses.isEmpty {
                Text(L("settings.logs.noSessions", "No sessions tracked yet."))
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
