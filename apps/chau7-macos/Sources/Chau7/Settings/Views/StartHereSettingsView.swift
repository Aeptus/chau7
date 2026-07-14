import SwiftUI
import Chau7Core

struct StartHereSettingsView: View {
    var model: AppModel
    @Bindable private var settings = FeatureSettings.shared
    @State private var permissionCenter = PermissionCenterModel()
    private var remote = RemoteControlManager.shared

    init(model: AppModel) {
        self.model = model
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Chau7Style.Settings.pageSectionSpacing) {
            SettingsSectionHeader(
                L("settings.startHere.operationalState", "Operational State"),
                icon: "checklist",
                anchorID: "startHereStatus"
            )
            SettingsStatusGrid(items: operationalItems)

            SettingsDivider()

            SettingsSectionHeader(L("settings.startHere.permissions", "Permissions"), icon: "lock.shield")
            SettingsStatusGrid(items: permissionItems)

            if let warning = model.notificationWarning, !warning.isEmpty {
                SettingsHint(icon: "exclamationmark.triangle", text: warning)
            }

            SettingsDivider()

            SettingsSectionHeader(L("settings.startHere.paths", "Paths"), icon: "folder")
            SettingsStatusGrid(items: pathItems, minimumColumnWidth: 240)

            SettingsHint(
                icon: "info.circle",
                text: L(
                    "settings.startHere.hint",
                    "Use the sidebar or search to change any setting shown here. This page summarizes current state only."
                )
            )
        }
        .onAppear {
            permissionCenter.refresh()
        }
    }

    private var operationalItems: [SettingsStatusItem] {
        [
            SettingsStatusItem(
                id: "launchAtLogin",
                label: L("settings.general.launchAtLogin", "Launch at Login"),
                value: enabledDisabled(settings.launchAtLogin),
                systemImage: "power",
                tone: enabledTone(settings.launchAtLogin)
            ),
            SettingsStatusItem(
                id: "activeProfile",
                label: L("settings.startHere.activeProfile", "Active Profile"),
                value: activeProfileName,
                detail: settings.activeProfile == nil
                    ? L("settings.startHere.defaultProfile.detail", "Using the default settings profile.")
                    : nil,
                systemImage: settings.activeProfile?.icon ?? "house.fill",
                tone: .neutral
            ),
            SettingsStatusItem(
                id: "mcp",
                label: L("settings.mcpControl", "Agent Control"),
                value: enabledDisabled(settings.mcpEnabled),
                detail: settings.mcpEnabled
                    ? String(format: L("settings.startHere.mcp.detail", "Max tabs: %d"), settings.mcpMaxTabs)
                    : nil,
                systemImage: "face.dashed",
                tone: enabledTone(settings.mcpEnabled)
            ),
            SettingsStatusItem(
                id: "remote",
                label: L("settings.remoteControl", "Remote Access"),
                value: remoteStatusValue,
                detail: remoteStatusDetail,
                systemImage: "antenna.radiowaves.left.and.right",
                tone: remoteStatusTone
            ),
            SettingsStatusItem(
                id: "notifications",
                label: L("settings.notifications", "Alerts"),
                value: model.notificationStatus,
                detail: model.notificationWarning,
                systemImage: "bell.badge",
                tone: notificationTone
            )
        ]
    }

    private var permissionItems: [SettingsStatusItem] {
        [
            SettingsStatusItem(
                id: "notificationPermission",
                label: L("settings.productivity.permissions.notifications", "Notifications"),
                value: permissionCenter.notificationPermissionState.localizedLabel,
                systemImage: "bell.badge",
                tone: permissionCenter.notificationPermissionState.isAuthorized ? .enabled : .warning
            ),
            SettingsStatusItem(
                id: "fullDiskAccess",
                label: L("settings.productivity.permissions.fullDiskAccess", "Full Disk Access"),
                value: fullDiskAccessValue,
                detail: fullDiskAccessDetail,
                systemImage: "externaldrive.badge.checkmark",
                tone: fullDiskAccessTone
            ),
            SettingsStatusItem(
                id: "protectedFolders",
                label: L("settings.startHere.protectedFolders", "Protected Folders"),
                value: protectedFoldersValue,
                detail: protectedFoldersDetail,
                systemImage: "folder.badge.gearshape",
                tone: permissionCenter.protectedSnapshots.contains(where: needsUserAction) ? .warning : .neutral
            )
        ]
    }

    private var pathItems: [SettingsStatusItem] {
        [
            SettingsStatusItem(
                id: "defaultDirectory",
                label: L("settings.general.defaultDirectory", "Default Directory"),
                value: settings.defaultStartDirectory.isEmpty ? "~" : settings.defaultStartDirectory,
                systemImage: "folder",
                tone: .neutral
            ),
            SettingsStatusItem(
                id: "eventLogPath",
                label: L("settings.notifications.eventLogPath", "Event Log Path"),
                value: model.logPath,
                systemImage: "doc.text.magnifyingglass",
                tone: .neutral
            )
        ]
    }

    private var activeProfileName: String {
        guard let profile = settings.activeProfile else {
            return L("settings.profileBar.defaultSettings", "Default Settings")
        }
        if profile.name == "Default", profile.icon == "house.fill" {
            return L("settings.profileBar.defaultSettings", "Default Settings")
        }
        return profile.name
    }

    private var remoteStatusValue: String {
        guard settings.isRemoteEnabled else {
            return L("status.disabled", "Disabled")
        }
        return remote.isAgentRunning ? L("status.running", "Running") : L("status.stopped", "Stopped")
    }

    private var remoteStatusDetail: String? {
        if let error = remote.lastError, !error.isEmpty {
            return error
        }
        if let connectedDevice = remote.pairedDevices.first(where: \.isConnected) {
            return String(format: L("settings.remote.connectedDevice", "Connected device: %@"), connectedDevice.name)
        }
        if let sessionStatus = remote.sessionStatus, !sessionStatus.isEmpty {
            return String(format: L("remote.sessionStatus", "Session: %@"), sessionStatus)
        }
        return settings.isRemoteEnabled ? remote.activeRelayURL : nil
    }

    private var remoteStatusTone: SettingsStatusTone {
        guard settings.isRemoteEnabled else { return .disabled }
        if remote.lastError != nil { return .warning }
        return remote.isAgentRunning ? .active : .warning
    }

    private var notificationTone: SettingsStatusTone {
        if model.notificationPermissionState.isAuthorized {
            return model.notificationWarning == nil ? .enabled : .warning
        }
        return .warning
    }

    private var fullDiskAccessValue: String {
        switch permissionCenter.fullDiskAccessStatus {
        case .granted:
            return L("settings.productivity.permissions.fda.granted", "Granted")
        case .denied:
            return L("settings.productivity.permissions.fda.denied", "Denied")
        case .indeterminate:
            return L("settings.productivity.permissions.fda.unknown", "Unknown")
        }
    }

    private var fullDiskAccessDetail: String {
        switch permissionCenter.fullDiskAccessStatus {
        case .granted:
            return L("settings.productivity.permissions.fda.granted.detail", "Child processes (codex, claude, shells) can reach protected folders like ~/Downloads.")
        case .denied:
            return L("settings.productivity.permissions.fda.denied.detail", "Grant Full Disk Access to Chau7 so child processes can reach protected folders.")
        case .indeterminate:
            return L("settings.productivity.permissions.fda.unknown.detail", "Full Disk Access status could not be determined.")
        }
    }

    private var fullDiskAccessTone: SettingsStatusTone {
        switch permissionCenter.fullDiskAccessStatus {
        case .granted:
            return .enabled
        case .denied:
            return .warning
        case .indeterminate:
            return .neutral
        }
    }

    private var protectedFoldersValue: String {
        if permissionCenter.protectedSnapshots.isEmpty {
            return L("settings.startHere.protectedFolders.none", "None tracked")
        }
        let blockedCount = permissionCenter.protectedSnapshots.filter(needsUserAction).count
        if blockedCount == 0 {
            return L("settings.startHere.protectedFolders.ready", "Ready")
        }
        return String(format: L("settings.startHere.protectedFolders.needsAccess", "%d need access"), blockedCount)
    }

    private var protectedFoldersDetail: String? {
        guard !permissionCenter.protectedSnapshots.isEmpty else { return nil }
        return String(
            format: L("settings.startHere.protectedFolders.detail", "%d protected roots tracked"),
            permissionCenter.protectedSnapshots.count
        )
    }

    private func enabledDisabled(_ isEnabled: Bool) -> String {
        isEnabled ? L("status.enabled", "Enabled") : L("status.disabled", "Disabled")
    }

    private func enabledTone(_ isEnabled: Bool) -> SettingsStatusTone {
        isEnabled ? .enabled : .disabled
    }

    private func needsUserAction(_ snapshot: ProtectedPathAccessSnapshot) -> Bool {
        snapshot.recommendedAction != .none
    }
}
