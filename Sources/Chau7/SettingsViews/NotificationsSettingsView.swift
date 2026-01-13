import SwiftUI
import AppKit
import Chau7Core

// MARK: - Notifications Settings

struct NotificationsSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings = FeatureSettings.shared

    private struct TriggerGroup: Identifiable {
        let id: String
        let source: NotificationTriggerSourceInfo
        let triggers: [NotificationTrigger]
    }

    private var notificationTriggerGroups: [TriggerGroup] {
        NotificationTriggerCatalog.sources
            .sorted { $0.sortOrder < $1.sortOrder }
            .compactMap { source in
                let triggers = NotificationTriggerCatalog
                    .triggers(for: source.id)
                    .filter { $0.displayContexts.contains(.settings) }
                guard !triggers.isEmpty else { return nil }
                return TriggerGroup(id: source.id.rawValue, source: source, triggers: triggers)
            }
    }

    private func binding(for trigger: NotificationTrigger) -> Binding<Bool> {
        Binding(
            get: { settings.notificationTriggerState.isEnabled(for: trigger) },
            set: { newValue in
                var state = settings.notificationTriggerState
                state.setEnabled(newValue, for: trigger)
                settings.notificationTriggerState = state
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Status & Permissions
            SettingsSectionHeader(L("settings.notifications.status", "Status & Permissions"), icon: "bell")

            SettingsInfoRow(
                label: L("settings.notifications.status.label", "Status"),
                value: model.notificationStatus,
                monospaced: true
            )

            if let warning = model.notificationWarning {
                SettingsRow(L("settings.notifications.warning", "Warning")) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text(warning)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            SettingsButtonRow(buttons: [
                .init(title: L("settings.notifications.requestPermission", "Request Permission"), icon: "bell.badge") {
                    model.requestNotificationPermission()
                },
                .init(title: L("settings.notifications.systemSettings", "System Settings"), icon: "gear") {
                    model.openNotificationSettings()
                },
                .init(title: L("settings.notifications.sendTest", "Send Test"), icon: "paperplane") {
                    model.sendTestNotification()
                }
            ])

            Divider()
                .padding(.vertical, 8)

            // Notification Filters
            SettingsSectionHeader(L("settings.notifications.filters", "Notification Filters"), icon: "line.3.horizontal.decrease.circle")

            Text(L("settings.notifications.filtersDescription", "Choose which events trigger notifications:"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

            ForEach(notificationTriggerGroups) { group in
                Text(group.source.localizedLabel)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)

                ForEach(group.triggers) { trigger in
                    SettingsToggle(
                        label: trigger.localizedLabel,
                        help: trigger.localizedDescription,
                        isOn: binding(for: trigger)
                    )
                }
            }

            Divider()
                .padding(.vertical, 8)

            // Event Monitoring
            SettingsSectionHeader(L("settings.notifications.eventMonitoring", "Event Monitoring"), icon: "waveform.path.ecg")

            SettingsToggle(
                label: L("settings.notifications.monitorAIEvents", "Monitor AI Events"),
                help: L("settings.notifications.monitorAIEvents.help", "Watch for AI CLI events like task completion, failures, and permission requests"),
                isOn: $model.isMonitoring
            )
            .onChange(of: model.isMonitoring) { _ in
                model.applyMonitoringState()
            }

            SettingsTextField(
                label: L("settings.notifications.eventLogPath", "Event Log Path"),
                help: L("settings.notifications.eventLogPath.help", "Path to the AI event log file"),
                placeholder: "~/.ai-events.log",
                text: $model.logPath,
                width: 280,
                monospaced: true,
                onSubmit: { model.restartTailer() }
            )

            SettingsButtonRow(buttons: [
                .init(title: L("settings.notifications.restartMonitor", "Restart Monitor"), icon: "arrow.clockwise") {
                    model.restartTailer()
                },
                .init(title: L("settings.notifications.revealInFinder", "Reveal in Finder"), icon: "folder") {
                    model.revealLogInFinder()
                }
            ])
        }
    }
}
