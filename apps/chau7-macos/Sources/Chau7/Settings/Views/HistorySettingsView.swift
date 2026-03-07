import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - History Settings

struct HistorySettingsView: View {
    @ObservedObject private var settings = FeatureSettings.shared
    @State private var totalRecords = 0
    @State private var databaseSize = ""
    @State private var showClearConfirmation = false
    @State private var showClearOlderConfirmation = false
    @State private var clearOlderDays = 30
    @State private var showExportSheet = false
    @State private var showImportSheet = false
    @State private var importError: String?
    @State private var maxRecordsValue: Double = 50000
    @State private var statusMessage: String?
    @State private var persistentHistoryEnabled: Bool = UserDefaults.standard.bool(forKey: "feature.persistentHistory")

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Persistent History Toggle
            SettingsSectionHeader(
                L("settings.history.persistent", "Persistent History"),
                icon: "clock.arrow.circlepath"
            )

            SettingsRow(
                L("settings.history.enable", "Enable Persistent History"),
                help: L("settings.history.enable.help", "Save command history to disk so it persists across app restarts")
            ) {
                Toggle("", isOn: $persistentHistoryEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .onChange(of: persistentHistoryEnabled) { newValue in
                        UserDefaults.standard.set(newValue, forKey: "feature.persistentHistory")
                    }
            }

            Divider()
                .padding(.vertical, 8)

            // Capacity
            SettingsSectionHeader(
                L("settings.history.capacity", "Capacity"),
                icon: "externaldrive"
            )

            SettingsRow(
                L("settings.history.maxRecords", "Maximum Records"),
                help: L("settings.history.maxRecords.help", "Maximum number of commands to store (10,000 - 100,000)")
            ) {
                VStack(alignment: .leading, spacing: 4) {
                    Slider(value: $maxRecordsValue, in: 10000 ... 100_000, step: 5000) {
                        EmptyView()
                    }
                    .frame(maxWidth: 280)
                    .onChange(of: maxRecordsValue) { newValue in
                        let intValue = Int(newValue)
                        PersistentHistoryStore.shared.maxRecords = intValue
                        UserDefaults.standard.set(intValue, forKey: "history.maxRecords")
                    }
                    Text(
                        String(
                            format: L("settings.history.recordsCount", "%@ records"),
                            Int(maxRecordsValue).formatted()
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Divider()
                .padding(.vertical, 8)

            // Statistics
            SettingsSectionHeader(
                L("settings.history.stats", "Statistics"),
                icon: "chart.bar"
            )

            SettingsRow(L("settings.history.totalRecords", "Total Records")) {
                Text(totalRecords.formatted())
                    .font(.system(.body, design: .monospaced))
            }

            SettingsRow(L("settings.history.databaseSize", "Database Size")) {
                Text(databaseSize)
                    .font(.system(.body, design: .monospaced))
            }

            if let msg = statusMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.green)
                    .padding(.leading, 4)
            }

            Divider()
                .padding(.vertical, 8)

            // Import / Export
            SettingsSectionHeader(
                L("settings.history.importExport", "Import / Export"),
                icon: "arrow.left.arrow.right"
            )

            HStack(spacing: 12) {
                Button(L("settings.history.export", "Export History...")) {
                    exportHistory()
                }
                .buttonStyle(.bordered)

                Button(L("settings.history.import", "Import History...")) {
                    importHistory()
                }
                .buttonStyle(.bordered)
            }

            if let err = importError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Divider()
                .padding(.vertical, 8)

            // Danger Zone
            SettingsSectionHeader(
                L("settings.history.maintenance", "Maintenance"),
                icon: "trash"
            )

            HStack(spacing: 12) {
                Button(L("settings.history.clearOlder", "Clear Older Than...")) {
                    showClearOlderConfirmation = true
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) {
                    showClearConfirmation = true
                } label: {
                    Text(L("settings.history.clearAll", "Clear All History"))
                }
                .buttonStyle(.bordered)
            }

            // Clear older than confirmation
            .alert(
                L("settings.history.clearOlder.title", "Clear Old History"),
                isPresented: $showClearOlderConfirmation
            ) {
                TextField(L("Days", "Days"), value: $clearOlderDays, format: .number)
                Button(L("settings.history.clearOlder.confirm", "Clear"), role: .destructive) {
                    PersistentHistoryStore.shared.clearOlderThan(days: clearOlderDays)
                    refreshStats()
                    statusMessage = "Cleared history older than \(clearOlderDays) days"
                    clearStatusAfterDelay()
                }
                Button(L("settings.history.cancel", "Cancel"), role: .cancel) {}
            } message: {
                Text(L("settings.history.clearOlder.message", "Enter the number of days. Records older than this will be permanently deleted."))
            }

            // Clear all confirmation
            .alert(
                L("settings.history.clearAll.title", "Clear All History?"),
                isPresented: $showClearConfirmation
            ) {
                Button(L("settings.history.clearAll.confirm", "Clear All"), role: .destructive) {
                    PersistentHistoryStore.shared.clearAll()
                    refreshStats()
                    statusMessage = "All history cleared"
                    clearStatusAfterDelay()
                }
                Button(L("settings.history.cancel", "Cancel"), role: .cancel) {}
            } message: {
                Text(L("settings.history.clearAll.message", "This will permanently delete all stored command history. This action cannot be undone."))
            }
        }
        .onAppear {
            refreshStats()
            let stored = UserDefaults.standard.integer(forKey: "history.maxRecords")
            maxRecordsValue = Double(max(10000, min(stored > 0 ? stored : 50000, 100_000)))
        }
    }

    // MARK: - Helpers

    private func refreshStats() {
        totalRecords = PersistentHistoryStore.shared.totalCount()
        let bytes = PersistentHistoryStore.shared.databaseSizeBytes()
        databaseSize = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func clearStatusAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            statusMessage = nil
        }
    }

    private func exportHistory() {
        guard let data = PersistentHistoryStore.shared.exportJSON() else {
            importError = "Failed to export history"
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.json]
        panel.nameFieldStringValue = "chau7-history.json"
        panel.title = "Export Command History"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try data.write(to: url)
                statusMessage = "Exported \(totalRecords) records"
                clearStatusAfterDelay()
            } catch {
                importError = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    private func importHistory() {
        importError = nil
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.json]
        panel.allowsMultipleSelection = false
        panel.title = "Import Command History"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                let data = try Data(contentsOf: url)
                let count = PersistentHistoryStore.shared.importJSON(data)
                if count > 0 {
                    statusMessage = "Imported \(count) records"
                    clearStatusAfterDelay()
                    refreshStats()
                } else {
                    importError = "No records found in the file or invalid format"
                }
            } catch {
                importError = "Import failed: \(error.localizedDescription)"
            }
        }
    }
}
