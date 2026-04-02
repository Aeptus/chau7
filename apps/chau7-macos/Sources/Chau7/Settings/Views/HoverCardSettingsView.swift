import SwiftUI

struct HoverCardSettingsView: View {
    @Bindable private var settings = FeatureSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSectionHeader(L("settings.hoverCard.sections", "Visible Sections"), icon: "text.bubble")

            SettingsDescription(L("settings.hoverCard.sections.description", "Choose which information sections appear when hovering over a tab."))

            SettingsToggle(
                label: L("settings.hoverCard.directory", "Working Directory"),
                help: L("settings.hoverCard.directory.help", "Show the tab's current working directory"),
                isOn: $settings.hoverCardShowDirectory
            )

            SettingsToggle(
                label: L("settings.hoverCard.gitBranch", "Git Branch"),
                help: L("settings.hoverCard.gitBranch.help", "Show the current git branch name"),
                isOn: $settings.hoverCardShowGitBranch
            )

            SettingsToggle(
                label: L("settings.hoverCard.lastCommand", "Last Command"),
                help: L("settings.hoverCard.lastCommand.help", "Show the last executed command with exit status and duration"),
                isOn: $settings.hoverCardShowLastCommand
            )

            SettingsToggle(
                label: L("settings.hoverCard.aiSession", "AI Session Summary"),
                help: L("settings.hoverCard.aiSession.help", "Show active AI session details: provider, tokens, cost, and top tool calls"),
                isOn: $settings.hoverCardShowAISession
            )

            SettingsToggle(
                label: L("settings.hoverCard.repoStats", "Repository Stats"),
                help: L("settings.hoverCard.repoStats.help", "Show aggregated repo metrics: total runs, tokens, cost, and commands"),
                isOn: $settings.hoverCardShowRepoStats
            )

            SettingsToggle(
                label: L("settings.hoverCard.conflicts", "File Conflicts"),
                help: L("settings.hoverCard.conflicts.help", "Show warnings when multiple tabs modify the same file"),
                isOn: $settings.hoverCardShowConflicts
            )

            SettingsToggle(
                label: L("settings.hoverCard.processes", "Process Info"),
                help: L("settings.hoverCard.processes.help", "Show running child processes with CPU and memory usage"),
                isOn: $settings.hoverCardShowProcesses
            )

            SettingsToggle(
                label: L("settings.hoverCard.devServer", "Dev Server"),
                help: L("settings.hoverCard.devServer.help", "Show detected dev server name, port, and URL"),
                isOn: $settings.hoverCardShowDevServer
            )

            SettingsToggle(
                label: L("settings.hoverCard.notificationState", "Notification State"),
                help: L("settings.hoverCard.notificationState.help", "Show the current notification style applied to the tab"),
                isOn: $settings.hoverCardShowNotificationState
            )

            SettingsToggle(
                label: L("settings.hoverCard.tokenOptimization", "Token Optimization"),
                help: L("settings.hoverCard.tokenOptimization.help", "Show CTO status and toggle"),
                isOn: $settings.hoverCardShowTokenOptimization
            )

            SettingsToggle(
                label: L("settings.hoverCard.shellIntegration", "Shell Integration"),
                help: L("settings.hoverCard.shellIntegration.help", "Show whether shell integration is active or using heuristics"),
                isOn: $settings.hoverCardShowShellIntegration
            )

            SettingsToggle(
                label: L("settings.hoverCard.broadcast", "Broadcast Status"),
                help: L("settings.hoverCard.broadcast.help", "Show whether the tab is included in broadcast mode"),
                isOn: $settings.hoverCardShowBroadcast
            )

            SettingsToggle(
                label: L("settings.hoverCard.footer", "Footer"),
                help: L("settings.hoverCard.footer.help", "Show creation time, session ID, and bookmark count"),
                isOn: $settings.hoverCardShowFooter
            )
        }
    }
}
