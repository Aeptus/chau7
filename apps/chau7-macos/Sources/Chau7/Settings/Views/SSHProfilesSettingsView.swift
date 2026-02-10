import SwiftUI
import Chau7Core

struct SSHProfilesSettingsView: View {
    @ObservedObject private var manager = SharedSSHProfileManager.shared
    @ObservedObject private var sshManager = SSHConnectionManager.shared
    @State private var showImportConfirmation = false
    @State private var selectedEntry: SSHConfigEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSectionHeader(
                L("settings.ssh.sync", "SSH Config Sync"),
                icon: "link"
            )

            statusRow

            SettingsSectionHeader(
                L("settings.ssh.entries", "SSH Config Entries"),
                icon: "list.bullet"
            )

            if manager.configEntries.isEmpty {
                emptyStateView
            } else {
                entryListView
            }

            SettingsSectionHeader(
                L("settings.ssh.actions", "Actions"),
                icon: "arrow.left.arrow.right"
            )

            actionButtons
        }
    }

    // MARK: - Status Row

    private var statusRow: some View {
        SettingsRow(L("settings.ssh.fileWatch", "File Watch")) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(manager.isWatching ? .green : .red)
                        .frame(width: 8, height: 8)
                    Text(manager.isWatching ? L("ssh.watch.active", "Watching ~/.ssh/config") : L("ssh.watch.inactive", "Not watching"))
                        .font(.body)
                }
                if let syncTime = manager.lastSyncTime {
                    Text(String(format: L("ssh.lastSync", "Last sync: %@"), syncTime.formatted(date: .abbreviated, time: .shortened)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.title)
                .foregroundStyle(.secondary)
            Text(L("No SSH config entries found", "No SSH config entries found"))
                .font(.body)
                .foregroundStyle(.secondary)
            Text(L("Add hosts to ~/.ssh/config to see them here.", "Add hosts to ~/.ssh/config to see them here."))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    // MARK: - Entry List

    private var entryListView: some View {
        VStack(spacing: 4) {
            ForEach(manager.configEntries) { entry in
                entryRow(entry)
            }
        }
    }

    private func entryRow(_ entry: SSHConfigEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.host.contains("*") ? "globe" : "server.rack")
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.host)
                    .font(.body)
                    .fontWeight(.medium)
                Text(entry.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                let connection = manager.importEntry(entry)
                sshManager.addConnection(connection)
            } label: {
                Label(L("Import", "Import"), systemImage: "square.and.arrow.down")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(entry.host.contains("*"))
            .accessibilityLabel(String(format: L("ssh.importHost", "Import %@ to Chau7"), entry.host))
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button {
                manager.loadSSHConfig()
            } label: {
                Label(L("Refresh", "Refresh"), systemImage: "arrow.clockwise")
            }
            .accessibilityLabel(L("Refresh SSH config", "Refresh SSH config"))

            Button {
                showImportConfirmation = true
            } label: {
                Label(L("Import All", "Import All"), systemImage: "square.and.arrow.down.on.square")
            }
            .disabled(manager.configEntries.isEmpty)
            .accessibilityLabel(L("Import all SSH config entries", "Import all SSH config entries"))
            .alert("Import All Entries?", isPresented: $showImportConfirmation) {
                Button(L("Import", "Import"), role: .none) {
                    let connections = manager.importAllEntries()
                    for connection in connections {
                        sshManager.addConnection(connection)
                    }
                }
                Button(L("Cancel", "Cancel"), role: .cancel) {}
            } message: {
                Text(
                    String(
                        format: L("ssh.importAll.confirm", "This will import %d SSH hosts into Chau7."),
                        manager.configEntries.filter { !$0.host.contains("*") }.count
                    )
                )
            }

            Spacer()

            Button {
                exportAllConnections()
            } label: {
                Label(L("Export to SSH Config", "Export to SSH Config"), systemImage: "square.and.arrow.up")
            }
            .disabled(sshManager.connections.isEmpty)
            .accessibilityLabel(L("Export Chau7 connections to SSH config", "Export Chau7 connections to SSH config"))
        }
    }

    // MARK: - Export

    private func exportAllConnections() {
        for connection in sshManager.connections {
            let entry = manager.exportConnection(connection)
            // Only append if not already in config
            let existingHosts = Set(manager.configEntries.map { $0.host })
            if !existingHosts.contains(entry.host) {
                manager.appendToSSHConfig(entry)
            }
        }
        manager.loadSSHConfig()
    }
}
